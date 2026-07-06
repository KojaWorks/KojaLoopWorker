"""Detect a down container engine (Docker/OrbStack) and bring it back.

A hot Supabase slot's provision/reset shells out to `docker`/`supabase`; if the engine
VM is stopped (OrbStack paused on host memory pressure or sleep), those commands fail with
a 'cannot connect to the Docker daemon' error and the slot goes BROKEN. Rather than
stranding every hot slot until a human runs `orb start`, the Manager recovers the engine
itself: run the start command, wait for `docker ps` to succeed, then let revive_broken
re-provision the slots.

Conservative by design: only ever runs a configured, KNOWN start command (default
`orb start`), caps the wait, backs off between attempts (one restart backs off ALL pools —
share a single instance), and notifies so a human hears about it. It never masks a
genuinely dead engine behind an infinite retry.
"""
from __future__ import annotations

import re
import shlex
import subprocess
import time
from collections.abc import Callable

# The daemon-unreachable messages docker/supabase print when the engine VM is down. Matched
# case-insensitively against provision/reset output to decide a BROKEN slot is worth an
# engine-recovery attempt (vs a real provision bug, which restarting the engine won't fix).
_ENGINE_DOWN = re.compile(
    r"cannot connect to the docker daemon"
    r"|is the docker daemon running"
    r"|docker daemon is not running"
    r"|dial unix [^\s]*docker\.sock"
    r"|error during connect.*docker",
    re.IGNORECASE,
)


def looks_like_engine_down(text: str) -> bool:
    """True if `text` (a failed provision/reset's output) reads like the container engine
    is unreachable, rather than an ordinary provision bug."""
    return bool(text and _ENGINE_DOWN.search(text))


class EngineRecovery:
    def __init__(
        self,
        start_command: str = "orb start",
        probe_command: str = "docker ps",
        *,
        probe_timeout: float = 90.0,
        poll_interval: float = 2.0,
        backoff: float = 300.0,
        log: Callable[[str], None] = lambda _m: None,
        notify: Callable[[str, str], None] = lambda *_a: None,
        run: Callable[..., subprocess.CompletedProcess] = subprocess.run,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
    ):
        self._start = start_command
        self._probe_cmd = probe_command
        self._probe_timeout = probe_timeout
        self._poll = poll_interval
        self._backoff = backoff
        self._log = log
        self._notify = notify
        self._run = run
        self._sleep = sleep
        self._clock = clock
        self._retry_after = 0.0  # monotonic deadline before which we won't re-run the start command

    def recover(self) -> bool:
        """Return True if the engine is reachable — immediately if it already is, else after
        running the start command and polling the probe until it succeeds or probe_timeout
        elapses. Backs off `backoff` seconds between start attempts so a genuinely dead
        engine isn't restarted every fill; a probe that succeeds on its own clears the
        backoff. Blocks (up to probe_timeout) like a provision does."""
        if self._probe():
            self._retry_after = 0.0
            return True  # engine is up (never down, or came back on its own) — nothing to do
        if self._clock() < self._retry_after:
            return False  # down, but backing off from a recent failed start attempt
        self._log(f"engine unreachable — recovering with {self._start!r}")
        self._notify("engine-recovery",
                     f"LoopWorker: container engine unreachable — running {self._start!r} to recover")
        # Set the backoff BEFORE running, so a hung/slow start command still delays the next attempt.
        self._retry_after = self._clock() + self._backoff
        try:
            self._run(shlex.split(self._start), capture_output=True, text=True, timeout=60)
        except Exception as e:
            self._log(f"engine start command failed: {e!r}")
            return False
        deadline = self._clock() + self._probe_timeout
        while self._clock() < deadline:
            if self._probe():
                self._log("engine back up (docker reachable)")
                self._retry_after = 0.0
                return True
            self._sleep(self._poll)
        self._log(f"engine still unreachable after {self._probe_timeout:g}s — leaving slots BROKEN")
        self._notify("engine-recovery-failed",
                     f"LoopWorker: engine still down after {self._start!r} — manual intervention needed")
        return False

    def _probe(self) -> bool:
        try:
            r = self._run(shlex.split(self._probe_cmd), capture_output=True, text=True, timeout=15)
            return r.returncode == 0
        except Exception:
            return False
