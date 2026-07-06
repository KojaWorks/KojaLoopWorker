"""Readiness sweep: each check reports ok/detail/remedy, and NONE ever raise — a check
that can't even run its probe is a FAIL with a remedy, not an exception that takes down
`doctor` (or the Mac app polling it)."""
import subprocess

from loopworker import readiness
from loopworker.readiness import (
    Check,
    check_all,
    check_backlog,
    check_claude,
    check_engine,
    check_tool,
)


def _ok(cmd, timeout):
    return subprocess.CompletedProcess(cmd, 0, stdout="ok", stderr="")


def _fail(stderr):
    def run(cmd, timeout):
        return subprocess.CompletedProcess(cmd, 1, stdout="", stderr=stderr)
    return run


def test_claude_ok(monkeypatch):
    monkeypatch.setattr(readiness.shutil, "which", lambda b: "/usr/bin/claude")
    c = check_claude(runner=_ok)
    assert c.ok and c.name == "claude"


def test_claude_missing_binary_is_fail_not_crash(monkeypatch):
    monkeypatch.setattr(readiness.shutil, "which", lambda b: None)
    c = check_claude(runner=_ok)  # runner never reached
    assert not c.ok and "PATH" in c.detail and c.remedy


def test_claude_bad_login_surfaces_last_error_line(monkeypatch):
    monkeypatch.setattr(readiness.shutil, "which", lambda b: "/usr/bin/claude")
    c = check_claude(runner=_fail("API Error: 401 Invalid authentication credentials"))
    assert not c.ok and "401" in c.detail and c.remedy


def test_claude_timeout_is_fail(monkeypatch):
    monkeypatch.setattr(readiness.shutil, "which", lambda b: "/usr/bin/claude")

    def boom(cmd, timeout):
        raise subprocess.TimeoutExpired(cmd, timeout)
    c = check_claude(runner=boom)
    assert not c.ok and "timed out" in c.detail


def test_claude_unexpected_error_is_fail_not_crash(monkeypatch):
    monkeypatch.setattr(readiness.shutil, "which", lambda b: "/usr/bin/claude")

    def boom(cmd, timeout):
        raise PermissionError("nope")
    c = check_claude(runner=boom)  # must not propagate
    assert not c.ok


def test_engine_ok(monkeypatch):
    monkeypatch.setattr(readiness.shutil, "which", lambda b: "/usr/bin/docker")
    assert check_engine("docker ps", runner=_ok).ok


def test_engine_down_gives_start_remedy(monkeypatch):
    monkeypatch.setattr(readiness.shutil, "which", lambda b: "/usr/bin/docker")
    c = check_engine("docker ps", start_hint="orb start", runner=_fail("Cannot connect to the Docker daemon"))
    assert not c.ok and "orb start" in c.remedy


def test_engine_missing_binary_is_fail(monkeypatch):
    monkeypatch.setattr(readiness.shutil, "which", lambda b: None)
    c = check_engine("docker ps", runner=_ok)
    assert not c.ok and "not found" in c.detail


def test_tool_present_and_absent(monkeypatch):
    monkeypatch.setattr(readiness.shutil, "which", lambda b: "/usr/bin/tmux")
    assert check_tool("tmux", "tmux", "install it").ok
    monkeypatch.setattr(readiness.shutil, "which", lambda b: None)
    c = check_tool("tmux", "tmux", "install it")
    assert not c.ok and c.remedy == "install it"


def test_backlog_any_http_response_is_reachable():
    # even a 401 proves the host answered — reachability, not auth validity
    assert check_backlog("https://api.example", probe=lambda url: 401).ok


def test_backlog_connection_error_is_fail():
    def boom(url):
        raise ConnectionError("refused")
    c = check_backlog("https://api.example", probe=boom)
    assert not c.ok and "unreachable" in c.detail


def test_backlog_no_config_is_fail_with_remedy():
    c = check_backlog(None)
    assert not c.ok and "config" in c.remedy


def test_check_all_covers_every_dimension(monkeypatch):
    monkeypatch.setattr(readiness.shutil, "which", lambda b: f"/usr/bin/{b}")

    class Cfg:
        api_base = "https://api.example"
        engine_probe_command = "docker ps"
        engine_start_command = "orb start"

    checks = check_all(Cfg(), runner=_ok, http_probe=lambda url: 200)
    assert {c.name for c in checks} == {"claude", "engine", "tmux", "git", "backlog"}
    assert all(c.ok for c in checks)
    assert all(isinstance(c, Check) for c in checks)


def test_check_all_without_config_still_runs_and_flags_backlog(monkeypatch):
    monkeypatch.setattr(readiness.shutil, "which", lambda b: f"/usr/bin/{b}")
    checks = {c.name: c for c in check_all(None, runner=_ok, http_probe=lambda url: 200)}
    assert not checks["backlog"].ok            # no api_base
    assert checks["claude"].ok and checks["git"].ok
