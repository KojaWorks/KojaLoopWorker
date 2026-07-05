"""Cheap preflight check for the claude login every worker spawn depends on.

A worker that hits an expired/invalid host login sits at an interactive "/login"
prompt printing "API Error: 401 Invalid authentication credentials" until the
wallclock cap, silently burning its slot (and a claimed card) for up to 90 minutes.
A short headless `claude -p` call, run before spawning and cached for a few minutes,
catches a dead credential before we ever launch a worker on it.
"""
from __future__ import annotations

import os
import subprocess
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
        timeout_seconds: float = 20.0,
        ttl_seconds: float = 180.0,
        log: Callable[[str], None] = lambda msg: None,
        notify: Callable[[str], None] = lambda msg: None,
    ):
        self.enabled = enabled
        self._cmd = cmd
        self._timeout = timeout_seconds
        self._ttl = ttl_seconds
        self._log = log
        self._notify = notify
        self._ok: bool | None = None  # None = never checked yet
        self._checked_at = 0.0

    def ok(self) -> bool:
        """True if the login looks healthy. Cached for ttl_seconds so dispatch doesn't
        pay a `claude -p` round-trip on every fill; a fresh check runs once the cache
        expires, which is also how a paused dispatch notices recovery and resumes.
        Logs + notifies once per ok<->fail transition, never every poll, so a sustained
        outage doesn't spam."""
        if not self.enabled:
            return True
        now = time.monotonic()
        if self._ok is not None and (now - self._checked_at) < self._ttl:
            return self._ok
        was_ok = self._ok
        self._ok, reason = self._check()
        self._checked_at = now
        if was_ok is not False and not self._ok:
            self._log(f"auth preflight failed - pausing dispatch: {reason}")
            self._notify(f"LoopWorker: claude login check failing ({reason}) - dispatch paused")
        elif was_ok is False and self._ok:
            self._log("auth preflight recovered - resuming dispatch")
            self._notify("LoopWorker: claude login recovered - dispatch resumed")
        return self._ok

    def _check(self) -> tuple[bool, str]:
        env = dict(os.environ)
        # Matches the worker launch script's own USER workaround (manager.py's
        # _write_launch) so a false positive here is never confused with a real
        # credential problem.
        env.pop("USER", None)
        try:
            r = subprocess.run(
                self._cmd, capture_output=True, text=True, timeout=self._timeout, env=env
            )
        except subprocess.TimeoutExpired:
            return False, "preflight timed out"
        except FileNotFoundError:
            return False, "claude binary not found"
        if r.returncode != 0:
            detail = (r.stderr or r.stdout or "").strip().splitlines()
            return False, (detail[-1] if detail else f"exit {r.returncode}")
        return True, ""
