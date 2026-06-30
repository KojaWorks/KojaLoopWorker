"""The long-lived Manager: poll, reconcile, spawn, reap.

Deterministic and non-AI. One process per project, guarded by a lockfile. Each tick it
reconciles live tmux sessions against card statuses, then fills idle slots with the
highest-priority workable cards.
"""
from __future__ import annotations

import os
import re
import signal
import time
from collections import deque
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import tmux
from .backlog import build_adapter
from .config import Manifest
from .models import Slot, SlotState
from .names import pick_name
from .reconciler import SlotAction, classify
from .slots import SlotError, SlotPool


def _slug(text: str, limit: int = 40) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:limit].strip("-") or "card"


class Manager:
    def __init__(
        self,
        manifest: Manifest,
        *,
        poll_interval: int = 300,
        grace_seconds: int = 120,
        base_port: int = 54400,
        state_dir: Path | None = None,
    ):
        self.manifest = manifest
        self.poll_interval = poll_interval
        self.grace = timedelta(seconds=grace_seconds)
        self.wallclock_cap = timedelta(minutes=manifest.worker.wallclock_cap_minutes)
        self.adapter = build_adapter(manifest)
        self.pool = SlotPool(manifest, base_port=base_port, log=self.log)
        self.state_dir = (state_dir or Path("state") / manifest.project_name).resolve()
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.lockfile = self.state_dir / "manager.lock"
        self.killswitch = self.state_dir / "PAUSED"
        self.started_at = datetime.now(timezone.utc)
        self.log_lines: deque[str] = deque(maxlen=200)
        self._stop = False

    # --- lifecycle ---------------------------------------------------------
    def run(self) -> None:
        self._acquire_lock()
        signal.signal(signal.SIGINT, self._on_signal)
        signal.signal(signal.SIGTERM, self._on_signal)
        try:
            self.log(f"building {self.manifest.slots} slot(s) — provisioning stacks (first run is slow)")
            self.pool.build()
            self.log("pool ready; entering reconcile loop")
            while not self._stop:
                try:
                    self.tick()
                except Exception as e:  # one bad tick must not kill the Manager
                    self.log(f"ERROR in tick: {e!r}")
                self._sleep(self.poll_interval)
        finally:
            self._release_lock()
            self.log("manager stopped (slots left warm)")

    def tick(self) -> None:
        now = datetime.now(timezone.utc)
        self._reconcile_busy(now)
        if self.killswitch.exists():
            self.log("killswitch present (PAUSED) — not spawning new workers")
            return
        self._fill_idle(now)

    # --- reconcile ---------------------------------------------------------
    def _reconcile_busy(self, now: datetime) -> None:
        for slot in self.pool.slots:
            if slot.state != SlotState.BUSY:
                continue
            card = self.adapter.get_card(slot.card_num)
            alive = tmux.worker_running(slot.session)
            action, reason = classify(slot, card, alive, now, self.wallclock_cap)

            if action == SlotAction.KEEP:
                slot.done_since = None
            elif action == SlotAction.REAP:
                if slot.done_since is None:
                    slot.done_since = now
                    self.log(f"slot {slot.index} ~{slot.card_num}: {reason}; reap grace started")
                elif now - slot.done_since >= self.grace:
                    self._reap(slot, reason)
            elif action in (SlotAction.CRASH_RECLAIM, SlotAction.HUNG_RECLAIM):
                self.log(f"slot {slot.index} ~{slot.card_num}: {reason} — reclaiming card")
                if card is not None:
                    try:
                        self.adapter.release(card, note=reason)
                    except Exception as e:
                        self.log(f"  release failed: {e!r}")
                self._reap(slot, reason)

    def _reap(self, slot: Slot, reason: str) -> None:
        slot.activity = f"reaping ({reason})"
        self.log(f"reaping slot {slot.index} (session {slot.session}): {reason}")
        if slot.session:
            tmux.kill(slot.session)
        self.pool.free(slot)

    # --- fill --------------------------------------------------------------
    def _fill_idle(self, now: datetime) -> None:
        idle = self.pool.idle_slots()
        if not idle:
            return
        workable = self.adapter.list_workable()
        if not workable:
            return
        taken = {s.session for s in self.pool.slots if s.session}  # avoid duplicate sessions
        for slot in idle:
            if not workable:
                break
            card = workable.pop(0)
            self._spawn_worker(slot, card, now)

    def _spawn_worker(self, slot: Slot, card, now: datetime) -> None:
        name = pick_name(taken=set())  # cosmetic; collisions are harmless
        try:
            worker = self.adapter.register_worker(
                name, role="generic", notes=f"~{card.num}: {card.title}"
            )
        except Exception as e:
            self.log(f"register_worker failed for ~{card.num}: {e!r}")
            return

        if not self.adapter.claim(card, worker):
            self.log(f"lost claim race for ~{card.num} — skipping")
            return

        try:
            self.pool.acquire(slot, _slug(f"{card.num}-{card.title}"))
        except SlotError as e:
            self.log(f"slot {slot.index} acquire failed: {e!r} — releasing ~{card.num}")
            slot.state = SlotState.BROKEN
            try:
                self.adapter.release(card)
            except Exception:
                pass
            return

        session = self._session_name(card.num)
        launch = self._write_launch(slot, card, worker)
        try:
            tmux.spawn(session, slot.dir, ["bash", str(launch)])
        except RuntimeError as e:
            self.log(f"tmux spawn failed for ~{card.num}: {e!r} — releasing")
            self.pool.free(slot)
            try:
                self.adapter.release(card)
            except Exception:
                pass
            return

        slot.state = SlotState.BUSY
        slot.activity = f"running ~{card.num} ({name})"
        slot.session = session
        slot.card_num = card.num
        slot.worker_id = worker.id
        slot.started_at = now
        slot.done_since = None
        self.log(f"spawned {name} on ~{card.num} ({card.title!r}) in slot {slot.index} (tmux: {session})")

    # --- worker launch -----------------------------------------------------
    def _session_name(self, card_num: int) -> str:
        proj = re.sub(r"[^a-zA-Z0-9]+", "-", self.manifest.project_name.lower()).strip("-")
        return f"lw-{proj}-{card_num}"

    def _build_prompt(self, slot: Slot, card, worker) -> str:
        brief = self.adapter.get_brief()
        return (
            f"You are {worker.name}, an autonomous LoopWorker.\n\n"
            f"You are assigned exactly ONE card: ~{card.num} \"{card.title}\" in project "
            f"{self.manifest.project_name}. It is already claimed for you (Assignee="
            f"{worker.name}, status In progress). Do NOT register yourself, do NOT pick "
            f"another card, do NOT browse the backlog for more work.\n\n"
            f"{brief}\n\n"
            f"Work this one card per that brief: decide if it is workable. If not, move it "
            f"to Needs refinement (with sharp numbered questions) or Backlog and clear your "
            f"Assignee. If workable: implement the minimum that works, verify, open a PR, run "
            f"a clean-context self-review subagent over the diff, address findings, merge on "
            f"green CI, then flip the card to Shipped with solved_in_pr and a summary at the "
            f"bottom of the card.\n\n"
            f"Final step before you stop (either outcome): record one short env-feedback note "
            f"— was anything missing from your environment, did any gate block you wrongly, "
            f"what slowed you down? Put it in the project's Env-feedback table if one exists, "
            f"otherwise at the bottom of the card. Then STOP — do not continue to another "
            f"card; the Manager handles iteration.\n\n"
            f"Your worktree is {slot.dir} (already on a fresh branch off main). The stack "
            f"port is {slot.port}."
        )

    def _write_launch(self, slot: Slot, card, worker) -> Path:
        prompt = self._build_prompt(slot, card, worker)
        slot_dir = Path(slot.dir)
        (slot_dir / ".loopworker-prompt.txt").write_text(prompt)
        launch = slot_dir / ".loopworker-launch.sh"
        launch.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f'cd "{slot.dir}"\n'
            'PROMPT="$(cat .loopworker-prompt.txt)"\n'
            'exec claude --permission-mode acceptEdits "$PROMPT"\n'
        )
        launch.chmod(0o755)
        return launch

    # --- snapshot for the dashboard ----------------------------------------
    def snapshot(self) -> dict:
        return {
            "project": self.manifest.project_name,
            "started_at": self.started_at.isoformat(),
            "paused": self.killswitch.exists(),
            "poll_interval": self.poll_interval,
            "slots": [
                {
                    "index": s.index,
                    "state": s.state.value,
                    "activity": s.activity,
                    "port": s.port,
                    "card": s.card_num,
                    "session": s.session,
                    "started_at": s.started_at.isoformat() if s.started_at else None,
                }
                for s in self.pool.slots
            ],
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

    def _on_signal(self, *_args) -> None:
        self.log("signal received — stopping after this tick")
        self._stop = True

    def _acquire_lock(self) -> None:
        if self.lockfile.exists():
            pid = self.lockfile.read_text().strip()
            if pid and _pid_alive(int(pid)):
                raise RuntimeError(f"another Manager (pid {pid}) holds {self.lockfile}")
        self.lockfile.write_text(str(os.getpid()))

    def _release_lock(self) -> None:
        try:
            self.lockfile.unlink()
        except FileNotFoundError:
            pass


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, ValueError):
        return False
    except PermissionError:
        return True
    return True
