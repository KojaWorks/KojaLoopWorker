"""_run_script streams a lifecycle script's output to the log AND captures it for
the LOOPWORKER_PORT handshake; a nonzero exit raises with the failing tail."""
from pathlib import Path

import pytest

from loopworker.config import (BacklogConfig, BriefConfig, Manifest,
                               ScriptsConfig, WorkerConfig)
from loopworker.models import Slot
from loopworker.slots import SlotError, SlotPool


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


def test_run_script_raises_with_tail_on_failure(tmp_path):
    logs: list[str] = []
    pool = _pool(tmp_path, 'echo about-to-fail\nexit 3\n', logs)
    slot = Slot(index=2, dir=str(tmp_path), port=1)
    with pytest.raises(SlotError) as e:
        pool._run_script("provision", slot)
    assert "rc=3" in str(e.value) and "about-to-fail" in str(e.value)
