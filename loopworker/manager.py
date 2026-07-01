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
from .models import CardStatus, Slot, SlotState
from .names import name_for_slot
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
        reconcile_interval: int = 15,
        adapter=None,
        project_id: str | None = None,
        name_prefix: str = "",
        hot: bool = True,
        brief: str | None = None,
        project_brief: str | None = None,
        port_step: int = 100,
        base_ref: str = "origin/main",
    ):
        self.manifest = manifest
        self.poll_interval = poll_interval
        # Reconcile (reap finished workers, refresh the dashboard, catch crashes) runs
        # on this fast cadence; spawning new workers (the expensive part) only every
        # poll_interval. Keeps the dashboard honest without hammering the backlog.
        self.reconcile_interval = min(reconcile_interval, poll_interval)
        self.grace = timedelta(seconds=grace_seconds)
        self.wallclock_cap = timedelta(minutes=manifest.worker.wallclock_cap_minutes)
        # host mode injects a SHARED adapter and scopes this Manager to one project;
        # single-project mode builds its own adapter from the manifest (project_id None).
        self.adapter = adapter if adapter is not None else build_adapter(manifest)
        self.project_id = project_id
        self.name_prefix = name_prefix
        # host mode injects the brief (generic loop pointer + per-project override) since
        # the shared adapter has no per-project manifest to resolve them from; single mode
        # leaves them None and resolves via the manifest at spawn time.
        self._brief = brief
        self._project_brief = project_brief
        self.pool = SlotPool(manifest, base_port=base_port, port_step=port_step,
                             log=self.log, hot=hot, base_ref=base_ref)
        self.state_dir = (state_dir or Path("state") / manifest.project_name).resolve()
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.lockfile = self.state_dir / "manager.lock"
        self.killswitch = self.state_dir / "PAUSED"
        self.started_at = datetime.now(timezone.utc)
        self.log_lines: deque[str] = deque(maxlen=200)
        self._stop = False          # exit the loop; finally reaps any live workers
        self._draining = False      # finish current workers, start no new ones
        self._sigint_count = 0      # ⌃C escalation: 1=drain, 2=force, 3=hard exit

    # --- lifecycle ---------------------------------------------------------
    def run(self) -> None:
        self._acquire_lock()
        signal.signal(signal.SIGINT, self._on_signal)
        signal.signal(signal.SIGTERM, self._on_signal)
        try:
            self._reap_orphans()  # workers stranded by a previously-dead Manager
            self.log(f"building {self.manifest.slots} slot(s) — provisioning stacks (first run is slow)")
            self.pool.build()
            self.log(f"pool ready; reconciling every {self.reconcile_interval}s, filling every {self.poll_interval}s")
            last_fill = 0.0  # 0 → fill on the first iteration
            while not self._stop:
                now = datetime.now(timezone.utc)
                try:
                    self._reconcile_busy(now)  # cheap: reap finished workers, refresh dashboard, catch crashes
                    if not self._draining and (time.monotonic() - last_fill) >= self.poll_interval:
                        if self.killswitch.exists():
                            self.log("killswitch present (PAUSED) — not spawning new workers")
                        else:
                            self._fill_idle(now)
                        last_fill = time.monotonic()
                except Exception as e:  # one bad iteration must not kill the Manager
                    self.log(f"ERROR in loop: {e!r}")
                if self._draining and not self._busy_count():
                    self.log("drain complete — all workers finished; shutting down")
                    break
                self._sleep(self.reconcile_interval)
        finally:
            # A worker without its Manager has no reconciler/reaper, so don't leave
            # orphans behind when we exit (Ctrl-C, SIGTERM, or a fatal error).
            self._reap_workers("manager shutting down")
            self._release_lock()
            self.log("manager stopped (slots left warm)")

    def tick(self) -> None:
        now = datetime.now(timezone.utc)
        self._reconcile_busy(now)
        if self._draining:
            return  # draining: keep reconciling/reaping current workers, start nothing new
        if self.killswitch.exists():
            self.log("killswitch present (PAUSED) — not spawning new workers")
            return
        self._fill_idle(now)

    # --- host-driven steps (host mode calls these instead of run()) --------
    def reconcile(self, now: datetime | None = None) -> None:
        """Reap finished/crashed workers, refresh state. Safe to call frequently."""
        self._reconcile_busy(now or datetime.now(timezone.utc))

    def fill(self, now: datetime | None = None, max_new: int | None = None) -> None:
        """Spawn up to max_new workers into available slots (the host's per-project share
        of the host slot budget). Respects this project's own PAUSED killswitch."""
        if self.killswitch.exists():
            return
        self._fill_idle(now or datetime.now(timezone.utc), max_new)

    def busy_count(self) -> int:
        return self._busy_count()

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
                # The worker finished/parked the card (it's no longer In progress).
                # Reflect that on the dashboard instead of a stale "running ~N".
                slot.activity = f"finishing — {reason}; reaping soon"
                if slot.done_since is None:
                    slot.done_since = now
                    self.log(f"slot {slot.index} ~{slot.card_num}: {reason}; reap grace started")
                elif now - slot.done_since >= self.grace:
                    self._reap(slot, reason)
            elif action in (SlotAction.CRASH_RECLAIM, SlotAction.HUNG_RECLAIM):
                slot.activity = f"reclaiming — {reason}"
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
        self.pool.recycle(slot)  # hot: back to warm IDLE; cold: teardown stack + worktree

    # --- fill --------------------------------------------------------------
    def _fill_idle(self, now: datetime, max_new: int | None = None) -> None:
        """Spawn workers into available slots. max_new caps how many we may start this
        pass (the host's per-project share of the host-wide slot budget); None = no cap."""
        if max_new is not None and max_new <= 0:
            return
        available = self.pool.available_slots()
        if not available:
            return
        workable = self.adapter.list_workable()
        if self.project_id is not None:  # host mode: only this Manager's project
            workable = [c for c in workable if c.project == self.project_id]
        if not workable:
            return
        for slot in available:
            if not workable or (max_new is not None and max_new <= 0):
                break
            card = workable.pop(0)
            self._spawn_worker(slot, card, now)
            if max_new is not None:
                max_new -= 1

    def _spawn_worker(self, slot: Slot, card, now: datetime) -> None:
        # stable per slot; reuses one worker row. name_prefix namespaces it per project
        # in host mode (so two projects' slot-0 aren't both "ada" in shared loop_workers).
        name = f"{self.name_prefix}{name_for_slot(slot.index)}"
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
            # a cold slot may already have provisioned a stack before the failure — tear it
            # down so a failed acquire never leaks a running stack (hot keeps its warm one).
            if not self.pool.hot:
                self.pool.teardown_slot(slot)
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
            self.pool.recycle(slot)
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
    def _session_prefix(self) -> str:
        proj = re.sub(r"[^a-zA-Z0-9]+", "-", self.manifest.project_name.lower()).strip("-")
        return f"lw-{proj}-"

    def _session_name(self, card_num: int) -> str:
        return f"{self._session_prefix()}{card_num}"

    def _reap_session(self, sess: str, reason: str) -> None:
        """Kill a worker tmux session AND release its card if it's still In progress —
        a reaped worker that didn't finish must not leave its card stranded with a
        dead owner (a card the worker already Shipped is left as-is)."""
        tmux.kill(sess)
        try:
            num = int(sess[len(self._session_prefix()):])
        except ValueError:
            return  # not one of our card sessions
        try:
            card = self.adapter.get_card(num)
            if card and card.status == CardStatus.IN_PROGRESS:
                self.adapter.release(card, note=reason)
                self.log(f"  released ~{num} back to Backlog ({reason})")
        except Exception as e:
            self.log(f"  could not release ~{num}: {e!r}")

    def _reap_orphans(self) -> None:
        """At startup, reap any worker sessions left running. The lockfile guarantees
        we're the only Manager, so any lw-<proj>-* session is an orphan from a prior
        Manager that died without reaping — it has no card-status reconciler behind it."""
        for sess in tmux.list_sessions(self._session_prefix()):
            self.log(f"reaping orphaned worker session {sess} (no Manager owned it)")
            self._reap_session(sess, "orphaned worker reclaimed at startup")

    def _reap_workers(self, reason: str) -> None:
        """Reap this Manager's live worker sessions — on shutdown, so a worker never
        outlives the Manager that would otherwise reap/reconcile it."""
        for slot in self.pool.slots:
            if slot.session and tmux.has_session(slot.session):
                self.log(f"reaping worker {slot.session} ({reason})")
                self._reap_session(slot.session, reason)
                self.pool.recycle(slot)  # tear down a cold slot's stack so shutdown leaves none running

    def _build_prompt(self, slot: Slot, card, worker) -> str:
        # generic loop protocol (a Patch page pointer); this project's deltas. Host mode
        # injects both (shared adapter has no manifest); single mode resolves via manifest.
        brief = self._brief if self._brief is not None else self.adapter.get_brief()
        project_brief = self._project_brief if self._project_brief is not None else self.manifest.project_brief()
        project_section = (
            f"--- PROJECT BRIEF ({self.manifest.project_name}) ---\n{project_brief}\n\n"
            if project_brief else ""
        )
        return (
            f"You are {worker.name}, an autonomous LoopWorker.\n\n"
            f"You are assigned exactly ONE card: ~{card.num} \"{card.title}\" in project "
            f"{self.manifest.project_name}. It is already claimed for you (Assignee="
            f"{worker.name}, status In progress). Do NOT register yourself, do NOT pick "
            f"another card, do NOT browse the backlog for more work.\n\n"
            f"You are UNATTENDED: no human is watching this terminal. NEVER ask an "
            f"interactive question or wait for input — a prompt left open just hangs your "
            f"slot forever. Anything you'd want to ask a human, write into the CARD as a "
            f"parked question (set Needs refinement, clear your Assignee) and STOP.\n\n"
            f"{brief}\n\n"
            f"{project_section}"
            f"Work this one card per that brief: decide if it is workable. If not, move it "
            f"to Needs refinement (with sharp numbered questions) or Backlog and clear your "
            f"Assignee. If workable: implement the minimum that works, verify, open a PR, run "
            f"a clean-context self-review subagent over the diff, address findings, then "
            f"merge on GREEN CI. NEVER merge over a red/failing required check — even a "
            f"pre-existing one unrelated to your diff. If CI can't go green for reasons you "
            f"can't or shouldn't fix, PARK: leave the PR open, note in the card which check "
            f"is red and why it isn't yours to fix, set Needs refinement, clear your "
            f"Assignee, and STOP for a human merge decision. On a clean merge, flip the "
            f"card to Shipped with solved_in_pr and a summary at the bottom of the card.\n\n"
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
            # LOOPWORKER marks this as a Manager-spawned worker so the project's
            # SessionEnd hook leaves the WARM slot stack up when we reap the worker
            # (otherwise reaping tears down the stack the next card needs).
            "export LOOPWORKER=1\n"
            # auto mode: the Worker runs unattended, so it must not block on
            # per-tool permission prompts (acceptEdits still prompts for MCP/bash).
            'exec claude --permission-mode auto "$PROMPT"\n'
        )
        launch.chmod(0o755)
        return launch

    # --- snapshot for the dashboard ----------------------------------------
    def snapshot(self) -> dict:
        return {
            "project": self.manifest.project_name,
            "hot": self.pool.hot,
            "started_at": self.started_at.isoformat(),
            "paused": self.killswitch.exists(),
            "poll_interval": self.poll_interval,
            "slots": [
                {
                    "index": s.index,
                    "state": s.state.value,
                    "activity": s.activity,
                    # live one-liner of what the worker is thinking/doing, scraped
                    # from its tmux pane (only while a worker holds the slot)
                    "thinking": tmux.summary_line(s.session) if (s.session and s.state == SlotState.BUSY) else "",
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

    def _busy_count(self) -> int:
        return sum(1 for s in self.pool.slots if s.state == SlotState.BUSY)

    def _dump_state(self) -> None:
        """Lightweight state dump for a hard exit — no tmux/network, safe in a handler."""
        self.log(f"state dump: {self._busy_count()} busy slot(s)")
        for s in self.pool.slots:
            self.log(f"  slot {s.index}: {s.state.value} | {s.activity} | card={s.card_num} | session={s.session}")

    def _on_signal(self, signum, _frame) -> None:
        # SIGTERM (a supervisor stopping us) goes straight to a clean force-stop.
        if signum == signal.SIGTERM:
            self.log("SIGTERM — force-stopping: reaping workers and releasing their cards")
            self._stop = True
            return
        # SIGINT (⌃C) escalates: drain -> force -> hard exit.
        self._sigint_count += 1
        if self._sigint_count == 1:
            self._draining = True
            self.log(f"⌃C — draining: letting {self._busy_count()} worker(s) finish, starting no new work. "
                     "⌃C again to force-stop them now.")
        elif self._sigint_count == 2:
            self._stop = True
            self.log("⌃C⌃C — force-stopping: killing workers and releasing their cards. ⌃C again for hard exit.")
        else:
            self.log("⌃C⌃C⌃C — hard exit (state dump below; resources may leak).")
            self._dump_state()
            os._exit(130)

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
