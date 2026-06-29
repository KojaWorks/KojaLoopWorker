"""Integration test for the Manager tick: a full spawn -> keep -> reap cycle and a
crash-reclaim, driven through real manager.py logic with a fake backlog and stubbed
tmux/pool (no network, no supabase, no real tmux)."""
from pathlib import Path

import pytest

from loopworker import manager as manager_mod
from loopworker.backlog.base import BacklogAdapter
from loopworker.config import (BacklogConfig, BriefConfig, Manifest,
                               ScriptsConfig, WorkerConfig)
from loopworker.manager import Manager
from loopworker.models import Card, CardStatus, SlotState, Worker


class FakeBacklog(BacklogAdapter):
    def __init__(self, manifest, cards):
        super().__init__(manifest)
        self.cards = {c.num: c for c in cards}
        self.claims: list[tuple[int, str]] = []
        self.releases: list[int] = []
        self._wid = 0

    def list_workable(self):
        return [c for c in self.cards.values()
                if c.status == CardStatus.BACKLOG and c.assignee is None]

    def get_card(self, num):
        return self.cards.get(num)

    def cards_in_progress(self):
        return [c for c in self.cards.values() if c.status == CardStatus.IN_PROGRESS]

    def register_worker(self, name, role="generic", notes=""):
        self._wid += 1
        return Worker(id=f"w{self._wid}", name=name, role=role, notes=notes)

    def claim(self, card, worker):
        if card.assignee is not None:
            return False
        card.assignee = worker.id
        card.status = CardStatus.IN_PROGRESS
        self.claims.append((card.num, worker.id))
        return True

    def release(self, card, *, note=None):
        card.assignee = None
        card.status = CardStatus.BACKLOG
        self.releases.append(card.num)

    def get_brief(self):
        return "FAKE BRIEF"


@pytest.fixture
def mgr(tmp_path, monkeypatch):
    monkeypatch.setenv("PATCH_SECRET_KEY", "test")
    project = tmp_path / "proj"
    project.mkdir()
    manifest = Manifest(
        project_name="demo", project_dir=project,
        backlog=BacklogConfig("patch", "", {"api_base": "https://x"}),
        brief=BriefConfig("repo-file", "B.md"),
        worker=WorkerConfig(), slots=1, scripts=ScriptsConfig(),
    )
    m = Manager(manifest, poll_interval=1, grace_seconds=0,
                state_dir=tmp_path / "state")
    # one workable card
    m.adapter = FakeBacklog(manifest, [Card("u1", 1, "do a thing", CardStatus.BACKLOG, 5)])
    # give the single slot a real temp dir; skip provisioning + git in acquire
    slot = m.pool.slots[0]
    sdir = tmp_path / "slot0"
    sdir.mkdir()
    slot.dir = str(sdir)
    monkeypatch.setattr(m.pool, "acquire", lambda s, slug: None)

    # control tmux from the test
    state = {"alive": True}
    spawned, killed = [], []
    monkeypatch.setattr(manager_mod.tmux, "spawn", lambda sess, cwd, argv: spawned.append(sess))
    monkeypatch.setattr(manager_mod.tmux, "kill", lambda sess: killed.append(sess))
    monkeypatch.setattr(manager_mod.tmux, "worker_running", lambda sess: state["alive"])
    return m, state, spawned, killed


def test_spawn_keep_reap_cycle(mgr):
    m, state, spawned, killed = mgr
    slot = m.pool.slots[0]

    # tick 1: claims the card, spawns a worker, slot goes BUSY
    m.tick()
    assert slot.state == SlotState.BUSY
    assert spawned == [slot.session]
    assert m.adapter.claims == [(1, "w1")]
    assert (Path(slot.dir) / ".loopworker-launch.sh").exists()

    # tick 2: worker alive, card still In progress -> KEEP
    m.tick()
    assert slot.state == SlotState.BUSY

    # worker ships the card; tick 3 starts the reap grace, tick 4 reaps
    m.adapter.cards[1].status = CardStatus.SHIPPED
    m.tick()
    assert slot.state == SlotState.BUSY and slot.done_since is not None
    m.tick()
    assert slot.state == SlotState.IDLE
    assert killed == [spawned[0]]
    assert m.adapter.releases == []  # legitimately Shipped — not reclaimed


def test_crash_reclaim(mgr):
    m, state, spawned, killed = mgr
    slot = m.pool.slots[0]

    m.tick()  # spawn
    assert slot.state == SlotState.BUSY

    # Pause spawning so we observe the reclaim in isolation (otherwise the same tick's
    # fill step would immediately re-pick the now-Backlog card — see the poison-card note).
    m.killswitch.touch()

    # worker process dies while the card is still In progress
    state["alive"] = False
    m.tick()
    assert slot.state == SlotState.IDLE        # reclaimed and freed
    assert m.adapter.releases == [1]
    assert m.adapter.cards[1].status == CardStatus.BACKLOG
    assert killed == [spawned[0]]
