"""AuthGate: cached claude-login preflight, transition logging/notify, no subprocess
calls when disabled (the default), and a preflight that can't wedge the reconcile loop.

ok()-level behaviour (caching, transitions, reclaim backoff) is driven by stubbing
_check(); _check() itself — process group, off-thread pipe read, killpg on timeout — is
exercised against real short-lived subprocesses, since that IS the thing under test."""
import subprocess
import time

from loopworker.authgate import AuthGate


def _stub_check(gate, *results):
    """Drive gate._check() from a sequence of (ok, reason) tuples; the last repeats."""
    seq = list(results)
    gate._check = lambda: seq.pop(0) if len(seq) > 1 else seq[0]


def _boom(self):
    raise AssertionError("_check must not run while disabled")


# --- ok(): caching, transitions, reclaim backoff (independent of how _check shells out) ---

def test_disabled_never_shells_out(monkeypatch):
    monkeypatch.setattr(AuthGate, "_check", _boom)
    gate = AuthGate()  # enabled=False by default
    assert gate.ok() is True
    assert gate.ok() is True


def test_ok_when_check_succeeds():
    gate = AuthGate(enabled=True)
    _stub_check(gate, (True, ""))
    assert gate.ok() is True


def test_fails_and_notifies_once_on_transition():
    gate = AuthGate(enabled=True, ttl_seconds=1000)
    logged, notified = [], []
    gate._log = logged.append
    gate._notify = lambda key, msg: notified.append((key, msg))
    _stub_check(gate, (False, "API Error: 401 Invalid authentication credentials"))

    assert gate.ok() is False
    assert gate.ok() is False  # cached: still one log/notify, not two
    assert len(logged) == 1 and "401" in logged[0]
    assert len(notified) == 1 and notified[0][0] == "auth-failure"


def test_recovery_logs_and_notifies_once_with_a_distinct_key():
    # A distinct notify key from the failure event matters: routing both through the same
    # dedupe key would swallow the recovery alert inside the failure alert's dedupe window.
    gate = AuthGate(enabled=True, ttl_seconds=0)
    logged, notified = [], []
    gate._log = logged.append
    gate._notify = lambda key, msg: notified.append((key, msg))
    _stub_check(gate, (False, "boom"), (True, ""))  # first fails, second recovers

    assert gate.ok() is False
    assert gate.ok() is True
    assert any("recovered" in m for m in logged)
    assert [k for k, _ in notified] == ["auth-failure", "auth-recovered"]


def test_unexpected_error_counts_as_failure_not_a_crash(monkeypatch):
    # A preflight must never raise out of ok() — host mode shares one gate across every
    # project's reconcile/fill, so an uncaught exception would take down the whole tick.
    monkeypatch.setattr(subprocess, "Popen",
                        lambda *a, **k: (_ for _ in ()).throw(PermissionError("nope")))
    gate = AuthGate(enabled=True)
    assert gate.ok() is False


def _always_ok(monkeypatch):
    monkeypatch.setattr(AuthGate, "_check", lambda self: (True, ""))


def _clock(monkeypatch):
    """Drive authgate's time.monotonic from a mutable list so backoff windows are
    deterministic. Returns a one-element list; bump [0] to advance the clock."""
    t = [1000.0]
    monkeypatch.setattr("loopworker.authgate.time.monotonic", lambda: t[0])
    return t


def test_auth_reclaim_pauses_dispatch_even_when_preflight_passes(monkeypatch):
    # The circuit-breaker: a login-prompt reclaim means interactive auth is broken even
    # though the headless `-p` preflight still returns 0 — ok() must pause anyway.
    _always_ok(monkeypatch)
    t = _clock(monkeypatch)
    gate = AuthGate(enabled=True, reclaim_backoff_base_seconds=30)
    assert gate.ok() is True
    gate.note_auth_reclaim()
    assert gate.ok() is False            # paused despite the preflight passing
    t[0] += 31                            # window (30s) elapsed
    assert gate.ok() is True             # resumes, re-consulting the preflight


def test_auth_reclaim_backoff_is_exponential_and_capped(monkeypatch):
    _always_ok(monkeypatch)
    t = _clock(monkeypatch)
    gate = AuthGate(enabled=True, reclaim_backoff_base_seconds=30, reclaim_backoff_cap_seconds=600)
    windows = []
    for _ in range(6):
        start = t[0]
        gate.note_auth_reclaim()
        span = 1
        while True:
            t[0] = start + span
            if gate.ok() is True:
                break
            span += 1
        windows.append(span)
        t[0] = start
    # 30, 60, 120, 240, 480, then capped at 600 (not 960)
    assert windows == [30, 60, 120, 240, 480, 600]


def test_clean_completion_resets_the_backoff_streak(monkeypatch):
    _always_ok(monkeypatch)
    t = _clock(monkeypatch)
    gate = AuthGate(enabled=True, reclaim_backoff_base_seconds=30)
    gate.note_auth_reclaim()
    gate.note_auth_reclaim()             # streak now 2 -> a 60s window
    gate.note_clean_completion()         # a worker finished cleanly
    assert gate.ok() is True             # backoff cleared immediately
    start = t[0]
    gate.note_auth_reclaim()
    t[0] = start + 31
    assert gate.ok() is True             # 30s (base), proving the streak reset


def test_disabled_gate_ignores_reclaims(monkeypatch):
    monkeypatch.setattr(AuthGate, "_check", _boom)
    gate = AuthGate()  # enabled=False
    gate.note_auth_reclaim()
    gate.note_auth_reclaim()
    assert gate.ok() is True


def test_clean_completion_is_a_noop_without_a_streak():
    logged = []
    gate = AuthGate(enabled=True, log=logged.append)
    gate.note_clean_completion()  # no live streak — must not log a spurious "cleared"
    assert logged == []


# --- _check(): the real subprocess mechanics (the wedge fix) ---

def test_check_success_real():
    gate = AuthGate(enabled=True, cmd=("bash", "-c", "echo ok; exit 0"), timeout_seconds=5)
    assert gate._check() == (True, "")


def test_check_failure_returns_last_line_real():
    gate = AuthGate(enabled=True, cmd=("bash", "-c", "echo '401 Invalid' >&2; exit 1"),
                    timeout_seconds=5)
    ok, reason = gate._check()
    assert not ok and "401 Invalid" in reason


def test_check_missing_binary_is_failure_real():
    gate = AuthGate(enabled=True, cmd=("loopworker-no-such-binary-xyz",), timeout_seconds=5)
    ok, reason = gate._check()
    assert not ok and "failed to run" in reason


def test_check_timeout_kills_group_and_reports_real():
    # A hung preflight is killed as a group and reported promptly — never waits out the sleep.
    gate = AuthGate(enabled=True, cmd=("bash", "-c", "sleep 30"), timeout_seconds=0.5)
    t0 = time.monotonic()
    ok, reason = gate._check()
    assert not ok and "timed out" in reason
    assert time.monotonic() - t0 < 5


def test_check_does_not_hang_when_grandchild_holds_pipe_real():
    # THE regression: the parent exits 0 immediately but leaves a grandchild holding stdout.
    # subprocess.run(capture_output=True) would block in communicate() until the grandchild
    # dies (defeating its timeout, wedging the loop). wait()+off-thread read returns at the
    # parent's exit regardless of the orphaned pipe.
    gate = AuthGate(enabled=True, cmd=("bash", "-c", "sleep 5 & echo ok; exit 0"),
                    timeout_seconds=10)
    t0 = time.monotonic()
    ok, _ = gate._check()
    assert ok
    assert time.monotonic() - t0 < 3   # did NOT wait for the 5s grandchild


def test_check_strips_user_from_env(monkeypatch):
    # The worker-launch USER workaround, verified against a real subprocess: USER is absent.
    monkeypatch.setenv("USER", "someone")
    gate = AuthGate(enabled=True, cmd=("bash", "-c", 'echo "USER=[$USER]" >&2; exit 1'),
                    timeout_seconds=5)
    ok, reason = gate._check()
    assert not ok and reason == "USER=[]"
