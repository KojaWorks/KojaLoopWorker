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
    assert h.notify_command == ""                      # default: no-op
    assert h.max_concurrent_workers == 6               # unset -> defaults to max_slots
    assert h.app_base == "" and h.roadmap_page_id == ""  # dashboard links off by default


def test_host_config_loads_dashboard_link_keys(tmp_path):
    cfg = tmp_path / "config.toml"
    cfg.write_text(textwrap.dedent("""
        worker_manager = "miquon"
        clones_dir = "~/clones"
        [backlog]
        api_base = "https://api.patch/"
        anon_key = "anon-public"
        app_base = "https://patch.d.nevyn.dev"
        roadmap_page_id = "ea3c65fb-9038-4dcb-8223-34dd395b2af8"
    """))
    h = HostConfig.load(cfg)
    assert h.app_base == "https://patch.d.nevyn.dev"
    assert h.roadmap_page_id == "ea3c65fb-9038-4dcb-8223-34dd395b2af8"


def test_max_concurrent_workers_explicit_override(tmp_path):
    cfg = tmp_path / "config.toml"
    cfg.write_text(textwrap.dedent("""
        worker_manager = "miquon"
        clones_dir = "~/clones"
        max_slots = 8
        max_concurrent_workers = 3
        [backlog]
        api_base = "https://api.patch/"
        anon_key = "anon-public"
    """))
    assert HostConfig.load(cfg).max_concurrent_workers == 3   # explicit cap honored, not max_slots


def test_host_config_notify_command(tmp_path):
    cfg = tmp_path / "config.toml"
    cfg.write_text(textwrap.dedent("""
        worker_manager = "miquon"
        clones_dir = "~/clones"
        notify_command = "curl -s -F message=@- https://example/notify"
        [backlog]
        api_base = "https://api.patch/"
        anon_key = "anon-public"
    """))
    h = HostConfig.load(cfg)
    assert h.notify_command == "curl -s -F message=@- https://example/notify"


def test_host_config_engine_defaults(tmp_path):
    cfg = tmp_path / "config.toml"
    cfg.write_text(textwrap.dedent("""
        worker_manager = "miquon"
        clones_dir = "~/clones"
        [backlog]
        api_base = "https://api.patch/"
        anon_key = "anon-public"
    """))
    h = HostConfig.load(cfg)
    assert h.engine_recover is True                     # on by default (OrbStack fleet)
    assert h.engine_start_command == "orb start"
    assert h.engine_probe_command == "docker ps"


def test_host_config_engine_override(tmp_path):
    cfg = tmp_path / "config.toml"
    cfg.write_text(textwrap.dedent("""
        worker_manager = "miquon"
        clones_dir = "~/clones"
        [backlog]
        api_base = "https://api.patch/"
        anon_key = "anon-public"
        [engine]
        recover = false
        start_command = "colima start"
        probe_command = "docker info"
    """))
    h = HostConfig.load(cfg)
    assert h.engine_recover is False
    assert h.engine_start_command == "colima start"
    assert h.engine_probe_command == "docker info"


def test_host_config_missing_required_key(tmp_path):
    cfg = tmp_path / "config.toml"
    cfg.write_text('worker_manager = "miquon"\nclones_dir = "/x"\n[backlog]\napi_base="https://a"\n')
    with pytest.raises(ValueError):                   # anon_key missing
        HostConfig.load(cfg)


def test_host_config_missing_file(tmp_path):
    with pytest.raises(FileNotFoundError):
        HostConfig.load(tmp_path / "nope.toml")
