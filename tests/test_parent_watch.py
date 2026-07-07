"""Parent-death watchdog: the Manager shuts down when the app that launched it dies,
so it never leaves orphaned workers/slot processes behind (a SIGKILLed app runs no
cleanup). Pure decision logic — no real loop needed."""
import os
import subprocess
import sys

from loopworker.manager import parent_gone, watched_parent_pid


def _dead_pid() -> int:
    """A pid guaranteed not alive: spawn a trivial process, reap it, reuse its pid."""
    p = subprocess.Popen([sys.executable, "-c", ""])
    p.wait()
    return p.pid


def test_watched_pid_prefers_env(monkeypatch):
    monkeypatch.setenv("LOOPWORKER_PARENT_PID", "4242")
    assert watched_parent_pid() == 4242


def test_watched_pid_falls_back_to_real_parent(monkeypatch):
    monkeypatch.delenv("LOOPWORKER_PARENT_PID", raising=False)
    assert watched_parent_pid() == os.getppid()


def test_watched_pid_disabled_for_init_parent(monkeypatch):
    # pid <= 1 (parent already launchd/init) => watch off: reparenting to 1 is normal there.
    for val in ("1", "0", "-1"):
        monkeypatch.setenv("LOOPWORKER_PARENT_PID", val)
        assert watched_parent_pid() is None


def test_watched_pid_bad_value_disables(monkeypatch):
    monkeypatch.setenv("LOOPWORKER_PARENT_PID", "not-a-pid")
    assert watched_parent_pid() is None


def test_parent_gone_none_never_fires():
    logs: list[str] = []
    assert parent_gone(None, logs.append) is False
    assert logs == []


def test_parent_gone_false_while_alive():
    logs: list[str] = []
    assert parent_gone(os.getpid(), logs.append) is False  # self is alive
    assert logs == []


def test_parent_gone_true_and_logs_when_dead():
    logs: list[str] = []
    assert parent_gone(_dead_pid(), logs.append) is True
    assert logs and "gone" in logs[0]
