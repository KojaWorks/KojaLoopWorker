import textwrap

import pytest

from loopworker.config import HostConfig, Manifest


def _write_manifest(root, body):
    d = root / ".loopworker"
    d.mkdir()
    (d / "manifest.toml").write_text(textwrap.dedent(body))
    return root


def test_loads_full_manifest(tmp_path):
    root = _write_manifest(tmp_path, """
        [project]
        name = "demo"
        [backlog]
        adapter = "patch"
        portal = "https://patch/x"
        [backlog.patch]
        api_base = "https://api.patch/"
        roadmap_table = "roadmap"
        [brief]
        source = "patch-page"
        ref = "https://patch/app/loop-runner-instructions-abc"
        [worker]
        mcp = ["patch", "chrome-devtools"]
        wallclock_cap_minutes = 45
        [slots]
        count = 3
    """)
    m = Manifest.load(root)
    assert m.project_name == "demo"
    assert m.backlog.adapter == "patch"
    assert m.backlog.options["api_base"] == "https://api.patch/"
    assert m.worker.mcp == ["patch", "chrome-devtools"]
    assert m.worker.wallclock_cap_minutes == 45
    assert m.slots == 3
    assert m.script_path("verify").name == "verify.sh"


def test_missing_manifest_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        Manifest.load(tmp_path)


def test_defaults(tmp_path):
    root = _write_manifest(tmp_path, """
        [project]
        name = "demo"
        [backlog]
        adapter = "patch"
        [brief]
        source = "repo-file"
        ref = "BRIEF.md"
    """)
    m = Manifest.load(root)
    assert m.slots == 1
    assert m.worker.wallclock_cap_minutes == 90
    assert m.scripts.provision == "provision.sh"


def test_nonpositive_script_timeout_rejected_at_load(tmp_path):
    # A typo like `reset_timeout_minutes = 0` would otherwise kill every script at t=0
    # with a baffling "timed out after 0s" — surface it as a config error instead.
    root = _write_manifest(tmp_path, """
        [project]
        name = "demo"
        [backlog]
        adapter = "patch"
        [brief]
        source = "repo-file"
        ref = "BRIEF.md"
        [scripts]
        reset_timeout_minutes = 0
    """)
    with pytest.raises(ValueError, match="reset_timeout_minutes"):
        Manifest.load(root)


def test_host_config_loads(tmp_path):
    cfg = tmp_path / "config.toml"
    cfg.write_text(textwrap.dedent("""
        worker_manager = "miquon"
        clones_dir = "~/clones"
        max_slots = 6
        [backlog]
        api_base = "https://api.patch/"
        anon_key = "anon-public"
        brief_page = "https://patch/app/loop"
    """))
    h = HostConfig.load(cfg)
    assert h.worker_manager == "miquon"
    assert h.api_base == "https://api.patch"          # trailing slash trimmed
    assert h.anon_key == "anon-public"
    assert h.max_slots == 6
    assert h.clones_dir.is_absolute()                 # ~ expanded
    assert h.projects_table == "projects"             # default
    assert h.brief_page == "https://patch/app/loop"


def test_max_concurrent_workers_defaults_to_max_slots(tmp_path):
    cfg = tmp_path / "config.toml"
    backlog = '[backlog]\napi_base="https://a"\nanon_key="k"\n'

    def top(extra=""):
        return f'worker_manager = "m"\nclones_dir = "/x"\nmax_slots = 8\n{extra}{backlog}'

    cfg.write_text(top())
    assert HostConfig.load(cfg).max_concurrent_workers == 8   # unset -> as many as there are stacks
    cfg.write_text(top("max_concurrent_workers = 3\n"))
    assert HostConfig.load(cfg).max_concurrent_workers == 3   # explicit cap honored


def test_host_config_missing_required_key(tmp_path):
    cfg = tmp_path / "config.toml"
    cfg.write_text('worker_manager = "miquon"\nclones_dir = "/x"\n[backlog]\napi_base="https://a"\n')
    with pytest.raises(ValueError):                   # anon_key missing
        HostConfig.load(cfg)


def test_host_config_missing_file(tmp_path):
    with pytest.raises(FileNotFoundError):
        HostConfig.load(tmp_path / "nope.toml")
