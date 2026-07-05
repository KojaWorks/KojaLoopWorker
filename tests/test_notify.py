"""Notifier: shells out to notify_command with the message on stdin, deduped per key."""
import subprocess

from loopworker.notify import Notifier


def test_empty_command_is_noop(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("must not run with no command configured")
    monkeypatch.setattr(subprocess, "run", boom)
    Notifier("").send("k", "hello")


def test_sends_message_on_stdin(monkeypatch):
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append((cmd, kwargs.get("input")))
        return subprocess.CompletedProcess(cmd, 0)
    monkeypatch.setattr(subprocess, "run", fake_run)
    Notifier("curl -F message=@- https://example/notify").send("k", "hello world")
    assert calls == [("curl -F message=@- https://example/notify", "hello world")]


def test_dedupes_same_key_within_window(monkeypatch):
    calls = []
    monkeypatch.setattr(subprocess, "run", lambda cmd, **k: calls.append(cmd))
    n = Notifier("echo", dedupe_seconds=10_000)
    n.send("auth", "first")
    n.send("auth", "second")
    assert len(calls) == 1


def test_different_keys_both_fire(monkeypatch):
    calls = []
    monkeypatch.setattr(subprocess, "run", lambda cmd, **k: calls.append(cmd))
    n = Notifier("echo", dedupe_seconds=10_000)
    n.send("auth", "a")
    n.send("slot-broken:proj:0", "b")
    assert len(calls) == 2


def test_notify_command_failure_is_logged_not_raised(monkeypatch):
    def boom(cmd, **kwargs):
        raise OSError("no shell")
    monkeypatch.setattr(subprocess, "run", boom)
    logged = []
    Notifier("echo", log=logged.append).send("k", "hello")
    assert logged and "notify command failed" in logged[0]
