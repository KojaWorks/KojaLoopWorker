# LoopWorker

A **Manager** daemon that claims cards from a backlog and spawns one disposable **Worker** (a
`claude` session in tmux) per card. The worker implements the card in its own slot, commits,
and writes an outcome file. The Manager then pushes the branch, opens a review request and
moves the card on. The Manager is deterministic and runs no model; workers hold no backlog or
forge credentials.

One Manager runs per host and serves every project in its host config, cloning each repo on
demand. Backlogs: GitLab issues, Patch and Notion databases. Forges: GitLab and GitHub. This README
shows GitLab and Notion; the Patch and GitHub backends document their config sections in their
source.
[DESIGN.md](DESIGN.md) has the architecture; [docs/glossary.md](docs/glossary.md) the terms.

## North star

A releasable, self-managing product: a Manager you start once that runs indefinitely and
recovers from most errors on its own (a paused container engine, a revoked credential, a hung
provision, a wedged worker) without a human restart. Every failure mode gets its detection and
recovery in the change that introduces it, and the status and log make the rare thing a human
must do obvious.

## Install

```bash
brew install nevyn/tap/loopworker
```

The host also needs `git`, the Claude Code CLI (`claude`), `git-lfs` for repos that use Git
LFS, `storygrafter` for projects that ask for review guides, and a container engine if a
project's lifecycle scripts start containers. macOS 14 or later.

## Set up with your coding agent

Give your coding agent this line:

> Run `loopworker prompt` and follow its instructions to set up LoopWorker on this host.

`loopworker prompt` prints what it finds on this host (the config, which tokens `secrets.env`
sets, whether a Manager runs; never a token value), then step-by-step setup instructions. The
agent asks you which backlog, forge and projects to use and who may vouch for cards, writes the
config, and leaves every token value for you to paste.

## Configuration

Everything lives in `$LOOPWORKER_HOME`, which defaults to `~/.loopworker`. `config.toml` is the
only config source; the Manager re-reads it when it changes (new projects start, removed ones
drain, slot counts resize).

A complete GitLab host config:

```toml
clones_dir             = "~/Dev/loopworker"   # clones and slot worktrees
max_slots              = 4                    # host budget in weighted slot units
max_concurrent_workers = 2                    # claude sessions at once; default ceil(max_slots)
max_attempts           = 3                    # crashes per card before it is marked stuck
# notify_command = "..."                      # receives alerts on stdin; empty disables them

[engine]                                      # restarts a container engine that went down
recover       = true
start_command = "orb start"
probe_command = "docker ps"

[backlog]
kind = "gitlab"

[backlog.gitlab]
base_url    = "https://gitlab.example.com"
token_env   = "LOOPWORKER_GITLAB_TOKEN"       # the variable in secrets.env that holds the token
allowed     = ["mygroup/"]                    # project path prefixes; anything else is ignored
status_mode = "work_item_status"              # also set the status field: none, labels or work_item_status

[backlog.gitlab.status]                       # status names per card state (these are the defaults)
ready   = "To do"
working = "In progress"
review  = "In review"
stuck   = "To do"
# verifying = "In progress"                   # waiting for CI or a merge; defaults to the working name
# merged    = "In review"                     # merged by the Manager; defaults to the review name

[forge]
kind = "gitlab"                               # [forge.gitlab] may override base_url and token_env

[[project]]
path        = "mygroup/myapp"                 # the forge path; also the backlog's project key
slots       = 1
hot         = false                           # hot slots stay provisioned between cards
weight      = 1                               # slot cost against max_slots
model       = "opus"                          # claude --model for this project's workers
base_branch = "main"                          # default: the forge's default branch
finish      = "draft"                         # draft, ready, merge or ci_then_merge
contract    = "~/.loopworker/contracts/myapp" # optional host-local overlay of the repo's .loopworker/
worker_env  = ["MYAPP_LICENSE_SERVER"]        # Manager variables forwarded to this project's workers
```

`status_mode = "none"` (the default) changes only the `loopworker::*` labels. `labels` also
adds the status names as labels. `work_item_status` sets GitLab's native status field
(Premium and up).

`finish` decides how a finished card ends. `draft` (the default) and `ready` open a draft or a
ready review request and move the card to review. `merge` merges the review request right after
opening it, without waiting for CI, so the worker's own `verify.sh` run is the only check.
`ci_then_merge` waits for the pushed commit's pipeline, fix rounds included, and merges once it
passes. The merging modes open the review request ready, because a forge refuses to merge a
draft, and move the card to `review_merged` (`loopworker::merged` on GitLab): the Manager merged
it, and a human still has to look at the result. Only the host config can set `finish`, so a
repo can't opt itself into a merge. The Manager reads `finish` again before each merge: a
project switched to `draft` or `ready` moves its waiting cards to review instead. `draft = true`
and `draft = false` still work as deprecated aliases for `finish = "draft"` and `"ready"`; the
Manager logs a warning and doctor shows it.

`worker_env` refuses the backlog and forge token variables: workers never get those.

## Secrets

Tokens go in `$LOOPWORKER_HOME/secrets.env`, one `NAME=value` per line, readable only by you:

```bash
chmod 600 ~/.loopworker/secrets.env
```

```
LOOPWORKER_GITLAB_TOKEN=...
CLAUDE_CODE_OAUTH_TOKEN=...
```

The Manager refuses to start when group or others can read the file. Values from it go only to
the backends and, for `CLAUDE_CODE_OAUTH_TOKEN` and `worker_env` names, to workers; lifecycle
scripts, git hooks and the notify command never see them. A variable in the Manager's own
environment is used when `secrets.env` doesn't set it, but a launchd service has no shell
environment, so put everything here.

Use a GitLab personal access token with the `api` scope for `LOOPWORKER_GITLAB_TOKEN`. An
OAuth token, such as the one `glab auth login` stores, expires after about two hours, and the
Manager can't refresh it.

`CLAUDE_CODE_OAUTH_TOKEN` comes from `claude setup-token`. Without it, workers use the host's
interactive claude login, which a LaunchDaemon can't reach and which concurrent workers can
log out by racing its refresh.

## GitLab cards

LoopWorker only works on cards that you vouched for. "You" is the user that the token belongs
to (`loopworker doctor` names it). An issue is picked up when all of these hold:

- it is open, in a configured `[[project]]` under an `allowed` prefix;
- you assigned yourself;
- you added the `loopworker::next` label.

Adding the label vouches for the title, description and comments as they are at that moment.
Later edits or comments by anyone else are withheld from the worker and named in the log. If a
colleague assigned you, re-assign yourself before adding the label.

Create the labels `loopworker::next`, `loopworker::working`, `loopworker::review` and
`loopworker::stuck` once in the group, `loopworker::ci` if a project waits for CI or merges, and
`loopworker::merged` if a project merges. The Manager moves a card between them:

| Label | Meaning | What happened on the issue |
| --- | --- | --- |
| `loopworker::next` | Ready to claim. | You added it, or the Manager released the card with a note saying why (a crash, a hang, an auth failure). |
| `loopworker::working` | A worker is on it. | The Manager claimed it and posted a note that names its host ("LoopWorker on buildmac.local is working on this card."); a hidden marker in that note records which Manager holds the card. |
| `loopworker::ci` | Waiting for CI or a merge. Only for projects whose contract sets `[review] wait_for_ci`, or whose `finish` merges. | The Manager pushed the branch, opened a merge request, linked it in a note and is watching its pipeline, merging it, or both. No worker runs. If CI fails only in jobs that also fail on the base branch, the card goes to review with a note that says so, and isn't merged. Failed jobs that pass on the base branch are re-run once, since they may be flaky. Any other failure is fixed by a worker on the same branch (the card shows `loopworker::working` meanwhile); if CI keeps failing, times out or is canceled, the card becomes stuck. `loopworker status` lists these cards under "waiting for CI or merge". |
| `loopworker::review` | Ready for your review. | The Manager pushed the branch, opened a merge request assigned to you and linked it in a note (and, after CI, the pipeline that passed). |
| `loopworker::merged` | Merged; a human still has to look. | The Manager merged the merge request into the base branch and linked it in a note with the merge commit (and, for `ci_then_merge`, the pipeline that passed). The issue stays open and assigned to you; look at the result, then close it. |
| `loopworker::stuck` | The worker needs a human. | A note says what blocks it. You stay assigned, so it stays in your queue; answer it on the issue, then add `loopworker::next` (it replaces `loopworker::stuck`); the next worker continues from the pushed branch. A card with two `loopworker::*` labels is ignored. |

The labels are GitLab scoped labels (`scope::value`, Premium and up): an issue carries one
`loopworker::*` label at a time, so adding `loopworker::next` to a stuck card replaces
`loopworker::stuck` by itself. On Free they are plain labels; remove the old one yourself. A card
can also carry `loopworker-priority::<n>` (higher is claimed sooner) and
`loopworker-model::<alias>` (the claude model for that card). `[backlog.gitlab] label_prefix`
changes the prefix; with a prefix that doesn't end in `::` (`label_prefix = "loopworker:"`) the
labels are `loopworker:next`, `loopworker:priority:<n>` and so on.

A card that crashes `max_attempts` times becomes stuck. Closing an issue or removing its
`loopworker::*` label while a worker runs stops that worker; nothing is written back.

The Manager merges one merge request per project at a time, and keeps the card in
`loopworker::ci` until the merge lands. When GitLab can't merge yet (it is still checking, or a
required pipeline still runs), the Manager tries again at each poll, and marks the card stuck
when the merge is still pending `ci_timeout_minutes` later. When the base branch moved, so the
merge request conflicts or needs a rebase, a worker rebases the branch onto the base branch once
and the Manager force-pushes it and tries again; the card shows `loopworker::working` meanwhile.
If GitLab still refuses for that reason, the card becomes stuck. A rule that a rebase can't
change (missing approvals, branch protection, a draft, unresolved threads) marks the card stuck
with a note that names the rule: merge the merge request by hand or change the rule, then move
the card on.

To have a worker address review comments, add `loopworker::next` to a card in
`loopworker::review` while its merge request is open. That runs a review round: the next worker
continues on the same branch and gets every unresolved thread, plus the plain comments made since
the previous review round read them. Resolve the threads that you don't want addressed
first. Adding the label vouches for the merge request's comments as they are then: anything a
colleague writes or edits afterwards is withheld and named in the log. When it finishes,
LoopWorker pushes to the same merge request, replies in each thread, and posts what it changed
as a note. It never resolves a thread; that stays your call. Commits that you push to the branch
before the round starts are kept: the worker starts from them.

## Notion cards

A Notion backlog keeps each project's cards in its own database. Notion is only a backlog: the
code still goes to the forge in `[forge]`.

```toml
[backlog]
kind = "notion"

[backlog.notion]
token_env         = "LOOPWORKER_NOTION_TOKEN"   # the variable in secrets.env that holds the secret
trusted_users     = ["<notion user id>"]        # required: people whose edits vouch for cards
state_property    = "LoopWorker"                # select with next, working, ci, review, merged and stuck
priority_property = "Priority"                  # optional: number, select or multi-select
model_property    = "Model"                     # optional: select or text (a claude model alias)

[backlog.notion.projects]                       # one database per [[project]]
"mygroup/myapp" = "https://www.notion.so/<workspace>/<title>-<32 hex>"   # or the bare id

[forge]
kind = "gitlab"
```

Create an internal integration for LoopWorker
([how](https://www.notion.com/help/add-and-manage-connections-with-the-api)) with the
capabilities to read, update and insert content, read and insert comments, and read user
information without email addresses. Put its secret in `secrets.env` as
`LOOPWORKER_NOTION_TOKEN`. A person's token is refused, because the Manager's writes would then
look like that person's edits. Connect the integration to each database: open the database,
choose ••• -> Connections and add the integration.

Give each database a select property that only LoopWorker uses, `LoopWorker` by default, with
the options `next`, `working`, `ci`, `review` and `stuck`, and `merged` when the project's
`finish` merges. The Manager never reads or writes the team's own status property.
`loopworker doctor` checks every database and names any property, option or connection that is
missing (`merged` only for a project that merges); it never changes a database. When a
`trusted_users` id is wrong, doctor lists the workspace's people with their ids.

A trusted user vouches for a card by setting its `LoopWorker` property to `next`. The Manager
claims a `next` card only when a trusted user edited the page last, and its claim comment
records the title as it was then. The worker sees that title, the blocks of the page that a
trusted user edited last, and the comments that a trusted user wrote on the page; everything
else is withheld and named in the log. Comments on a block inside the page (inline comments)
aren't read at all, so trusted users comment on the page itself. The Manager moves the card
through the same states as on GitLab and posts a comment for most moves: when it claims the
card, when it releases it (and why), when the worker is stuck (and on what), when it opens
a review request, waits for its CI or starts merging it, and when it merged it. Starting a fix
round posts no comment.
A teammate sees those comments and the `LoopWorker` property change; the integration is their
author.

Don't resolve LoopWorker's comments. Notion's API doesn't return resolved comments, so the
Manager would lose count of failed attempts and could stop treating a released card as ready.
The Manager treats a `working` or `ci` card as its own only when its own comments say that it
claimed the card, so setting `working` by hand does nothing.

Notion doesn't record who changed one property, only who edited the page last. If someone
untrusted sets `next` and a trusted user then edits the page for any reason, the Manager reads
that edit as the vouch. Use a database that only trusted users can edit when that matters.

A stuck card stays `stuck` until a trusted user answers in a comment and sets `LoopWorker` back
to `next`; the next worker continues from the pushed branch. A card that crashes `max_attempts`
times becomes stuck. Clearing the `LoopWorker` property, or moving the page to the trash, while
a worker runs stops that worker; nothing is written back.

Setting a card in `review` back to `next` while its review request is open runs a review round,
as on GitLab. Notion records no time when a card was vouched for, so only the comments that the
forge token's user wrote on the review request reach the worker; everyone else's are withheld.

## Running

```bash
loopworker prompt              # setup instructions for a coding agent, with this host's context
loopworker doctor              # check the host first
loopworker                     # run the Manager in the foreground (same as `loopworker run`)
```

To keep a foreground Manager running after you log out of an SSH session, start it in tmux:

```bash
tmux new-session -d -s loopworker loopworker run
```

tmux runs that command through your login shell, so shell syntax such as `VAR=x cmd` or `&&`
fails under fish and similar shells. The Manager needs none: settings live in `config.toml` and
tokens in `secrets.env`. Wrap anything else in `bash -c '...'`.

As a launchd service, which starts at login and restarts after a crash:

```bash
loopworker service install             # a LaunchAgent for the current user
loopworker service install --daemon    # a LaunchDaemon for a host where nobody logs in
loopworker service install --dry-run   # print the plist and commands, change nothing
loopworker service uninstall
```

`--daemon` needs root, so it writes the plist to `$LOOPWORKER_HOME/state` and prints the `sudo`
commands to install it. The service runs the binary at the path you installed it from, with
`LOOPWORKER_HOME` and a `PATH` of `~/.local/bin`, Homebrew's bin and the system dirs; doctor
warns about tools outside that `PATH`. The service writes its output to
`$LOOPWORKER_HOME/state/manager.out`; the redacted log is `state/manager.log`. Use either this
or `brew services`, not both.

A LaunchDaemon, or any host where the Manager's user has no GUI session, can't answer
Gatekeeper's first-launch prompt, so macOS kills a quarantined binary (one that a Homebrew cask
installed, for example) the moment it starts. Clear the flag from each tool the Manager runs
with `xattr -d com.apple.quarantine <path>`, on the resolved binary rather than the symlink on
`PATH`; `loopworker doctor` names every quarantined tool and the exact command. A binary that
a user already approved in a GUI session keeps the attribute with its approval flag set; doctor
accepts it.

## Doctor

`loopworker doctor` prints `ok`, `warn` or `FAIL` per check, with a remedy for each problem,
and exits 1 when anything fails. `--json` prints the same as JSON. It checks:

- `config.toml` parses, and lists the projects; a deprecated key such as `draft` warns;
- `secrets.env` is mode 600, and each token is set there (a token only in your shell warns);
- `tmux`, `git`, `claude` and `bash` are on `PATH`; `git-lfs` and `storygrafter` warn when absent,
  and a missing `git-lfs` fails once a cloned project uses Git LFS;
- none of those tools, nor `loopworker` itself, carries macOS's quarantine flag without a user's approval;
- claude answers `claude -p` headless, the same check that gates claims;
- the container engine answers its probe (a warning only);
- the backlog and forge accept their tokens, and whose they are;
- `$LOOPWORKER_HOME` is writable, and whether a Manager is running.

## Status, pause and stop

```bash
loopworker status              # projects, slots, cards, auth, recent log; exits 1 when no Manager runs
loopworker status --json       # state/status.json as is
loopworker pause [project]     # no new claims for the host or one project; running workers finish
loopworker resume [project]
```

`status` also says when the Manager holds its lock but stopped updating (wedged).

One Manager serves each project. When a second one serves the same project with the same
backlog (two hosts configured for it by mistake), each leaves the cards that the other claimed
alone: `status` lists them under "held by other Managers" with the other Manager's
`<host>:<home>`, and the log says so once per card. Remove the project from one host's config;
if the other Manager is gone for good, move its cards back to ready.

Stopping escalates. The first SIGINT (Ctrl-C) drains: running workers finish, nothing new is
claimed, then the Manager exits. A second SIGINT force-stops: it reaps every worker and releases
its card back to `loopworker::next`. A third exits at once. SIGTERM force-stops. For the
LaunchAgent:

```bash
launchctl kill SIGINT gui/$(id -u)/dev.nevyn.loopworker    # drain
launchctl kill SIGTERM gui/$(id -u)/dev.nevyn.loopworker   # force-stop
launchctl kickstart gui/$(id -u)/dev.nevyn.loopworker      # start again
```

## Making a project compatible

Give the repo a `.loopworker/` contract (`manifest.toml`, lifecycle scripts, an optional
`BRIEF.md`), or keep one on the host and point the project's `contract` at it. See
[docs/project-contract.md](docs/project-contract.md) and [examples/](examples/).

## Development

See [docs/dev_guide.md](docs/dev_guide.md).
