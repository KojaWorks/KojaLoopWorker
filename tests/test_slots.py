"""_run_script streams a lifecycle script's output to the log AND captures it for
the LOOPWORKER_PORT handshake; a nonzero exit raises with the failing tail."""
from pathlib import Path

import pytest

from loopworker.config import (BacklogConfig, BriefConfig, Manifest,
                               ScriptsConfig, WorkerConfig)
from loopworker.models import Slot, SlotState
from loopworker.slots import SlotError, SlotPool, _redact


def _pool(tmp_path, script: str, logs: list[str]) -> SlotPool:
    lw = tmp_path / ".loopworker"
    lw.mkdir()
    (lw / "provision.sh").write_text("#!/usr/bin/env bash\n" + script)
    m = Manifest(
        project_name="demo", project_dir=tmp_path,
        backlog=BacklogConfig("patch", "", {}), brief=BriefConfig("repo-file", "B.md"),
        worker=WorkerConfig(), slots=1, scripts=ScriptsConfig(),
    )
    return SlotPool(m, log=logs.append)


def test_run_script_streams_and_captures_port(tmp_path):
    logs: list[str] = []
    pool = _pool(tmp_path, 'echo doing-a-thing\necho LOOPWORKER_PORT=31999\n', logs)
    slot = Slot(index=0, dir=str(tmp_path), port=1)
    rc, out = pool._run_script("provision", slot)
    assert rc == 0
    assert any("doing-a-thing" in line for line in logs)      # streamed live
    pool._capture_port(slot, out)
    assert slot.port == 31999                                 # handshake parsed from captured output


def test_redact_scrubs_stack_secrets():
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.abcdef123456"
    assert _redact(f"service_role key {jwt}") == "service_role key [redacted]"
    assert _redact("Access Key 625729a08b95bf1b7ff351a663f3a23c") == "Access Key [redacted]"
    assert _redact("URL postgresql://postgres:supersecret@127.0.0.1:30402/postgres") \
        == "URL postgresql://postgres:[redacted]@127.0.0.1:30402/postgres"
    assert _redact("Applying migration 0101_personal_access_tokens.sql") \
        == "Applying migration 0101_personal_access_tokens.sql"   # ordinary lines untouched


def test_run_script_raises_with_tail_on_failure(tmp_path):
    logs: list[str] = []
    pool = _pool(tmp_path, 'echo about-to-fail\nexit 3\n', logs)
    slot = Slot(index=2, dir=str(tmp_path), port=1)
    with pytest.raises(SlotError) as e:
        pool._run_script("provision", slot)
    assert "rc=3" in str(e.value) and "about-to-fail" in str(e.value)


def _cold_pool(tmp_path):
    lw = tmp_path / ".loopworker"
    lw.mkdir()
    (lw / "provision.sh").write_text("#!/usr/bin/env bash\ntrue\n")
    m = Manifest(
        project_name="demo", project_dir=tmp_path,
        backlog=BacklogConfig("patch", "", {}), brief=BriefConfig("repo-file", "B.md"),
        worker=WorkerConfig(), slots=1, scripts=ScriptsConfig(),
    )
    return SlotPool(m, hot=False, log=lambda *_: None)


def test_cold_pool_build_provisions_nothing(tmp_path, monkeypatch):
    pool = _cold_pool(tmp_path)
    monkeypatch.setattr(pool, "_provision",
                        lambda s: (_ for _ in ()).throw(AssertionError("cold build must not provision")))
    pool.build()
    assert all(s.state == SlotState.COLD for s in pool.slots)
    assert pool.available_slots() == pool.slots          # COLD slots are available for work


def test_cold_pool_provisions_on_acquire_then_tears_down(tmp_path, monkeypatch):
    pool = _cold_pool(tmp_path)
    slot = pool.slots[0]
    calls: list = []
    monkeypatch.setattr(pool, "_ensure_worktree", lambda s: calls.append("worktree"))
    monkeypatch.setattr(pool, "_provision", lambda s: calls.append("provision"))
    monkeypatch.setattr(pool, "_git", lambda *a, **k: calls.append(("git", a[1])))
    monkeypatch.setattr(pool, "_run_script", lambda which, s, **k: (calls.append(which) or (0, "")))

    pool.acquire(slot, "card-x")
    assert calls[:2] == ["worktree", "provision"]        # cold provisions before reset
    assert "reset" in calls                              # then the normal reset.sh

    calls.clear()
    pool.recycle(slot)
    assert "teardown" in calls                           # cold teardown runs teardown.sh
    assert slot.state == SlotState.COLD                  # returned to cold (no lingering stack)
