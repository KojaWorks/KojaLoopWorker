# Glossary

One term per concept. Code, docs, logs and commits use the term in the left column.

| Term | Definition | Don't say |
| --- | --- | --- |
| **LoopWorker** | The product: the `loopworker` CLI and the daemon it runs. | KojaLoopWorker (that is only the repo name), Koja Loops Manager |
| **Manager** | The deterministic, non-AI daemon. One per host; it serves every configured project. | host manager, HostManager, orchestrator |
| **Worker** | One `claude` session that implements exactly one card in one slot, then stops. Holds no loop state and no forge or backlog credentials. | agent, runner, loop session |
| **Backlog** | Where cards live and change state: GitLab issues, Patch, a Notion database, later GitHub issues. A pluggable backend behind the `Backlog` protocol. | tracker, board, roadmap (Patch's table name only) |
| **Forge** | Where code is pushed and reviewed: GitLab, GitHub. A pluggable backend behind the `Forge` protocol, independent of the backlog. | host, remote, SCM |
| **Card** | One unit of work in a backlog: a GitLab issue, a Patch roadmap row, a Notion page in a database. | ticket, issue (except when naming GitLab's own object), row, item |
| **Card ref** | A card's stable identity, opaque to the Manager and owned by its backlog (`group/project#12`, `~802`). | card num, id |
| **Card state** | The Manager's normalized view of a card: `ready`, `working`, `verifying`, `review`, `stuck`, or `other`. Each backlog maps its own statuses and labels onto it. | status (except a backlog's own field) |
| **State property** | The Notion select property that holds a card's state for the Manager alone (`LoopWorker` by default: `next`, `working`, `ci`, `review`, `stuck`), the counterpart of GitLab's `loopworker::*` labels. A team's own status property is never used. | status property, LoopWorker column |
| **Verifying** | The card state between opening the review request and its CI passing, for projects that set `wait_for_ci`. No worker runs and no slot is held; the Manager polls the pipeline of the pushed commit. | waiting for CI, CI pending |
| **Fix round** | A worker run that fixes a `verifying` card's failed CI on its existing branch and review request. | CI retry, rework |
| **Review round** | A worker run on a card that its owner moved back to ready while its review request is open: the worker addresses the review feedback on the existing branch, and the Manager posts its replies and summary on the same review request. | review cycle, revision |
| **Review feedback** | The unresolved threads and newer plain comments on a review request that a review round's worker gets, with only the notes that the trust check accepts. | review comments, MR comments |
| **Pipeline** | The forge's CI run for one commit: a GitLab pipeline, or a GitHub commit's check runs taken together. | CI job (that is one part of it), build |
| **Claim** | The Manager moving a ready card to `working` before it spawns a worker. | pick, take, assign |
| **Holder** | The Manager that a `working` or `verifying` card's newest claim names, by its holder id `<host name>:<LOOPWORKER_HOME>` (saved in `state/holder`). A Manager leaves cards that another Manager holds alone. | owner (that is the card's human), claimer, lock holder (the pid in `manager.lock`) |
| **Release** | The Manager returning a `working` card to `ready` after a crash, hang or auth failure, with a note on the card. | reclaim, unclaim, bail |
| **Outcome** | The JSON file that a worker writes as its last act: `done` (with review request text) or `stuck` (with the blocker). The worker's only output channel to the Manager. | result, exit signal |
| **Attachment** | A file that a worker writes into its slot state directory and names in its outcome, as the `guide` or as `attachment:<path>` in the body. The Manager checks it and uploads it to the forge at finish. | upload, asset |
| **Finish** | The Manager applying an outcome: pushing the branch, opening the review request and moving the card to `review` or `stuck`. | wind down, ship |
| **Push ledger** | `state/pushes.json`: per card, the branch and the commit that the Manager last pushed, or that a resumed card or fix round started from. A push leases on it, and a re-queued card whose branch is still on the forge resumes from it. | push record, lease file |
| **Review request** | A forge's request to merge a branch: a GitLab merge request, a GitHub pull request. | MR, PR (except when naming one forge's object) |
| **Vouch** | A human's act that makes a card trusted: on GitLab, the token's user adding the `next` label; on Notion, a trusted user being the last to edit a card in `next`. | approve, authorize |
| **Trusted user** | A Notion user listed in `[backlog.notion] trusted_users`. Their edits vouch for cards and their blocks and comments reach the worker. | allowed user, owner |
| **Trusted** | A card that a human vouched for, with only content that the trust check accepts. Only trusted cards are claimed. | authorized, safe |
| **Snapshot** | The trusted content of a card (description and comments) that the Manager renders to a file for the worker. Content that fails the trust check is left out. | card body, prompt |
| **Project** | A repository the Manager serves, declared in the host config. | repo (when meaning the configured unit) |
| **Project contract** | A project's `.loopworker/` directory: `manifest.toml`, the lifecycle scripts and an optional `BRIEF.md`. May live in the repo or in a host-local overlay. | manifest (that is one file in it), scaffolding |
| **Brief** | The instructions a worker is spawned with: LoopWorker's built-in worker brief plus the project's `BRIEF.md`. | protocol, loop instructions, Managed Agent Loop |
| **Slot** | A worktree, a port band and a stack that one worker uses. `hot` slots stay provisioned between cards; `cold` slots are provisioned per card. | lane, sandbox |
| **Stack** | Whatever a project's `provision.sh` starts for a slot (containers, databases, simulators). | environment |
| **Lifecycle script** | `provision.sh`, `reset.sh`, `verify.sh` or `teardown.sh` from the project contract. Always run in its own process group under a hard timeout. | hook |
| **Reap** | Killing a worker's tmux session. | kill (in prose about workers) |
| **Recycle** | Returning a slot to the pool after a card: reset for hot, teardown for cold. | release (that is for cards) |
| **Retire** | Removing a slot from the pool for good (resize down, project removed). | recycle |
| **Broken** | A slot whose lifecycle script failed. The Manager skips it and retries with backoff. | dead, failed |
| **Tick** | One pass of the Manager loop: reconcile every busy slot, then fill free slots. | poll, cycle |
| **Drain** | Stop claiming, let running workers finish, then exit. The first SIGINT. | graceful shutdown |
