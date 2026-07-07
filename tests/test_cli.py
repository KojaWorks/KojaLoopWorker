"""The operator subcommands: `doctor` (host-prereq sweep, standalone), `status` (pretty
-prints a running Manager's /json), and `--version`. These dispatch before the host/single
argparse so bare `loopworker` is unchanged."""
import json

import httpx
import pytest

from loopworker import __main__ as cli
from loopworker import __version__, readiness
from loopworker.config import HostConfig
from loopworker.readiness import Check


@pytest.fixture(autouse=True)
def _no_real_config(monkeypatch):
    # Never touch a real ~/.loopworker/config.toml on the host running the suite.
    monkeypatch.setattr(HostConfig, "load", classmethod(lambda cls, path=None: (_ for _ in ()).throw(FileNotFoundError())))


def test_doctor_exit_zero_when_all_ok(monkeypatch, capsys):
    monkeypatch.setattr(readiness, "check_all", lambda *a, **k: [Check("claude", True, "healthy")])
    assert cli._cmd_doctor([]) == 0
    assert "OK" in capsys.readouterr().out


def test_doctor_exit_one_when_a_check_fails(monkeypatch, capsys):
    monkeypatch.setattr(readiness, "check_all",
                        lambda *a, **k: [Check("claude", True, "healthy"),
                                         Check("engine", False, "daemon down", "run `orb start`")])
    assert cli._cmd_doctor([]) == 1
    out = capsys.readouterr().out
    assert "FAIL" in out and "orb start" in out  # remedy shown for the failure


def test_doctor_json_is_machine_readable(monkeypatch, capsys):
    monkeypatch.setattr(readiness, "check_all",
                        lambda *a, **k: [Check("git", False, "git not on PATH", "install git")])
    rc = cli._cmd_doctor(["--json"])
    payload = json.loads(capsys.readouterr().out)
    assert rc == 1 and payload["ok"] is False
    assert payload["checks"][0] == {"name": "git", "ok": False, "detail": "git not on PATH",
                                    "remedy": "install git", "required": True}


def test_doctor_recommended_failure_stays_ready(monkeypatch, capsys):
    # A failed RECOMMENDED check (e.g. no container engine) is a warning, not "not ready":
    # readiness keys on required checks only, so doctor still exits 0.
    monkeypatch.setattr(readiness, "check_all",
                        lambda *a, **k: [Check("claude", True, "ok"),
                                         Check("engine", False, "no docker", "install it", required=False)])
    rc = cli._cmd_doctor(["--json"])
    payload = json.loads(capsys.readouterr().out)
    assert rc == 0 and payload["ok"] is True          # recommended failure doesn't block
    assert any(c["name"] == "engine" and c["ok"] is False for c in payload["checks"])  # still reported


def test_doctor_surfaces_malformed_config_not_missing(monkeypatch, capsys):
    # A present-but-broken config raises ValueError from HostConfig.load; doctor must show
    # the real parse error as its own check, not collapse it to "no config".
    monkeypatch.setattr(HostConfig, "load",
                        classmethod(lambda cls, path=None: (_ for _ in ()).throw(
                            ValueError("/x/config.toml: missing required key 'api_base'"))))
    monkeypatch.setattr(readiness, "check_all", lambda *a, **k: [Check("claude", True, "ok")])
    rc = cli._cmd_doctor(["--json"])
    payload = json.loads(capsys.readouterr().out)
    assert rc == 1
    cfg = next(c for c in payload["checks"] if c["name"] == "config")
    assert "api_base" in cfg["detail"] and cfg["ok"] is False


def test_status_empty_host_shows_no_phantom_project(monkeypatch, capsys):
    snap = {"worker_manager": "miquon", "started_at": "t", "poll_interval": 300,
            "paused": False, "projects": []}  # host serving zero projects

    class Resp:
        def json(self):
            return snap
    monkeypatch.setattr(httpx, "get", lambda url, timeout: Resp())
    assert cli._cmd_status([]) == 0
    out = capsys.readouterr().out
    assert "no projects assigned" in out and "None" not in out


def test_status_reports_no_manager_when_unreachable(monkeypatch, capsys):
    def refused(url, timeout):
        raise httpx.ConnectError("connection refused")
    monkeypatch.setattr(httpx, "get", refused)
    assert cli._cmd_status([]) == 1
    assert "no running Manager" in capsys.readouterr().err


def test_status_pretty_prints_a_host_snapshot(monkeypatch, capsys):
    snap = {"worker_manager": "miquon", "started_at": "t", "poll_interval": 300, "paused": False,
            "projects": [{"project": "Patch", "hot": True,
                          "slots": [{"index": 0, "state": "busy", "card": 772, "activity": "running ~772"}]}]}

    class Resp:
        def json(self):
            return snap
    monkeypatch.setattr(httpx, "get", lambda url, timeout: Resp())
    assert cli._cmd_status([]) == 0
    out = capsys.readouterr().out
    assert "miquon" in out and "Patch" in out and "~772" in out


def test_version_flag(capsys):
    with pytest.raises(SystemExit) as e:
        cli.main(["--version"])
    assert e.value.code == 0
    assert __version__ in capsys.readouterr().out
