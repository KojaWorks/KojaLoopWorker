"""Pluggable outbound notifications for Manager interventions — a worker auth
failure, a slot marked BROKEN, and similar conditions a human should hear about
promptly instead of discovering cold in the dashboard.

No baked-in integration: `notify_command` (host config) is a shell command template
that receives the message on stdin, so Pushover is just a curl one-liner
(`curl -s -F token=... -F user=... -F message=@- https://api.pushover.net/1/messages.json`)
and any other CLI push tool works the same way.
"""
from __future__ import annotations

import subprocess
import time
from collections.abc import Callable


class Notifier:
    """Runs `command` with the alert message on stdin, deduped per condition `key` so a
    sustained condition doesn't refire every reconcile tick. `command` empty (the
    default) makes send() a no-op — notify_command is opt-in."""

    def __init__(
        self,
        command: str = "",
        *,
        dedupe_seconds: float = 300.0,
        log: Callable[[str], None] = lambda msg: None,
    ):
        self._command = command
        self._dedupe = dedupe_seconds
        self._log = log
        self._last_sent: dict[str, float] = {}

    def send(self, key: str, message: str) -> None:
        if not self._command:
            return
        now = time.monotonic()
        last = self._last_sent.get(key)
        if last is not None and (now - last) < self._dedupe:
            return
        self._last_sent[key] = now
        try:
            subprocess.run(
                self._command, shell=True, input=message, text=True,
                capture_output=True, timeout=20,
            )
        except Exception as e:
            self._log(f"notify command failed: {e!r}")
