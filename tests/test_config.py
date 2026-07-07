import textwrap
import tomllib

import pytest

from loopworker.config import HostConfig, Manifest, config_get, config_set


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
        notify_command = "curl -s -F 'message=<-' https://example/notify"
        [backlog]
        api_base = "https://api.patch/"
        anon_key = "anon-public"
    """))
    h = HostConfig.load(cfg)
    assert h.notify_command == "curl -s -F 'message=<-' https://example/notify"


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


# --- config set/get: the app shells out to these instead of hand-writing TOML ---------

def test_config_set_creates_file_and_parent(tmp_path):
    cfg = tmp_path / "sub" / "config.toml"          # parent dir doesn't exist yet
    config_set(cfg, "worker_manager", "miquon")
    assert cfg.is_file()
    assert config_get(cfg, "worker_manager") == "miquon"


def test_config_set_nested_key_makes_table(tmp_path):
    cfg = tmp_path / "config.toml"
    config_set(cfg, "backlog.api_base", "https://api.patch")
    assert config_get(cfg, "backlog.api_base") == "https://api.patch"
    assert tomllib.loads(cfg.read_text())["backlog"]["api_base"] == "https://api.patch"


def test_config_set_int_and_bool_coercion(tmp_path):
    cfg = tmp_path / "config.toml"
    config_set(cfg, "max_slots", "8")               # arrives as a string, must land as int
    config_set(cfg, "engine.recover", "false")
    raw = tomllib.loads(cfg.read_text())
    assert raw["max_slots"] == 8 and isinstance(raw["max_slots"], int)
    assert raw["engine"]["recover"] is False


def test_config_set_bad_int_rejected(tmp_path):
    cfg = tmp_path / "config.toml"
    with pytest.raises(ValueError, match="max_slots"):
        config_set(cfg, "max_slots", "lots")


def test_config_set_preserves_every_hand_set_key(tmp_path):
    # The scar: an app writing the whole file dropped keys it didn't manage. Setting one
    # managed key must leave EVERY other key — including unknown/hand-tuned ones — intact.
    cfg = tmp_path / "config.toml"
    cfg.write_text(textwrap.dedent("""
        worker_manager = "miquon"
        clones_dir = "~/clones"
        max_slots = 12
        max_concurrent_workers = 3
        base_port = 55000
        notify_command = "push"
        [backlog]
        api_base = "https://api.patch"
        anon_key = "anon-public"
        [engine]
        recover = false
        start_command = "colima start"
    """))
    config_set(cfg, "backlog.anon_key", "rotated-key")   # the app changes exactly one thing

    h = HostConfig.load(cfg)
    assert h.anon_key == "rotated-key"                   # the change applied
    assert h.max_slots == 12                             # a tuned value survived
    assert h.max_concurrent_workers == 3
    assert h.base_port == 55000
    assert h.notify_command == "push"
    assert h.engine_recover is False
    assert h.engine_start_command == "colima start"
    assert h.api_base == "https://api.patch"


def test_config_set_output_reparses(tmp_path):
    # Whatever we emit must be valid TOML the loader can read back (values with quotes,
    # backslashes, ints, bools all round-trip).
    cfg = tmp_path / "config.toml"
    config_set(cfg, "worker_manager", 'weird"\\name')
    config_set(cfg, "max_slots", "4")
    config_set(cfg, "backlog.api_base", "https://api.patch")
    raw = tomllib.loads(cfg.read_text())
    assert raw["worker_manager"] == 'weird"\\name'
    assert raw["max_slots"] == 4
    assert raw["backlog"]["api_base"] == "https://api.patch"


def test_config_get_missing_returns_none(tmp_path):
    cfg = tmp_path / "config.toml"
    assert config_get(cfg, "worker_manager") is None     # no file yet
    config_set(cfg, "worker_manager", "miquon")
    assert config_get(cfg, "nope") is None
    assert config_get(cfg, "backlog.api_base") is None    # missing nested


def test_config_set_rejects_key_under_a_scalar(tmp_path):
    cfg = tmp_path / "config.toml"
    config_set(cfg, "worker_manager", "miquon")
    with pytest.raises(ValueError, match="not a table"):
        config_set(cfg, "worker_manager.oops", "x")
