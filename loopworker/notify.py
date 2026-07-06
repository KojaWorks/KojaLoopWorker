"""Pluggable outbound notifications for Manager interventions — a worker auth
failure, a slot marked BROKEN, and similar conditions a human should hear about
promptly instead of discovering cold in the dashboard.

No baked-in integration: `notify_command` (host config) is a shell command template
that receives the message on stdin, so Pushover is just a curl one-liner
(`curl -s -F token=... -F user=... -F message=@- https://api.pushover.net/1/messages.json`)
and any other CLI push tool works the same way.
"""
from __future__ import annotations

import json
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
            result = subprocess.run(
                self._command, shell=True, input=message, text=True,
                capture_output=True, timeout=20,
            )
        except Exception as e:
            self._log(f"notify command failed: {e!r}")
            return
        self._check(key, result)

    def _check(self, key: str, result) -> None:
        """Surface a send that failed WITHOUT raising a subprocess exception. curl -s exits
        0 even on an API rejection, so the incident (a Pushover status:0) left no trace. A
        non-zero exit, or a JSON body whose `status` isn't 1 (Pushover's ok marker), is now
        logged. Non-JSON output from some other notify tool is left alone."""
        if result is None:
            return
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "").strip()[:200]
            self._log(f"notify {key!r} command exited {result.returncode}: {detail}")
            return
        body = (result.stdout or "").strip()
        try:
            parsed = json.loads(body)
        except (ValueError, TypeError):
            return  # not a JSON API response — nothing to validate
        if isinstance(parsed, dict) and "status" in parsed and parsed.get("status") != 1:
            self._log(f"notify {key!r} rejected by API: {body[:200]}")
