"""Cheap preflight check for the claude login every worker spawn depends on.

A worker that hits an expired/invalid host login sits at an interactive "/login"
prompt printing "API Error: 401 Invalid authentication credentials" until the
wallclock cap, silently burning its slot (and a claimed card) for up to 90 minutes.
A short headless `claude -p` call, run before spawning and cached for a few minutes,
catches a dead credential before we ever launch a worker on it.
"""
from __future__ import annotations

import os
import signal
import subprocess
import threading
import time
from collections.abc import Callable

_DEFAULT_CMD = ("claude", "-p", "ok", "--model", "haiku")


class AuthGate:
    """Cached auth-preflight check, shared by every spawn point that draws on the same
    claude login (one instance per HostManager, or per standalone Manager).

    `enabled=False` (the default) makes ok() always return True without ever shelling
    out — the safe default so constructing a Manager/HostManager in a test never
    silently spawns a real `claude` process. Only a real unattended run (wired in
    __main__.py) turns it on."""

    def __init__(
        self,
        *,
        enabled: bool = False,
        cmd: tuple[str, ...] = _DEFAULT_CMD,
        timeout_seconds: float = 60.0,
        ttl_seconds: float = 180.0,
        reclaim_backoff_base_seconds: float = 30.0,
        reclaim_backoff_cap_seconds: float = 600.0,
        log: Callable[[str], None] = lambda msg: None,
        notify: Callable[[str, str], None] = lambda key, msg: None,
    ):
        self.enabled = enabled
        self._cmd = cmd
        self._timeout = timeout_seconds
        self._ttl = ttl_seconds
        self._backoff_base = reclaim_backoff_base_seconds
        self._backoff_cap = reclaim_backoff_cap_seconds
        self._log = log
        self._notify = notify
        self._ok: bool | None = None  # None = never checked yet
        self._checked_at = 0.0
        # A worker reaching claude's interactive login prompt (an AUTH_RECLAIM) proves
        # interactive auth is broken even when the headless `-p` preflight still passes,
        # so respawning straight back in just hammers the account (deepening the very
        # revocation). Each consecutive reclaim arms an exponentially longer window during
        # which ok() pauses dispatch host-wide; a clean worker completion clears it.
        self._reclaim_streak = 0
        self._backoff_until = 0.0  # monotonic deadline; 0 = not backing off

    def ok(self) -> bool:
        """True if the login looks healthy. Cached for ttl_seconds so dispatch doesn't
        pay a `claude -p` round-trip on every fill; a fresh check runs once the cache
        expires, which is also how a paused dispatch notices recovery and resumes.
        Logs + notifies once per ok<->fail transition, never every poll, so a sustained
        outage doesn't spam."""
        if not self.enabled:
            return True
        now = time.monotonic()
        if now < self._backoff_until:
            return False  # in an auth-reclaim backoff window (note_auth_reclaim logged it)
        if self._ok is not None and (now - self._checked_at) < self._ttl:
            return self._ok
        was_ok = self._ok
        self._ok, reason = self._check()
        self._checked_at = now
        if was_ok is not False and not self._ok:
            self._log(f"auth preflight failed - pausing dispatch: {reason}")
            self._notify("auth-failure", f"LoopWorker: claude login check failing ({reason}) - dispatch paused")
        elif was_ok is False and self._ok:
            self._log("auth preflight recovered - resuming dispatch")
            # distinct key from the failure notify above: same key would dedupe this
            # recovery notification away if it lands inside the failure's dedupe window
            self._notify("auth-recovered", "LoopWorker: claude login recovered - dispatch resumed")
        return self._ok

    def _check(self) -> tuple[bool, str]:
        env = dict(os.environ)
        # Matches the worker launch script's own USER workaround (manager.py's
        # _write_launch) so a false positive here is never confused with a real
        # credential problem.
        env.pop("USER", None)
        # Own process group + off-thread pipe read + killpg on timeout — the same shape as
        # slots._run_script, and for the same scar: `claude` leaves a grandchild holding the
        # stdout pipe, so subprocess.run(capture_output=True)'s post-timeout communicate()
        # blocks in read() FOREVER, defeating its own timeout and wedging the whole reconcile
        # loop (one host-wide gate → the entire Manager freezes on a single hung preflight).
        # proc.wait(timeout) always returns control; killpg reaps the tree; the reader is a
        # daemon we never block on.
        try:
            proc = subprocess.Popen(
                self._cmd, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, env=env, start_new_session=True,
            )
        except Exception as e:
            # A preflight check must never itself crash the reconcile loop — treat any failure
            # to even launch (missing binary, permissions, ...) as "not ok".
            return False, f"preflight failed to run: {e!r}"
        out: list[str] = []
        reader = threading.Thread(
            target=lambda: out.extend(proc.stdout or []), daemon=True, name="authgate-pump"
        )
        reader.start()
        try:
            rc = proc.wait(timeout=self._timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)  # whole group: claude spawns a tree
            except (ProcessLookupError, PermissionError):
                pass
            proc.wait()
            return False, "preflight timed out"
        if rc == 0:
            return True, ""  # success needs no output — don't wait on a maybe-orphaned pipe
        reader.join(timeout=2)  # only a FAILURE needs its reason; EOF follows a clean exit
        detail = "".join(out).strip().splitlines()
        return False, (detail[-1] if detail else f"exit {rc}")

    def note_auth_reclaim(self) -> None:
        """Record that a worker was reclaimed off claude's login prompt. Bumps the
        consecutive-reclaim streak and arms an exponential backoff (base * 2^(n-1),
        capped) during which ok() pauses dispatch host-wide regardless of the `-p`
        preflight — the reclaim itself is proof interactive auth is broken. Cleared by
        note_clean_completion(). Inert while disabled: without ok() ever gating, an armed
        window would do nothing but mislead."""
        if not self.enabled:
            return
        self._reclaim_streak += 1
        delay = min(self._backoff_cap, self._backoff_base * 2 ** (self._reclaim_streak - 1))
        self._backoff_until = time.monotonic() + delay
        self._log(f"auth reclaim #{self._reclaim_streak} - pausing dispatch {delay:.0f}s (backoff)")
        self._notify(
            "auth-reclaim-backoff",
            f"LoopWorker: {self._reclaim_streak} consecutive auth reclaim(s) - dispatch paused {delay:.0f}s",
        )

    def note_clean_completion(self) -> None:
        """A worker finished its card cleanly, so interactive auth is working — clear the
        auth-reclaim streak and any armed backoff. Only acts when a streak is live, so a
        steady stream of normal completions costs nothing."""
        if self._reclaim_streak:
            self._reclaim_streak = 0
            self._backoff_until = 0.0
            self._log("auth-reclaim backoff cleared - a worker completed cleanly")
