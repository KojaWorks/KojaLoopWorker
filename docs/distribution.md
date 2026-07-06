# LoopWorker — distribution & release

How a LoopWorker Manager gets installed, kept running, updated, and (eventually) seen in
Koja Works. Today distribution is `git clone` + `venv` + `pip install -e .` + a hand-run
`tmux` session you re-`git pull` and restart by hand — fine for the author, hostile to
anyone else and tedious even for the author. This doc is the plan to replace that with a
**packaged, self-updating, start/stop-able** Manager on each platform, without forking the
codebase in two.

## Who this is for

- **Mac operator — semi-technical.** Can install Claude Code and Docker/OrbStack, has a
  `claude` login, but does not want to babysit venvs and `tmux attach`. Wants: launch,
  glance at status, quit — like any menu-bar utility.
- **Linux fleet operator — technical.** Runs headless boxes over SSH, thinks in services
  and units, wants clean install + `systemctl` + a one-command update.
- **Not for:** a truly non-technical user. LoopWorker fundamentally requires a `claude`
  login (spending that host's compute), a container engine for provision stacks, `tmux`,
  `git`, and a per-project `.loopworker/` contract. No wrapper makes those prerequisites
  vanish. We design so the app *surfaces* readiness (see below), not so it pretends the
  dependencies aren't there.

The endgame for both: the Manager ties into **Koja Works**, registering into a specific
**Koja Place** and streaming its live status so a fleet is visible as presence in a shared
space.

## The one principle: package + supervise, never rewrite

The Manager (reconciler / manager / slots / tmux / backlog) is the tested, deterministic,
near-stdlib core. **No platform shell reimplements it.** Each shell is a thin *supervisor +
status client* over two seams that already exist:

1. **The status seam — `GET http://127.0.0.1:8787/json`** returns the Manager's full
   in-memory snapshot. Any UI (a SwiftUI panel, a `loopworker status` CLI, a Koja
   publisher) is a *client* of this, not a second source of truth.
2. **The control seam — signals.** `SIGINT` = drain (finish current workers, spawn none,
   then exit); `SIGTERM` = force-stop (reap workers, release their cards to Backlog). These
   already exist and map directly onto an app's Quit / Force-Quit.

Two corollaries we hold firm:

- **One update mechanism per platform, and it owns the Python code.** If the Mac app
  supervises a *separate* git checkout you have to `git pull` and restart, we have rebuilt
  the current pain inside a nicer wrapper. The app bundle must *contain* the Manager (frozen
  Python), so "update the app" == "update the Manager." Same spirit on Linux: `pipx upgrade`
  (or a package) moves the code, not a manual pull.
- **Local dashboard stays the source of truth; Koja Works is a projection.** The Manager
  must run fully with Koja unreachable or unconfigured. Presence is an additional *output
  sink* for the same snapshot, never a dependency in the loop. (One fact, one home.)

## Mac: a menu-bar app

Menu-bar is the right archetype: a background daemon you occasionally glance at and flip on
and off. Native SwiftUI (`MenuBarExtra`) — no `WKWebView`; the panel is cheap to build
natively and reads better than embedded browser chrome.

What it is:

- **Supervisor + login item.** Owns the `loopworker` subprocess, relaunches it on
  unexpected exit, starts at login (opt-in). Quitting the app *is* the off switch the
  operator wants.
- **Lifecycle maps onto the existing signals — invent nothing new.**
  - **Quit** → `SIGINT` (graceful drain; via `applicationShouldTerminate` → `.terminateLater`
    the app stays alive showing "draining…" until the Manager exits, then quits — with a long
    safety timeout that escalates to `SIGTERM`/`SIGKILL` so a wedged Manager can't block Quit).
  - **Force stop** (explicit menu item) → `SIGTERM` (reap + release cards).
  - *Caveat:* a hard **Force-Quit** sends `SIGKILL`, which no app can intercept — so use *Force
    stop*, not Force-Quit, when you want cards released. A normal quit/logout won't orphan the
    Manager (`applicationWillTerminate` sends a best-effort `SIGTERM`); an app *crash* can leave
    a still-running, crash-safe Manager behind — adopting/force-stopping such an orphan on next
    launch is a known Phase 1 follow-up.
- **Status panel — a native render of `/json`.** Slots, current cards, per-slot activity,
  the recent log tail. Icon state reflects fleet health (idle / working / error) so the
  menu bar itself is the at-a-glance signal.
- **Readiness panel — the highest-value screen.** `claude: logged in ✓ / Docker: not
  running ✗ / tmux ✓ / backlog reachable ✓`. This is the thing `tmux attach` can't give
  you, and it's what makes the "make the rare thing a human must do obvious" north star real
  on the desktop. Backed by `loopworker doctor --json` (Phase 0), which the app runs on
  demand and on a slow timer — never per status-poll (a `claude -p` check is not free; it's
  cached, mirroring `AuthGate`'s 180s TTL).
- **Updates via Sparkle**, with the app bundle owning a frozen copy of the Manager. One
  update channel for UI *and* Manager code. This is the feature that ends the manual
  `pull`+restart loop.

Costs, named honestly:

- **Freezing the Python.** The Manager is near-stdlib (`httpx` only), so PyInstaller (or a
  vendored relocatable `python3` + `pip install --target`) is straightforward. This freezes
  only the Python side; `claude`, `tmux`, `git`, and the container engine remain host
  prerequisites the readiness panel reports on.
- **Signing + notarization.** A distributed Mac app needs Developer ID signing +
  notarization or Gatekeeper blocks it. Known territory (KojaPatchApp / Xcode Cloud), but a
  real per-release step.

Where it lives: `macapp/` in this repo (xcodegen-generated project), versioned alongside the
Python it wraps — they release together, which is the whole point of "the bundle owns the
code."

## Linux: pipx + systemd (not AppImage, not a container)

For a headless fleet operator the right primitives are the boring ones:

- **`pipx install loopworker`** (from PyPI, or pipx-from-git to start) — isolated,
  `pipx upgrade` is the update story.
- **A shipped `loopworker.service` systemd unit** + a one-line install script. systemd is
  the Linux equivalent of "menu-bar app as supervisor + login item": start on boot,
  restart on crash, `systemctl stop` sends `SIGTERM` = force-stop, and a drain-then-stop is
  `systemctl kill -s INT` then wait. Status is `curl /json`, the browser dashboard, or
  `loopworker status` in the terminal.

Explicitly rejected, with reasons:

- **AppImage** is for GUI desktop apps a user double-clicks; wrong shape for a headless
  daemon. A fleet operator wants a service, not a clickable blob.
- **Running the Manager in a container** means Docker-in-Docker for the projects' own
  provision stacks, plus `claude`-login-inside-a-container. It's a *host-level* orchestrator
  that drives host `tmux` / `git` / Docker — it belongs on the host, not in a box.
- **deb/apt** later, only on demand — Debian packaging is heavy and ties us to
  Ubuntu/Debian; pipx covers the technical user today.

## Koja Works / Koja Place: presence as an additive publisher

Integration = the Manager registers into a configured Koja Place and streams the same
snapshot `/json` already produces, so a fleet shows up as live presence in a shared space.
It is an **output sink**, not a rearchitecture. Constraints:

- **Local is truth; Koja is a mirror.** The Manager runs fully without it. Koja
  unreachable/unconfigured → the publisher is a no-op, the loop is unaffected.
- **Decoupled + optional.** A single publisher module reads the snapshot on a timer and
  pushes it over a persistent connection; a `[koja]` config block (place id + credential)
  turns it on. Nothing in reconcile/spawn/reap depends on it.
- **Sequenced last** — it depends on Koja Works exposing a presence/ingest API, which may
  not exist yet. Blocked on that API's shape.

## Phasing

Phase 0 is the real unlock: it turns `/json` into a documented, versioned contract and adds
the readiness surface every shell needs — and it ends the manual-restart pain regardless of
platform. Phases 1 and 2 are independent shells over Phase 0; order them by whose pain is
louder (the author's Manager runs on a Mac, so Phase 1 leads).

| Phase | Delivers | Needs a human for |
| --- | --- | --- |
| **0 — Status & readiness contract** *(shared)* | `loopworker doctor` (host-prereq checks), `/health` endpoint, `contract_version` in `/json`, `loopworker --version`, `loopworker status`. Packaging metadata ready to publish. | Deciding PyPI vs pipx-from-git; picking the freeze tool. |
| **1 — Mac menu-bar app** | SwiftUI `MenuBarExtra` supervisor: launch/stop, status panel, readiness panel, signal-mapped Quit/Force-stop, Sparkle wired. | Developer ID signing + notarization; Sparkle appcast hosting; GUI verification. |
| **2 — Linux service** | `loopworker.service` unit, install script, pipx install/upgrade docs. | Publishing to PyPI (or the git URL choice); testing on a real headless box. |
| **3 — Koja Works presence** | A decoupled presence publisher pushing the snapshot to a configured Koja Place; `[koja]` config block. | The Koja Works presence/ingest API shape + a place credential. |

## The status-API contract (Phase 0)

Consumed by every shell; treat as a stable interface, versioned by `contract_version`.

- **`GET /json`** — the full snapshot (existing), now carrying `contract_version` and
  `loopworker_version`. Rich, for the status panel and the Koja publisher.
- **`GET /health`** — a compact, cheap liveness/state summary derived from the snapshot
  (no subprocess work): `{contract_version, loopworker_version, paused, busy, slots,
  worker_manager, started_at}`. Safe to poll frequently.
- **`loopworker doctor [--json]`** — host-prerequisite checks (claude login, container
  engine, tmux, git, backlog reachability), each with a name / ok / detail / remedy. Runs
  standalone (no running Manager required); this is what the Mac readiness panel calls.
  Exit 0 iff all pass.
- **`loopworker status`** — pretty-prints a running Manager's `/json` in the terminal (the
  Linux at-a-glance).
- **`loopworker --version`** — the version Sparkle / `pipx` compare against.

## Open decisions

1. **Publish channel** — PyPI (clean `pipx install loopworker`, needs an account/token) vs
   pipx-from-git (zero infra, uglier command). Start git, move to PyPI when there's a second
   operator.
2. **Freeze tool** — PyInstaller vs a vendored relocatable python3. PyInstaller is the
   lazier path given the tiny dep surface; revisit if it fights notarization.
3. **Koja presence API** — doesn't exist yet (as far as this doc knows). Phase 3 is blocked
   on its shape; the publisher is designed to be a thin, swappable sink so the wait costs
   nothing else.
