"""The per-host Manager: one process serving every project in the shared backlog whose
worker_manager is ours.

Discovers projects from the `projects` table, clones each on demand under clones_dir,
and runs a per-project Manager (reusing all its spawn/reconcile/reap logic) over a SINGLE
shared backlog adapter. A host-wide slot budget (max_slots) bounds live Supabase stacks:
hot projects keep warm pools (counted permanently); cold projects provision a slot per
card from the leftover budget and tear it down after.

Deterministic and non-AI, like the single-project Manager. One process per host, guarded
by a lockfile.
"""
from __future__ import annotations

import os
import signal
import subprocess
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

from .backlog.patch import PatchAdapter
from .config import HostConfig, Manifest
from .manager import Manager, _pid_alive, _slug
from .models import ProjectRow


class HostManager:
    def __init__(
        self,
        host: HostConfig,
        *,
        poll_interval: int = 300,
        reconcile_interval: int = 15,
        grace_seconds: int = 120,
        state_dir: Path | None = None,
    ):
        self.host = host
        self.poll_interval = poll_interval
        self.reconcile_interval = min(reconcile_interval, poll_interval)
        self.grace_seconds = grace_seconds
        self.adapter = PatchAdapter.from_host(host)
        self.state_dir = (state_dir or Path("state") / "host").resolve()
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.lockfile = self.state_dir / "host.lock"
        self.killswitch = self.state_dir / "PAUSED"
        self.started_at = datetime.now(timezone.utc)
        self.log_lines: deque[str] = deque(maxlen=200)
        self.managers: list[Manager] = []
        self._stop = False
        self._draining = False
        self._sigint_count = 0

    # --- discovery / clone -------------------------------------------------
    def discover(self) -> None:
        """Read served projects from the backlog, clone any missing, and build a
        per-project Manager. A project whose clone lacks a .loopworker contract is
        logged and skipped (not fatal — the others still run)."""
        rows = self.adapter.list_projects()
        self.log(f"serving {len(rows)} project(s) as worker_manager={self.host.worker_manager!r}")
        self.managers = []
        for idx, row in enumerate(rows):
            try:
                clone = self._ensure_clone(row)
                manifest = Manifest.load(clone)
            except Exception as e:
                self.log(f"skipping project {row.name!r}: {e}")
                continue
            if row.slots:
                manifest.slots = row.slots
            self.managers.append(self._build_manager(row, manifest, idx))
            self.log(f"  {row.name}: {'hot' if row.hot else 'cold'}, {manifest.slots} slot(s)")

    def _ensure_clone(self, row: ProjectRow) -> Path:
        dest = self.host.clones_dir / _slug(row.name)
        if (dest / ".git").exists():
            return dest
        if not row.repo:
            raise RuntimeError("no repo to clone (set the project's Repo)")
        self.host.clones_dir.mkdir(parents=True, exist_ok=True)
        self.log(f"cloning {row.name} from {row.repo}")
        r = subprocess.run(["git", "clone", row.repo, str(dest)], capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"git clone failed: {r.stderr.strip()}")
        return dest

    def _build_manager(self, row: ProjectRow, manifest: Manifest, idx: int) -> Manager:
        # Each project gets its own port band (1000 apart) so slots never collide, a
        # name prefix so its workers are distinct in the shared loop_workers table, and
        # its own state dir for the per-project killswitch.
        return Manager(
            manifest,
            poll_interval=self.poll_interval,
            reconcile_interval=self.reconcile_interval,
            grace_seconds=self.grace_seconds,
            base_port=self.host.base_port + idx * 1000,
            state_dir=self.state_dir / _slug(row.name),
            adapter=self.adapter,
            project_id=row.id,
            name_prefix=f"{_slug(row.name)}-",
            hot=row.hot,
        )

    # --- lifecycle ---------------------------------------------------------
    def build(self) -> None:
        """Provision warm pools, capping total hot slots to the host budget so warm
        stacks never exceed max_slots (leaving the remainder for cold projects)."""
        remaining = self.host.max_slots
        for m in self.managers:
            if not m.pool.hot:
                continue
            if len(m.pool.slots) > remaining:
                kept = max(remaining, 0)
                self.log(f"capping hot {m.manifest.project_name} to {kept} slot(s) (host max_slots={self.host.max_slots})")
                m.pool.slots = m.pool.slots[:kept]
            remaining -= len(m.pool.slots)
        for m in self.managers:
            m._reap_orphans()
            m.pool.build()

    def run(self) -> None:
        self._acquire_lock()
        signal.signal(signal.SIGINT, self._on_signal)
        signal.signal(signal.SIGTERM, self._on_signal)
        try:
            self.discover()
            if not self.managers:
                self.log("no serviceable projects — nothing to do")
                return
            self.build()
            self.log(f"host ready; reconciling every {self.reconcile_interval}s, filling every {self.poll_interval}s")
            last_fill = 0.0
            while not self._stop:
                now = datetime.now(timezone.utc)
                try:
                    self._reconcile_all(now)
                    if not self._draining and (time.monotonic() - last_fill) >= self.poll_interval:
                        if self.killswitch.exists():
                            self.log("killswitch present (PAUSED) — not spawning new workers")
                        else:
                            self._fill_all(now)
                        last_fill = time.monotonic()
                except Exception as e:
                    self.log(f"ERROR in loop: {e!r}")
                if self._draining and not self._busy_total():
                    self.log("drain complete — all workers finished; shutting down")
                    break
                self._sleep(self.reconcile_interval)
        finally:
            self._reap_all("host shutting down")
            self._release_lock()
            self.log("host stopped (warm slots left up)")

    def tick(self) -> None:
        """One reconcile + fill pass (for --once / tests)."""
        now = datetime.now(timezone.utc)
        self._reconcile_all(now)
        if not self._draining and not self.killswitch.exists():
            self._fill_all(now)

    # --- scheduling --------------------------------------------------------
    def _reconcile_all(self, now: datetime) -> None:
        for m in self.managers:
            m.reconcile(now)

    def _fill_all(self, now: datetime) -> None:
        """Hot projects fill their warm slots freely (those stacks are already counted in
        the budget). Cold projects share the leftover budget, provisioning new stacks only
        while live stacks stay under max_slots."""
        hot = [m for m in self.managers if m.pool.hot]
        cold = [m for m in self.managers if not m.pool.hot]
        for m in hot:
            m.fill(now)
        reserved_hot = sum(len(m.pool.slots) for m in hot)
        cold_busy = sum(m.busy_count() for m in cold)
        remaining = self.host.max_slots - reserved_hot - cold_busy
        for m in cold:
            if remaining <= 0:
                break
            before = m.busy_count()
            m.fill(now, max_new=remaining)
            remaining -= m.busy_count() - before

    def _reap_all(self, reason: str) -> None:
        for m in self.managers:
            m._reap_workers(reason)

    def _busy_total(self) -> int:
        return sum(m.busy_count() for m in self.managers)

    # --- snapshot ----------------------------------------------------------
    def snapshot(self) -> dict:
        return {
            "worker_manager": self.host.worker_manager,
            "started_at": self.started_at.isoformat(),
            "paused": self.killswitch.exists(),
            "poll_interval": self.poll_interval,
            "max_slots": self.host.max_slots,
            "projects": [m.snapshot() for m in self.managers],
            "log": list(self.log_lines),
        }

    # --- plumbing ----------------------------------------------------------
    def log(self, msg: str) -> None:
        line = f"{datetime.now(timezone.utc).strftime('%H:%M:%S')} {msg}"
        self.log_lines.append(line)
        print(line, flush=True)

    def _sleep(self, seconds: int) -> None:
        deadline = time.monotonic() + seconds
        while not self._stop and time.monotonic() < deadline:
            time.sleep(min(2.0, deadline - time.monotonic()))

    def _on_signal(self, signum, _frame) -> None:
        if signum == signal.SIGTERM:
            self.log("SIGTERM — force-stopping: reaping workers and releasing their cards")
            self._stop = True
            return
        self._sigint_count += 1
        if self._sigint_count == 1:
            self._draining = True
            self.log(f"⌃C — draining: letting {self._busy_total()} worker(s) finish, starting no new work. "
                     "⌃C again to force-stop them now.")
        elif self._sigint_count == 2:
            self._stop = True
            self.log("⌃C⌃C — force-stopping: killing workers and releasing their cards. ⌃C again for hard exit.")
        else:
            self.log("⌃C⌃C⌃C — hard exit (resources may leak).")
            os._exit(130)

    def _acquire_lock(self) -> None:
        if self.lockfile.exists():
            pid = self.lockfile.read_text().strip()
            if pid and _pid_alive(int(pid)):
                raise RuntimeError(f"another host Manager (pid {pid}) holds {self.lockfile}")
        self.lockfile.write_text(str(os.getpid()))

    def _release_lock(self) -> None:
        try:
            self.lockfile.unlink()
        except FileNotFoundError:
            pass
