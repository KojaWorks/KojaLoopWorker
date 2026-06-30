"""The warm slot pool.

A slot = (git worktree, port, long-lived stack). `supabase start` (or any project's
bring-up) is the expensive part, so slots are provisioned ONCE and reused across many
cards. The isolation guarantee is *reset on acquire* — never trust that a (possibly
crashed) previous tenant left the slot clean.

The Manager owns git/worktree mechanics here; the project owns its stack via the
.loopworker lifecycle scripts. Each script runs with LOOPWORKER_SLOT_DIR and
LOOPWORKER_PORT in its environment, and may print a line `LOOPWORKER_PORT=<n>` on
stdout to report the port it actually bound (e.g. a project whose own tooling derives
the port from the worktree path).
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

from .config import Manifest
from .models import Slot, SlotState

_PORT_LINE = re.compile(r"^LOOPWORKER_PORT=(\d+)\s*$", re.MULTILINE)


class SlotError(RuntimeError):
    pass


class SlotPool:
    def __init__(self, manifest: Manifest, base_port: int = 54400, port_step: int = 100):
        self.manifest = manifest
        self.base_port = base_port
        self.port_step = port_step
        # Slot worktrees live OUTSIDE the main working copy (a worktree nested inside
        # its own repo is an anti-pattern) — as a sibling directory.
        self.root = manifest.project_dir.parent / f"{manifest.project_dir.name}.loopworker-slots"
        self.slots: list[Slot] = [
            Slot(index=i, dir=str(self.root / f"slot-{i}"), port=base_port + i * port_step)
            for i in range(manifest.slots)
        ]

    # --- lifecycle ---------------------------------------------------------
    def build(self) -> None:
        """Create every slot's worktree and provision its stack. Idempotent: safe to
        call on every Manager start; existing worktrees/stacks are reused."""
        self.root.mkdir(parents=True, exist_ok=True)
        for slot in self.slots:
            self._ensure_worktree(slot)
            self._provision(slot)

    def teardown(self) -> None:
        for slot in self.slots:
            self._run_script("teardown", slot, check=False)
            self._git(self.manifest.project_dir, "worktree", "remove", "--force", slot.dir, check=False)

    # --- acquire / free ----------------------------------------------------
    def acquire(self, slot: Slot, branch_slug: str) -> None:
        """Reset the slot to a clean tree on a fresh branch off origin/main and run the
        project's reset.sh (e.g. db reset). Raises SlotError on failure; the caller
        should mark the slot BROKEN and skip it."""
        wt = Path(slot.dir)
        self._git(self.manifest.project_dir, "fetch", "origin", "-q")
        self._git(wt, "reset", "--hard", "origin/main")
        self._git(wt, "clean", "-fd")
        self._git(wt, "checkout", "-B", f"claude/{branch_slug}", "origin/main")
        rc, out = self._run_script("reset", slot, check=False)
        if rc != 0:
            raise SlotError(f"reset.sh failed for slot {slot.index} (rc={rc})")
        self._capture_port(slot, out)

    def free(self, slot: Slot) -> None:
        slot.state = SlotState.IDLE
        slot.session = None
        slot.card_num = None
        slot.worker_id = None
        slot.started_at = None
        slot.done_since = None

    def idle_slots(self) -> list[Slot]:
        return [s for s in self.slots if s.state == SlotState.IDLE]

    # --- internals ---------------------------------------------------------
    def _ensure_worktree(self, slot: Slot) -> None:
        if (Path(slot.dir) / ".git").exists():
            return
        self._git(self.manifest.project_dir, "fetch", "origin", "-q")
        # Flat branch name (hyphen, not "loopworker/slot-N"): a slash makes git treat
        # "loopworker" as a directory, which collides with a plain branch named
        # "loopworker" (the obvious name for this work) — git then can't create the ref.
        self._git(
            self.manifest.project_dir,
            "worktree", "add", "-B", f"loopworker-slot-{slot.index}", slot.dir, "origin/main",
        )

    def _provision(self, slot: Slot) -> None:
        rc, out = self._run_script("provision", slot, check=False)
        if rc != 0:
            slot.state = SlotState.BROKEN
            raise SlotError(f"provision.sh failed for slot {slot.index} (rc={rc})")
        self._capture_port(slot, out)

    def _capture_port(self, slot: Slot, stdout: str) -> None:
        m = _PORT_LINE.search(stdout or "")
        if m:
            slot.port = int(m.group(1))

    def _run_script(self, which: str, slot: Slot, *, check: bool = True) -> tuple[int, str]:
        path = self.manifest.script_path(which)
        if not path.is_file():
            raise SlotError(f"missing {which} script: {path}")
        env = {
            **os.environ,
            "LOOPWORKER_SLOT_DIR": slot.dir,
            "LOOPWORKER_PORT": str(slot.port),
            "LOOPWORKER_PROJECT": self.manifest.project_name,
        }
        r = subprocess.run(
            ["bash", str(path), slot.dir],
            cwd=slot.dir if Path(slot.dir).is_dir() else str(self.manifest.project_dir),
            env=env, capture_output=True, text=True, check=False,
        )
        if check and r.returncode != 0:
            raise SlotError(f"{which} script failed (rc={r.returncode}): {r.stderr.strip()}")
        return r.returncode, r.stdout

    @staticmethod
    def _git(cwd: Path | str, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        r = subprocess.run(
            ["git", "-C", str(cwd), *args], capture_output=True, text=True, check=False
        )
        if check and r.returncode != 0:
            raise SlotError(f"git {' '.join(args)} failed in {cwd}: {r.stderr.strip()}")
        return r
