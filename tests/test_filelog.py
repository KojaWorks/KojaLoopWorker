"""filelog writes the Manager's log to a rotating, redacted on-disk file — a no-op until
configured, so importing the library or building a Manager in a test never makes a file."""
import logging
import re

import pytest

from loopworker import filelog


@pytest.fixture(autouse=True)
def _reset_filelog():
    """filelog is a module singleton — reset it around every test so they don't leak."""
    lg = logging.getLogger("loopworker.filelog")
    def clear():
        for h in list(lg.handlers):
            lg.removeHandler(h)
            h.close()
        filelog._logger = None
        filelog._path = None
    clear()
    yield
    clear()


def test_noop_before_configure(tmp_path):
    filelog.log("nothing should happen")   # unconfigured
    assert filelog.path() is None
    assert not any(tmp_path.iterdir())      # no file created


def test_writes_full_timestamped_line(tmp_path):
    f = tmp_path / "manager.log"
    filelog.configure(f)
    filelog.log("host: serving 7 project(s)")
    text = f.read_text()
    assert "host: serving 7 project(s)" in text
    assert re.search(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ", text, re.M)  # full date+time, not just HH:MM:SS
    assert filelog.path() == f


def test_redacts_secrets_before_disk(tmp_path):
    f = tmp_path / "manager.log"
    filelog.configure(f)
    filelog.log("provision: URL postgresql://postgres:supersecret@127.0.0.1:5432/db")
    filelog.log("token eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.abcdef123456")
    text = f.read_text()
    assert "supersecret" not in text and "[redacted]" in text   # db-url password scrubbed
    assert "eyJhbGci" not in text                                # JWT scrubbed


def test_rotates_when_full(tmp_path):
    f = tmp_path / "manager.log"
    filelog.configure(f, max_bytes=300, backups=2)
    for i in range(200):
        filelog.log(f"line {i} " + "x" * 40)
    assert f.exists() and (tmp_path / "manager.log.1").exists()  # rotated to a backup
