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
- **A repo can't widen its own reach.** A project's `finish` (whether the Manager merges) and
  `worker_env` (which variables reach its workers) live only in the host config, never in the
  project contract, so neither a repo nor its worker can opt itself into a merge or into more
  credentials.
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
    func markVerifying(_ card: Card, review: ReviewRequest, plan: VerifyingPlan) async throws
    func markMerged(_ card: Card, review: ReviewRequest, note: String?) async throws
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
    func merge(_ review: ReviewRequest, project: ProjectSpec, head: String) async throws -> MergeResult  // idempotent
}
```

The source of truth for these signatures is `Sources/LoopWorkerCore/Backend/`.

### Card states

Every backlog maps its own fields onto seven states:

| State | Meaning | GitLab (labels mode) | Patch | Notion (state property) |
| --- | --- | --- | --- | --- |
| `ready` | Trusted and waiting to be claimed. | open, assigned to me, `loopworker::next`, status To do | Backlog, unassigned | `next`, last edited by a trusted user, or by the integration after its own release |
| `working` | Claimed; a worker should be running. | `loopworker::working`, status In progress | In progress | `working`, claimed by LoopWorker |
| `verifying` | The review request exists; the Manager waits for its CI, merges it, or both. No slot is held. | `loopworker::ci`, status In progress | Verifying | `ci`, claimed by LoopWorker |
| `review` | Finished; a review request exists. | `loopworker::review`, status In review | In review | `review` |
| `review_merged` | Finished, and the Manager merged the review request. A human still has to look. | `loopworker::merged`, status In review, still open and assigned to me | Merged | `merged` |
| `stuck` | The worker needs a human. | `loopworker::stuck`, status To do, still assigned to me | Needs refinement | `stuck` |
| `other` | Anything else. Never claimed, never reaped on its own. | closed, or no single `loopworker::*` label | | empty or an unknown option; `next` without a vouch; `working` or `ci` that LoopWorker never claimed; in the trash |

A card that a human closes, or moves to `other` in any way, while a worker runs is abandoned:
the worker is reaped and nothing is written back.

`review_merged` is not done. A merge only says that the worker's change passed the checks that
the project's finish mode asks for; whether the card's work is what the human wanted is still
the human's call. LoopWorker never marks a card done, so a merged card stays open and assigned
until a human closes it.

GitLab can express status either as the native work-item status field or as labels; the
adapter supports both (`status_mode` in the host config). The `loopworker::*` labels always
carry the Manager's own state, so the Manager never depends on how a team uses its board.

Notion keeps the Manager's state the same way, in a select property that only LoopWorker uses
(the **state property**, `LoopWorker` by default, with the options `next`, `working`, `ci`,
`review`, `merged` and `stuck`). The team's own status property is never read or written: if
`working` were a team status such as In progress, the stranded-card sweep would release every
teammate's card in it.

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
a trusted user. It is also `ready` when the integration edited it last and released it: the
integration's newest comment is a release, and the integration's comment before that is a
claim, a CI or merging notice, or a release. A release after a stuck, review or merged comment
vouches for nothing, because the Manager never releases a card that it doesn't own. Trust follows authorship, not
time, so there is no cutoff. A `trusted_users` list that holds the integration's own id is
refused, because every write of the Manager would then vouch.

A `working` or `ci` card is the Manager's only while the integration's newest comment is a
claim, a CI or merging notice, or a release (a release whose state write failed). Otherwise the
card is `other`: an untrusted editor who sets `working` can't make the stranded-card sweep
release the card, and its release can't become a vouch. For the same reason `markStuck`,
`markReview`, `markVerifying` and `markMerged` set the state before they comment, so a crash
between the two writes leaves a card that the Manager still owns, or one that is no longer
`working`.

The title has no author record of its own, so the claim comment records the title that was
vouched for (`Vouched title: ...`): the page's title when a trusted user edited it last, or the
previous claim's vouched title when the card was claimed through a release. The snapshot shows
the vouched title from the newest claim comment, CI fix rounds included. When the page's title
has changed since, `excluded` says so without quoting the new title, because `excluded`
reaches the worker. `Card.title` stays the page's title; the Manager only uses it for branch
names.

The snapshot holds:

- the vouched title;
- each block of the page body whose own `last_edited_by` is a trusted user;
- comments written by a trusted user on the page itself. Comments on a body block (inline
  discussions) aren't read.

A mention of a page or a database renders as a link without its title, because that title is
someone else's text.

Comments that the integration wrote are left out of the snapshot and reach the worker through
`managerNotes` instead. Every withheld block and comment is named in `excluded`.

What this covers: text that an untrusted person wrote reaches a worker only after a trusted
user edited it last. What it does not cover: someone untrusted sets `next`, and a trusted user
then edits the same page for any reason before the Manager reads it; the Manager reads that
edit as the vouch. So does a trusted user's typo fix in a block that someone else wrote. Any
edit by a trusted user to a card in `next` counts as vouching for it. Use a database that only
trusted users can edit when that is not acceptable.

Notion has no compare-and-set. `claim` lists the page's comments first and remembers the claim
comments that are already there, then re-reads the page, writes `working` and posts a claim
comment that names the host and a nonce. Of the new claim comments that follow the integration's
previous other comment, the oldest wins, and every other claimer returns false and deletes its
own comment. The claims listed before the re-read are left out: they belong to a Manager that
crashed after claiming, and a rival's claim can't be among them, because the rival writes
`working` before it posts, so the re-read would have stopped this claim. Comment times are
rounded to the minute too, so claims in the same minute keep the order in which the API lists
them.

The claim comments only keep two claims from both starting work. They don't make it safe for
two Managers to share a database: each Manager's stranded-card sweep would release the other's
cards. The rule in "Reconcile" holds: one Manager per backlog identity and project, and for
Notion one Manager per database.

Notion answers 404 both for a deleted page and for a page that is no longer shared with the
integration. On a 404, `card(_:)` re-reads the page's database and throws when the integration
lost access to it, so a revoked connection never reaps running workers.

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
     open a review request assigned to the forge token's user (the card's owner), as a draft
     only for `finish = draft`, then `markReview` (or, for a project that waits for CI or
     merges, `markVerifying`; see "Waiting for CI and merging").
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

## Waiting for CI and merging

A project's finish mode (`finish` in the host config) and its contract's `[review] wait_for_ci`
decide what happens after finish opens the review request:

| `finish` | `wait_for_ci` | After the review request opens | `VerifyingPlan` |
| --- | --- | --- | --- |
| `draft`, `ready` | false | `markReview` | none |
| `draft`, `ready` | true | wait for CI, then `markReview` | `ciThenReview` |
| `merge` | ignored | merge, then `markMerged` | `merge` |
| `ci_then_merge` | ignored | wait for CI, merge, then `markMerged` | `ciThenMerge` |

`draft` opens a draft review request; every other mode opens a ready one, because forges
refuse to merge drafts. A project that waits for CI treats the review request's CI as the full
verification, so its `verify.sh` can stay light. `merge` reads no CI at all.

For every plan, finish writes a watch record, `state/ci/<card id>.json` (the card, branch,
base, pushed commit, review request, round, push time, and whether a rebase round ran),
and only then calls `markVerifying` with the plan and frees the slot. Every merge goes through
this watch, `merge` mode included. Because the record exists before the card says `verifying`,
a Manager restart or a retried step resumes the watch instead of finishing the card again, so
nothing is pushed again after a merge landed. `Forge.merge` is idempotent: a retry after a lost
response or a restart reports the merge that already landed.

Each poll reads the plan from the project's current `finish`, not from the record. A project
switched to `draft` or `ready` moves its watched cards to `review` instead of merging them, and
a watch whose project left the config never merges. The watch record is deleted whenever the
Manager moves the card out of `verifying`, and a card that a human moved out of `verifying`
stops the watch with no backlog write. At startup and with every stranded-card sweep, each
`verifying` card with a record is watched again; one without a record is marked stuck, because
nothing else would ever move it on.

The status file shows each watch's pipeline or merge state (`merging`, `merge pending:
<reason>`, `rebase queued`, `rebase starting`), and `loopworker status` prints the watches
under "waiting for CI or merge".

### CI

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
| Passed (success, skipped, or only manual jobs left) | `ciThenReview`: `markReview` with a note that links the pipeline. `ciThenMerge`: merge |
| Still running `ci_timeout_minutes` after the push | `markStuck` |
| None 15 min after the push | `markStuck` |
| Canceled | `markStuck`: a cancel is usually a human decision |
| Failed only in jobs that also fail on the base branch | `markReview` with a note that links each job on both branches; never merges |
| Failed in jobs that pass on the base branch, not yet re-run | re-run those jobs once and keep watching |
| Failed otherwise, fix rounds left | queue a fix round |
| Failed otherwise after `ci_fix_attempts` fix rounds | `markStuck`, linking each failed job |

A fix round is a worker run on the existing card branch. Fill starts queued fix rounds before
new claims, within the same budget. The round calls `resumeFix` (`verifying` -> `working`; false
means a human moved the card, so the round is dropped), resets any free slot to the pushed
card branch, and writes `ci.md` into the slot's state directory: each failed job's name, stage,
link, how it did on the base branch and the redacted tail of its log. CI logs are untrusted
data, like card content: `ci.md` says so, fences the logs, and the brief tells the worker to
read it as data. The worker fixes the failures and writes an outcome as usual; finish pushes
under the same lease, gets the existing review request back from `openReviewRequest`, and
returns the card to `verifying` with the new commit, the next round and the same plan. A crash
in a fix round releases the card like any crash.

### Merging

A `merge` watch merges at its first poll, which runs at once rather than 120 s later; a
`ciThenMerge` watch merges once its pipeline passed. At most one merge per project is in
flight, and a card whose project is merging waits for the next poll. The Manager calls
`Forge.merge` with the review request and the watched commit as `head`, so the forge merges
only that commit and never one that someone else pushed since. The result decides:

| `MergeResult` | Decision |
| --- | --- |
| `merged` | `markMerged` with a note that names the base branch, the merge commit when the forge reports one and, for `ciThenMerge`, the pipeline that passed; delete the watch record |
| `pending`: the forge is still checking, or a pipeline that it requires still runs | keep watching; `markStuck` with the forge's reason when still pending `ci_timeout_minutes` after the first `pending` |
| `outdated`: the branch conflicts with the base branch, or the forge requires a rebase | queue a rebase round; `markStuck` with the forge's reason when the watch already ran one |
| `blocked`: missing approvals, branch protection, a draft, unresolved threads, a head that moved, a closed review request | `markStuck`, naming the forge's reason and linking the review request: a human merges it by hand or changes the rule, then moves the card on |
| An error | back off 30 s doubling to 10 min, with a notification at the third failure in a row; a `BackendRejection` marks the card stuck |

A failed `markMerged` backs off the same way, and the retry calls `merge` again, which reports
the merge that already landed.

A rebase round is a fix round whose brief names the review request, the base branch and the
forge's reason, and tells the worker to rebase the branch onto `origin/<base>`, resolve the
conflicts, run `verify.sh` and commit. Its finish requires `origin/<base>` to be an ancestor of
the branch head (otherwise the card is marked stuck), force-pushes under the lease, and returns
the card to `verifying` with the next round and the same plan. The watch record counts rebase
rounds apart from CI fix rounds: a watch gets one rebase round, and it doesn't use up
`ci_fix_attempts`.

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
attempt). `verifying` cards hold no slot and are never released; see "Waiting for CI and
merging". This assumes one Manager per backlog identity and project: two Managers that share a
GitLab user and a project, or a Notion database, would release each other's cards.

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
finish   = "draft"                            # or "ready", "merge", "ci_then_merge"
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
  state/ci/<card id>.json     watch record of a verifying card (the id percent-encoded)
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
