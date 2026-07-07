"""Parent-death watchdog: the Manager shuts down when the app that launched it dies,
so it never leaves orphaned workers/slot processes behind (a SIGKILLed app runs no
cleanup). Pure decision logic — no real loop needed."""
import os

from loopworker import manager as manager_mod
from loopworker.manager import parent_gone, watched_parent_pid


def test_watched_pid_from_env(monkeypatch):
    monkeypatch.setenv("LOOPWORKER_PARENT_PID", "4242")
    assert watched_parent_pid() == 4242


def test_watched_pid_unset_disables(monkeypatch):
    # Opt-in only: no env => no watch, so unsupervised/nohup runs keep normal survival.
    monkeypatch.delenv("LOOPWORKER_PARENT_PID", raising=False)
    assert watched_parent_pid() is None


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


def test_parent_gone_true_and_logs_when_dead(monkeypatch):
    # Deterministic: force the liveness probe to report the parent dead (a real reaped
    # pid can be recycled between reap and check).
    monkeypatch.setattr(manager_mod, "_pid_alive", lambda pid: False)
    logs: list[str] = []
    assert parent_gone(4242, logs.append) is True
    assert logs and "gone" in logs[0]
