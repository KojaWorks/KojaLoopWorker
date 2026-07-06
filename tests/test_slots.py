"""_run_script streams a lifecycle script's output to the log AND captures it for
the LOOPWORKER_PORT handshake; a nonzero exit raises with the failing tail."""
import os
import signal
import time
import types
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
    assert slot.port_reported is True                         # project bound a port → dashboard shows it


def test_capture_port_absent_leaves_port_unreported(tmp_path):
    logs: list[str] = []
    pool = _pool(tmp_path, "true\n", logs)
    slot = Slot(index=0, dir=str(tmp_path), port=55200)
    pool._capture_port(slot, "built an iOS app, no server\n")  # native provision emits no port line
    assert slot.port_reported is False                        # → dashboard hides the (unused) port


def test_revive_broken_resets_cold(tmp_path):
    cold = _cold_pool(tmp_path)
    cold.slots[0].state = SlotState.BROKEN
    assert cold.revive_broken() == 1 and cold.slots[0].state == SlotState.COLD


def test_revive_broken_reprovisions_hot_in_place(tmp_path, monkeypatch):
    # A hot slot has no on-demand provision path, so revive_broken must re-provision it live
    # (the self-heal after e.g. a paused Docker) — success returns it to warm IDLE.
    hot = _hot_pool(tmp_path, monkeypatch)                 # _provision stubbed to succeed
    provisioned: list[int] = []
    monkeypatch.setattr(hot, "_provision", lambda s: provisioned.append(s.index))
    hot.slots[0].state = SlotState.BROKEN
    assert hot.revive_broken() == 1
    assert hot.slots[0].state == SlotState.IDLE and provisioned == [0]


def test_revive_broken_hot_failure_backs_off_before_retrying(tmp_path, monkeypatch):
    # A re-provision that keeps failing must not re-run the slow provision.sh every fill: it
    # stays BROKEN and backs off. Crucially the cooldown is measured from when the attempt
    # FINISHED — a slow-hanging provision (here 300s, > the cooldown) must NOT be instantly
    # retryable just because wall-clock passed during the attempt itself.
    clock = [1000.0]
    hot = _hot_pool(tmp_path, monkeypatch)
    hot._clock = lambda: clock[0]
    attempts: list[float] = []

    def boom(_s):
        attempts.append(clock[0])
        clock[0] += 300.0                                 # the failing provision itself burns 300s
        raise SlotError("docker down")
    monkeypatch.setattr(hot, "_provision", boom)

    hot.slots[0].state = SlotState.BROKEN
    assert hot.revive_broken() == 0 and hot.slots[0].state == SlotState.BROKEN
    assert len(attempts) == 1                              # first attempt ran (clock now 1300)

    # Even though 300s (> cooldown) elapsed DURING the attempt, the next pass must NOT retry:
    # the backoff clock starts at attempt end, not attempt start.
    assert hot.revive_broken() == 0 and len(attempts) == 1

    clock[0] += 200.0                                      # past the 180s cooldown after the attempt
    assert hot.revive_broken() == 0 and len(attempts) == 2  # retried once the backoff elapsed


class _FakeEngine:
    """Stands in for EngineRecovery — records recover() calls, returns a scripted result."""
    def __init__(self, result=True):
        self.result = result
        self.calls = 0

    def recover(self):
        self.calls += 1
        return self.result


def test_revive_broken_recovers_engine_then_reprovisions(tmp_path, monkeypatch):
    # A hot slot broken by a down engine: revive_broken restarts the engine first, then
    # re-provisions the slot back to IDLE.
    hot = _hot_pool(tmp_path, monkeypatch)
    hot._engine = _FakeEngine(result=True)
    provisioned: list[int] = []
    monkeypatch.setattr(hot, "_provision", lambda s: provisioned.append(s.index))
    hot.slots[0].state = SlotState.BROKEN
    hot.slots[0].engine_down = True
    assert hot.revive_broken() == 1
    assert hot._engine.calls == 1                     # engine restart attempted
    assert hot.slots[0].state == SlotState.IDLE and provisioned == [0]


def test_revive_broken_skips_engine_recovery_for_non_engine_break(tmp_path, monkeypatch):
    # A slot broken by an ordinary provision bug (engine_down False) must NOT trigger an
    # `orb start` — restarting the engine wouldn't fix it.
    hot = _hot_pool(tmp_path, monkeypatch)
    hot._engine = _FakeEngine(result=True)
    monkeypatch.setattr(hot, "_provision", lambda s: None)
    hot.slots[0].state = SlotState.BROKEN
    hot.slots[0].engine_down = False
    assert hot.revive_broken() == 1
    assert hot._engine.calls == 0                     # engine left alone


def test_revive_broken_backs_off_when_engine_stays_down(tmp_path, monkeypatch):
    # If the engine can't be recovered, the engine_down slot stays BROKEN and backs off —
    # revive_broken must NOT go on to re-provision into an unreachable daemon.
    clock = [1000.0]
    hot = _hot_pool(tmp_path, monkeypatch)
    hot._clock = lambda: clock[0]
    hot._engine = _FakeEngine(result=False)
    provisioned: list[int] = []
    monkeypatch.setattr(hot, "_provision", lambda s: provisioned.append(s.index))
    hot.slots[0].state = SlotState.BROKEN
    hot.slots[0].engine_down = True
    assert hot.revive_broken() == 0
    assert provisioned == []                          # never re-provisioned
    assert hot.slots[0].state == SlotState.BROKEN
    assert hot.slots[0].retry_after > clock[0]        # backed off before the next attempt


def test_provision_failure_flags_engine_down(tmp_path, monkeypatch):
    # A provision whose output looks like a down docker daemon sets engine_down; an
    # ordinary failure leaves it clear.
    logs: list[str] = []
    hot = _pool(tmp_path, "true\n", logs)       # real _provision (not the _hot_pool stub)
    monkeypatch.setattr(hot, "_run_script",
                        lambda which, s, **k: (1, "Cannot connect to the Docker daemon at unix://..."))
    slot = hot.slots[0]
    with pytest.raises(SlotError):
        hot._provision(slot)
    assert slot.engine_down is True
    monkeypatch.setattr(hot, "_run_script", lambda which, s, **k: (1, "migration 0007 failed"))
    with pytest.raises(SlotError):
        hot._provision(slot)
    assert slot.engine_down is False


def test_redact_scrubs_stack_secrets():
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.abcdef123456"
    assert _redact(f"service_role key {jwt}") == "service_role key [redacted]"
    assert _redact("Access Key 625729a08b95bf1b7ff351a663f3a23c") == "Access Key [redacted]"
    assert _redact("URL postgresql://postgres:supersecret@127.0.0.1:30402/postgres") \
        == "URL postgresql://postgres:[redacted]@127.0.0.1:30402/postgres"
    assert _redact("Applying migration 0101_personal_access_tokens.sql") \
        == "Applying migration 0101_personal_access_tokens.sql"   # ordinary lines untouched


def _assert_dead(pid: int) -> None:
    """The kernel delivers SIGKILL to the group asynchronously; poll briefly."""
    for _ in range(50):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    os.kill(pid, signal.SIGKILL)  # don't leak it past the failed assertion
    pytest.fail(f"pid {pid} survived the process-group kill")


def test_run_script_timeout_kills_whole_process_group(tmp_path):
    # A wedged docker daemon once made reset.sh hang forever and froze the Manager for
    # 7.5h. The script must be killed WITH its children (scripts spawn npm→node→… trees).
    logs: list[str] = []
    pool = _pool(tmp_path, "sleep 600 &\necho $! > child.pid\necho started\nwait\n", logs)
    pool.manifest.scripts.provision_timeout_minutes = 0.02   # 1.2s; soft warn at 0.6s
    slot = Slot(index=0, dir=str(tmp_path), port=1)
    with pytest.raises(SlotError) as e:
        pool._run_script("provision", slot)                  # check=True and check=False both raise
    assert "timed out" in str(e.value)
    assert any("still running" in line for line in logs)     # soft watchdog fired before the kill
    _assert_dead(int((tmp_path / "child.pid").read_text()))  # the backgrounded child died too


def test_teardown_timeout_stays_best_effort(tmp_path):
    logs: list[str] = []
    pool = _pool(tmp_path, "true\n", logs)
    (tmp_path / ".loopworker" / "teardown.sh").write_text("#!/usr/bin/env bash\nsleep 600\n")
    pool.manifest.scripts.teardown_timeout_minutes = 0.01
    slot = Slot(index=0, dir=str(tmp_path), port=1)
    pool.teardown_slot(slot)                                 # must NOT raise — teardown is best-effort
    assert any("teardown incomplete" in line for line in logs)


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
    monkeypatch.setattr(pool, "_git", lambda *a, **k:
                        (calls.append(("git", a[1])), types.SimpleNamespace(stdout="c0ffee0\n"))[1])
    monkeypatch.setattr(pool, "_run_script", lambda which, s, **k: (calls.append(which) or (0, "")))

    pool.acquire(slot, "card-x")
    assert calls[:2] == ["worktree", "provision"]        # cold provisions before reset
    assert "reset" in calls                              # then the normal reset.sh

    calls.clear()
    pool.recycle(slot)
    assert "teardown" in calls                           # cold teardown runs teardown.sh
    assert slot.state == SlotState.COLD                  # returned to cold (no lingering stack)


def _hot_pool(tmp_path, monkeypatch, start=1):
    """A hot pool with worktree/provision/teardown stubbed out (no git/supabase)."""
    logs: list[str] = []
    pool = _pool(tmp_path, "true\n", logs)          # constructor makes `slots=1` IDLE slot
    monkeypatch.setattr(pool, "_ensure_worktree", lambda s: None)
    monkeypatch.setattr(pool, "_provision", lambda s: None)
    if start != 1:
        pool.resize(start)
    return pool


def test_resize_grow_provisions_only_new_slots(tmp_path, monkeypatch):
    pool = _hot_pool(tmp_path, monkeypatch)
    provisioned: list[int] = []
    monkeypatch.setattr(pool, "_provision", lambda s: provisioned.append(s.index))
    pool.resize(3)
    assert {s.index for s in pool.slots} == {0, 1, 2}
    assert provisioned == [1, 2]                     # slot 0 already existed; only 1,2 are new


def test_resize_shrink_tears_down_highest_idle_first(tmp_path, monkeypatch):
    pool = _hot_pool(tmp_path, monkeypatch, start=3)
    torn: list[int] = []
    monkeypatch.setattr(pool, "teardown_slot", lambda s: torn.append(s.index))
    pool.resize(1)
    assert torn == [2, 1]                            # surplus removed highest-index first
    assert [s.index for s in pool.slots] == [0]


def test_resize_shrink_defers_a_busy_slot_until_recycled(tmp_path, monkeypatch):
    pool = _hot_pool(tmp_path, monkeypatch, start=2)
    pool.slots[1].state = SlotState.BUSY            # slot 1 is running a card
    torn: list[int] = []
    monkeypatch.setattr(pool, "teardown_slot", lambda s: torn.append(s.index))
    pool.resize(1)
    assert pool.slots[1].retiring is True           # busy slot flagged, NOT yanked
    assert torn == [] and len(pool.slots) == 2      # still present, nothing torn down yet
    assert pool.slots[1] not in pool.available_slots()  # the retiring slot gets no new work
    pool.recycle(pool.slots[1])                     # its worker finishes
    assert torn == [1] and [s.index for s in pool.slots] == [0]


def test_resize_up_revives_a_retiring_slot(tmp_path, monkeypatch):
    pool = _hot_pool(tmp_path, monkeypatch, start=2)
    pool.slots[1].state = SlotState.BUSY
    pool.resize(1)
    assert pool.slots[1].retiring is True
    added: list = []
    monkeypatch.setattr(pool, "_add_slot", lambda: added.append(1))
    pool.resize(2)                                  # need one back — revive, don't provision anew
    assert pool.slots[1].retiring is False and added == []
