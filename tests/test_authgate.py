"""AuthGate: cached claude-login preflight, transition logging/notify, no subprocess
calls when disabled (the default)."""
import subprocess

import pytest

from loopworker.authgate import AuthGate


def test_disabled_never_shells_out(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("subprocess.run must not be called while disabled")
    monkeypatch.setattr(subprocess, "run", boom)
    gate = AuthGate()  # enabled=False by default
    assert gate.ok() is True
    assert gate.ok() is True


def test_ok_when_command_succeeds(monkeypatch):
    def fake_run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout="ok", stderr="")
    monkeypatch.setattr(subprocess, "run", fake_run)
    gate = AuthGate(enabled=True)
    assert gate.ok() is True


def test_fails_and_notifies_once_on_transition(monkeypatch):
    def fake_run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="API Error: 401 Invalid authentication credentials")
    monkeypatch.setattr(subprocess, "run", fake_run)
    logged, notified = [], []
    gate = AuthGate(enabled=True, ttl_seconds=1000, log=logged.append, notify=notified.append)

    assert gate.ok() is False
    assert gate.ok() is False  # cached: still one log/notify, not two
    assert len(logged) == 1 and "401" in logged[0]
    assert len(notified) == 1


def test_recovery_logs_and_notifies_once(monkeypatch):
    results = iter([1, 0])  # first check fails, second (after cache expiry) succeeds

    def fake_run(cmd, **kwargs):
        code = next(results)
        return subprocess.CompletedProcess(cmd, code, stdout="", stderr="boom" if code else "")
    monkeypatch.setattr(subprocess, "run", fake_run)
    logged = []
    gate = AuthGate(enabled=True, ttl_seconds=0, log=logged.append)

    assert gate.ok() is False
    assert gate.ok() is True
    assert any("recovered" in m for m in logged)


def test_timeout_counts_as_failure(monkeypatch):
    def fake_run(cmd, **kwargs):
        raise subprocess.TimeoutExpired(cmd, kwargs.get("timeout", 0))
    monkeypatch.setattr(subprocess, "run", fake_run)
    gate = AuthGate(enabled=True)
    assert gate.ok() is False


def test_missing_binary_counts_as_failure(monkeypatch):
    def fake_run(cmd, **kwargs):
        raise FileNotFoundError()
    monkeypatch.setattr(subprocess, "run", fake_run)
    gate = AuthGate(enabled=True)
    assert gate.ok() is False


def test_check_strips_user_from_env(monkeypatch):
    monkeypatch.setenv("USER", "someone")
    seen_env = {}

    def fake_run(cmd, **kwargs):
        seen_env.update(kwargs.get("env") or {})
        return subprocess.CompletedProcess(cmd, 0)
    monkeypatch.setattr(subprocess, "run", fake_run)
    gate = AuthGate(enabled=True)
    gate.ok()
    assert "USER" not in seen_env
