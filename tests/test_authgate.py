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
    gate = AuthGate(enabled=True, ttl_seconds=1000, log=logged.append,
                    notify=lambda key, msg: notified.append((key, msg)))

    assert gate.ok() is False
    assert gate.ok() is False  # cached: still one log/notify, not two
    assert len(logged) == 1 and "401" in logged[0]
    assert len(notified) == 1 and notified[0][0] == "auth-failure"


def test_recovery_logs_and_notifies_once_with_a_distinct_key(monkeypatch):
    # A distinct notify key from the failure event matters: routing both through the
    # same dedupe key (in a Notifier keyed on `key` alone) would swallow the recovery
    # alert whenever it lands inside the failure alert's own dedupe window.
    results = iter([1, 0])  # first check fails, second (after cache expiry) succeeds

    def fake_run(cmd, **kwargs):
        code = next(results)
        return subprocess.CompletedProcess(cmd, code, stdout="", stderr="boom" if code else "")
    monkeypatch.setattr(subprocess, "run", fake_run)
    logged, notified = [], []
    gate = AuthGate(enabled=True, ttl_seconds=0, log=logged.append,
                    notify=lambda key, msg: notified.append((key, msg)))

    assert gate.ok() is False
    assert gate.ok() is True
    assert any("recovered" in m for m in logged)
    keys = [k for k, _ in notified]
    assert keys == ["auth-failure", "auth-recovered"]


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


def test_unexpected_error_counts_as_failure_not_a_crash(monkeypatch):
    # A preflight check must never itself raise out of ok() — host mode shares one
    # gate across every project's reconcile/fill, so an uncaught exception here would
    # take down the whole tick, not just this one check.
    def fake_run(cmd, **kwargs):
        raise PermissionError("not executable")
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
