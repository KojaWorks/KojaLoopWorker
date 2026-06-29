# LoopWorker — design

An outer **Manager** that polls a project's backlog and spawns disposable **Workers**, each of
which implements exactly one card and exits. It externalizes the build loop that previously lived
*inside* a single Claude session (self-pacing via `ScheduleWakeup`, self-registering, self-selecting
cards). That in-session loop was the fragile part; LoopWorker moves all the statefulness out to the
Manager and leaves the Worker stateless and throwaway.

LoopWorker is project-agnostic. It targets any repo that ships a `.loopworker/` contract (see below).
The first supported backlog is [Patch](https://patch.d.nevyn.dev); Notion/GitHub/etc. are future
adapters behind the same interface.

## Principles

- **The Worker is stateless and disposable.** It is told its card, its name, and that it is already
  claimed. It does one card, reports the outcome to the card, goes idle, and is reaped. No
  self-pacing, no card selection, no backlog re-query, no registration. A crashed Worker just dies —
  it cannot corrupt loop state because it holds none.
- **The Manager is deterministic and non-AI.** Polling, claiming, slot lifecycle, and crash recovery
  are mechanical. No model runs in the loop — it's cheap, debuggable, and predictable. (This is *why*
  the Manager talks to the backlog over its HTTP API, not the MCP — see "Manager is not a Claude".)
- **The card status is the source of truth**, not the process. "Card left In progress" is the exit
  signal; "Worker process gone while card still In progress" is the crash signal. The Manager
  reconciles process state against card state every tick.
- **One fact, one home.** Blocking is the `blocked_by` relation, never a duplicate status column.
  The claim is the card's `Assignee`. Slot state lives in the Manager's memory + dashboard.

## Components

### Manager (`loopworker.py`)

A single long-lived Python process. Each tick (~5 min) it **reconciles** two sets — live Worker
processes (tmux sessions) against card statuses — and fixes any divergence. It is a reconciler, not
just a spawner; the happy path (spawn workable cards) is one of four cases:

| tmux session | card state | meaning | Manager action |
|---|---|---|---|
| alive | In progress, assigned to it | healthy | leave it |
| **dead** | **In progress, assigned to it** | **Worker crashed** | reclaim: clear `Assignee`, move card to Backlog, log |
| alive | left In progress (Shipped / Needs refinement / Backlog) | done or bailed | reap tmux after 120s grace |
| alive | In progress, `Last active` stale (hrs) | hung | watchdog reap + reclaim |

The crash case (row 2) is the one that silently stalls the system if missing: a card stuck
`In progress` with a dead owner is skipped by every other Worker forever. The Manager owns crash
recovery precisely because the Worker, by definition, cannot.

Per tick, for each free slot, the Manager also: finds the highest-priority **workable** card
(Backlog, unassigned, not an epic, all direct `blocked_by` targets Shipped), claims it (`Assignee` +
`In progress`) **before** spawning so its own next tick skips it, and spawns a Worker into that slot.

### Worker

An interactive `claude` running in a tmux session, one per in-flight card. Spawned with the brief
delivered as the **initial-prompt argv** (reliable; no `send-keys` timing races):

```
tmux new-session -d -s lw-<project>-<cardid> \
  "cd $SLOT_DIR && claude --permission-mode acceptEdits 'You are <Name>. ...one-card brief...'"
```

Interactive (not `claude -p`) so the session is human-attachable for intervention and has the full
tool surface — notably **Chrome DevTools MCP** for browser verification. The Manager only ever uses
`send-keys` for follow-up nudges into a stuck Worker, never for the initial delivery.

The Worker:
1. Reads its card body (via the Patch MCP — Workers *are* Claudes and do use the MCP).
2. Decides workability. Not workable → moves the card to Needs refinement (with sharp numbered
   questions) or back to Backlog, clears `Assignee`, and stops.
3. Workable → implements the minimum that works, runs `verify.sh`, opens a PR, runs a
   **clean-context self-review subagent** over the diff, addresses findings, merges on green CI.
4. Reports outcome to the card: Shipped + `solved_in_pr` + a summary at the bottom.
5. **Env survey** (wind-down): writes one row to the shared Env-feedback table — *"anything missing
   from your environment, any gate that blocked you wrongly, anything that slowed you down?"*
6. Goes idle. The Manager reaps the pane next tick (scrollback preserved for inspection).

The Worker never picks a second card. Iteration is the Manager's job.

### Slot pool

`supabase start` (or any project's stack bring-up) is the expensive part, so stacks are **warm and
reused**. A slot = `(worktree dir, port, long-lived stack)`. The Manager builds N slots once at
pool-init and reuses them across many cards. With ~3 slots on miquon (RAM-bound: 3 stacks + 3
Claudes + 3 headless Chromes), N is a config knob; expect to land at 2–3.

**Reset on acquire, never trust release.** A crashed Worker leaves its slot dirty (uncommitted
files, polluted DB). Resetting on release would skip that cleanup on the exact path that needs it.
So the Manager resets a slot *before* every spawn:

```
git -C $SLOT fetch origin -q
git -C $SLOT reset --hard origin/main && git -C $SLOT clean -fd   # keep .git / node_modules
git -C $SLOT checkout -B claude/<slug> origin/main
<project reset.sh>          # e.g. supabase db reset — the test-isolation guarantee
```

The stack stays *up* across jobs; only the DB content resets. Seconds, not minutes.

### Backlog adapter

The Manager talks to the backlog through a narrow interface so new backends slot in later:

```
list_workable() -> [Card]      # Backlog, unassigned, not epic, blockers all Shipped, sorted by priority
claim(card, worker)            # set Assignee + In progress
release(card)                  # clear Assignee, set Backlog (crash recovery)
is_unblocked(card) -> bool     # all direct blocked_by targets Shipped
```

v1 ships the **Patch adapter** only, hitting PostgREST at `api.patch.d.nevyn.dev` with a service
token. Notion/GitHub adapters are future work behind the same four methods.

## Manager is not a Claude

The `mcp__…__*` tools exist only inside a Claude session. The Manager is deliberately non-AI, so it
**cannot use the Patch MCP** — it hits Patch's REST API (PostgREST) directly with a service token.
This is a feature: deterministic, cheap, no model in the polling loop, and it makes the
backlog-adapter boundary clean. It also means no `claude -p` preflight is needed — the initial-prompt
argv *is* the kickoff, a static template with no AI in the Manager anywhere.

## The project contract

A repo is **LoopWorker-compatible** iff it ships a valid `.loopworker/` directory. The Manager owns
git/worktree mechanics (generic); the project owns its stack (Supabase, Rails, docker-compose, …).

```
myproject/.loopworker/
  manifest.toml      # portal/backlog location, brief source, required MCPs, slot hints, script paths
  provision.sh       # FIRST time per slot: heavy, idempotent. Brings the stack up. Emits port(s).
  reset.sh           # per-acquire: cheap. DB reset + project clean. The isolation gate.
  verify.sh          # the merge gate: typecheck + tests. Nonzero exit = do not ship.
  teardown.sh        # slot retirement: stop stack, free ports.
```

Why `provision` (heavy, once) is split from `reset` (cheap, every acquire): that split *is* the
warm-stack optimization. Port handshake: the Manager injects `LOOPWORKER_SLOT_DIR` and
`LOOPWORKER_PORT` into the script + Worker environment; scripts read them.

The **loop instructions / worker brief** are pointed to by the manifest and can be whatever suits the
project: a Markdown file in the repo, a URL, or a Patch page (the live, canonical form today). For
repo-file/url sources the Manager inlines the text into the spawn prompt; for a `patch-page` it hands
the Worker a *pointer* and lets the Worker read it via the Patch MCP (`get_page`) — the Manager stays
out of brief-parsing, which keeps it free of the blocks-table API. Either way the Manager wraps the
brief with the per-card preamble (you're pre-claimed, do this one card, report, then stop).

### `manifest.toml` (schema sketch)

```toml
[project]
name = "myproject"

[backlog]
adapter = "patch"                                  # patch | notion | github (only patch in v1)
portal  = "https://patch.d.nevyn.dev/app/projects-myproject-roadmap-<uuid>"
# adapter-specific resolution of roadmap table / workers table / brief lives under [backlog.patch]

[brief]
source = "patch-page"                              # patch-page | repo-file | url
ref    = "https://patch.d.nevyn.dev/app/loop-runner-instructions-<uuid>"
# or: source = "repo-file"; ref = ".loopworker/BRIEF.md"

[worker]
mcp = ["patch", "chrome-devtools"]                 # required MCP servers; .mcp.json ships in repo
wallclock_cap_minutes = 90                         # Manager reaps regardless after this

[slots]
count = 3                                           # pool size; RAM-bound on the host
```

## Gates (merge-to-main is autonomous and unattended)

1. `verify.sh` — typecheck + unit, must pass before PR. *Project-defined.*
2. **Clean-context self-review subagent** before merge — an independent read of the diff; the main
   quality gate.
3. **CI green + branch protection** (up-to-date-with-main, required checks) — the hard gate the
   Worker cannot bypass.
4. **Slot isolation** (per-acquire `reset.sh`) — a bad Worker can't poison another's tree or DB.
5. **Manager kill-switch** — a flag file checked each tick that halts new spawns (panic button).
6. **Per-Worker wallclock cap** — Manager reaps after N minutes regardless of state, so a stuck
   Worker can't burn tokens all night.

Gates 5 and 6 are the ones required *before* running unattended.

## Manager state & dashboard

The Manager holds slot/worker state in memory and serves it as a **local HTTP status page** (it's
already a long-lived process; serving its own state is cheap and gives real-time richness for free).
Optionally it mirrors a compact heartbeat row to a Patch page for phone-glanceability — but Patch is
never the primary store of Manager state.

## Runtime & first-time setup

```
cd ~/Dev && git clone git@…/myproject
git clone git@…/KojaLoopWorker && cd KojaLoopWorker
uv venv && uv pip install -e .            # venv, not system pip
cp .env.example .env                       # PATCH_SERVICE_TOKEN, etc.
tmux new -s loopworker './loopworker.py --project ~/Dev/myproject'
#   first run builds N slots + provisions N stacks (slow, once), then starts reconciling
```

The working copy's `manifest.toml` is the source of truth; CLI flags are overrides. `--project` is
the only required argument.

Credentials on the host:
- Manager needs a **Patch service token** — the Supabase `service_role` key, read from
  `PATCH_SECRET_KEY` in `.env` (REST, not MCP). It bypasses RLS; never commit it.
- The Workers' `claude` CLI must be **logged in on the host once** — interactive `claude` inherits
  that auth; there is no per-Worker login.
- Worker `.mcp.json` (Patch + Chrome DevTools) ships in the project repo; the Manager injects secrets
  via env.

For "survives reboot," run the Manager under **launchd KeepAlive** rather than a tmux session. tmux
is the right v1 (attach and watch it reconcile); the spawned Workers stay in tmux regardless.

## Notable capability shift from the old in-session loop

The previous Workers ran inside the **Claude Desktop app**, whose verification leaned on the
**Preview MCP** (`preview_start`, `preview_eval`, in-page session minting). CLI Workers in tmux do
not have Preview — they have **Chrome DevTools MCP**, with different primitives. So porting the
worker brief is not just trimming the loop/selection/registration sections: the *verification
recipes need a real rewrite* against Chrome DevTools MCP. The iOS-simulator path (`simctl`) is plain
CLI and survives unchanged.

## Open questions / future

- **Worker brief: generic protocol vs project specifics.** The generic protocol (you're pre-claimed,
  do one card, verify, PR, self-review, report, survey, stop) belongs to LoopWorker; project
  specifics (stack quirks, verify recipes, gotchas) belong to the project's brief. The spawn prompt
  composes both. Exact seam TBD when we write the brief.
- Notion / GitHub backlog adapters.
- Whether the Env-feedback table auto-files recurring requests as LoopWorker backlog cards.
- launchd packaging for the Manager.
