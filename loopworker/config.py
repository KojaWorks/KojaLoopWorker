"""Load and validate a project's `.loopworker/manifest.toml`.

The working copy is the source of truth: `loopworker --project <dir>` reads
`<dir>/.loopworker/manifest.toml`. CLI flags may override individual values.
"""
from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class BacklogConfig:
    adapter: str                       # patch | notion | github  (only patch in v1)
    portal: str                        # human URL of the project's roadmap/portal
    options: dict = field(default_factory=dict)  # adapter-specific, e.g. [backlog.patch]


@dataclass
class BriefConfig:
    source: str                        # patch-page | repo-file | url
    ref: str


@dataclass
class WorkerConfig:
    mcp: list[str] = field(default_factory=list)
    # Env var NAMES the worker needs (e.g. a backend secret). The Manager forwards their
    # values from its own env into the worker's tmux session — bypassing tmux's frozen
    # server env, which otherwise hides a var added to .env after the server started.
    # Auth vars every worker needs forward by default (manager._DEFAULT_WORKER_ENV).
    env: list[str] = field(default_factory=list)
    wallclock_cap_minutes: int = 90


@dataclass
class ScriptsConfig:
    provision: str = "provision.sh"
    reset: str = "reset.sh"
    verify: str = "verify.sh"
    teardown: str = "teardown.sh"
    # Hard per-script timeouts (minutes; floats allowed). A wedged stack tool (a hung
    # docker daemon) once made reset.sh block forever and froze the whole Manager —
    # on timeout the script's process group is killed and the slot goes BROKEN.
    provision_timeout_minutes: float = 45
    reset_timeout_minutes: float = 15
    teardown_timeout_minutes: float = 10

    def __post_init__(self) -> None:
        for name in ("provision", "reset", "teardown"):
            if getattr(self, f"{name}_timeout_minutes") <= 0:
                raise ValueError(f"scripts.{name}_timeout_minutes must be > 0")


@dataclass
class HostConfig:
    """Host-level config for the per-host Manager (`~/.loopworker/config.toml`). The
    backlog connection and host identity live here, NOT in any project repo: one
    Manager serves every project in the shared backlog whose worker_manager is ours,
    cloning each on demand under clones_dir. PATCH_PAT still comes from the env."""
    worker_manager: str                # this host's Manager id
    api_base: str
    anon_key: str
    clones_dir: Path                   # where project repos are cloned
    max_slots: int = 4                 # host-wide RAM budget, in weighted slot-cost units
    #                                   (see ProjectRow.weight) — NOT a raw slot count when
    #                                   projects have non-default weights
    # host-wide cap on concurrently RUNNING workers (cards in flight), independent of the
    # weighted RAM budget: lets a host hold many cold slots for capacity but only auth/run
    # a few claudes at once. Concurrent claudes on one account race the shared OAuth refresh
    # and can trip session revocation, so keeping this low is an auth-safety measure, not
    # just RAM. 0 → default to max_slots at load.
    max_concurrent_workers: int = 0
    base_port: int = 54400
    port_step: int = 100
    roadmap_table: str = "roadmap"
    workers_table: str = "loop_workers"
    managers_table: str = "loop_managers"   # this host registers + heartbeats a row here
    projects_table: str = "projects"
    # Dashboard ~NNN linkifier: the Patch APP origin (e.g. https://patch.d.nevyn.dev — NOT
    # api_base, the API host) and the roadmap table's patch_items id. Both must be set for
    # links to render; otherwise ~NNN stays plain text.
    app_base: str = ""
    roadmap_page_id: str = ""
    brief_page: str = ""               # the shared generic loop page (url or id) all workers read
    notify_command: str = ""           # shell template receiving an alert message on stdin
    #                                   (worker auth failure, a slot marked BROKEN); empty = no-op
    # Container-engine auto-recovery: when a hot slot's provision/reset fails with a
    # daemon-unreachable error (a stopped Docker/OrbStack), the Manager runs engine_start_command
    # and waits for engine_probe_command to succeed before re-provisioning. Defaults to OrbStack
    # (the known engine on this fleet); set engine_recover = false to disable, or point the
    # commands at another engine.
    engine_recover: bool = True
    engine_start_command: str = "orb start"
    engine_probe_command: str = "docker ps"

    def __post_init__(self) -> None:
        if self.max_concurrent_workers <= 0:  # unset → run as many at once as the budget allows
            self.max_concurrent_workers = self.max_slots

    @classmethod
    def load(cls, path: str | Path | None = None) -> "HostConfig":
        path = Path(path or "~/.loopworker/config.toml").expanduser()
        if not path.is_file():
            raise FileNotFoundError(
                f"no host config at {path} — create it (worker_manager, [backlog] api_base/"
                "anon_key, clones_dir). See README."
            )
        with path.open("rb") as f:
            raw = tomllib.load(f)
        backlog = raw.get("backlog", {})
        eng = raw.get("engine", {})
        try:
            worker_manager = raw["worker_manager"]
            api_base = backlog["api_base"]
            anon_key = backlog["anon_key"]
            clones_dir = raw["clones_dir"]
        except KeyError as e:
            raise ValueError(f"{path}: missing required key {e}") from e
        return cls(
            worker_manager=worker_manager,
            api_base=api_base.rstrip("/"),
            anon_key=anon_key,
            clones_dir=Path(clones_dir).expanduser(),
            max_slots=raw.get("max_slots", 4),
            max_concurrent_workers=raw.get("max_concurrent_workers", 0),
            base_port=raw.get("base_port", 54400),
            port_step=raw.get("port_step", 100),
            roadmap_table=backlog.get("roadmap_table", "roadmap"),
            workers_table=backlog.get("workers_table", "loop_workers"),
            managers_table=backlog.get("managers_table", "loop_managers"),
            projects_table=backlog.get("projects_table", "projects"),
            app_base=backlog.get("app_base", ""),
            roadmap_page_id=backlog.get("roadmap_page_id", ""),
            brief_page=backlog.get("brief_page", ""),
            notify_command=raw.get("notify_command", ""),
            engine_recover=eng.get("recover", True),
            engine_start_command=eng.get("start_command", "orb start"),
            engine_probe_command=eng.get("probe_command", "docker ps"),
        )


# --- config.toml read-modify-write --------------------------------------------------
# The Mac app used to hand-write the whole config.toml from a fixed template, silently
# dropping any key it doesn't manage (notify_command, engine.*, base_port, a tuned
# max_slots). Instead the app shells out to `loopworker config set` so Python owns the
# format: read the existing file, change ONE key, re-emit everything else untouched.
# This module is the one home for which keys are ints/bools; anything else is a string.

_INT_KEYS = frozenset({"max_slots", "max_concurrent_workers", "base_port", "port_step"})
_BOOL_KEYS = frozenset({"engine.recover"})


def _coerce(dotted_key: str, value: str):
    """A CLI value arrives as a string; give it the type HostConfig expects, so a set of
    an int/bool key round-trips to a real int/bool in the TOML (not a string that later
    breaks arithmetic)."""
    if dotted_key in _BOOL_KEYS:
        low = value.strip().lower()
        if low in ("true", "1", "yes", "on"):
            return True
        if low in ("false", "0", "no", "off"):
            return False
        raise ValueError(f"{dotted_key} expects a boolean, got {value!r}")
    if dotted_key in _INT_KEYS:
        try:
            return int(value)
        except ValueError:
            raise ValueError(f"{dotted_key} expects an integer, got {value!r}") from None
    return value


def _toml_value(v) -> str:
    if isinstance(v, bool):          # before int — bool is an int subclass
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v) if isinstance(v, float) else str(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, list):
        return "[" + ", ".join(_toml_value(x) for x in v) + "]"
    raise ValueError(f"can't serialize {type(v).__name__} to TOML")


def _emit_toml(data: dict) -> str:
    """Serialize a parsed-TOML dict back to TOML text: top-level scalars first, then a
    [section] per nested table (dotted headers for deeper nesting). Comments aren't
    preserved (stdlib has no round-tripping TOML writer) but every key/value is."""
    lines: list[str] = []

    def emit(path: list[str], d: dict) -> None:
        scalars = [(k, v) for k, v in d.items() if not isinstance(v, dict)]
        tables = [(k, v) for k, v in d.items() if isinstance(v, dict)]
        if path:
            if lines:
                lines.append("")
            lines.append(f"[{'.'.join(path)}]")
        for k, v in scalars:
            lines.append(f"{k} = {_toml_value(v)}")
        for k, v in tables:
            emit(path + [k], v)

    emit([], data)
    return "\n".join(lines) + "\n"


def _read_config(path: Path) -> dict:
    if not path.is_file():
        return {}
    with path.open("rb") as f:
        return tomllib.load(f)


def _write_config(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    header = "# Managed by loopworker. Any hand-set key is preserved on rewrite.\n"
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(header + _emit_toml(data), encoding="utf-8")
    tmp.replace(path)   # atomic swap so a crash mid-write never leaves a half file


def config_set(path: Path, dotted_key: str, value: str) -> None:
    """Set one dotted key in config.toml, preserving every other key. Creates the file
    (and any missing parent table) if absent."""
    data = _read_config(path)
    parts = dotted_key.split(".")
    d = data
    for i, p in enumerate(parts[:-1]):
        nxt = d.get(p)
        if nxt is None:
            nxt = {}
            d[p] = nxt
        elif not isinstance(nxt, dict):
            raise ValueError(f"{'.'.join(parts[:i + 1])} is a value, not a table")
        d = nxt
    d[parts[-1]] = _coerce(dotted_key, value)
    _write_config(path, data)


def config_get(path: Path, dotted_key: str):
    """Read one dotted key from config.toml; None if the file or key is absent."""
    d = _read_config(path)
    for p in dotted_key.split("."):
        if not isinstance(d, dict) or p not in d:
            return None
        d = d[p]
    return d


@dataclass
class Manifest:
    project_name: str
    project_dir: Path                  # the working copy root (--project)
    backlog: BacklogConfig
    brief: BriefConfig
    worker: WorkerConfig
    slots: int
    scripts: ScriptsConfig
    worker_manager: str = ""           # which host's Manager serves this project; ""=serve all (back-compat)

    @property
    def loopworker_dir(self) -> Path:
        return self.project_dir / ".loopworker"

    def script_path(self, which: str) -> Path:
        """Absolute path to one of the lifecycle scripts (provision/reset/verify/teardown)."""
        name = getattr(self.scripts, which)
        return self.loopworker_dir / name

    def project_brief(self) -> str:
        """The per-project brief (.loopworker/BRIEF.md): project-specific deltas to the
        generic loop protocol — verify recipe, merge convention, gotchas. Empty if absent
        (a minimal project leans on the generic protocol + its repo's own docs)."""
        path = self.loopworker_dir / "BRIEF.md"
        return path.read_text() if path.is_file() else ""

    @classmethod
    def load(cls, project_dir: str | Path) -> "Manifest":
        project_dir = Path(project_dir).expanduser().resolve()
        path = project_dir / ".loopworker" / "manifest.toml"
        if not path.is_file():
            raise FileNotFoundError(
                f"{project_dir} is not LoopWorker-compatible: missing {path}"
            )
        with path.open("rb") as f:
            raw = tomllib.load(f)

        try:
            project = raw["project"]
            backlog = raw["backlog"]
            brief = raw["brief"]
        except KeyError as e:
            raise ValueError(f"{path}: missing required section {e}") from e

        adapter = backlog["adapter"]
        manifest = cls(
            project_name=project["name"],
            project_dir=project_dir,
            backlog=BacklogConfig(
                adapter=adapter,
                portal=backlog.get("portal", ""),
                options=backlog.get(adapter, {}),
            ),
            brief=BriefConfig(source=brief["source"], ref=brief["ref"]),
            worker=WorkerConfig(
                mcp=raw.get("worker", {}).get("mcp", []),
                env=raw.get("worker", {}).get("env", []),
                wallclock_cap_minutes=raw.get("worker", {}).get("wallclock_cap_minutes", 90),
            ),
            slots=raw.get("slots", {}).get("count", 1),
            scripts=ScriptsConfig(**raw.get("scripts", {})),
            worker_manager=project.get("worker_manager", ""),
        )
        return manifest
