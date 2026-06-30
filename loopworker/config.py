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
    wallclock_cap_minutes: int = 90


@dataclass
class ScriptsConfig:
    provision: str = "provision.sh"
    reset: str = "reset.sh"
    verify: str = "verify.sh"
    teardown: str = "teardown.sh"


@dataclass
class Manifest:
    project_name: str
    project_dir: Path                  # the working copy root (--project)
    backlog: BacklogConfig
    brief: BriefConfig
    worker: WorkerConfig
    slots: int
    scripts: ScriptsConfig

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
                wallclock_cap_minutes=raw.get("worker", {}).get("wallclock_cap_minutes", 90),
            ),
            slots=raw.get("slots", {}).get("count", 1),
            scripts=ScriptsConfig(**raw.get("scripts", {})),
        )
        return manifest
