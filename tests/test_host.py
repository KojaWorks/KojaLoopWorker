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
        brief_page=kw.get("brief_page", ""),
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


class FakePool:
    def __init__(self, hot, nslots):
        self.hot = hot
        self.slots = list(range(nslots))
        self.torn = False

    def build(self):
        pass

    def teardown(self):
        self.torn = True

    def resize(self, count):
        self.slots = list(range(count))


class FakeMgr:
    """Stands in for a per-project Manager for scheduling tests."""
    def __init__(self, name, hot, nslots, busy=0, will_take=0, project_id=None):
        self.manifest = types.SimpleNamespace(project_name=name, slots=nslots)
        self.pool = FakePool(hot, nslots)
        self.project_id = project_id
        self._busy = busy
        self._will_take = will_take
        self.fills: list = []
        self.reaped = None

    def busy_count(self):
        return self._busy

    def fill(self, now, max_new=None):
        self.fills.append(max_new)
        take = self._will_take if max_new is None else min(max_new, self._will_take)
        self._busy += take

    def reconcile(self, now):
        pass

    def _reap_workers(self, reason):
        self.reaped = reason

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

    h = _host(tmp_path, brief_page="https://patch/app/loop-abc", projects=[
        ProjectRow(id="p1", name="Patch", repo="git@x", hot=True, slots=3),
        ProjectRow(id="p2", name="GitZ", repo="git@y", hot=False,
                   default_branch="master", brief_ref="https://patch/app/gitz-brief"),
    ])
    h.discover()
    assert len(h.managers) == 2
    a, b = h.managers
    assert a.project_id == "p1" and a.pool.hot is True and a.manifest.slots == 3   # row.slots override
    assert a.name_prefix == "patch-"
    assert b.project_id == "p2" and b.pool.hot is False
    assert a.adapter is h.adapter                                                  # shared adapter injected
    # generic loop brief injected (no manifest on the shared adapter to resolve it from)
    assert "loop-abc" in a._brief and a._project_brief is None                     # Patch uses repo BRIEF.md
    assert "gitz-brief" in b._project_brief                                        # GitZ overrides via brief_ref
    assert b.pool.base_ref == "origin/master"                                      # default_branch wired
    # distinct port bands wide enough for the host budget — no overlap
    assert b.pool.base_port - a.pool.base_port >= h.host.max_slots * h.host.port_step


def test_host_mode_build_prompt_uses_injected_brief(tmp_path):
    # Regression: the shared adapter has no manifest in host mode, so the Manager must use
    # the INJECTED brief/project_brief and never call adapter.get_brief() (which would crash
    # and strand the already-claimed card).
    from loopworker.config import (BacklogConfig, BriefConfig, Manifest,
                                   ScriptsConfig, WorkerConfig)
    from loopworker.manager import Manager
    from loopworker.models import Card, CardStatus, Slot, Worker

    proj = tmp_path / "proj"
    proj.mkdir()
    manifest = Manifest(
        project_name="demo", project_dir=proj,
        backlog=BacklogConfig("patch", "", {}), brief=BriefConfig("repo-file", "B.md"),
        worker=WorkerConfig(), slots=1, scripts=ScriptsConfig(),
    )

    class BadAdapter:
        def get_brief(self):
            raise AssertionError("host mode must not call adapter.get_brief()")

    m = Manager(manifest, adapter=BadAdapter(), project_id="p1",
                brief="GENERIC LOOP", project_brief="PROJECT DELTA", state_dir=tmp_path / "s")
    prompt = m._build_prompt(
        Slot(index=0, dir=str(proj), port=1),
        Card("u1", 5, "do x", CardStatus.BACKLOG, 1, project="p1"),
        Worker("w1", "ada"),
    )
    assert "GENERIC LOOP" in prompt and "PROJECT DELTA" in prompt
    # unattended workers must be told not to ask interactively, and not to merge over red CI
    assert "UNATTENDED" in prompt
    assert "NEVER merge over a red" in prompt


def test_discover_skips_project_without_contract(tmp_path, monkeypatch):
    import loopworker.host as host_mod
    monkeypatch.setattr(HostManager, "_ensure_clone", lambda self, row: tmp_path / "missing")
    # Manifest.load raises FileNotFoundError for a clone with no .loopworker — skipped, not fatal.
    h = _host(tmp_path, projects=[ProjectRow(id="p1", name="Broken", repo="git@x")])
    h.discover()
    assert h.managers == []


def _reconcile_host(tmp_path, monkeypatch, rows_box):
    """A host whose _build_manager yields FakeMgrs, so reconcile_projects can be tested
    without git/supabase/network. rows_box["rows"] is the mutable served-project set."""
    import loopworker.host as host_mod
    h = _host(tmp_path, max_slots=4)
    h.adapter.list_projects = lambda: list(rows_box["rows"])
    made: dict = {}

    def fake_build_manager(row, manifest, idx):
        m = FakeMgr(row.name, row.hot, manifest.slots, project_id=row.id)
        made[row.id] = m
        return m

    monkeypatch.setattr(h, "_build_manager", fake_build_manager)
    monkeypatch.setattr(h, "_ensure_clone", lambda row: tmp_path)
    monkeypatch.setattr(host_mod.Manifest, "load",
                        staticmethod(lambda clone: types.SimpleNamespace(slots=1, project_name="x")))
    return h, made


def test_reconcile_projects_adds_retires_and_resizes(tmp_path, monkeypatch):
    p1 = ProjectRow(id="p1", name="Patch", repo="git@x", hot=True, slots=3)
    p2 = ProjectRow(id="p2", name="Melur", repo="git@y", hot=False, slots=1)
    box = {"rows": [p1, p2]}
    h, made = _reconcile_host(tmp_path, monkeypatch, box)

    h.reconcile_projects()                                   # first pass: both built
    assert {m.project_id for m in h.managers} == {"p1", "p2"}
    assert made["p1"].manifest.slots == 3                    # row.slots override applied
    assert made["p1"].pool.hot and len(made["p1"].pool.slots) == 3
    assert not made["p2"].pool.hot

    # drop Melur, add GitZ, shrink Patch 3 -> 2 — all without a restart
    box["rows"] = [ProjectRow(id="p1", name="Patch", repo="git@x", hot=True, slots=2),
                   ProjectRow(id="p3", name="GitZ", repo="git@z", hot=False, slots=1)]
    h.reconcile_projects()
    assert {m.project_id for m in h.managers} == {"p1", "p3"}
    assert made["p2"].pool.torn and made["p2"].reaped        # retired: workers reaped + torn down
    assert len(made["p1"].pool.slots) == 2                   # Patch resized live
    assert "p3" in made                                      # GitZ picked up


def test_reconcile_projects_survives_a_backlog_error(tmp_path):
    h = _host(tmp_path)
    keep = FakeMgr("Patch", hot=True, nslots=3, project_id="p1")
    h.managers = [keep]

    def boom():
        raise RuntimeError("network blip")

    h.adapter.list_projects = boom
    h.reconcile_projects()
    assert h.managers == [keep]     # a transient read failure must not retire everything


def test_apply_slot_targets_caps_hot_to_budget(tmp_path):
    h = _host(tmp_path, max_slots=2)
    a = FakeMgr("A", hot=True, nslots=1, project_id="p1")
    b = FakeMgr("B", hot=True, nslots=1, project_id="p2")
    h.managers = [a, b]
    rows = {"p1": ProjectRow(id="p1", name="A", hot=True, slots=3),   # wants 3
            "p2": ProjectRow(id="p2", name="B", hot=True, slots=3)}   # wants 3
    h._apply_slot_targets(rows)
    assert len(a.pool.slots) == 2    # first hot project takes the whole 2-slot budget
    assert len(b.pool.slots) == 0    # nothing left for the second
