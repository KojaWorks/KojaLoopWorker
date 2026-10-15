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
- **The Worker is stateless, disposable and credential-free.** It gets a worktree, a snapshot
  of its trusted card content and a brief, and no backlog or forge credentials: its only
  output is the outcome file, and the Manager does every backlog and forge write. This stops
  accidents and a worker that naively follows injected instructions. It is not a security
  boundary yet: the worker runs as the Manager's user, so a worker that is deliberately
  turned against the host can read anything that user can, including `secrets.env`. Running
  workers under their own user or in an OS sandbox is planned hardening.
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
| `NotionBackend` | `NotionBacklog` (Notion REST API, data sources). | Core |
| `loopworker` | The CLI (swift-argument-parser). Builds backends from config and runs the Manager. | all of the above |

Core never imports a backend.

## Backlog and forge are separate seams

A backlog decides what to work on. A forge receives the code. GitLab provides both, but
Patch+GitHub and Notion+GitHub are real combinations, so the host config names each one
separately.

```swift
public protocol Backlog: Sendable {
    func workable(in projects: [ProjectSpec]) async throws -> [Card]  // ready + trusted, best first
    func card(_ ref: CardRef) async throws -> Card?                  // nil: the card is gone
    func working(in projects: [ProjectSpec]) async throws -> [Card]   // for stranded-card recovery
    func verifying(in projects: [ProjectSpec]) async throws -> [Card] // to resume CI watches
    func claim(_ card: Card) async throws -> Bool                     // false: lost a race, skip
    func snapshot(_ card: Card) async throws -> CardSnapshot
    func markReview(_ card: Card, review: ReviewRequest, note: String?) async throws
    func markVerifying(_ card: Card, review: ReviewRequest) async throws
    func resumeFix(_ card: Card) async throws -> Bool                 // false: a human moved it
    func markStuck(_ card: Card, blocker: String) async throws
    func release(_ card: Card, reason: String, countsAsAttempt: Bool) async throws
}

public protocol Forge: Sendable {
    func gitEnvironment() -> [String: String]                 // credentials for clone/fetch/push
    func cloneURL(for project: ProjectSpec) -> String
    func openReviewRequest(_ draft: ReviewRequestDraft) async throws -> ReviewRequest  // idempotent per branch
    func attach(_ file: URL, to project: ProjectSpec) async throws -> URL?           // nil: forge has no attachments
    func pipeline(for project: ProjectSpec, commit: String) async throws -> PipelineStatus?  // nil: no pipeline yet
    func baselineJobs(for project: ProjectSpec, ref: String, names: [String]) async throws -> [String: CIJobBaseline]
    func retryJobs(project: ProjectSpec, jobs: [CIJob]) async throws -> Bool         // false: can't re-run them
}
```

The source of truth for these signatures is `Sources/LoopWorkerCore/Backend/`.

### Card states

Every backlog maps its own fields onto six states:

| State | Meaning | GitLab (labels mode) | Patch | Notion (state property) |
| --- | --- | --- | --- | --- |
| `ready` | Trusted and waiting to be claimed. | open, assigned to me, `loopworker::next`, status To do | Backlog, unassigned | `next`, last edited by a trusted user |
| `working` | Claimed; a worker should be running. | `loopworker::working`, status In progress | In progress | `working` |
| `verifying` | The review request exists; the Manager waits for its CI. No slot is held. | `loopworker::ci`, status In progress | Verifying | `ci` |
| `review` | Finished; a review request exists. | `loopworker::review`, status In review | In review | `review` |
| `stuck` | The worker needs a human. | `loopworker::stuck`, status To do, still assigned to me | Needs refinement | `stuck` |
| `other` | Anything else. Never claimed, never reaped on its own. | closed, or no single `loopworker::*` label | | empty, or `next` without a trusted last editor; in the trash |

A card that a human closes, or moves to `other` in any way, while a worker runs is abandoned:
the worker is reaped and nothing is written back.

GitLab can express status either as the native work-item status field or as labels; the
adapter supports both (`status_mode` in the host config). The `loopworker::*` labels always
carry the Manager's own state, so the Manager never depends on how a team uses its board.

Notion keeps the Manager's state the same way, in a select property that only LoopWorker uses
(the **state property**, `LoopWorker` by default, with the options `next`, `working`, `ci`,
`review` and `stuck`). The team's own status property is never read or written: if `working`
were a team status such as In progress, the stranded-card sweep would release every teammate's
card in it.

### Trust

A backlog only reports a card as `ready` if its own identity (the token's user) vouched for it.
For GitLab that means all of these hold:

- the issue is assigned to me, and the system note that assigned me was written by me;
- the most recent `loopworker::next` label event was added by me;
- the issue's project is inside the configured allowlist.

The time of that label event is the card's trust cutoff. When the Manager itself re-adds
`loopworker::next` to release a card, the cutoff stays at the human's original label event (the
release note records it), so a retry never trusts content that arrived while the card was
`working`.

The snapshot only contains content that I vouched for: the title and description if I edited
them last or they were last edited before the cutoff, and comments that I wrote or that were
last edited before the cutoff. Notes that the Manager posted (releases, blockers, review links)
are left out, because they carry worker-written text under my name. Everything left out is
named in the snapshot's `excluded` list and logged, so a human can see why a worker didn't see
something.

Every piece of worker-written text that the Manager posts (blockers, review request titles and
bodies) is posted under my name, so the GitLab backend neutralizes quick actions in it: a line
that starts with `/` is escaped, so `/merge` or `/label` from a worker is shown, never executed.

#### Trust in Notion

Notion records no per-property history: a page has one `last_edited_by` and one
`last_edited_time` (rounded to the minute) for every edit to it, whether to a property, the
title or a body block. Nothing in the public API says who set the state property to `next`. Blocks
and comments do carry their own authors, and Notion sets those itself.

The token is an internal integration's secret, so it belongs to a bot, not a person. The
people who vouch therefore come from the host config: `trusted_users`, one or more Notion user
ids. A token that belongs to a person (a personal access token) is refused, because the
Manager's writes would then look like that person's edits.

A Notion card is `ready` when its state property is `next` and the page's `last_edited_by` is
a trusted user, or is the integration itself when its newest Manager comment is a release.
Trust follows authorship, not time, so there is no cutoff. The snapshot holds:

- the title;
- each block of the page body whose own `last_edited_by` is a trusted user;
- comments written by a trusted user.

Comments that the integration wrote are left out of the snapshot and reach the worker through
`managerNotes` instead. Every withheld block and comment is named in `excluded`.

What this covers: text that an untrusted person wrote reaches a worker only after a trusted
user edited it last. What it does not cover: someone untrusted sets `next`, and a trusted user
then edits the same page for any reason before the Manager reads it; the Manager reads that
edit as the vouch. So does a trusted user's typo fix in a block that someone else wrote. Any
edit by a trusted user to a card in `next` counts as vouching for it. Use a database that only
trusted users can edit when that is not acceptable.

Notion has no compare-and-set. `claim` writes `working`, then posts a claim comment that names
the host and a nonce; when several claim comments follow the integration's previous other
comment, the oldest wins, and every other claimer returns false and deletes its own comment.
Comment times are rounded to the minute too, so claims in the same minute keep the order in
which the API lists them.

## The worker lifecycle

1. **Fill.** For a free slot, the Manager takes the best `workable` card of that slot's project
   and calls `claim`. A lost claim skips the card.
2. **Acquire.** A task resets the slot's worktree to the base branch, checks out
   a branch named from the contract's template (default `loopworker-{number}-{slug}`, flat so it
   can't collide with a branch named `loopworker`; a project whose commit hooks parse branch
   names sets its own), and runs `reset.sh` (hot) or `provision.sh` (cold). When the push ledger
   says an earlier attempt of this card pushed that branch (it went stuck, and a human sent it
   back to ready), the Manager fetches, and if the forge still has the branch, resets to it
   instead, and the brief tells the worker to continue from that work. If the branch is gone, the
   card starts over from the base and its ledger entry is dropped.
3. **Spawn.** The Manager writes the snapshot, the brief and a launch script into the slot's
   state directory (never into the worktree) and starts `claude` in a tmux session. The worker
   gets `LOOPWORKER_OUTCOME`, the path where its outcome goes, and an MCP config that contains
   only the project's declared servers (`--strict-mcp-config`). The launch script starts from
   `env -i` and adds back only `HOME`, `PATH`, `TERM`, `LANG`, `TMPDIR` and the variables in the
   slot's `worker.env`, so no backlog or forge token in the Manager's environment, or in the
   tmux server's, reaches the worker. When the card was worked on before, the brief gets a
   "Previous attempt" section: the last outcome that a slot of the project kept for this card
   and the Manager's three latest notes on it (`managerNotes`), fenced and labelled as
   LoopWorker's own output rather than content that the owner vouched for. The snapshot still
   leaves those notes out.
4. **Work.** The worker implements, runs `verify.sh`, reviews its own diff with fresh-context
   subagents, optionally writes a review guide, commits, and writes the outcome:

   ```json
   {"outcome": "done", "title": "...", "body": "markdown", "guide": "guide.html"}
   {"outcome": "stuck", "blocker": "markdown: what is missing and who can provide it"}
   ```

5. **Finish.** When the outcome file exists, the Manager reaps the session after a short grace
   period and runs the finish task:
   - `done`: check that the branch has commits ahead of the base (otherwise treat the outcome
     as `stuck`), push, attach the files that the outcome names (the guide, and each
     `attachment:<path>` link or image in the body, such as `![after](attachment:after.png)`),
     open a draft review request assigned to the forge token's user (the card's owner), `markReview` (or, for a project
     that waits for CI, `markVerifying`; see "Waiting for CI").
   - An attached file must resolve (symlinks resolved) inside the slot's state directory, be
     not be one of the files that the Manager writes there (such as `worker.env`), be a
     regular non-empty file under 20 MB, not have a credential-like name, and not contain a
     credential shape or a PEM private key. The Manager uploads it with `forge.attach` and puts
     the URL in place of the reference. A refused file, or any file on a forge without
     attachments, keeps its reference, is logged, and gets a line under the body that says
     "LoopWorker didn't attach <path>: <reason>". The worker stays credential-free.
   - `stuck`: push the branch if it has commits, so the human can see the work in progress,
     then `markStuck` with the blocker and the branch name.
   - The slot is recycled only after the finish task succeeds. A failed finish is retried on
     later ticks from the same outcome file. A `BackendRejection` (the forge or backlog refused
     the request outright) turns the card `stuck` instead, so a finish that can never succeed
     doesn't hold the card forever.
6. **Recycle.** Hot slots detach HEAD and wait; the next acquire resets them. Cold slots tear
   down.

## Waiting for CI

A project whose contract sets `[review] wait_for_ci` treats the review request's CI as the full
verification, so its `verify.sh` can stay light. Finish writes a watch record,
`state/ci/<card id>.json` (the card, branch, pushed commit, review request, round and push
time), and only then moves the card to `verifying` and frees the slot.

Every 120 s the Manager re-reads each watched card and the forge's pipeline for the pushed
commit (by commit, not by review request, because some repos run pipelines only on branch
pushes). A commit can have several pipelines (a branch push and a merge request pipeline);
the forge combines the newest of each kind, and any failure fails the commit. For a failed
pipeline the Manager also reads how each failed job did on the base branch (`baselineJobs`): a
job that also fails there is pre-existing, and one that passes there may be flaky. Flaky jobs
are re-run at most once per commit; the watch record notes the re-run before the forge is
asked, and a forge that can't re-run them leads straight to a fix round:

| Pipeline | Decision |
| --- | --- |
| Passed (success, skipped, or only manual jobs left) | `markReview` with a note that links the pipeline |
| Still running `ci_timeout_minutes` after the push | `markStuck` |
| None 15 min after the push | `markStuck` |
| Canceled | `markStuck`: a cancel is usually a human decision |
| Failed only in jobs that also fail on the base branch | `markReview` with a note that links each job on both branches |
| Failed in jobs that pass on the base branch, not yet re-run | re-run those jobs once and keep watching |
| Failed otherwise, fix rounds left | queue a fix round |
| Failed otherwise after `ci_fix_attempts` fix rounds | `markStuck`, linking each failed job |
| Card no longer `verifying` | stop watching; no backlog write |

A fix round is a worker run on the existing card branch. Fill starts queued fix rounds before
new claims, within the same budget. The round calls `resumeFix` (`verifying` -> `working`; false
means a human moved the card, so the round is dropped), resets any free slot to the pushed
card branch, and writes `ci.md` into the slot's state directory: each failed job's name, stage,
link, how it did on the base branch and the redacted tail of its log. CI logs are untrusted
data, like card content: `ci.md` says so, fences the logs, and the brief tells the worker to
read it as data. The worker fixes
the failures and writes an outcome as usual; finish pushes under the same lease, gets the
existing review request back from `openReviewRequest`, and returns the card to `verifying`
with the new commit and the next round. A crash in a fix round releases the card like any
crash.

The watch record is deleted whenever the Manager moves the card out of `verifying`. At startup
and with every stranded-card sweep, each `verifying` card with a record is watched again; one
without a record is marked stuck, because nothing else would ever move it on.

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

A release for a crash or a hang counts as a failed attempt; an auth release doesn't, because
the host failed, not the card. When a counted release would reach `max_attempts`, the Manager
marks the card `stuck` instead, with the release reasons as the blocker, so a card that always
crashes its worker can't loop forever.

At startup, and every few minutes after, the Manager calls `working(in:)` and compares it
against its slots. A `working` card with no slot is either finishable (its slot directory has an
outcome file) or stranded (released with reason "Manager restarted", not counted as an
attempt). `verifying` cards hold no slot and are never released; see "Waiting for CI". This
assumes one Manager per backlog identity and project: two Managers that share a GitLab user and
a project would release each other's cards.

## Host config

`~/.loopworker/config.toml` (or `$LOOPWORKER_HOME/config.toml`) is the only config source.
The Manager re-reads it when it changes: new projects start, removed ones drain, slot counts
resize (busy slots retire after their card). All state paths are absolute and derive from
`LOOPWORKER_HOME`, never from the working directory.

Backend tokens are named in the config (`token_env`) and looked up in
`$LOOPWORKER_HOME/secrets.env` (`NAME=value` lines), falling back to the Manager's environment.
The Manager refuses to start if `secrets.env` is readable by group or others. Values from
`secrets.env` stay in the Manager's memory and go only to the backends; they are never put into
the process environment, so lifecycle scripts, git hooks and the notify command never inherit
them. That is also how a launchd service gets its tokens.

```toml
clones_dir             = "~/Dev/loopworker"   # clones and slot worktrees
max_slots              = 4                    # weighted budget
max_concurrent_workers = 2
max_attempts           = 3

[backlog]
kind = "gitlab"

[backlog.gitlab]                              # each backend decodes its own section
base_url    = "https://gitlab.com"
token_env   = "LOOPWORKER_GITLAB_TOKEN"
allowed     = ["mygroup/"]                    # path prefixes; anything else is ignored
status_mode = "work_item_status"              # or "labels", or "none"

[forge]
kind = "gitlab"                               # [forge.gitlab] may override; else uses [backlog.gitlab]

[[project]]
path     = "mygroup/myapp"                    # forge path; also the backlog's project key
slots    = 1
hot      = false
weight   = 1
model    = "opus"
contract = "~/.loopworker/contracts/myapp"    # optional host-local overlay of .loopworker/
worker_env = []                               # Manager variables forwarded to workers
```

The repo's own `.loopworker/` is read from the clone's working tree, which the Manager resets to
`origin/<base>` after every fetch, so scripts and the brief always match the base branch.

## State on disk

```
$LOOPWORKER_HOME/
  config.toml
  secrets.env                 tokens, mode 0600
  state/manager.lock          pid lock: one Manager per home
  state/status.json           written atomically each tick; `loopworker status` reads it
  state/manager.log           redacted
  state/PAUSED                host killswitch; state/projects/<key>/PAUSED per project
  state/tmux                  the Manager's own tmux server socket
  state/ci/<card id>.json     CI watch record of a verifying card (the id percent-encoded)
  state/pushes.json           push ledger: the branch and commit last pushed per card id, the push lease
  slots/<key>/<n>/            brief, snapshot, launch script, outcome, MCP config, ci.md;
                              last-outcome.json: the last finished outcome and its card id
<clones_dir>/<key>/           the clone; its working tree tracks origin/<base>
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

Workers run on the Manager's own tmux server (`tmux -S $LOOPWORKER_HOME/state/tmux`), in
sessions named `lw_<key>_<slot>`, so a
human's tmux sessions on a shared host are never listed or reaped, and workers survive a
Manager restart: the next Manager adopts each live worker whose slot's `card.json` names a
card that is still `working`.

## Signals

The first SIGINT drains, the second force-stops (reap every worker and release its card), the
third exits immediately. SIGTERM force-stops. launchd and systemd send SIGTERM.

## Distribution

A single `loopworker` binary from the `nevyn/tap` Homebrew formula. `loopworker service install`
writes a launchd plist (a LaunchDaemon with `UserName` when the host has no logged-in user, or a
LaunchAgent). A menu-bar app may come back later as a client of `status.json`.
