"""Durable, rotating, redacted on-disk log for the Manager.

`Manager.log()` / `HostManager.log()` write to an in-memory ring buffer (the dashboard,
last 200 lines) and stdout (the tmux pane) — both ephemeral and gone on restart. This adds
a rotating file so a past run's decisions (spawns, reaps, provision failures, auth events,
and the redacted lifecycle-script output that streams through `log()`) survive a restart
and can be read after the fact, instead of reconstructed from tmux scrollback and worker
transcripts.

Every line is run through `slots._redact` before it hits disk — the same discipline
`slots._run_script` applies to streamed output, enforced here belt-and-suspenders on EVERY
line, since a stray `log()` elsewhere could carry a token. Stdlib only (`logging` +
`RotatingFileHandler`); thread-safe by the handler's own lock.
"""
from __future__ import annotations

import logging
import time
from logging.handlers import RotatingFileHandler
from pathlib import Path

from .slots import _redact

_logger: logging.Logger | None = None
_path: Path | None = None


def configure(path: Path | str, *, max_bytes: int = 10 * 1024 * 1024, backups: int = 5) -> None:
    """Point the file log at `path` (rotating: `max_bytes` × `backups`, ~50 MB by default).
    Idempotent for the same path, so the host Manager and every per-project Manager can call
    it without double-writing. A different path replaces the handler."""
    global _logger, _path
    path = Path(path)
    if _logger is not None and _path == path:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    handler = RotatingFileHandler(path, maxBytes=max_bytes, backupCount=backups, encoding="utf-8")
    fmt = logging.Formatter("%(asctime)s %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
    fmt.converter = time.gmtime  # UTC, matching the dashboard's HH:MM:SS timestamps
    handler.setFormatter(fmt)
    logger = logging.getLogger("loopworker.filelog")
    logger.setLevel(logging.INFO)
    logger.propagate = False
    for h in list(logger.handlers):  # replace on re-configure so we never double-write
        logger.removeHandler(h)
        h.close()
    logger.addHandler(handler)
    _logger, _path = logger, path


def log(msg: str) -> None:
    """Append one redacted line to the file log. No-op until `configure()` has run, so
    importing the library or constructing a Manager in a test never creates a file."""
    if _logger is not None:
        _logger.info(_redact(msg))


def path() -> Path | None:
    """The active log file path, or None if unconfigured (for the dashboard / a startup line)."""
    return _path
