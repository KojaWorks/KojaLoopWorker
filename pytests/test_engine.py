"""EngineRecovery: detect a down container engine and restart it (orb start + docker ps),
with a capped wait, backoff between attempts, and notifications — no real subprocesses."""
import types

from loopworker.engine import EngineRecovery, looks_like_engine_down


def test_looks_like_engine_down_matches_daemon_errors():
    for msg in [
        "Cannot connect to the Docker daemon at unix:///var/run/docker.sock.",
        "error during connect: Get http://.../containers/json: dial unix /root/.orbstack/run/docker.sock: no such file or directory",
        "Is the docker daemon running?",
    ]:
        assert looks_like_engine_down(msg)
    # An ordinary provision failure must NOT be read as an engine outage.
    assert not looks_like_engine_down("supabase db reset failed: relation already exists")
    assert not looks_like_engine_down("")


def _ok(code):
    return lambda *a, **k: types.SimpleNamespace(returncode=code, stdout="", stderr="")


def _seq(codes: list[int]):
    """A fake subprocess.run whose successive calls return the given exit codes in order.
    Records the argv of each call for assertions."""
    calls: list[list[str]] = []
    it = iter(codes)

    def run(argv, **k):
        calls.append(argv)
        return types.SimpleNamespace(returncode=next(it), stdout="", stderr="")

    return run, calls


def test_recover_noop_when_engine_already_up():
    run, calls = _seq([0])                      # first probe succeeds → nothing to start
    eng = EngineRecovery(run=run, clock=lambda: 0.0)
    assert eng.recover() is True
    assert calls == [["docker", "ps"]]          # probed once, never ran `orb start`


def test_recover_starts_engine_and_waits_until_reachable():
    # probe down, run start, probe still down once, then up.
    run, calls = _seq([1, 0, 1, 0])
    logs, notes = [], []
    t = [0.0]
    eng = EngineRecovery(
        run=run, log=logs.append, notify=lambda k, m: notes.append(k),
        sleep=lambda _s: t.__setitem__(0, t[0] + 2.0), clock=lambda: t[0],
    )
    # calls: [0]=initial probe(1), [1]=orb start(0), [2]=probe(1), [3]=probe(0)
    assert eng.recover() is True
    assert calls[0] == ["docker", "ps"] and calls[1] == ["orb", "start"]
    assert "engine-recovery" in notes                    # notified that it happened
    assert any("back up" in line for line in logs)


def test_recover_gives_up_after_probe_timeout_and_notifies():
    run, calls = _seq([1, 0] + [1] * 100)                # start runs, engine never comes back
    logs, notes = [], []
    t = [0.0]
    eng = EngineRecovery(
        probe_timeout=10.0, run=run, log=logs.append,
        notify=lambda k, m: notes.append(k),
        sleep=lambda _s: t.__setitem__(0, t[0] + 2.0), clock=lambda: t[0],
    )
    assert eng.recover() is False
    assert "engine-recovery-failed" in notes             # human alerted to manual intervention
    assert any("still unreachable" in line for line in logs)


def test_recover_backs_off_before_re_running_start():
    # After a failed attempt, a second recover() within the backoff window must NOT re-run
    # `orb start` — but it still probes (the engine may have come back on its own).
    run, calls = _seq([1, 0] + [1] * 100 +   # attempt 1: probe down, start, never comes up
                      [1])                    # attempt 2: probe still down → backing off, no start
    t = [0.0]
    eng = EngineRecovery(probe_timeout=4.0, backoff=300.0, run=run,
                         sleep=lambda _s: t.__setitem__(0, t[0] + 2.0), clock=lambda: t[0])
    assert eng.recover() is False
    starts = [c for c in calls if c == ["orb", "start"]]
    assert len(starts) == 1
    # t advanced during the polling but is still well within the 300s backoff.
    assert eng.recover() is False
    assert len([c for c in calls if c == ["orb", "start"]]) == 1   # no second start attempt


def test_recover_survives_a_start_command_that_raises():
    def run(argv, **k):
        if argv == ["docker", "ps"]:
            return types.SimpleNamespace(returncode=1, stdout="", stderr="")
        raise FileNotFoundError("orb not installed")
    logs = []
    eng = EngineRecovery(run=run, log=logs.append, clock=lambda: 0.0)
    assert eng.recover() is False                         # no crash — a host without orb just fails
    assert any("start command failed" in line for line in logs)
