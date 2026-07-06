"""Notifier: shells out to notify_command with the message on stdin, deduped per key."""
import os
import pathlib
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from loopworker.notify import Notifier


def test_empty_command_is_noop(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("must not run with no command configured")
    monkeypatch.setattr(subprocess, "run", boom)
    Notifier("").send("k", "hello")


def test_sends_message_on_stdin(monkeypatch):
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append((cmd, kwargs.get("input")))
        return subprocess.CompletedProcess(cmd, 0)
    monkeypatch.setattr(subprocess, "run", fake_run)
    Notifier("curl -F 'message=<-' https://example/notify").send("k", "hello world")
    assert calls == [("curl -F 'message=<-' https://example/notify", "hello world")]


def test_dedupes_same_key_within_window(monkeypatch):
    calls = []
    monkeypatch.setattr(subprocess, "run", lambda cmd, **k: calls.append(cmd))
    n = Notifier("echo", dedupe_seconds=10_000)
    n.send("auth", "first")
    n.send("auth", "second")
    assert len(calls) == 1


def test_different_keys_both_fire(monkeypatch):
    calls = []
    monkeypatch.setattr(subprocess, "run", lambda cmd, **k: calls.append(cmd))
    n = Notifier("echo", dedupe_seconds=10_000)
    n.send("auth", "a")
    n.send("slot-broken:proj:0", "b")
    assert len(calls) == 2


def test_notify_command_failure_is_logged_not_raised(monkeypatch):
    def boom(cmd, **kwargs):
        raise OSError("no shell")
    monkeypatch.setattr(subprocess, "run", boom)
    logged = []
    Notifier("echo", log=logged.append).send("k", "hello")
    assert logged and "notify command failed" in logged[0]


def test_pushover_rejection_is_logged(monkeypatch):
    # The incident: curl -s exits 0 even when Pushover rejects the message with a
    # status:0 body, so the send silently failed. The Notifier must now surface it.
    monkeypatch.setattr(subprocess, "run", lambda cmd, **k: subprocess.CompletedProcess(
        cmd, 0, stdout='{"status":0,"errors":["application token is invalid"]}'))
    logged = []
    Notifier("curl -F 'message=<-' https://pushover", log=logged.append).send("k", "hi")
    assert logged and "rejected" in logged[0] and "invalid" in logged[0]


def test_pushover_success_is_silent(monkeypatch):
    monkeypatch.setattr(subprocess, "run", lambda cmd, **k: subprocess.CompletedProcess(
        cmd, 0, stdout='{"status":1,"request":"abc"}'))
    logged = []
    Notifier("curl -F 'message=<-' https://pushover", log=logged.append).send("k", "hi")
    assert logged == []


def test_nonzero_exit_is_logged(monkeypatch):
    monkeypatch.setattr(subprocess, "run", lambda cmd, **k: subprocess.CompletedProcess(
        cmd, 7, stdout="", stderr="curl: (6) could not resolve host"))
    logged = []
    Notifier("curl https://nope", log=logged.append).send("k", "hi")
    assert logged and "exited 7" in logged[0] and "resolve host" in logged[0]


def test_non_json_output_is_left_alone(monkeypatch):
    # A different notify tool (not Pushover) may print human text on success — don't
    # mistake it for a rejection.
    monkeypatch.setattr(subprocess, "run", lambda cmd, **k: subprocess.CompletedProcess(
        cmd, 0, stdout="notification sent"))
    logged = []
    Notifier("my-push-tool", log=logged.append).send("k", "hi")
    assert logged == []


def test_shipped_example_command_delivers_a_plain_message(tmp_path):
    # The mocked tests above never run a real shell/curl, so they can't catch the two
    # ways the shipped Pushover one-liner has broken in the field, both silently:
    #   - `-F message=@-` uploads stdin as a FILE part -> Pushover reads message blank
    #   - unquoted `-F message=<-` -> the shell treats < as a redirect, curl never POSTs
    # This runs the *actual* config.toml.example command exactly as the Notifier does
    # (shell=True, message on stdin) against a throwaway server, and proves the message
    # arrives as a normal form field.
    curl = shutil.which("curl")
    if not curl:
        pytest.skip("curl not on PATH")

    example = pathlib.Path(__file__).resolve().parent.parent / "config.toml.example"
    cmd = None
    for line in example.read_text().splitlines():
        key, sep, val = line.lstrip("# ").partition("=")
        if sep and key.strip() == "notify_command":
            cmd = val.strip().strip('"')
            break
    assert cmd, "no notify_command example found in config.toml.example"

    received = {}
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            received["body"] = self.rfile.read(n).decode("utf-8", "replace")
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status":1}')
        def log_message(self, *a):  # keep the test output quiet
            pass

    srv = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.handle_request, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_address[1]}/"
    run_cmd = cmd.replace("https://api.pushover.net/1/messages.json", url)

    msg = "loopworker regression: this must arrive as a plain field, not a file"
    env = {**os.environ, "PUSHOVER_TOKEN": "t", "PUSHOVER_USER": "u"}
    result = subprocess.run(run_cmd, shell=True, input=msg, text=True,
                            capture_output=True, timeout=20, env=env)
    srv.server_close()

    # unquoted `<-` fails here: /bin/sh errors on the redirect before curl runs
    assert result.returncode == 0, f"notify command failed in the shell: {result.stderr!r}"
    body = received.get("body", "")
    assert msg in body, "message text never reached the server (blank-message bug)"
    # `@-` marks the part with filename="-"; a plain field has no filename
    assert "filename=" not in body, "message was uploaded as a file part (@- bug); Pushover reads it blank"
