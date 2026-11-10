# Glossary

One term per concept. Code, docs, logs and commits use the term in bold.

**LoopWorker**: The product: the `loopworker` CLI and the daemon it runs.
*Avoid:* KojaLoopWorker (that is only the repo name), Koja Loops Manager.

**Manager**: The deterministic, non-AI daemon. One per host; it serves every configured project.
*Avoid:* host manager, HostManager, orchestrator.

**Worker**: One `claude` session that implements exactly one card in one slot, then stops. Holds no loop state and no forge or backlog credentials.
*Avoid:* agent, runner, loop session.

**Backlog**: Where cards live and change state: GitLab issues, Patch, a Notion database, later GitHub issues. A pluggable backend behind the `Backlog` protocol.
*Avoid:* tracker, board, roadmap (Patch's table name only).

**Forge**: Where code is pushed and reviewed: GitLab, GitHub. A pluggable backend behind the `Forge` protocol, independent of the backlog.
*Avoid:* host, remote, SCM.

**Card**: One unit of work in a backlog: a GitLab issue, a Patch roadmap row, a Notion page in a database.
*Avoid:* ticket, issue (except when naming GitLab's own object), row, item.

**Card ref**: A card's stable identity, opaque to the Manager and owned by its backlog (`group/project#12`, `~802`).
*Avoid:* card num, id.

**Card state**: The Manager's normalized view of a card: `ready`, `working`, `verifying`, `review`, `review_merged`, `stuck`, or `other`. Each backlog maps its own statuses and labels onto it.
*Avoid:* status (except a backlog's own field).

**State property**: The Notion select property that holds a card's state for the Manager alone (`LoopWorker` by default: `next`, `working`, `ci`, `review`, `merged`, `stuck`), the counterpart of GitLab's `loopworker::*` labels. A team's own status property is never used.
*Avoid:* status property, LoopWorker column.

**Verifying**: The card state between opening the review request and moving the card on, while the Manager waits for its CI (`wait_for_ci`, `finish = ci_then_merge`), merges it (`finish = merge` or `ci_then_merge`), or both. No worker runs and no slot is held.
*Avoid:* waiting for CI, CI pending.

**Fix round**: A worker run on a `verifying` card's existing branch and review request: one that fixes its failed CI, or a rebase round.
*Avoid:* CI retry, rework.

**Rebase round**: A fix round that rebases the card branch onto a base branch that moved, after the forge refused to merge it as outdated.
*Avoid:* conflict round, re-merge.

**Review round**: A worker run on a card that its owner moved back to ready while its review request is open: the worker addresses the review feedback on the existing branch, and the Manager posts its replies and summary on the same review request.
*Avoid:* review cycle, revision.

**Review feedback**: The unresolved threads and newer plain comments on a review request that a review round's worker gets, with only the notes that the trust check accepts.
*Avoid:* review comments, MR comments.

**Pipeline**: The forge's CI run for one commit: a GitLab pipeline, or a GitHub commit's check runs taken together.
*Avoid:* CI job (that is one part of it), build.

**Claim**: The Manager moving a ready card to `working` before it spawns a worker.
*Avoid:* pick, take, assign.

**Holder**: The Manager that a `working` or `verifying` card's newest claim names, by its holder id `<host name>:<LOOPWORKER_HOME>` (saved in `state/holder`). A Manager leaves cards that another Manager holds alone.
*Avoid:* owner (that is the card's human), claimer, lock holder (the pid in `manager.lock`).

**Release**: The Manager returning a `working` card to `ready` after a crash, hang or auth failure, with a note on the card.
*Avoid:* reclaim, unclaim, bail.

**Outcome**: The JSON file that a worker writes as its last act: `done` (with review request text) or `stuck` (with the blocker). The worker's only output channel to the Manager.
*Avoid:* result, exit signal.

**Attachment**: A file that a worker writes into its slot state directory and names in its outcome, as the `guide` or as `attachment:<path>` in the body. The Manager checks it and uploads it to the forge at finish, or publishes it through the host's `upload_command` on a forge without attachments.
*Avoid:* upload, asset.

**Finish**: The Manager applying an outcome: pushing the branch, opening the review request and moving the card to `review`, `verifying` or `stuck`.
*Avoid:* wind down, ship.

**Finish mode**: A project's `finish` in the host config: `draft`, `ready`, `merge` or `ci_then_merge`. It decides whether the review request opens as a draft and whether the Manager merges it.
*Avoid:* merge policy, auto-merge setting.

**Merge**: The Manager merging a card's review request into the base branch through the forge, for projects whose finish mode merges.
*Avoid:* land, ship, auto-merge.

**Review merged**: The card state `review_merged`: the Manager merged the card's review request, and a human still has to look at the result. Not done: only a human decides that a card is done, and LoopWorker never does.
*Avoid:* merged (except as Notion's option or GitLab's label), done, shipped.

**Push record**: The branch and the commit of LoopWorker's newest push for a card, recorded on the card by the backlog write that follows the push (`Backlog.lastPush`). Any Manager that claims the card resumes the branch that it names. `state/pushes.json`, the legacy push ledger, held it before.
*Avoid:* push marker, push ledger (only the legacy file).

**Lease tip**: The commit that the next push of a slot's card branch expects on the forge, kept in the slot's `card.json`: none for a fresh start, then the commit that a resumed card or round started from, then each push's own.
*Avoid:* lease file, expected commit.

**Review request**: A forge's request to merge a branch: a GitLab merge request, a GitHub pull request.
*Avoid:* MR, PR (except when naming one forge's object).

**Vouch**: A human's act that makes a card trusted: on GitLab, the token's user adding the `next` label; on Notion, a trusted user being the last to edit a card in `next`.
*Avoid:* approve, authorize.

**Trusted user**: A Notion user listed in `[backlog.notion] trusted_users`. Their edits vouch for cards and their blocks and comments reach the worker.
*Avoid:* allowed user, owner.

**Trusted**: A card that a human vouched for, with only content that the trust check accepts. Only trusted cards are claimed.
*Avoid:* authorized, safe.

**Snapshot**: The trusted content of a card (description and comments) that the Manager renders to a file for the worker. Content that fails the trust check is left out.
*Avoid:* card body, prompt.

**Project**: A repository the Manager serves, declared in the host config.
*Avoid:* repo (when meaning the configured unit).

**Project contract**: A project's `.loopworker/` directory: `manifest.toml`, the lifecycle scripts and an optional `BRIEF.md`. May live in the repo or in a host-local overlay.
*Avoid:* manifest (that is one file in it), scaffolding.

**Brief**: The instructions a worker is spawned with: LoopWorker's built-in worker brief plus the project's `BRIEF.md`.
*Avoid:* protocol, loop instructions, Managed Agent Loop.

**Slot**: A worktree, a port band and a stack that one worker uses. `hot` slots stay provisioned between cards; `cold` slots are provisioned per card.
*Avoid:* lane, sandbox.

**Stack**: Whatever a project's `provision.sh` starts for a slot (containers, databases, simulators).
*Avoid:* environment.

**Lifecycle script**: `provision.sh`, `reset.sh`, `verify.sh` or `teardown.sh` from the project contract. Always run in its own process group under a hard timeout.
*Avoid:* hook.

**Reap**: Killing a worker's tmux session.
*Avoid:* kill (in prose about workers).

**Recycle**: Returning a slot to the pool after a card: reset for hot, teardown for cold.
*Avoid:* release (that is for cards).

**Retire**: Removing a slot from the pool for good (resize down, project removed).
*Avoid:* recycle.

**Broken**: A slot whose lifecycle script failed. The Manager skips it and retries with backoff.
*Avoid:* dead, failed.

**Tick**: One pass of the Manager loop: reconcile every busy slot, then fill free slots.
*Avoid:* poll, cycle.

**Failing read**: A backlog list read (`workable`, `working` or `verifying`) that failed at its last attempt for a project. The Manager retries it, lists it on the status `backlog:` line, and alerts once it has failed for 10 minutes.
*Avoid:* read error, backlog outage.

**Drain**: Stop claiming, let running workers finish, then exit. The first SIGINT.
*Avoid:* graceful shutdown.
