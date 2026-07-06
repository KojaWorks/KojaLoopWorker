"""Guard the shipped Linux-service artifacts (packaging/): the systemd unit and the install
script. They're the Phase 2 distribution contract, so break-the-contract edits should fail
the suite, not a headless operator's box."""
import subprocess
from pathlib import Path

PACKAGING = Path(__file__).resolve().parent.parent / "packaging"


def test_service_unit_is_wellformed():
    unit = (PACKAGING / "loopworker.service").read_text()
    unit.encode("ascii")  # config files are 7-bit ASCII; raises on a stray smart quote
    # The load-bearing directives the operator's `systemctl --user` relies on.
    assert "ExecStart=%h/.local/bin/loopworker" in unit  # pipx's bin dir
    assert "KillSignal=SIGTERM" in unit                  # stop == force-stop (release cards)
    assert "WantedBy=default.target" in unit             # enablable as a --user unit
    assert "Restart=on-failure" in unit                  # supervise across crashes


def test_install_script_is_valid_bash():
    script = PACKAGING / "install.sh"
    script.read_text().encode("ascii")
    # `bash -n` parses without executing — catches a syntax slip in the heredoc etc.
    assert subprocess.run(["bash", "-n", str(script)]).returncode == 0
