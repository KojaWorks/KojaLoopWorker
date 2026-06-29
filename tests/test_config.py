import textwrap

import pytest

from loopworker.config import Manifest


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
