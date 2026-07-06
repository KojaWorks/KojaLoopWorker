"""The warm slot pool.

A slot = (git worktree, port, long-lived stack). `supabase start` (or any project's
bring-up) is the expensive part, so slots are provisioned ONCE and reused across many
cards. The isolation guarantee is *reset on acquire* — never trust that a (possibly
crashed) previous tenant left the slot clean.

The Manager owns git/worktree mechanics here; the project owns its stack via the
.loopworker lifecycle scripts. Each script runs with LOOPWORKER_SLOT_DIR and
LOOPWORKER_PORT in its environment, and may print a line `LOOPWORKER_PORT=<n>` on
stdout to report the port it actually bound (e.g. a project whose own tooling derives
the port from the worktree path).
"""
from __future__ import annotations

import os
import re
import signal
import subprocess
import threading
import time
from collections.abc import Callable
from pathlib import Path

from .config import Manifest
from .models import Slot, SlotState

_PORT_LINE = re.compile(r"^LOOPWORKER_PORT=(\d+)\s*$", re.MULTILINE)

# Coarse watchdog: log that a script is still running once it passes this (or half its
# timeout, whichever is sooner), so a slow-but-alive script is visible before the kill.
_SOFT_WARN_SECS = 300.0

# A BROKEN hot slot is re-provisioned live by revive_broken once its cause clears, but at
# most once per this cooldown — the AuthGate-style backoff that keeps a persistently-failing
# provision (a genuinely dead stack) from re-running the slow provision.sh on every fill.
_HOT_REPROVISION_COOLDOWN = 180.0


def _fmt_dur(secs: float) -> str:
    return f"{secs / 60:g} min" if secs >= 60 else f"{secs:g}s"

# Provision/reset scripts print stack secrets (supabase start dumps anon/service-role
# JWTs, the JWT secret, S3 keys, the DB URL). We STREAM that output to the log + tmux +
# dashboard, so redact secret-shaped tokens first. Over-redaction (e.g. a git SHA) is a
# harmless cosmetic; leaking a service_role key is not.
_REDACT = [
    re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}"),  # JWTs (anon/service-role)
    re.compile(r"sb_(?:secret|publishable)_[A-Za-z0-9]+"),                        # newer supabase keys
    re.compile(r"\b[0-9a-f]{32,}\b"),                                             # hex secrets (S3 access/secret keys)
]
_DB_URL_PW = re.compile(r"(postgres(?:ql)?://[^:@/\s]+:)[^@/\s]+(@)")


def _redact(line: str) -> str:
    line = _DB_URL_PW.sub(r"\1[redacted]\2", line)
    for pat in _REDACT:
        line = pat.sub("[redacted]", line)
    return line


class SlotError(RuntimeError):
    pass


class SlotPool:
    def __init__(self, manifest: Manifest, base_port: int = 54400, port_step: int = 100,
                 log: Callable[[str], None] = lambda _m: None, hot: bool = True,
                 base_ref: str = "origin/main", clock: Callable[[], float] = time.monotonic):
        self.manifest = manifest
        self.base_port = base_port
        self.port_step = port_step
        self.log = log
        # monotonic clock, injectable so tests can drive the hot-revive backoff deterministically.
        self._clock = clock
        # the upstream ref worktrees branch off and reset to (a project's default branch);
        # "origin/main" for most, "origin/master" etc. for others.
        self.base_ref = base_ref
        # hot: keep warm stacks (provision once, reuse). cold: provision a slot per card
        # and tear it down after, so an occasional project leaves no lingering stack.
        self.hot = hot
        # Slot worktrees live OUTSIDE the main working copy (a worktree nested inside
        # its own repo is an anti-pattern) — as a sibling directory.
        self.root = manifest.project_dir.parent / f"{manifest.project_dir.name}.loopworker-slots"
        self.slots: list[Slot] = [
            Slot(index=i, dir=str(self.root / f"slot-{i}"), port=base_port + i * port_step,
                 state=SlotState.IDLE if hot else SlotState.COLD)
            for i in range(manifest.slots)
        ]

    # --- lifecycle ---------------------------------------------------------
    def build(self) -> None:
        """Create every slot's worktree and provision its stack. Idempotent: safe to
        call on every Manager start; existing worktrees/stacks are reused. A slot that
        fails to provision is marked BROKEN and skipped — one bad stack must not crash
        the whole Manager; the healthy slots still run.

        Cold pools provision nothing here — their slots stay COLD until a card arrives,
        then acquire() provisions on demand and recycle() tears down after."""
        if not self.hot:
            self.log(f"cold pool: {len(self.slots)} slot(s) provision on demand (no warm stacks)")
            self.root.mkdir(parents=True, exist_ok=True)
            return
        self.log(f"building warm pool: {len(self.slots)} slot(s) — first run provisions a Supabase stack each (slow)")
        self.root.mkdir(parents=True, exist_ok=True)
        for slot in self.slots:
            try:
                self._ensure_worktree(slot)
                self._provision(slot)
                slot.state = SlotState.IDLE
                slot.activity = "idle"
                self.log(f"slot {slot.index}: ready on port {slot.port}")
            except SlotError as e:
                slot.state = SlotState.BROKEN
                slot.activity = f"broken: {e}"
                self.log(f"slot {slot.index}: BROKEN — {e}")
        healthy = [s for s in self.slots if s.state != SlotState.BROKEN]
        self.log(f"pool ready: {len(healthy)}/{len(self.slots)} slot(s) healthy")
        if not healthy:
            self.log("WARNING: no healthy slots — check the provision output above; nothing will spawn")

    def teardown(self) -> None:
        for slot in self.slots:
            self.teardown_slot(slot)

    def resize(self, count: int) -> None:
        """Grow or shrink the pool to `count` slots live (a project's slot count changed
        in the backlog). Grow: add slots — a hot pool provisions each now, a cold pool
        leaves them COLD until a card acquires them. Shrink: retire the surplus — free
        slots are torn down immediately; a BUSY slot is flagged `retiring` and torn down
        by recycle() after its card finishes, so a running worker is never yanked.
        Idempotent: resizing to the current active size is a no-op."""
        active = [s for s in self.slots if not s.retiring]
        if count > len(active):
            need = count - len(active)
            for slot in self.slots:  # revive any not-yet-torn-down retiring slots first
                if need and slot.retiring:
                    slot.retiring = False
                    need -= 1
                    self.log(f"slot {slot.index}: retirement cancelled (slot count raised again)")
            for _ in range(need):
                self._add_slot()
        elif count < len(active):
            for slot in sorted(active, key=lambda s: s.index, reverse=True)[: len(active) - count]:
                self._retire(slot)

    def _add_slot(self) -> Slot:
        idx = self._free_index()
        slot = Slot(index=idx, dir=str(self.root / f"slot-{idx}"),
                    port=self.base_port + idx * self.port_step,
                    state=SlotState.IDLE if self.hot else SlotState.COLD)
        self.slots.append(slot)
        if self.hot:
            try:
                self._ensure_worktree(slot)
                self._provision(slot)
                slot.state = SlotState.IDLE
                slot.activity = "idle"
                self.log(f"slot {idx}: added, ready on port {slot.port}")
            except SlotError as e:
                slot.state = SlotState.BROKEN
                slot.activity = f"broken: {e}"
                self.log(f"slot {idx}: added but BROKEN — {e}")
        else:
            self.log(f"slot {idx}: added (cold — provisions on demand)")
        return slot

    def _free_index(self) -> int:
        used = {s.index for s in self.slots}
        i = 0
        while i in used:
            i += 1
        return i

    def _retire(self, slot: Slot) -> None:
        if slot.state == SlotState.BUSY:
            slot.retiring = True
            self.log(f"slot {slot.index}: retiring after its current card finishes")
        else:
            self.teardown_slot(slot)
            self.slots.remove(slot)
            self.log(f"slot {slot.index}: retired (torn down)")

    # --- acquire / free ----------------------------------------------------
    def acquire(self, slot: Slot, branch_slug: str) -> None:
        """Reset the slot to a clean tree on a fresh branch off origin/main and run the
        project's reset.sh (e.g. db reset). Raises SlotError on failure; the caller
        should mark the slot BROKEN and skip it.

        A COLD slot (cold pool) is provisioned first — worktree created and provision.sh
        run — so a cold project gets a live stack only while it has a card to work."""
        if slot.state == SlotState.COLD:
            self.log(f"slot {slot.index}: cold — provisioning on demand")
            self._ensure_worktree(slot)
            self._provision(slot)
        slot.activity = f"resetting (branch claude/{branch_slug})"
        self.log(f"slot {slot.index}: resetting worktree to origin/main, branch claude/{branch_slug}")
        wt = Path(slot.dir)
        self._git(self.manifest.project_dir, "fetch", "origin", "-q")
        self._git(wt, "reset", "--hard", self.base_ref)
        self._git(wt, "clean", "-fd")
        self._git(wt, "checkout", "-B", f"claude/{branch_slug}", self.base_ref)
        # Log the resolved tip, so a stale reset is instantly visible instead of a guess
        # about whether the worktree actually landed on origin/main's latest.
        head = self._git(wt, "rev-parse", "--short", "HEAD").stdout.strip()
        self.log(f"slot {slot.index}: worktree at {self.base_ref} @ {head}, branch claude/{branch_slug}")
        rc, out = self._run_script("reset", slot, check=False)
        if rc != 0:
            raise SlotError(f"reset.sh failed for slot {slot.index} (rc={rc})")
        self._capture_port(slot, out)

    def free(self, slot: Slot) -> None:
        slot.state = SlotState.IDLE
        slot.activity = "idle"
        slot.session = None
        slot.card_num = None
        slot.worker_id = None
        slot.model = None
        slot.started_at = None
        slot.done_since = None

    def recycle(self, slot: Slot) -> None:
        """Release a slot after a worker is reaped. Retiring → tear it down and drop it
        (its slot was removed while it was busy). Hot → back to warm IDLE (stack kept).
        Cold → tear the stack + worktree down and return to COLD, so an idle cold project
        leaves nothing running."""
        if slot.retiring:
            self.teardown_slot(slot)
            if slot in self.slots:
                self.slots.remove(slot)
            self.log(f"slot {slot.index}: retired (torn down after its card finished)")
            return
        if self.hot:
            self.free(slot)
            return
        slot.activity = "tearing down (cold)"
        self.log(f"slot {slot.index}: cold teardown (stack down, worktree removed)")
        self.teardown_slot(slot)
        self.free(slot)
        slot.state = SlotState.COLD
        slot.activity = "cold"

    def teardown_slot(self, slot: Slot) -> None:
        """Stop one slot's stack and remove its worktree (best-effort)."""
        try:
            self._run_script("teardown", slot, check=False)
        except SlotError as e:  # timeout or missing script — teardown stays best-effort
            self.log(f"slot {slot.index}: teardown incomplete — {e}")
        self._git(self.manifest.project_dir, "worktree", "remove", "--force", slot.dir, check=False)

    def available_slots(self) -> list[Slot]:
        """Slots that can take a card now: warm IDLE, or COLD (provisioned on acquire).
        A retiring slot is on its way out — never hand it new work."""
        return [s for s in self.slots if s.state in (SlotState.IDLE, SlotState.COLD) and not s.retiring]

    def idle_slots(self) -> list[Slot]:
        return [s for s in self.slots if s.state == SlotState.IDLE]

    def revive_broken(self) -> int:
        """Return BROKEN slots to service so a transient provision failure (a paused Docker,
        a missing host tool, a busy port) self-heals on a later fill instead of stranding the
        slot until a Manager restart. Returns how many slots were returned to service.

        Cold slots flip back to COLD — acquire() re-provisions them on demand once a card
        lands. Hot slots have no on-demand path, so they're RE-PROVISIONED here in place: on
        success they return to warm IDLE; on failure they stay BROKEN and back off
        _HOT_REPROVISION_COOLDOWN before the next attempt, so a genuinely dead stack isn't
        re-run every fill."""
        n = 0
        for s in self.slots:
            if s.state != SlotState.BROKEN:
                continue
            if not self.hot:
                s.state = SlotState.COLD
                s.activity = "cold (retry after earlier failure)"
                s.retiring = False
                n += 1
                continue
            # Read the clock fresh per slot: a re-provision below blocks (up to provision.sh's
            # timeout), so a shared pass-start timestamp would be stale for later slots.
            if self._clock() < s.retry_after:
                continue  # backing off — not yet time to retry this hot slot
            try:
                s.activity = "re-provisioning (retry after earlier failure)"
                self._ensure_worktree(s)
                self._provision(s)
            except SlotError as e:
                # Measure the cooldown from when the attempt FINISHED, not when it started —
                # a slow-hanging provision (up to its timeout) would otherwise already be past
                # a start-relative deadline and be retried immediately, defeating the backoff.
                s.retry_after = self._clock() + _HOT_REPROVISION_COOLDOWN
                s.activity = f"broken: {e}"
                self.log(f"slot {s.index}: re-provision failed, backing off "
                         f"{_fmt_dur(_HOT_REPROVISION_COOLDOWN)} — {e}")
                continue
            s.state = SlotState.IDLE
            s.activity = "idle"
            s.retry_after = 0.0
            self.log(f"slot {s.index}: re-provisioned and back to idle on port {s.port}")
            n += 1
        return n

    def live_slot_count(self) -> int:
        """Slots that hold (or are being brought up to hold) a warm stack — everything but
        BROKEN. The host's hot-budget reservation counts these: a BROKEN slot runs no stack,
        so it must not reserve RAM budget a cold project could use (revive_broken brings it
        back live once its cause clears)."""
        return sum(1 for s in self.slots if s.state != SlotState.BROKEN)

    def active_count(self) -> int:
        """The pool's effective size for resize decisions: slots not being retired. A
        retiring slot is on its way out, so it doesn't count toward the target."""
        return sum(1 for s in self.slots if not s.retiring)

    # --- internals ---------------------------------------------------------
    def _ensure_worktree(self, slot: Slot) -> None:
        if (Path(slot.dir) / ".git").exists():
            self.log(f"slot {slot.index}: reusing worktree {slot.dir}")
            return
        slot.activity = "creating worktree"
        self.log(f"slot {slot.index}: creating worktree {slot.dir}")
        self._git(self.manifest.project_dir, "fetch", "origin", "-q")
        # Flat branch name (hyphen, not "loopworker/slot-N"): a slash makes git treat
        # "loopworker" as a directory, which collides with a plain branch named
        # "loopworker" (the obvious name for this work) — git then can't create the ref.
        self._git(
            self.manifest.project_dir,
            "worktree", "add", "-B", f"loopworker-slot-{slot.index}", slot.dir, self.base_ref,
        )

    def _provision(self, slot: Slot) -> None:
        slot.activity = "provisioning"  # the project's provision.sh — its output streams to the log
        rc, out = self._run_script("provision", slot, check=False)
        if rc != 0:
            raise SlotError(f"provision.sh failed (rc={rc}) — see the [slot {slot.index} provision] log above")
        self._capture_port(slot, out)

    def _capture_port(self, slot: Slot, stdout: str) -> None:
        m = _PORT_LINE.search(stdout or "")
        if m:
            slot.port = int(m.group(1))
            slot.port_reported = True

    def _script_timeout(self, which: str) -> float:
        """Hard deadline (seconds) for a lifecycle script, from the manifest."""
        return getattr(self.manifest.scripts, f"{which}_timeout_minutes", 15.0) * 60

    def _run_script(self, which: str, slot: Slot, *, check: bool = True) -> tuple[int, str]:
        """Run a lifecycle script, STREAMING its output line-by-line to the log (so a
        slow/failing provision isn't a silent black box) while capturing it for the
        LOOPWORKER_PORT handshake. stderr is merged into stdout so errors show too.

        The script gets its own process group and a hard timeout: a wedged docker daemon
        once made reset.sh hang forever, freezing the whole Manager for hours. On timeout
        the entire group is killed (scripts spawn trees like npm→node→supabase) and
        SlotError raises — even with check=False — so BROKEN-slot handling takes over."""
        path = self.manifest.script_path(which)
        if not path.is_file():
            raise SlotError(f"missing {which} script: {path}")
        timeout = self._script_timeout(which)
        env = {
            **os.environ,
            "LOOPWORKER_SLOT_DIR": slot.dir,
            "LOOPWORKER_PORT": str(slot.port),
            "LOOPWORKER_PROJECT": self.manifest.project_name,
        }
        proc = subprocess.Popen(
            ["bash", str(path), slot.dir],
            cwd=slot.dir if Path(slot.dir).is_dir() else str(self.manifest.project_dir),
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
            start_new_session=True,
        )
        lines: list[str] = []
        abandoned = threading.Event()

        # Stream on a side thread: a pipe read can block indefinitely (even past the
        # child's death, if an orphaned grandchild inherited the write end), while
        # wait(timeout) always returns control to the Manager thread.
        def pump() -> None:
            assert proc.stdout is not None
            for line in proc.stdout:
                if abandoned.is_set():
                    return  # run is over; a late line must not log into a later card
                line = line.rstrip("\n")
                lines.append(line)
                if line.strip():
                    self.log(f"  [slot {slot.index} {which}] {_redact(line)}")

        reader = threading.Thread(target=pump, daemon=True, name=f"slot{slot.index}-{which}-pump")
        reader.start()

        soft = min(_SOFT_WARN_SECS, timeout / 2)
        timed_out = False
        try:
            rc = proc.wait(timeout=soft)
        except subprocess.TimeoutExpired:
            self.log(f"  [slot {slot.index} {which}] still running after {_fmt_dur(soft)}"
                     f" (killed at {_fmt_dur(timeout)})")
            try:
                rc = proc.wait(timeout=timeout - soft)
            except subprocess.TimeoutExpired:
                timed_out = True
                self.log(f"  [slot {slot.index} {which}] timed out after {_fmt_dur(timeout)}"
                         " — killing its process group")
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                rc = proc.wait()
        reader.join(timeout=5)  # EOF follows the group's death; don't hang on a stuck pipe
        if reader.is_alive():
            abandoned.set()
            self.log(f"  [slot {slot.index} {which}] output pipe still open after exit"
                     " (orphaned child?) — abandoning the reader")
        out = "\n".join(lines)
        if timed_out:
            raise SlotError(f"{which} script timed out after {_fmt_dur(timeout)} (process group killed)")
        if check and rc != 0:
            tail = _redact(lines[-1]) if lines else "(no output)"
            raise SlotError(f"{which} script failed (rc={rc}): {tail}")
        return rc, out

    @staticmethod
    def _git(cwd: Path | str, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        r = subprocess.run(
            ["git", "-C", str(cwd), *args], capture_output=True, text=True, check=False
        )
        if check and r.returncode != 0:
            raise SlotError(f"git {' '.join(args)} failed in {cwd}: {r.stderr.strip()}")
        return r
