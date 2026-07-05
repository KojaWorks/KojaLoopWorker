"""Integration test for the Manager tick: a full spawn -> keep -> reap cycle and a
crash-reclaim, driven through real manager.py logic with a fake backlog and stubbed
tmux/pool (no network, no supabase, no real tmux)."""
import signal
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
    monkeypatch.setenv("PATCH_PAT", "pat_test")
    # Manager() builds a real PatchAdapter; don't exchange the PAT over the network
    # (this test swaps in FakeBacklog right after, but construction runs first).
    monkeypatch.setattr("loopworker.backlog.patch.PatchAdapter._ensure_token",
                        lambda self, force=False: None)
    project = tmp_path / "proj"
    project.mkdir()
    manifest = Manifest(
        project_name="demo", project_dir=project,
        backlog=BacklogConfig("patch", "", {"api_base": "https://x", "anon_key": "anon-test"}),
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
    monkeypatch.setattr(manager_mod.tmux, "spawn", lambda sess, cwd, argv, env=None: spawned.append(sess))
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
    launch = (Path(slot.dir) / ".loopworker-launch.sh").read_text()
    # claude-code 2.1.201: USER in the env 401s interactive sessions once MCP tools load
    assert "unset USER" in launch and launch.index("unset USER") < launch.index("exec claude")

    # tick 2: worker alive, card still In progress -> KEEP
    m.tick()
    assert slot.state == SlotState.BUSY

    # worker ships the card; tick 3 starts the reap grace, tick 4 reaps
    m.adapter.cards[1].status = CardStatus.SHIPPED
    m.tick()
    assert slot.state == SlotState.BUSY and slot.done_since is not None
    assert "reaping" in slot.activity  # dashboard reflects "finishing", not a stale "running"
    m.tick()
    assert slot.state == SlotState.IDLE
    assert killed == [spawned[0]]
    assert m.adapter.releases == []  # legitimately Shipped — not reclaimed


def test_launch_omits_model_flag_when_unset(mgr):
    m, *_ = mgr
    m.tick()
    launch = (Path(m.pool.slots[0].dir) / ".loopworker-launch.sh").read_text()
    assert "--model" not in launch
    assert 'exec claude --permission-mode auto "$PROMPT"' in launch


def test_launch_uses_card_model_over_project_default(mgr):
    m, *_ = mgr
    m._project_model = "sonnet"                    # project-wide default
    m.adapter.cards[1].model = "opus"               # card override wins
    m.tick()
    launch = (Path(m.pool.slots[0].dir) / ".loopworker-launch.sh").read_text()
    assert 'exec claude --permission-mode auto --model opus "$PROMPT"' in launch


def test_launch_falls_back_to_project_default_model(mgr):
    m, *_ = mgr
    m._project_model = "sonnet"
    m.tick()
    launch = (Path(m.pool.slots[0].dir) / ".loopworker-launch.sh").read_text()
    assert 'exec claude --permission-mode auto --model sonnet "$PROMPT"' in launch


def test_reap_workers_on_shutdown(mgr, monkeypatch):
    # A worker must not outlive its Manager — shutdown kills live worker sessions
    # AND returns the still-In-progress card to the backlog (not stranded).
    m, _state, _spawned, killed = mgr
    m.tick()                                   # spawn a worker; card 1 -> In progress
    sess = m.pool.slots[0].session
    monkeypatch.setattr(manager_mod.tmux, "has_session", lambda s: True)
    killed.clear()
    m._reap_workers("shutting down")
    assert killed == [sess]
    assert m.adapter.releases == [1]           # the unfinished card was released


def test_sigint_escalates_drain_then_force(mgr):
    # 1st ⌃C: drain (finish current, no new). 2nd ⌃C: force-stop.
    m, *_ = mgr
    m._on_signal(signal.SIGINT, None)
    assert m._draining and not m._stop
    m._on_signal(signal.SIGINT, None)
    assert m._stop


def test_sigterm_force_stops_immediately(mgr):
    m, *_ = mgr
    m._on_signal(signal.SIGTERM, None)
    assert m._stop and not m._draining


def test_third_sigint_hard_exits(mgr, monkeypatch):
    m, *_ = mgr
    m._sigint_count = 2                      # two already happened
    exits = []
    monkeypatch.setattr(manager_mod.os, "_exit", lambda code: exits.append(code))
    m._on_signal(signal.SIGINT, None)
    assert exits == [130]


def test_draining_starts_no_new_workers(mgr):
    # While draining, a tick reconciles but spawns nothing, even with a workable card.
    m, _state, spawned, _killed = mgr
    m._draining = True
    m.tick()
    assert spawned == []
    assert m.pool.slots[0].state == SlotState.IDLE


def test_default_auth_env_forwarded_to_worker(mgr, monkeypatch):
    # CLAUDE_CODE_OAUTH_TOKEN forwards into the session without a manifest declaration,
    # so headless workers stay off the host's shared keychain credential.
    m, _state, _spawned, _killed = mgr
    envs: list[dict] = []
    monkeypatch.setattr(manager_mod.tmux, "spawn",
                        lambda sess, cwd, argv, env=None: envs.append(env))
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "tok_test")
    m.tick()
    assert envs == [{"CLAUDE_CODE_OAUTH_TOKEN": "tok_test"}]


def test_reap_orphans_at_startup(mgr, monkeypatch):
    # A previous Manager that died leaves lw-<proj>-* sessions; startup kills them.
    m, _state, _spawned, killed = mgr
    monkeypatch.setattr(manager_mod.tmux, "list_sessions",
                        lambda prefix: ["lw-demo-9", "lw-demo-10"] if prefix == m._session_prefix() else [])
    killed.clear()
    m._reap_orphans()
    assert set(killed) == {"lw-demo-9", "lw-demo-10"}


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
