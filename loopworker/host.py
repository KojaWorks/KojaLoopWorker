"""The per-host Manager: one process serving every project in the shared backlog whose
worker_manager is ours.

Discovers projects from the `projects` table, clones each on demand under clones_dir,
and runs a per-project Manager (reusing all its spawn/reconcile/reap logic) over a SINGLE
shared backlog adapter. A host-wide slot budget (max_slots) bounds live stacks: hot
projects keep warm pools (counted permanently); cold projects provision a slot per card
from the leftover budget and tear it down after. The budget is spent in WEIGHTED units
(each project's `weight`, default 1) rather than raw slot counts, since a slot's cost
varies wildly by project — a warm Supabase stack (a dozen containers, several GB
resident) is nothing like a cold native build (idle at rest). See _project_weight.

Deterministic and non-AI, like the single-project Manager. One process per host, guarded
by a lockfile.
"""
from __future__ import annotations

import os
import shutil
import signal
import subprocess
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

from . import filelog, tmux
from .authgate import AuthGate
from .backlog.patch import PatchAdapter, brief_pointer
from .config import HostConfig, Manifest
from .engine import EngineRecovery
from .manager import _DEFAULT_WORKER_ENV, Manager, _pid_alive, _slug, watch_trust
from .models import ProjectRow
from .notify import Notifier


def _project_weight(row: ProjectRow | None) -> float:
    """A project's relative cost per slot (default 1) — e.g. a warm Supabase stack costs
    more RAM than a cold native build, so it should spend more of the host budget per
    slot. Guards against a bad (zero/negative) config value falling back to the default
    rather than corrupting the budget arithmetic."""
    if row and row.weight and row.weight > 0:
        return row.weight
    return 1.0


def _affordable(remaining: float, weight: float) -> int:
    """floor(remaining / weight) as a slot count, tolerant of the tiny binary-float error
    a weight like 0.1/0.3/1.2 introduces — a naive `remaining // weight` can silently
    undercount by one slot (e.g. int(1 // 0.1) == 9, not 10)."""
    return int(remaining / weight + 1e-9)


class HostManager:
    def __init__(
        self,
        host: HostConfig,
        *,
        poll_interval: int = 300,
        reconcile_interval: int = 15,
        grace_seconds: int = 120,
        state_dir: Path | None = None,
    ):
        self.host = host
        self.poll_interval = poll_interval
        self.reconcile_interval = min(reconcile_interval, poll_interval)
        self.grace_seconds = grace_seconds
        self.state_dir = (state_dir or Path("state") / "host").resolve()
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.lockfile = self.state_dir / "host.lock"
        self.killswitch = self.state_dir / "PAUSED"
        self.started_at = datetime.now(timezone.utc)
        self.log_lines: deque[str] = deque(maxlen=200)
        self.notifier = Notifier(host.notify_command, log=self.log)
        # Built after log/notifier so the adapter can surface pat-exchange retry progress
        # and alert if the backend stays unreachable through startup.
        self.adapter = PatchAdapter.from_host(host, log=self.log, notify=self.notifier.send)
        # One shared gate across every project's Manager — they all draw on the same
        # forwarded claude login (_DEFAULT_WORKER_ENV), so a dead credential pauses
        # dispatch host-wide, not per project. enabled=True here (unlike a bare
        # Manager's own default): HostManager is the real spawn point, never ticked
        # with a real Manager in tests (only FakeMgr stand-ins).
        self.auth_gate = AuthGate(enabled=True, log=self.log, notify=self.notifier.send)
        # One shared engine-recovery across every pool: the container engine is a host
        # singleton, so a single `orb start` (and its backoff) must cover all of them.
        # Disabled → None, so a slot broken by a down engine just backs off as before.
        self.engine_recovery = (
            EngineRecovery(host.engine_start_command, host.engine_probe_command,
                           log=self.log, notify=self.notifier.send)
            if host.engine_recover else None
        )
        self.managers: list[Manager] = []
        self._bands: dict[str, int] = {}   # project_id -> port-band index (freed on retire, reused)
        self._weights: dict[str, float] = {}  # project_id -> slot cost (see _project_weight)
        self._stop = False
        self._draining = False
        self._sigint_count = 0

    # --- discovery / clone -------------------------------------------------
    def discover(self) -> None:
        """Read served projects from the backlog, clone any missing, and build a
        per-project Manager. A project whose clone lacks a .loopworker contract is logged
        and skipped (not fatal — the others still run), after kicking a one-off scaffolding
        agent to open a PR adding one (see _scaffold_if_needed)."""
        rows = self.adapter.list_projects()
        self.log(f"serving {len(rows)} project(s) as worker_manager={self.host.worker_manager!r}")
        # Auth forwarding is silent per-spawn, so say up front whether workers will get
        # their own credential or fall back to the host's shared (race-prone) login.
        for k in _DEFAULT_WORKER_ENV:
            self.log(f"worker auth: {k} {'set — forwarding to workers' if k in os.environ else 'NOT set — workers use the host claude login'}")
        if not self.host.brief_page:
            self.log("WARNING: no brief_page in host config — workers get no generic loop protocol; "
                     "set [backlog].brief_page to the Managed Agent Loop page")
        self.managers = []
        self._bands = {}
        self._weights = {}
        for row in rows:
            try:
                manifest = self._load_row(row)
            except Exception as e:
                self.log(f"skipping project {row.name!r}: {e}")
                continue
            self._weights[row.id] = _project_weight(row)
            self.managers.append(self._build_manager(row, manifest, self._alloc_band(row.id)))
            weight_note = f", weight {row.weight:g}" if row.weight != 1.0 else ""
            self.log(f"  {row.name}: {'hot' if row.hot else 'cold'}, {manifest.slots} slot(s){weight_note}")

    def reconcile_projects(self, now: datetime | None = None) -> None:
        """Re-read the served-project set from the backlog and reconcile it into the live
        Managers WITHOUT a restart: newly-assigned projects are cloned + built, projects
        no longer ours are drained + torn down, and a changed slot count resizes the pool.
        Runs on the poll cadence. A failed read leaves the current Managers untouched — a
        transient backlog error must never be read as 'no projects, retire everything'."""
        try:
            rows = {r.id: r for r in self.adapter.list_projects()}
        except Exception as e:
            self.log(f"project reconcile skipped — list_projects failed: {e!r}")
            return
        current = {m.project_id: m for m in self.managers}

        for pid, m in list(current.items()):  # retire projects no longer assigned to us
            if pid not in rows:
                self.log(f"{m.manifest.project_name!r} no longer assigned to this host — draining + tearing down")
                try:
                    m._reap_workers("project unassigned from this host")  # releases in-progress cards
                    m.pool.teardown()                                     # stop warm stacks, remove worktrees
                except Exception as e:
                    self.log(f"  teardown of {m.manifest.project_name!r} hit an error: {e!r}")
                self.managers.remove(m)
                self._bands.pop(pid, None)
                self._weights.pop(pid, None)

        for pid, row in rows.items():  # build newly-assigned projects
            if pid in current:
                continue
            try:
                manifest = self._load_row(row)
            except Exception as e:
                self.log(f"skipping new project {row.name!r}: {e}")
                continue
            m = self._build_manager(row, manifest, self._alloc_band(pid))
            try:
                m._reap_orphans()
                m.pool.build()  # hot: provision warm slots; cold: nothing until a card arrives
            except Exception as e:
                self.log(f"provisioning new project {row.name!r} failed: {e!r}")
            self.managers.append(m)
            self.log(f"added project {row.name}: {'hot' if row.hot else 'cold'}, {manifest.slots} slot(s)")

        for m in self.managers:  # a hot⇄cold flip changes the whole provisioning model
            row = rows.get(m.project_id)
            if row and row.hot != m.pool.hot:
                self.log(f"{m.manifest.project_name!r} hot flag is now {row.hot} — restart the Manager "
                         "to change its pool model (slot count still updates live)")

        self._apply_slot_targets(rows)

    def _load_row(self, row: ProjectRow) -> Manifest:
        """Clone the project on demand and load its .loopworker manifest, applying a
        row-level slot-count override. Raises if the clone lacks a contract — after kicking
        a one-off scaffolding attempt (see _scaffold_if_needed) so the project can eventually
        onboard itself instead of sitting skipped forever."""
        dest = self._ensure_clone(row)
        try:
            manifest = Manifest.load(dest)
        except FileNotFoundError:
            self._scaffold_if_needed(row)
            raise
        if row.slots:
            manifest.slots = row.slots
        return manifest

    def _scaffold_if_needed(self, row: ProjectRow) -> None:
        """A registered project whose clone has no .loopworker contract can't be served. Kick
        a one-off agent — in a throwaway clone of its own, never the shared clones_dir/<project>
        directory _ensure_clone refreshes with `git reset --hard` — to inspect the repo and open
        a PR adding a best-guess contract. Once per project (a marker file): a human reviewing
        that PR shouldn't be fighting a respawn every poll interval. Best-effort: never raises,
        so a scaffold failure can't take down discovery for the other projects."""
        if not row.repo:
            return
        marker = self.state_dir / f"scaffold-{_slug(row.name)}.attempted"
        if marker.exists():
            return
        session = f"lw-scaffold-{_slug(row.name)}"
        if tmux.has_session(session):
            return
        # Nested under a "_scaffold" namespace (never a sibling like "<slug>-scaffold") so it
        # can NEVER collide with another project's real clones_dir/_slug(name) directory —
        # _slug() strips underscores, so no project's real clone dir can ever land here.
        scaffold_dir = self.host.clones_dir / "_scaffold" / _slug(row.name)
        try:
            if scaffold_dir.exists():
                shutil.rmtree(scaffold_dir)
            scaffold_dir.parent.mkdir(parents=True, exist_ok=True)
            r = subprocess.run(["git", "clone", row.repo, str(scaffold_dir)],
                               capture_output=True, text=True)
            if r.returncode != 0:
                raise RuntimeError(f"git clone failed: {r.stderr.strip()}")
            launch = self._write_scaffold_launch(scaffold_dir, row)
            env = {k: os.environ[k] for k in _DEFAULT_WORKER_ENV if k in os.environ}
            tmux.spawn(session, str(scaffold_dir), ["bash", str(launch)], env=env)
            watch_trust(session, self.log)
            marker.write_text(datetime.now(timezone.utc).isoformat())
            self.log(f"no .loopworker contract for {row.name!r} — spawned scaffolding agent ({session})")
        except Exception as e:
            self.log(f"scaffold spawn failed for {row.name!r}: {e!r}")

    def _write_scaffold_launch(self, scaffold_dir: Path, row: ProjectRow) -> Path:
        prompt = self._scaffold_prompt(row)
        # Local-only excludes (never committed themselves) so a `git add -A` by the agent
        # can't sweep our own launch plumbing into the PR it opens for human review.
        exclude = scaffold_dir / ".git" / "info" / "exclude"
        with exclude.open("a") as f:
            f.write("\n.loopworker-scaffold-prompt.txt\n.loopworker-scaffold-launch.sh\n")
        (scaffold_dir / ".loopworker-scaffold-prompt.txt").write_text(prompt)
        launch = scaffold_dir / ".loopworker-scaffold-launch.sh"
        launch.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f'cd "{scaffold_dir}"\n'
            'PROMPT="$(cat .loopworker-scaffold-prompt.txt)"\n'
            "unset USER\n"
            'exec claude --permission-mode auto "$PROMPT"\n'
        )
        launch.chmod(0o755)
        return launch

    def _scaffold_prompt(self, row: ProjectRow) -> str:
        """The reusable contract-authoring prompt. Self-contained: the scaffolding agent runs
        in a fresh clone of THIS project, not of LoopWorker, so it can't read LoopWorker's own
        examples/ — inline the manifest spec instead of pointing at it."""
        spec_path = Path(__file__).resolve().parent.parent / "examples" / "loopworker-manifest.toml"
        spec = spec_path.read_text() if spec_path.is_file() else ""
        return (
            f"You are a one-off LoopWorker scaffolding agent — NOT a card worker. This repo "
            f"({row.name!r}, {row.repo}) is registered in the LoopWorker projects table but has "
            f"no .loopworker/ contract yet, so the Manager can't serve any cards on it. Your job: "
            f"inspect this repo's shape and add a best-guess .loopworker/ contract (manifest.toml "
            f"+ provision.sh/reset.sh/verify.sh/teardown.sh), then open a PR for a human to "
            f"review.\n\n"
            f"You are UNATTENDED: no human is watching this terminal. NEVER ask an interactive "
            f"question or wait for input. Where you're genuinely unsure of a design choice (the "
            f"Patch portal URL, the brief page, secrets), make the most conservative guess, mark "
            f"it clearly with a TODO comment, and call it out in the PR body instead of "
            f"blocking.\n\n"
            f"--- Contract format (this IS the schema — follow it exactly) ---\n{spec}\n\n"
            f"--- Guessing the stack (adapt freely; these are hints, not a fixed list) ---\n"
            f"- package.json (+ a supabase/ dir) -> web stack: provision = npm install (+ "
            f"supabase start if used), verify = npm test / lint, teardown = supabase stop\n"
            f"- *.xcodeproj or *.xcworkspace -> verify = xcodebuild build/test on a sane scheme\n"
            f"- project.yml (XcodeGen) -> provision generates the project first (xcodegen "
            f"generate)\n"
            f"- Package.swift -> verify = swift test\n"
            f"- pyproject.toml / requirements.txt -> provision = a venv + pip install, verify = "
            f"pytest\n"
            f"- nothing recognizable (a library/docs repo) -> a minimal contract: no ports, "
            f"verify = whatever check exists (or a no-op that exits 0 if genuinely nothing to "
            f"check), teardown.sh with nothing to do\n\n"
            f"--- Steps ---\n"
            f"1. Read the repo (package.json, Gemfile, Package.swift, project.yml, *.xcodeproj, "
            f"pyproject.toml, requirements.txt, docker-compose.yml, README, etc.) to figure out "
            f"its stack and how it's normally built/tested.\n"
            f"2. Write .loopworker/manifest.toml per the schema above ([project].name = "
            f"{_slug(row.name)!r}). You don't know this project's Patch portal URL or brief page "
            f"— leave those as an obvious placeholder (e.g. \"# TODO: fill in\") and flag it "
            f"prominently in the PR body.\n"
            f"3. Write provision.sh (idempotent, first-time-per-slot setup), reset.sh (cheap, "
            f"per-card reset — the isolation gate), verify.sh (the merge gate: must exit nonzero "
            f"on failure), teardown.sh (undo what provision started). Each receives "
            f"LOOPWORKER_SLOT_DIR and LOOPWORKER_PORT in its env — echo the port if the stack "
            f"binds one, otherwise don't.\n"
            f"4. Config files (*.toml, *.sh, *.yml) are 7-bit ASCII only — no em-dashes, no "
            f"smart quotes.\n"
            f"5. Commit on a new branch, push, and open a PR (gh pr create) explaining what you "
            f"guessed, what you're unsure about, and what a human must fill in before merging. "
            f"Do NOT merge it yourself — this is a best guess, not something you can verify "
            f"against a live Manager.\n"
            f"6. Then STOP. This is a one-off task, not a recurring card: do not touch the Patch "
            f"backlog, do not claim or create any card, do not loop."
        )

    def _alloc_band(self, project_id: str) -> int:
        """Assign a project the lowest free port-band index so two projects' slot ports
        never overlap; reused after a project retires."""
        used = set(self._bands.values())
        idx = 0
        while idx in used:
            idx += 1
        self._bands[project_id] = idx
        return idx

    def _apply_slot_targets(self, rows: dict) -> None:
        """Resize each project's pool to its configured slot count, capping hot pools so
        total WEIGHTED hot slot cost stays within max_slots (in Manager order — earlier
        projects keep theirs). A project's weight (default 1) is its relative cost per
        slot — see _project_weight. Cold pools take their configured count as cheap COLD
        placeholders; the real concurrency cap for cold work is enforced dynamically in
        _fill_all."""
        remaining = self.host.max_slots
        for m in self.managers:
            row = rows.get(m.project_id)
            weight = _project_weight(row)
            self._weights[m.project_id] = weight
            desired = row.slots if (row and row.slots) else m.manifest.slots
            if m.pool.hot:
                affordable = _affordable(remaining, weight)
                target = max(min(desired, affordable), 0)
                remaining -= target * weight
            else:
                # Cold pools don't reserve budget (they draw from leftover in _fill_all),
                # but the count is still capped to max_slots: a project's port band is only
                # max_slots wide, so more slots than that would overflow into the next
                # project's band and collide on a port. You can never run more than
                # max_slots concurrently anyway (weight only shrinks that further), so
                # extra cold slots buy nothing.
                target = min(desired, self.host.max_slots)
            # gate on active (non-retiring) count — resize() ignores retiring slots, so
            # counting them here would log a phantom resize every poll while one drains.
            if target != m.pool.active_count():
                self.log(f"{m.manifest.project_name}: resizing {m.pool.active_count()} -> {target} slot(s)")
                try:
                    m.pool.resize(target)
                except Exception as e:
                    self.log(f"  resize of {m.manifest.project_name!r} failed: {e!r}")

    def _ensure_clone(self, row: ProjectRow) -> Path:
        dest = self.host.clones_dir / _slug(row.name)
        if (dest / ".git").exists():
            # Keep the cached clone current. Without this it's frozen at first-clone, so the
            # manifest (loaded from here) never picks up a manifest.toml change — not even
            # across a host restart, until the clone is deleted by hand. Fetch + hard-reset
            # the working tree to the latest default branch. Best-effort: a transient failure
            # keeps the last-good clone rather than crashing the host. (Worker code is already
            # kept fresh per-card by the slot's reset_and_claim; this is for the manifest.)
            for step in (["fetch", "--quiet", "origin"],
                         ["reset", "--hard", "--quiet", f"origin/{row.default_branch}"]):
                r = subprocess.run(["git", "-C", str(dest), *step], capture_output=True, text=True)
                if r.returncode != 0:
                    self.log(f"warning: git {step[0]} failed refreshing {row.name} clone "
                             f"(using cached): {r.stderr.strip()}")
                    break
            return dest
        if not row.repo:
            raise RuntimeError("no repo to clone (set the project's Repo)")
        self.host.clones_dir.mkdir(parents=True, exist_ok=True)
        self.log(f"cloning {row.name} from {row.repo}")
        r = subprocess.run(["git", "clone", row.repo, str(dest)], capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"git clone failed: {r.stderr.strip()}")
        return dest

    def _build_manager(self, row: ProjectRow, manifest: Manifest, idx: int) -> Manager:
        # Each project gets its own port band — wide enough for the whole host budget so
        # two projects' slot ports can never overlap — a name prefix so its workers are
        # distinct in the shared loop_workers table, and its own state dir (killswitch).
        band = self.host.port_step * max(self.host.max_slots, 1)
        # the generic loop protocol is shared (host brief_page); a project may override its
        # own brief with a Patch page (brief_ref), else its repo's BRIEF.md is used.
        project_brief = brief_pointer(row.brief_ref) if row.brief_ref else None
        return Manager(
            manifest,
            poll_interval=self.poll_interval,
            reconcile_interval=self.reconcile_interval,
            grace_seconds=self.grace_seconds,
            base_port=self.host.base_port + idx * band,
            port_step=self.host.port_step,
            state_dir=self.state_dir / _slug(row.name),
            adapter=self.adapter,
            project_id=row.id,
            name_prefix=f"{_slug(row.name)}-",
            hot=row.hot,
            base_ref=f"origin/{row.default_branch}",
            brief=brief_pointer(self.host.brief_page),
            project_brief=project_brief,
            project_model=row.model,
            auth_gate=self.auth_gate,
            notify=self.notifier.send,
            engine_recovery=self.engine_recovery,
        )

    # --- lifecycle ---------------------------------------------------------
    def build(self) -> None:
        """Provision warm pools, capping total WEIGHTED hot slot cost to the host budget
        so warm stacks never exceed max_slots worth of weight (leaving the remainder for
        cold projects)."""
        remaining = self.host.max_slots
        for m in self.managers:
            if not m.pool.hot:
                continue
            weight = self._weights.get(m.project_id, 1.0)
            affordable = _affordable(remaining, weight)
            if len(m.pool.slots) > affordable:
                kept = max(affordable, 0)
                self.log(f"capping hot {m.manifest.project_name} to {kept} slot(s) "
                         f"(host max_slots={self.host.max_slots}, weight={weight:g})")
                m.pool.slots = m.pool.slots[:kept]
            remaining -= len(m.pool.slots) * weight
        for m in self.managers:
            m._reap_orphans()
            m.pool.build()

    def run(self) -> None:
        self._acquire_lock()
        signal.signal(signal.SIGINT, self._on_signal)
        signal.signal(signal.SIGTERM, self._on_signal)
        try:
            self._notify_self_test()
            self.discover()
            if not self.managers:
                self.log("no serviceable projects — nothing to do")
                return
            self.build()
            self.log(f"host ready; reconciling + staggered fill every {self.reconcile_interval}s, "
                     f"project discovery every {self.poll_interval}s")
            last_discover = 0.0
            while not self._stop:
                now = datetime.now(timezone.utc)
                try:
                    self._reconcile_all(now)
                    if not self._draining:
                        paused = self.killswitch.exists()
                        # Project discovery (backlog read + clone) stays on the slow cadence;
                        # spawning runs every cycle so the one-per-pass stagger ramps quickly.
                        if (time.monotonic() - last_discover) >= self.poll_interval:
                            if paused:
                                self.log("killswitch present (PAUSED) — not spawning new workers")
                            else:
                                self.reconcile_projects(now)  # added/removed/resized projects
                            last_discover = time.monotonic()
                        if not paused:
                            self._fill_all(now)
                except Exception as e:
                    self.log(f"ERROR in loop: {e!r}")
                if self._draining and not self._busy_total():
                    self.log("drain complete — all workers finished; shutting down")
                    break
                self._sleep(self.reconcile_interval)
        finally:
            self._reap_all("host shutting down")
            self._release_lock()
            self.log("host stopped (warm slots left up)")

    def _notify_self_test(self) -> None:
        """Boot-time proof the alert channel actually works. A one-shot ping on startup so a
        misconfigured notify_command or missing Pushover env surfaces immediately (and its
        API status is logged by the Notifier), instead of being discovered during an incident
        when the first real BROKEN alert silently fails to arrive."""
        if not self.host.notify_command:
            self.log("notify: no notify_command configured — Manager alerts are DISABLED")
            return
        self.log("notify: sending startup self-test ping")
        self.notifier.send("startup", f"LoopWorker: Manager up on {self.host.worker_manager}, notify healthy")

    def tick(self) -> None:
        """One reconcile + fill pass (for --once / tests)."""
        now = datetime.now(timezone.utc)
        self._reconcile_all(now)
        if not self._draining and not self.killswitch.exists():
            self.reconcile_projects(now)
            self._fill_all(now)

    # --- scheduling --------------------------------------------------------
    def _reconcile_all(self, now: datetime) -> None:
        for m in self.managers:
            m.reconcile(now)

    def _fill_all(self, now: datetime) -> None:
        """Spawn workers under three limits: `max_concurrent_workers` caps how many claudes
        RUN at once host-wide (auth-safety — concurrent claudes race the shared OAuth refresh
        and can trip session revocation), the weighted `max_slots` budget caps live-stack RAM,
        and a one-worker-per-pass stagger keeps a fresh fleet from authing all at once. Runs on
        the fast reconcile cadence, so the next worker starts ~reconcile_interval later — a
        staggered ramp rather than a thundering herd. Cold provisioning still respects the
        weighted budget."""
        if self._busy_total() >= self.host.max_concurrent_workers:
            return
        budget = 1  # stagger: at most one new worker per pass
        hot = [m for m in self.managers if m.pool.hot]
        cold = [m for m in self.managers if not m.pool.hot]
        for m in hot:
            if budget <= 0:
                break
            before = m.busy_count()
            m.fill(now, max_new=budget)
            budget -= m.busy_count() - before
        # BROKEN hot slots run no stack (revive_broken re-provisions them live once their
        # cause clears), so they don't reserve budget a cold project could otherwise spend.
        reserved_hot = sum(m.pool.live_slot_count() * self._weights.get(m.project_id, 1.0) for m in hot)
        cold_busy = sum(m.busy_count() * self._weights.get(m.project_id, 1.0) for m in cold)
        remaining = self.host.max_slots - reserved_hot - cold_busy
        for m in cold:
            if budget <= 0:
                break
            weight = self._weights.get(m.project_id, 1.0)
            affordable = _affordable(remaining, weight)
            if affordable <= 0:
                continue
            before = m.busy_count()
            m.fill(now, max_new=min(budget, affordable))
            started = m.busy_count() - before
            budget -= started
            remaining -= started * weight

    def _reap_all(self, reason: str) -> None:
        for m in self.managers:
            m._reap_workers(reason)

    def _busy_total(self) -> int:
        return sum(m.busy_count() for m in self.managers)

    # --- snapshot ----------------------------------------------------------
    def snapshot(self) -> dict:
        return {
            "worker_manager": self.host.worker_manager,
            "started_at": self.started_at.isoformat(),
            "paused": self.killswitch.exists(),
            "poll_interval": self.poll_interval,
            "max_slots": self.host.max_slots,
            "max_concurrent_workers": self.host.max_concurrent_workers,
            "busy_total": self._busy_total(),
            "projects": [m.snapshot() for m in self.managers],
            "log": list(self.log_lines),
            "log_file": str(filelog.path()) if filelog.path() else None,
            "card_links": self.adapter.card_links(),
        }

    # --- plumbing ----------------------------------------------------------
    def log(self, msg: str) -> None:
        line = f"{datetime.now(timezone.utc).strftime('%H:%M:%S')} {msg}"
        self.log_lines.append(line)
        print(line, flush=True)
        filelog.log(f"host: {msg}")  # durable, redacted

    def _sleep(self, seconds: int) -> None:
        deadline = time.monotonic() + seconds
        while not self._stop and time.monotonic() < deadline:
            time.sleep(min(2.0, deadline - time.monotonic()))

    def _on_signal(self, signum, _frame) -> None:
        if signum == signal.SIGTERM:
            self.log("SIGTERM — force-stopping: reaping workers and releasing their cards")
            self._stop = True
            return
        self._sigint_count += 1
        if self._sigint_count == 1:
            self._draining = True
            self.log(f"⌃C — draining: letting {self._busy_total()} worker(s) finish, starting no new work. "
                     "⌃C again to force-stop them now.")
        elif self._sigint_count == 2:
            self._stop = True
            self.log("⌃C⌃C — force-stopping: killing workers and releasing their cards. ⌃C again for hard exit.")
        else:
            self.log("⌃C⌃C⌃C — hard exit (resources may leak).")
            os._exit(130)

    def _acquire_lock(self) -> None:
        if self.lockfile.exists():
            pid = self.lockfile.read_text().strip()
            if pid and _pid_alive(int(pid)):
                raise RuntimeError(f"another host Manager (pid {pid}) holds {self.lockfile}")
        self.lockfile.write_text(str(os.getpid()))

    def _release_lock(self) -> None:
        try:
            self.lockfile.unlink()
        except FileNotFoundError:
            pass
