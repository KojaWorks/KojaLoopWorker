"""Host-prerequisite checks: can this box actually run workers right now?

The Manager already fails a spawn on a dead claude login (`authgate.py`); this is the
operator-facing complement — a one-shot readiness sweep that `loopworker doctor` and the
Mac app's readiness panel render, so a human sees "Docker not running" *before* starting
the Manager instead of after a slot goes BROKEN. It answers the 2am question the dashboard
can't: not "what is the Manager doing" but "why won't it start".

Each check is self-contained and NEVER raises: a check that can't even run is a failed
check with a remedy, not a crash. The subprocess/HTTP calls are injectable so the suite
tests the decision without shelling out to a real `claude`/`docker`.
"""
from __future__ import annotations

import os
import shlex
import shutil
import subprocess
from collections.abc import Callable, Sequence
from dataclasses import dataclass

from .slots import _redact  # same secret-scrub every streaming surface uses

# Same headless probe AuthGate uses — a cheap call that fails fast on a dead login.
CLAUDE_PREFLIGHT = ("claude", "-p", "ok", "--model", "haiku")

# The fix for a failing headless login. NOT "run `claude` and log in": an interactive login
# does not carry over to the headless `claude -p` workers (and this preflight) run on — that's
# the whole trap this check exists to catch. A long-lived `claude setup-token` in the env is
# what headless mode reads. The Mac app renders this same string on its readiness row.
_SETUP_TOKEN_REMEDY = (
    "run `claude setup-token` and put CLAUDE_CODE_OAUTH_TOKEN=... in ~/.loopworker/.env "
    "(an interactive `claude` login does not carry to headless workers)"
)

Runner = Callable[[Sequence[str], float], subprocess.CompletedProcess]
HttpProbe = Callable[[str], int]


@dataclass
class Check:
    name: str          # short id: claude | engine | tmux | git | backlog
    ok: bool
    detail: str        # one line: what we found
    remedy: str = ""   # what a human does about a failure (empty when ok)
    required: bool = True  # a failed REQUIRED check means "not ready"; a recommended one is a warning
    #                        (e.g. a container engine isn't needed by an Xcode-only project)

    def as_dict(self) -> dict:
        return {"name": self.name, "ok": self.ok, "detail": self.detail,
                "remedy": self.remedy, "required": self.required}


def _default_runner(cmd: Sequence[str], timeout: float) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env.pop("USER", None)  # match the worker-launch + authgate USER workaround
    return subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout, env=env)


def _default_http_probe(url: str) -> int:
    import httpx  # local import: `doctor` shouldn't pay httpx startup unless it probes
    return httpx.get(url, timeout=5.0).status_code


def _last_line(r: subprocess.CompletedProcess) -> str:
    detail = (r.stderr or r.stdout or "").strip().splitlines()
    # doctor streams this to stdout / --json (the Mac panel) — redact secret-shaped tokens
    # first, same as filelog/slots. Today's probes emit no secrets, but the gate is by
    # construction, not by trusting that stays true.
    return _redact(detail[-1] if detail else f"exit {r.returncode}")


def check_claude(runner: Runner = _default_runner, timeout: float = 20.0) -> Check:
    """The load-bearing one: workers spend THIS host's claude compute, and a dead login
    silently wedges every spawn at an interactive /login prompt (see authgate.py)."""
    if not shutil.which("claude"):
        return Check("claude", False, "claude not on PATH",
                     f"install Claude Code, then {_SETUP_TOKEN_REMEDY}")
    try:
        r = runner(CLAUDE_PREFLIGHT, timeout)
    except subprocess.TimeoutExpired:
        return Check("claude", False, "login preflight timed out",
                     "check the network; re-run `claude -p ok` to confirm the login")
    except Exception as e:
        return Check("claude", False, f"preflight failed to run: {e!r}", _SETUP_TOKEN_REMEDY)
    if r.returncode == 0:
        return Check("claude", True, "login healthy")
    return Check("claude", False, _last_line(r), _SETUP_TOKEN_REMEDY)


def check_engine(probe: str = "docker ps", start_hint: str = "orb start",
                 runner: Runner = _default_runner, timeout: float = 15.0) -> Check:
    """The container engine most projects' provision/reset scripts drive. A stopped
    Docker/OrbStack is the classic "everything goes BROKEN" cause."""
    try:
        cmd = shlex.split(probe)  # operator config — a mismatched quote must FAIL, not raise
    except ValueError as e:
        return Check("engine", False, f"bad probe command {probe!r}: {e}",
                     "fix engine.probe_command in ~/.loopworker/config.toml")
    if not cmd or not shutil.which(cmd[0]):
        return Check("engine", False, f"{probe!r}: command not found",
                     "install a container engine (Docker / OrbStack)")
    try:
        r = runner(cmd, timeout)
    except subprocess.TimeoutExpired:
        return Check("engine", False, f"{probe!r} timed out", f"start the engine (`{start_hint}`)")
    except Exception as e:
        return Check("engine", False, f"{probe!r} failed to run: {e!r}",
                     f"start the engine (`{start_hint}`)")
    if r.returncode == 0:
        return Check("engine", True, "container engine reachable")
    return Check("engine", False, _last_line(r), f"start the engine (`{start_hint}`)")


def check_tool(name: str, binary: str, remedy: str) -> Check:
    path = shutil.which(binary)
    return Check(name, True, path) if path else Check(name, False, f"{binary} not on PATH", remedy)


def check_backlog(api_base: str | None, probe: HttpProbe = _default_http_probe) -> Check:
    """Reachability only: ANY HTTP response (even 401/404) means the backlog host answered;
    only a connection-level failure (DNS, refused, offline) is a real not-ready. We don't
    validate the PAT here — that's the Manager's job, and a 401 still proves reachability."""
    if not api_base:
        return Check("backlog", False, "no host config (backlog api_base unset)",
                     "create ~/.loopworker/config.toml (see README)")
    try:
        code = probe(api_base)
    except Exception as e:
        return Check("backlog", False, f"unreachable: {e!r}", "check the network / backlog.api_base")
    return Check("backlog", True, f"reachable (HTTP {code})")


def check_config(config) -> Check:
    """Host-config completeness for the keys that silently DEGRADE the loop when absent
    rather than block it: brief_page (workers lose the shared generic loop protocol) and
    app_base/roadmap_page_id (the dashboard's ~NNN card links fall back to plain text).
    Recommended, not required — the Manager still runs. It lives here because the Manager
    only whispers these to the log at startup, and 'nobody reads the console of the app':
    the readiness panel is where a config gap becomes visible and actionable."""
    missing = [k for k in ("brief_page", "app_base", "roadmap_page_id")
               if not getattr(config, k, "")]
    if not missing:
        return Check("config", True, "brief + dashboard links set")
    return Check("config", False, f"missing [backlog]: {', '.join(missing)}",
                 "re-run onboarding, or add them under [backlog] in ~/.loopworker/config.toml",
                 required=False)


def check_all(config=None, *, runner: Runner = _default_runner,
              http_probe: HttpProbe = _default_http_probe) -> list[Check]:
    """The full sweep. `config` is a HostConfig (or None when there isn't one yet — then the
    engine probe falls back to the default and the backlog check reports the missing config)."""
    probe = getattr(config, "engine_probe_command", "docker ps")
    start = getattr(config, "engine_start_command", "orb start")
    api_base = getattr(config, "api_base", None)
    engine = check_engine(probe, start, runner)
    engine.required = False  # recommended, not required: a project that provisions no container
    #                          stack (e.g. a native/Xcode build) runs fine without one.
    checks = [
        check_claude(runner),
        engine,
        check_tool("tmux", "tmux", "install tmux (`brew install tmux` / `apt install tmux`)"),
        check_tool("git", "git", "install git"),
        check_backlog(api_base, http_probe),
    ]
    # Config-completeness only matters once a config EXISTS; with none, the backlog check
    # above already reports the real problem (unconfigured → onboarding), so don't double up.
    if config is not None:
        checks.append(check_config(config))
    return checks
