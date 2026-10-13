# LoopWorker design

LoopWorker is a deterministic **Manager** daemon that claims cards from a **backlog** and spawns
one disposable **Worker** (a `claude` session in tmux) per card. The worker implements the card
in its own slot and writes an **outcome** file. The Manager then **finishes** the card: it pushes
the branch to the **forge**, opens a review request, and moves the card on. Terms are defined in
[docs/glossary.md](docs/glossary.md).

This document describes the Swift implementation. Behaviour that the Python implementation
learned the hard way, and which the port must keep or fix, is listed in
[docs/behavior-spec.md](docs/behavior-spec.md).

## Principles

- **The Manager is deterministic and non-AI.** It talks to backlogs and forges over their HTTP
  APIs. No model runs in the loop.
- **The Worker is stateless, disposable and powerless.** It gets a worktree, a snapshot of its
  card and a brief. It holds no backlog or forge credentials, so it cannot change anything
  outside its worktree: a worker that follows a prompt injection can at worst write bad code
  into a draft review request.
- **The card state is the source of truth.** The Manager reconciles live sessions, outcome files
  and card states every tick. A card in `working` with no live worker and no outcome is a crash;
  a card that a human moved out of `working` means the worker is reaped without finishing.
- **Reconcile, don't fire once.** Every step that touches the outside world is re-derived from
  observed state on the next tick, so a Manager restart in the middle of any step heals itself.
- **Nothing slow runs inside a tick.** Lifecycle scripts, git, forge writes and auth preflights
  run as tracked tasks with hard timeouts. A tick only observes and starts work, so one wedged
  project never stalls the others.
- **Errors surface.** Every failure reaches the log and, when a slot or card is affected, the
  status file, with enough detail for a human to act. A failed backlog read is never treated as
  "no cards" or "no projects".

## Package layout

| Target | Contents | May import |
| --- | --- | --- |
| `LoopWorkerCore` | Models, the `Backlog` and `Forge` protocols, config, process control, tmux, git, slots, the reconciler, the Manager loop, status, notify, doctor checks. | Foundation, TOMLDecoder |
| `GitLabBackend` | `GitLabBacklog`, `GitLabForge`, the REST/GraphQL client. | Core |
| `PatchBackend` | `PatchBacklog` (PostgREST). | Core |
| `GitHubBackend` | `GitHubForge`; later `GitHubBacklog`. | Core |
| `loopworker` | The CLI (swift-argument-parser). Builds backends from config and runs the Manager. | all of the above |

Core never imports a backend. A future Notion backlog is one more target.

## Backlog and forge are separate seams

A backlog decides what to work on. A forge receives the code. GitLab provides both, but
Patch+GitHub and Notion+GitHub are real combinations, so the host config names each one
separately.

```swift
public protocol Backlog: Sendable {
    func workable(in projects: [ProjectSpec]) async throws -> [Card]  // ready + trusted, best first
    func card(_ ref: CardRef) async throws -> Card?                  // nil: the card is gone
    func working(in projects: [ProjectSpec]) async throws -> [Card]   // for stranded-card recovery
    func claim(_ card: Card) async throws -> Bool                     // false: lost a race, skip
    func snapshot(_ card: Card) async throws -> CardSnapshot
    func markReview(_ card: Card, review: ReviewRequest) async throws
    func markStuck(_ card: Card, blocker: String) async throws
    func release(_ card: Card, reason: String) async throws
}

public protocol Forge: Sendable {
    func gitEnvironment() -> [String: String]                 // credentials for clone/fetch/push
    func cloneURL(for project: ProjectSpec) -> String
    func openReviewRequest(_ draft: ReviewRequestDraft) async throws -> ReviewRequest  // idempotent per branch
    func attach(_ file: URL, to project: ProjectSpec) async throws -> URL?           // nil: forge has no attachments
}
```

The source of truth for these signatures is `Sources/LoopWorkerCore/Backend/`.

### Card states

Every backlog maps its own fields onto five states:

| State | Meaning | GitLab (labels mode) | Patch |
| --- | --- | --- | --- |
| `ready` | Trusted and waiting to be claimed. | open, assigned to me, `loopworker:next`, status To Do | Backlog, unassigned |
| `working` | Claimed; a worker should be running. | `loopworker:working`, status In progress | In progress |
| `review` | Finished; a review request exists. | `loopworker:review`, status In review | (round 2) |
| `stuck` | The worker needs a human. | `loopworker:stuck`, status To Do, still assigned to me | Needs refinement |
| `other` | Anything else. Never claimed, never reaped on its own. | | |

GitLab can express status either as the native work-item status field or as labels; the
adapter supports both (`status_mode` in the host config). The `loopworker:*` labels always
carry the Manager's own state, so the Manager never depends on how a team uses its board.

### Trust

A backlog only reports a card as `ready` if its own identity (the token's user) vouched for it.
For GitLab that means all of these hold:

- the issue is assigned to me, and the assignment event's author is me;
- the most recent `loopworker:next` label event was added by me;
- the issue's project is inside the configured allowlist.

The snapshot only contains content that I vouched for: the description if I edited it last or
it was last edited before my label event, and comments that I wrote or that were posted before
my label event. Everything left out is named in the snapshot's `excluded` list and logged, so a
human can see why a worker didn't see something.

## The worker lifecycle

1. **Fill.** For a free slot, the Manager takes the best `workable` card of that slot's project
   and calls `claim`. A lost claim skips the card.
2. **Acquire.** A task resets the slot's worktree to the base branch, checks out
   `loopworker/<card-slug>`, and runs `reset.sh` (hot) or `provision.sh` (cold).
3. **Spawn.** The Manager writes the snapshot, the brief and a launch script into the slot's
   state directory (never into the worktree) and starts `claude` in a tmux session. The worker
   gets `LOOPWORKER_OUTCOME`, the path where its outcome goes, and an MCP config that contains
   only the project's declared servers (`--strict-mcp-config`).
4. **Work.** The worker implements, runs `verify.sh`, reviews its own diff with fresh-context
   subagents, optionally writes a review guide, commits, and writes the outcome:

   ```json
   {"outcome": "done", "title": "...", "body": "markdown", "guide": "relative/path.html"}
   {"outcome": "stuck", "blocker": "markdown: what is missing and who can provide it"}
   ```

5. **Finish.** When the outcome file exists, the Manager reaps the session after a short grace
   period and runs the finish task:
   - `done`: check that the branch has commits ahead of the base (otherwise treat the outcome
     as `stuck`), push, attach the guide, open a draft review request, `markReview`.
   - `stuck`: `markStuck` with the blocker. Commits stay on the local branch.
   - The slot is recycled only after the finish task succeeds. A failed finish is retried on
     the next tick from the same outcome file.
6. **Recycle.** Hot slots reset; cold slots tear down.

## Reconcile

Each tick, for every busy slot, the pure function `Reconciler.decide` maps an observation to one
decision:

| Observation | Decision |
| --- | --- |
| Outcome file present | `finish` |
| Card gone, or a human moved it out of `working` | `abandon`: reap, recycle, no backlog write |
| Session dead, no outcome, card `working` | `release(crashed)` |
| Pane shows claude's login or 401 screen | `release(auth)`, and the auth circuit breaker backs off |
| Running longer than the wall-clock cap | `release(hung)` |
| Otherwise | `keep` |

A release increments the card's attempt count. When it reaches `max_attempts`, the Manager marks
the card `stuck` instead, with the releases as the blocker, so a card that always crashes its
worker can't loop forever.

At startup, and every few minutes after, the Manager calls `working(in:)` and compares it
against its slots. A `working` card with no slot is either finishable (its slot directory has an
outcome file) or stranded (released with reason "Manager restarted").

## Host config

`~/.loopworker/config.toml` (or `$LOOPWORKER_HOME/config.toml`) is the only config source.
All state paths are absolute and derive from `LOOPWORKER_HOME`, never from the working
directory. Secrets come from environment variables named in the config, never from the file.

```toml
clones_dir             = "~/Dev/loopworker"   # clones and slot worktrees
max_slots              = 4                    # weighted budget
max_concurrent_workers = 2
max_attempts           = 3

[backlog]
kind      = "gitlab"
base_url  = "https://gitlab.com"
token_env = "LOOPWORKER_GITLAB_TOKEN"
allowed   = ["mygroup/"]                      # path prefixes; anything else is ignored
status_mode = "labels"                        # or "work_item_status"

[forge]
kind      = "gitlab"                          # shares the backlog's base_url and token by default

[[project]]
path     = "mygroup/myapp"                    # forge path; also the backlog's project key
slots    = 1
hot      = false
weight   = 1
model    = "opus"
contract = "~/.loopworker/contracts/myapp"    # optional host-local overlay of .loopworker/
```

## State on disk

```
$LOOPWORKER_HOME/
  config.toml
  state/manager.lock          pid lock: one Manager per home
  state/status.json           written atomically each tick; `loopworker status` reads it
  state/manager.log           redacted
  state/PAUSED                host killswitch; state/projects/<key>/PAUSED per project
  slots/<key>/<n>/            brief, snapshot, launch script, outcome, MCP config
<clones_dir>/<key>/           the clone
<clones_dir>/<key>.slots/<n>/ slot worktrees
```

## Concurrency

The Manager is an actor. The tick runs every 15 s and only does fast work: reading tmux state,
reading outcome files, a bounded number of backlog reads, and starting tasks. Acquire, finish,
recycle, provision, clone refresh and the auth preflight are tasks owned by their slot or
project, each under its own timeout. A slot with a running task is skipped by fill and by
reconcile until the task completes and records its result on the slot.

Every subprocess, including git and tmux, runs through one `ProcessRunner`: its own process
group, stdin from `/dev/null`, `GIT_TERMINAL_PROMPT=0`, a hard timeout that kills the group, and
output read without waiting on grandchildren that keep the pipe open.

## Signals

The first SIGINT drains, the second force-stops (reap every worker and release its card), the
third exits immediately. SIGTERM force-stops. launchd and systemd send SIGTERM.

## Distribution

A single `loopworker` binary from the `nevyn/tap` Homebrew formula. `loopworker service install`
writes a launchd plist (a LaunchDaemon with `UserName` when the host has no logged-in user, or a
LaunchAgent). A menu-bar app may come back later as a client of `status.json`.
