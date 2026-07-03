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
    max_slots: int = 4                 # host-wide cap on concurrent live stacks (RAM budget)
    base_port: int = 54400
    port_step: int = 100
    roadmap_table: str = "roadmap"
    workers_table: str = "loop_workers"
    projects_table: str = "projects"
    brief_page: str = ""               # the shared generic loop page (url or id) all workers read

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
            base_port=raw.get("base_port", 54400),
            port_step=raw.get("port_step", 100),
            roadmap_table=backlog.get("roadmap_table", "roadmap"),
            workers_table=backlog.get("workers_table", "loop_workers"),
            projects_table=backlog.get("projects_table", "projects"),
            brief_page=backlog.get("brief_page", ""),
        )


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
