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

from .backlog.patch import PatchAdapter, brief_pointer
from .config import HostConfig, Manifest
from .manager import _DEFAULT_WORKER_ENV, Manager, _pid_alive, _slug
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
        self._bands: dict[str, int] = {}   # project_id -> port-band index (freed on retire, reused)
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
        # Auth forwarding is silent per-spawn, so say up front whether workers will get
        # their own credential or fall back to the host's shared (race-prone) login.
        for k in _DEFAULT_WORKER_ENV:
            self.log(f"worker auth: {k} {'set — forwarding to workers' if k in os.environ else 'NOT set — workers use the host claude login'}")
        if not self.host.brief_page:
            self.log("WARNING: no brief_page in host config — workers get no generic loop protocol; "
                     "set [backlog].brief_page to the Managed Agent Loop page")
        self.managers = []
        self._bands = {}
        for row in rows:
            try:
                manifest = self._load_row(row)
            except Exception as e:
                self.log(f"skipping project {row.name!r}: {e}")
                continue
            self.managers.append(self._build_manager(row, manifest, self._alloc_band(row.id)))
            self.log(f"  {row.name}: {'hot' if row.hot else 'cold'}, {manifest.slots} slot(s)")

    def reconcile_projects(self, now: datetime | None = None) -> None:
        """Re-read the served-project set from the backlog and reconcile it into the live
        Managers WITHOUT a restart: newly-assigned projects are cloned + built, projects
        no longer ours are drained + torn down, and a changed slot count resizes the pool.
        Runs on the poll cadence. A failed read leaves the current Managers untouched — a
        transient backlog error must never be read as 'no projects, retire everything'."""
        try:
            rows = {r.id: r for r in self.adapter.list_projects()}
        except Exception as e:
            self.log(f"project reconcile skipped — list_projects failed: {e!r}")
            return
        current = {m.project_id: m for m in self.managers}

        for pid, m in list(current.items()):  # retire projects no longer assigned to us
            if pid not in rows:
                self.log(f"{m.manifest.project_name!r} no longer assigned to this host — draining + tearing down")
                try:
                    m._reap_workers("project unassigned from this host")  # releases in-progress cards
                    m.pool.teardown()                                     # stop warm stacks, remove worktrees
                except Exception as e:
                    self.log(f"  teardown of {m.manifest.project_name!r} hit an error: {e!r}")
                self.managers.remove(m)
                self._bands.pop(pid, None)

        for pid, row in rows.items():  # build newly-assigned projects
            if pid in current:
                continue
            try:
                manifest = self._load_row(row)
            except Exception as e:
                self.log(f"skipping new project {row.name!r}: {e}")
                continue
            m = self._build_manager(row, manifest, self._alloc_band(pid))
            try:
                m._reap_orphans()
                m.pool.build()  # hot: provision warm slots; cold: nothing until a card arrives
            except Exception as e:
                self.log(f"provisioning new project {row.name!r} failed: {e!r}")
            self.managers.append(m)
            self.log(f"added project {row.name}: {'hot' if row.hot else 'cold'}, {manifest.slots} slot(s)")

        for m in self.managers:  # a hot⇄cold flip changes the whole provisioning model
            row = rows.get(m.project_id)
            if row and row.hot != m.pool.hot:
                self.log(f"{m.manifest.project_name!r} hot flag is now {row.hot} — restart the Manager "
                         "to change its pool model (slot count still updates live)")

        self._apply_slot_targets(rows)

    def _load_row(self, row: ProjectRow) -> Manifest:
        """Clone the project on demand and load its .loopworker manifest, applying a
        row-level slot-count override. Raises if the clone lacks a contract."""
        manifest = Manifest.load(self._ensure_clone(row))
        if row.slots:
            manifest.slots = row.slots
        return manifest

    def _alloc_band(self, project_id: str) -> int:
        """Assign a project the lowest free port-band index so two projects' slot ports
        never overlap; reused after a project retires."""
        used = set(self._bands.values())
        idx = 0
        while idx in used:
            idx += 1
        self._bands[project_id] = idx
        return idx

    def _apply_slot_targets(self, rows: dict) -> None:
        """Resize each project's pool to its configured slot count, capping hot pools so
        total hot slots stay within max_slots (in Manager order — earlier projects keep
        theirs). Cold pools take their configured count as cheap COLD placeholders; the
        real concurrency cap for cold work is enforced dynamically in _fill_all."""
        remaining = self.host.max_slots
        for m in self.managers:
            row = rows.get(m.project_id)
            desired = row.slots if (row and row.slots) else m.manifest.slots
            if m.pool.hot:
                target = max(min(desired, remaining), 0)
                remaining -= target
            else:
                # Cold pools don't reserve budget (they draw from leftover in _fill_all),
                # but the count is still capped to max_slots: a project's port band is only
                # max_slots wide, so more slots than that would overflow into the next
                # project's band and collide on a port. You can never run more than
                # max_slots concurrently anyway, so extra cold slots buy nothing.
                target = min(desired, self.host.max_slots)
            # gate on active (non-retiring) count — resize() ignores retiring slots, so
            # counting them here would log a phantom resize every poll while one drains.
            if target != m.pool.active_count():
                self.log(f"{m.manifest.project_name}: resizing {m.pool.active_count()} -> {target} slot(s)")
                try:
                    m.pool.resize(target)
                except Exception as e:
                    self.log(f"  resize of {m.manifest.project_name!r} failed: {e!r}")

    def _ensure_clone(self, row: ProjectRow) -> Path:
        dest = self.host.clones_dir / _slug(row.name)
        if (dest / ".git").exists():
            # Keep the cached clone current. Without this it's frozen at first-clone, so the
            # manifest (loaded from here) never picks up a manifest.toml change — not even
            # across a host restart, until the clone is deleted by hand. Fetch + hard-reset
            # the working tree to the latest default branch. Best-effort: a transient failure
            # keeps the last-good clone rather than crashing the host. (Worker code is already
            # kept fresh per-card by the slot's reset_and_claim; this is for the manifest.)
            for step in (["fetch", "--quiet", "origin"],
                         ["reset", "--hard", "--quiet", f"origin/{row.default_branch}"]):
                r = subprocess.run(["git", "-C", str(dest), *step], capture_output=True, text=True)
                if r.returncode != 0:
                    self.log(f"warning: git {step[0]} failed refreshing {row.name} clone "
                             f"(using cached): {r.stderr.strip()}")
                    break
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
        # Each project gets its own port band — wide enough for the whole host budget so
        # two projects' slot ports can never overlap — a name prefix so its workers are
        # distinct in the shared loop_workers table, and its own state dir (killswitch).
        band = self.host.port_step * max(self.host.max_slots, 1)
        # the generic loop protocol is shared (host brief_page); a project may override its
        # own brief with a Patch page (brief_ref), else its repo's BRIEF.md is used.
        project_brief = brief_pointer(row.brief_ref) if row.brief_ref else None
        return Manager(
            manifest,
            poll_interval=self.poll_interval,
            reconcile_interval=self.reconcile_interval,
            grace_seconds=self.grace_seconds,
            base_port=self.host.base_port + idx * band,
            port_step=self.host.port_step,
            state_dir=self.state_dir / _slug(row.name),
            adapter=self.adapter,
            project_id=row.id,
            name_prefix=f"{_slug(row.name)}-",
            hot=row.hot,
            base_ref=f"origin/{row.default_branch}",
            brief=brief_pointer(self.host.brief_page),
            project_brief=project_brief,
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
            self.log(f"host ready; reconciling + staggered fill every {self.reconcile_interval}s, "
                     f"project discovery every {self.poll_interval}s")
            last_discover = 0.0
            while not self._stop:
                now = datetime.now(timezone.utc)
                try:
                    self._reconcile_all(now)
                    if not self._draining:
                        paused = self.killswitch.exists()
                        # Project discovery (backlog read + clone) stays on the slow cadence;
                        # spawning runs every cycle so the one-per-pass stagger ramps quickly.
                        if (time.monotonic() - last_discover) >= self.poll_interval:
                            if paused:
                                self.log("killswitch present (PAUSED) — not spawning new workers")
                            else:
                                self.reconcile_projects(now)  # added/removed/resized projects
                            last_discover = time.monotonic()
                        if not paused:
                            self._fill_all(now)
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
            self.reconcile_projects(now)
            self._fill_all(now)

    # --- scheduling --------------------------------------------------------
    def _reconcile_all(self, now: datetime) -> None:
        for m in self.managers:
            m.reconcile(now)

    def _fill_all(self, now: datetime) -> None:
        """Spawn workers under two caps: `max_concurrent_workers` bounds how many claudes
        run at once host-wide (auth-safety — concurrent claudes race the shared OAuth
        refresh), and `max_slots` bounds live Supabase stacks (RAM). Runs on the fast
        reconcile cadence but starts at most ONE worker per pass, so a fresh fleet ramps up
        staggered (~reconcile_interval apart) instead of a thundering herd of simultaneous
        auths. Called every cycle, so the next worker starts a tick later."""
        headroom = self.host.max_concurrent_workers - self._busy_total()
        if headroom <= 0:
            return
        budget = 1  # stagger: one new worker per pass
        hot = [m for m in self.managers if m.pool.hot]
        cold = [m for m in self.managers if not m.pool.hot]
        for m in hot:
            if budget <= 0:
                break
            before = m.busy_count()
            m.fill(now, max_new=budget)
            budget -= m.busy_count() - before
        reserved_hot = sum(len(m.pool.slots) for m in hot)
        cold_busy = sum(m.busy_count() for m in cold)
        stack_room = self.host.max_slots - reserved_hot - cold_busy
        for m in cold:
            if budget <= 0 or stack_room <= 0:
                break
            before = m.busy_count()
            m.fill(now, max_new=min(budget, stack_room))
            started = m.busy_count() - before
            budget -= started
            stack_room -= started

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
            "max_concurrent_workers": self.host.max_concurrent_workers,
            "busy_total": self._busy_total(),
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
