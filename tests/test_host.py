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

    def active_count(self):
        return len(self.slots)


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
        ProjectRow(id="p1", name="Patch", repo="git@x", hot=True, slots=3, weight=2.0, model="opus"),
        ProjectRow(id="p2", name="GitZ", repo="git@y", hot=False,
                   default_branch="master", brief_ref="https://patch/app/gitz-brief"),
    ])
    h.discover()
    assert len(h.managers) == 2
    a, b = h.managers
    assert a.project_id == "p1" and a.pool.hot is True and a.manifest.slots == 3   # row.slots override
    assert a.name_prefix == "patch-"
    assert h._weights == {"p1": 2.0, "p2": 1.0}                                    # weight tracked, default 1
    assert a._project_model == "opus" and b._project_model is None                # row.model wired per project
    assert b.project_id == "p2" and b.pool.hot is False
    assert a.adapter is h.adapter                                                  # shared adapter injected
    # generic loop brief injected (no manifest on the shared adapter to resolve it from)
    assert "loop-abc" in a._brief and a._project_brief is None                     # Patch uses repo BRIEF.md
    assert "gitz-brief" in b._project_brief                                        # GitZ overrides via brief_ref
    assert b.pool.base_ref == "origin/master"                                      # default_branch wired
    # distinct port bands wide enough for the host budget — no overlap
    assert b.pool.base_port - a.pool.base_port >= h.host.max_slots * h.host.port_step
    # both projects share ONE auth gate + notifier — a dead login pauses dispatch
    # host-wide, not per project (they all draw on the same forwarded claude login)
    assert a.auth is h.auth_gate and b.auth is h.auth_gate
    assert a._notify == h.notifier.send and b._notify == h.notifier.send


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
    assert "EXIT SIGNAL" in prompt   # status flip is the reap trigger — must be the last step


def test_discover_skips_project_without_contract(tmp_path, monkeypatch):
    import loopworker.host as host_mod
    monkeypatch.setattr(HostManager, "_ensure_clone", lambda self, row: tmp_path / "missing")
    scaffolded = []
    monkeypatch.setattr(HostManager, "_scaffold_if_needed", lambda self, row: scaffolded.append(row))
    # Manifest.load raises FileNotFoundError for a clone with no .loopworker — skipped, not fatal.
    h = _host(tmp_path, projects=[ProjectRow(id="p1", name="Broken", repo="git@x")])
    h.discover()
    assert h.managers == []
    assert [r.name for r in scaffolded] == ["Broken"]   # scaffold kicked off before giving up


def _scaffold_host(tmp_path, monkeypatch, *, clone_ok=True, session_running=False):
    """A host wired for _scaffold_if_needed tests: fake git clone + tmux, no network."""
    import loopworker.host as host_mod
    h = _host(tmp_path)
    calls = {"clone": [], "spawn": []}

    def fake_run(argv, **kw):
        calls["clone"].append(argv)
        if clone_ok:
            # simulate `git clone` creating the dir (with the .git/info/ a real clone ships)
            (Path(argv[-1]) / ".git" / "info").mkdir(parents=True, exist_ok=True)
        return types.SimpleNamespace(returncode=0 if clone_ok else 1, stderr="" if clone_ok else "boom")

    monkeypatch.setattr(host_mod.subprocess, "run", fake_run)
    monkeypatch.setattr(host_mod.tmux, "has_session", lambda s: session_running)
    monkeypatch.setattr(host_mod.tmux, "spawn",
                        lambda session, cwd, argv, env=None: calls["spawn"].append((session, cwd, argv, env)))
    monkeypatch.setattr(host_mod, "watch_trust", lambda session, log: None)
    return h, calls


def test_scaffold_spawns_once_per_project(tmp_path, monkeypatch):
    h, calls = _scaffold_host(tmp_path, monkeypatch)
    row = ProjectRow(id="p1", name="Broken Repo", repo="git@x:broken.git")

    h._scaffold_if_needed(row)

    assert len(calls["clone"]) == 1 and calls["clone"][0][:2] == ["git", "clone"]
    assert len(calls["spawn"]) == 1
    session, cwd, argv, env = calls["spawn"][0]
    assert session == "lw-scaffold-broken-repo"
    # nested under _scaffold/ (never a "<slug>-scaffold" sibling — see collision-safety test below)
    assert cwd == str(h.host.clones_dir / "_scaffold" / "broken-repo")
    assert argv == ["bash", str(Path(cwd) / ".loopworker-scaffold-launch.sh")]
    marker = h.state_dir / "scaffold-broken-repo.attempted"
    assert marker.exists()

    h._scaffold_if_needed(row)  # second call: marker guards against a respawn
    assert len(calls["spawn"]) == 1


def test_scaffold_dir_cannot_collide_with_a_real_project_clone_dir(tmp_path, monkeypatch):
    # Regression: an old "<slug>-scaffold" sibling naming would collide with a project whose
    # OWN name happens to slug to that string (e.g. real project "Broken Scaffold" cloning to
    # clones_dir/broken-scaffold — the same path "Broken"'s scaffold used to rmtree into).
    # Nesting under "_scaffold/" makes this impossible: _slug() strips underscores, so no
    # project's real clone dir (clones_dir/_slug(name)) can ever equal clones_dir/_scaffold/...
    h, calls = _scaffold_host(tmp_path, monkeypatch)
    h._scaffold_if_needed(ProjectRow(id="p1", name="Broken", repo="git@x"))
    scaffold_dir = Path(calls["spawn"][0][1])
    assert scaffold_dir.parent.name == "_scaffold"
    real_clone_dir = h.host.clones_dir / _slug_of("Broken Scaffold")
    assert scaffold_dir != real_clone_dir
    assert not str(scaffold_dir).startswith(str(real_clone_dir))


def _slug_of(name):
    from loopworker.manager import _slug
    return _slug(name)


def test_scaffold_writes_launch_script_and_excludes_its_own_files(tmp_path, monkeypatch):
    h, calls = _scaffold_host(tmp_path, monkeypatch)
    h._scaffold_if_needed(ProjectRow(id="p1", name="Melur", repo="git@x:melur.git"))
    scaffold_dir = Path(calls["spawn"][0][1])

    launch = (scaffold_dir / ".loopworker-scaffold-launch.sh").read_text()
    assert "unset USER" in launch
    assert 'exec claude --permission-mode auto "$PROMPT"' in launch
    assert 'cat .loopworker-scaffold-prompt.txt' in launch

    prompt_file = (scaffold_dir / ".loopworker-scaffold-prompt.txt").read_text()
    assert prompt_file == h._scaffold_prompt(ProjectRow(id="p1", name="Melur", repo="git@x:melur.git"))

    # the agent's own plumbing must never leak into the PR it opens
    exclude = (scaffold_dir / ".git" / "info" / "exclude").read_text()
    assert ".loopworker-scaffold-prompt.txt" in exclude
    assert ".loopworker-scaffold-launch.sh" in exclude


def test_scaffold_forwards_default_worker_env(tmp_path, monkeypatch):
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "tok-123")
    h, calls = _scaffold_host(tmp_path, monkeypatch)
    h._scaffold_if_needed(ProjectRow(id="p1", name="Melur", repo="git@x:melur.git"))
    _, _, _, env = calls["spawn"][0]
    assert env == {"CLAUDE_CODE_OAUTH_TOKEN": "tok-123"}


def test_scaffold_skips_without_repo(tmp_path, monkeypatch):
    h, calls = _scaffold_host(tmp_path, monkeypatch)
    h._scaffold_if_needed(ProjectRow(id="p1", name="No Repo", repo=None))
    assert calls["spawn"] == []


def test_scaffold_skips_if_session_already_running(tmp_path, monkeypatch):
    h, calls = _scaffold_host(tmp_path, monkeypatch, session_running=True)
    h._scaffold_if_needed(ProjectRow(id="p1", name="Broken", repo="git@x"))
    assert calls["spawn"] == []
    assert not (h.state_dir / "scaffold-broken.attempted").exists()


def test_scaffold_clone_failure_is_logged_not_raised_and_no_marker(tmp_path, monkeypatch):
    h, calls = _scaffold_host(tmp_path, monkeypatch, clone_ok=False)
    h._scaffold_if_needed(ProjectRow(id="p1", name="Broken", repo="git@x"))
    assert calls["spawn"] == []
    assert not (h.state_dir / "scaffold-broken.attempted").exists()   # no marker -> retried next poll
    assert any("scaffold spawn failed" in line for line in h.log_lines)


def test_scaffold_prompt_covers_the_contract_and_guardrails(tmp_path, monkeypatch):
    h, _ = _scaffold_host(tmp_path, monkeypatch)
    prompt = h._scaffold_prompt(ProjectRow(id="p1", name="Melur", repo="git@x:melur.git"))
    assert "[project]" in prompt and "[scripts]" in prompt      # inlined manifest schema
    assert "xcodebuild" in prompt and "pytest" in prompt         # stack-guessing hints
    assert "gh pr create" in prompt and "Do NOT merge it yourself" in prompt
    assert "7-bit ASCII" in prompt
    assert "do not claim or create any card" in prompt           # not a recurring loop worker


def test_ensure_clone_refreshes_existing_clone(tmp_path, monkeypatch):
    """Regression: an existing clone must be fetched + hard-reset to the latest default
    branch. Without it the clone (and the manifest loaded from it) stays frozen at
    first-clone forever — not even a host restart picks up a manifest.toml change."""
    import loopworker.host as host_mod
    h = _host(tmp_path)
    row = ProjectRow(id="p1", name="Patch", repo="git@x", default_branch="main")
    (h.host.clones_dir / "patch" / ".git").mkdir(parents=True)   # clone already present

    calls: list = []
    monkeypatch.setattr(host_mod.subprocess, "run",
                        lambda argv, **kw: (calls.append(argv),
                                            types.SimpleNamespace(returncode=0, stderr=""))[1])
    dest = h._ensure_clone(row)

    assert dest == h.host.clones_dir / "patch"
    assert [c[3] for c in calls] == ["fetch", "reset"]     # refreshed, in order
    assert calls[1][-1] == "origin/main"                   # to the default branch


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


def test_apply_slot_targets_caps_cold_to_max_slots(tmp_path):
    # A cold pool with more slots than max_slots would overflow its port band into the
    # next project's — cap it (concurrency is separately capped in _fill_all anyway).
    h = _host(tmp_path, max_slots=3)
    cold = FakeMgr("C", hot=False, nslots=1, project_id="p1")
    h.managers = [cold]
    h._apply_slot_targets({"p1": ProjectRow(id="p1", name="C", hot=False, slots=6)})
    assert len(cold.pool.slots) == 3


def test_apply_slot_targets_spends_budget_in_weighted_units(tmp_path):
    # A weight=2 (heavy) project's slots cost double — 2 slots exhaust a 4-slot budget,
    # leaving only 2 units (i.e. 2 slots at weight 1) for the next hot project.
    h = _host(tmp_path, max_slots=4)
    a = FakeMgr("A", hot=True, nslots=1, project_id="p1")
    b = FakeMgr("B", hot=True, nslots=1, project_id="p2")
    h.managers = [a, b]
    rows = {"p1": ProjectRow(id="p1", name="A", hot=True, slots=3, weight=2.0),
            "p2": ProjectRow(id="p2", name="B", hot=True, slots=3)}
    h._apply_slot_targets(rows)
    assert len(a.pool.slots) == 2    # 2 slots * weight 2 = the whole 4-unit budget
    assert len(b.pool.slots) == 0    # nothing left
    assert h._weights["p1"] == 2.0 and h._weights["p2"] == 1.0


def test_apply_slot_targets_ignores_zero_or_negative_weight(tmp_path):
    for bad_weight in (0, -2.0):
        h = _host(tmp_path, max_slots=2)
        a = FakeMgr("A", hot=True, nslots=1, project_id="p1")
        h.managers = [a]
        h._apply_slot_targets({"p1": ProjectRow(id="p1", name="A", hot=True, slots=1, weight=bad_weight)})
        assert len(a.pool.slots) == 1     # falls back to 1, not a divide-by-zero/negative-budget
        assert h._weights["p1"] == 1.0


def test_affordable_tolerates_fractional_weight_float_error(tmp_path):
    # Regression: a naive `remaining // weight` undercounts by one slot for weights not
    # exactly representable in binary floats (e.g. int(1 // 0.1) == 9, not 10).
    from loopworker.host import _affordable
    assert _affordable(1, 0.1) == 10
    assert _affordable(2, 0.2) == 10
    assert _affordable(10, 0.1) == 100


def test_build_caps_hot_pools_to_weighted_budget(tmp_path):
    h = _host(tmp_path, max_slots=4)
    h.managers = [FakeMgr("A", hot=True, nslots=3, project_id="p1"),
                  FakeMgr("B", hot=True, nslots=2, project_id="p2")]
    h._weights = {"p1": 2.0, "p2": 1.0}
    h.build()
    assert len(h.managers[0].pool.slots) == 2     # A's 3 slots at weight 2 -> capped to 2 (4 units)
    assert len(h.managers[1].pool.slots) == 0     # nothing left for B


def test_fill_all_cold_shares_leftover_in_weighted_units(tmp_path):
    h = _host(tmp_path, max_slots=4)
    hot = FakeMgr("A", hot=True, nslots=1, will_take=1, project_id="p1")
    cold = FakeMgr("C", hot=False, nslots=5, will_take=5, project_id="p2")
    h.managers = [hot, cold]
    h._weights = {"p1": 1.0, "p2": 2.0}   # C is a heavy (weight 2) cold project
    h._fill_all(now=None)
    # budget = 4 - reserved_hot(1*1) - cold_busy(0) = 3; at weight 2 that's 1 affordable slot
    assert cold.fills == [1]
