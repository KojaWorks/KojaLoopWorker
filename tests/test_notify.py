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


def test_pushover_rejection_is_logged(monkeypatch):
    # The incident: curl -s exits 0 even when Pushover rejects the message with a
    # status:0 body, so the send silently failed. The Notifier must now surface it.
    monkeypatch.setattr(subprocess, "run", lambda cmd, **k: subprocess.CompletedProcess(
        cmd, 0, stdout='{"status":0,"errors":["application token is invalid"]}'))
    logged = []
    Notifier("curl -F message=@- https://pushover", log=logged.append).send("k", "hi")
    assert logged and "rejected" in logged[0] and "invalid" in logged[0]


def test_pushover_success_is_silent(monkeypatch):
    monkeypatch.setattr(subprocess, "run", lambda cmd, **k: subprocess.CompletedProcess(
        cmd, 0, stdout='{"status":1,"request":"abc"}'))
    logged = []
    Notifier("curl -F message=@- https://pushover", log=logged.append).send("k", "hi")
    assert logged == []


def test_nonzero_exit_is_logged(monkeypatch):
    monkeypatch.setattr(subprocess, "run", lambda cmd, **k: subprocess.CompletedProcess(
        cmd, 7, stdout="", stderr="curl: (6) could not resolve host"))
    logged = []
    Notifier("curl https://nope", log=logged.append).send("k", "hi")
    assert logged and "exited 7" in logged[0] and "resolve host" in logged[0]


def test_non_json_output_is_left_alone(monkeypatch):
    # A different notify tool (not Pushover) may print human text on success — don't
    # mistake it for a rejection.
    monkeypatch.setattr(subprocess, "run", lambda cmd, **k: subprocess.CompletedProcess(
        cmd, 0, stdout="notification sent"))
    logged = []
    Notifier("my-push-tool", log=logged.append).send("k", "hi")
    assert logged == []
