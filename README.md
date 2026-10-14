# LoopWorker

A **Manager** daemon that claims cards from a backlog and spawns one disposable **Worker** (a
`claude` session in tmux) per card. The worker implements the card in its own slot, commits,
and writes an outcome file. The Manager then pushes the branch, opens a review request and
moves the card on. The Manager is deterministic and runs no model; workers hold no backlog or
forge credentials.

One Manager runs per host and serves every project in its host config, cloning each repo on
demand. Backlogs: GitLab issues and Patch. Forges: GitLab and GitHub. This README shows GitLab;
the other backends document their config sections in their source.
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
# verifying = "In progress"                   # waiting for CI; defaults to the working name

[forge]
kind = "gitlab"                               # [forge.gitlab] may override base_url and token_env

[[project]]
path        = "mygroup/myapp"                 # the forge path; also the backlog's project key
slots       = 1
hot         = false                           # hot slots stay provisioned between cards
weight      = 1                               # slot cost against max_slots
model       = "opus"                          # claude --model for this project's workers
base_branch = "main"                          # default: the forge's default branch
draft       = true                            # open review requests as drafts
contract    = "~/.loopworker/contracts/myapp" # optional host-local overlay of the repo's .loopworker/
worker_env  = ["MYAPP_LICENSE_SERVER"]        # Manager variables forwarded to this project's workers
```

`status_mode = "none"` (the default) changes only the `loopworker:*` labels. `labels` also
adds the status names as labels. `work_item_status` sets GitLab's native status field
(Premium and up).

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
- you added the `loopworker:next` label.

Adding the label vouches for the title, description and comments as they are at that moment.
Later edits or comments by anyone else are withheld from the worker and named in the log. If a
colleague assigned you, re-assign yourself before adding the label.

Create the labels `loopworker:next`, `loopworker:working`, `loopworker:review` and
`loopworker:stuck` once in the group, and `loopworker:ci` if a project waits for CI. The Manager
moves a card between them:

| Label | Meaning | What happened on the issue |
| --- | --- | --- |
| `loopworker:next` | Ready to claim. | You added it, or the Manager released the card with a note saying why (a crash, a hang, an auth failure). |
| `loopworker:working` | A worker is on it. | The Manager claimed it. |
| `loopworker:ci` | Waiting for CI. Only for projects whose contract sets `[review] wait_for_ci`. | The Manager pushed the branch, opened a merge request, linked it in a note and is watching its pipeline. No worker runs. If CI fails, a worker fixes it on the same branch (the card shows `loopworker:working` meanwhile); if it keeps failing, times out or is canceled, the card becomes stuck. `loopworker status` lists these cards under "waiting for CI". |
| `loopworker:review` | Done. | The Manager pushed the branch, opened a merge request and linked it in a note (and, after CI, the pipeline that passed). |
| `loopworker:stuck` | The worker needs a human. | A note says what blocks it. You stay assigned, so it stays in your queue; answer it on the issue, then replace `loopworker:stuck` with `loopworker:next`. A card with two `loopworker:*` labels is ignored. |

A card that crashes `max_attempts` times becomes stuck. Closing an issue or removing its
`loopworker:*` label while a worker runs stops that worker; nothing is written back.

## Running

```bash
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

## Doctor

`loopworker doctor` prints `ok`, `warn` or `FAIL` per check, with a remedy for each problem,
and exits 1 when anything fails. `--json` prints the same as JSON. It checks:

- `config.toml` parses, and lists the projects;
- `secrets.env` is mode 600, and each token is set there (a token only in your shell warns);
- `tmux`, `git`, `claude` and `bash` are on `PATH`; `git-lfs` and `storygrafter` warn when absent,
  and a missing `git-lfs` fails once a cloned project uses Git LFS;
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

Stopping escalates. The first SIGINT (Ctrl-C) drains: running workers finish, nothing new is
claimed, then the Manager exits. A second SIGINT force-stops: it reaps every worker and releases
its card back to `loopworker:next`. A third exits at once. SIGTERM force-stops. For the
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
