"""Thin wrapper over tmux for Worker sessions.

A Worker is an interactive `claude` running in a detached tmux session, so it stays
human-attachable (`tmux attach -t <session>`) for intervention. We deliver the brief
via the launch script (see manager.spawn_worker), never via `send-keys`.
"""
from __future__ import annotations

import subprocess

# pane_current_command values that mean "no Worker process — just an idle shell".
_SHELLS = {"fish", "bash", "sh", "zsh", "dash", "-fish", "-bash", "-zsh"}


def _tmux(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["tmux", *args], capture_output=True, text=True, check=False
    )


def has_session(session: str) -> bool:
    return _tmux("has-session", "-t", session).returncode == 0


def worker_running(session: str) -> bool:
    """True while a non-shell process (claude/node) holds the pane. Goes False if the
    Worker crashed back to a shell or the session is gone. NOTE: an interactive claude
    that has finished its turn but sits idle still counts as running — 'done' is judged
    from card status, not from this."""
    if not has_session(session):
        return False
    r = _tmux("display-message", "-p", "-t", session, "#{pane_current_command}")
    if r.returncode != 0:
        return False
    return r.stdout.strip() not in _SHELLS


def spawn(session: str, cwd: str, argv: list[str]) -> None:
    """Start a detached session running `argv` in `cwd`. Raises on failure."""
    r = _tmux("new-session", "-d", "-s", session, "-c", cwd, *argv)
    if r.returncode != 0:
        raise RuntimeError(f"tmux new-session failed for {session}: {r.stderr.strip()}")


def kill(session: str) -> None:
    _tmux("kill-session", "-t", session)  # best-effort; ignore if already gone


def capture(session: str, lines: int = 200) -> str:
    """Recent pane scrollback, for the dashboard / debugging."""
    r = _tmux("capture-pane", "-p", "-t", session, "-S", f"-{lines}")
    return r.stdout if r.returncode == 0 else ""


# Pane lines that are UI chrome, not the agent's actual thinking/talking.
_CHROME_PREFIXES = ("─", "❯", "⏵", "│", "╭", "╰", "│")


def _pick_summary(pane: str) -> str:
    """The most recent substantive line in pane text (an assistant step `⏺ …` or a
    thinking spinner `✢ Percolating… (24s)`), skipping box-drawing / prompt / footer
    chrome. Empty if nothing useful. Pure (no tmux) so it's testable."""
    for line in reversed(pane.splitlines()):
        s = line.strip()
        if not s or s.startswith(_CHROME_PREFIXES):
            continue
        if "mode on (shift+tab" in s or "esc to interrupt" in s:
            continue
        return s[:140]
    return ""


def summary_line(session: str, lookback: int = 40) -> str:
    """A one-line gist of what the Worker is doing right now, scraped from its pane.
    Best-effort cosmetics for the dashboard — empty string on any trouble."""
    r = _tmux("capture-pane", "-p", "-t", session, "-S", f"-{lookback}")
    return _pick_summary(r.stdout) if r.returncode == 0 else ""


def list_sessions(prefix: str = "") -> list[str]:
    r = _tmux("list-sessions", "-F", "#{session_name}")
    if r.returncode != 0:
        return []
    names = [n for n in r.stdout.splitlines() if n]
    return [n for n in names if n.startswith(prefix)] if prefix else names
