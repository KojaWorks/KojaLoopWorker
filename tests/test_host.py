"""HostManager: project discovery, the host slot budget (hot reserve + cold leftover),
and warm-pool capping. Real scheduling logic over fake managers/adapter — no network,
git, supabase, or tmux."""
import types
from pathlib import Path

import pytest

from loopworker.config import HostConfig
from loopworker.host import HostManager
from loopworker.models import ProjectRow


def _host(tmp_path, **kw):
    cfg = HostConfig(
        worker_manager="miquon", api_base="https://api", anon_key="anon",
        clones_dir=tmp_path / "clones", max_slots=kw.get("max_slots", 4),
    )
    # Don't build a real (network) adapter in __init__.
    import loopworker.host as host_mod
    fake_adapter = types.SimpleNamespace(list_projects=lambda: kw.get("projects", []))
    orig = host_mod.PatchAdapter.from_host
    host_mod.PatchAdapter.from_host = staticmethod(lambda h: fake_adapter)
    try:
        h = HostManager(cfg, state_dir=tmp_path / "state")
    finally:
        host_mod.PatchAdapter.from_host = orig
    h.adapter = fake_adapter
    return h


class FakeMgr:
    """Stands in for a per-project Manager for scheduling tests."""
    def __init__(self, name, hot, nslots, busy=0, will_take=0):
        self.manifest = types.SimpleNamespace(project_name=name)
        self.pool = types.SimpleNamespace(hot=hot, slots=list(range(nslots)), build=lambda: None)
        self._busy = busy
        self._will_take = will_take
        self.fills: list = []

    def busy_count(self):
        return self._busy

    def fill(self, now, max_new=None):
        self.fills.append(max_new)
        take = self._will_take if max_new is None else min(max_new, self._will_take)
        self._busy += take

    def reconcile(self, now):
        pass

    def _reap_workers(self, reason):
        pass

    def _reap_orphans(self):
        pass


def test_build_caps_hot_pools_to_budget(tmp_path):
    h = _host(tmp_path, max_slots=2)
    h.managers = [FakeMgr("A", hot=True, nslots=3), FakeMgr("B", hot=True, nslots=2)]
    h.build()
    assert len(h.managers[0].pool.slots) == 2     # A capped to the 2-slot budget
    assert len(h.managers[1].pool.slots) == 0     # B gets nothing left


def test_fill_all_hot_unbounded_cold_shares_leftover(tmp_path):
    h = _host(tmp_path, max_slots=3)
    hot = FakeMgr("A", hot=True, nslots=1, will_take=1)
    cold1 = FakeMgr("C", hot=False, nslots=5, will_take=1)   # takes 1
    cold2 = FakeMgr("D", hot=False, nslots=5, will_take=5)   # would take the rest
    h.managers = [hot, cold1, cold2]
    h._fill_all(now=None)
    assert hot.fills == [None]                  # hot fills its warm slots freely
    # budget = 3 - reserved_hot(1) - cold_busy(0) = 2; C takes 1, D offered the remaining 1
    assert cold1.fills == [2]
    assert cold2.fills == [1]


def test_fill_all_stops_cold_when_budget_exhausted(tmp_path):
    h = _host(tmp_path, max_slots=2)
    hot = FakeMgr("A", hot=True, nslots=1, will_take=1)
    cold1 = FakeMgr("C", hot=False, nslots=5, will_take=5)   # grabs all remaining
    cold2 = FakeMgr("D", hot=False, nslots=5, will_take=5)
    h.managers = [hot, cold1, cold2]
    h._fill_all(now=None)
    assert cold1.fills == [1]    # budget = 2 - 1 = 1; C takes it
    assert cold2.fills == []     # nothing left -> D never offered


def test_discover_builds_managers_and_applies_row(tmp_path, monkeypatch):
    import loopworker.host as host_mod
    from loopworker.config import (BacklogConfig, BriefConfig, Manifest,
                                   ScriptsConfig, WorkerConfig)

    def fake_manifest(_clone):
        return Manifest(
            project_name="patch", project_dir=tmp_path / "clone",
            backlog=BacklogConfig("patch", "", {}), brief=BriefConfig("repo-file", "B.md"),
            worker=WorkerConfig(), slots=1, scripts=ScriptsConfig(),
        )
    monkeypatch.setattr(host_mod.Manifest, "load", staticmethod(fake_manifest))
    monkeypatch.setattr(HostManager, "_ensure_clone", lambda self, row: tmp_path / "clone")

    h = _host(tmp_path, projects=[
        ProjectRow(id="p1", name="Patch", repo="git@x", hot=True, slots=3),
        ProjectRow(id="p2", name="GitZ", repo="git@y", hot=False),
    ])
    h.discover()
    assert len(h.managers) == 2
    a, b = h.managers
    assert a.project_id == "p1" and a.pool.hot is True and a.manifest.slots == 3   # row.slots override
    assert a.name_prefix == "patch-"
    assert b.project_id == "p2" and b.pool.hot is False
    assert a.adapter is h.adapter                                                  # shared adapter injected


def test_discover_skips_project_without_contract(tmp_path, monkeypatch):
    import loopworker.host as host_mod
    monkeypatch.setattr(HostManager, "_ensure_clone", lambda self, row: tmp_path / "missing")
    # Manifest.load raises FileNotFoundError for a clone with no .loopworker — skipped, not fatal.
    h = _host(tmp_path, projects=[ProjectRow(id="p1", name="Broken", repo="git@x")])
    h.discover()
    assert h.managers == []
