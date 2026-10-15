# Writing a project contract

A project contract tells LoopWorker how to build a slot for one project: how to bring up its
stack, how to reset it between cards, how a worker proves its change works, and how to tear it
down. Scheduling (slot count, hot or cold, weight, model) is host config, not contract.

## Where it lives

- In the repo, as `.loopworker/`, when the project's maintainers want it there.
- In a host-local overlay, when it shouldn't be committed (a shared repo, an experiment): set
  `contract = "~/.loopworker/contracts/<name>"` on the project in `config.toml`. The overlay
  replaces the repo's `.loopworker/` entirely; the two are never merged.

## Files

```
manifest.toml   settings (all optional)
provision.sh    brings a slot's stack up; heavy, idempotent
reset.sh        cheap reset between cards on a hot slot
verify.sh       the gate a worker must pass before reporting done
teardown.sh     stops the stack; best effort
BRIEF.md        project-specific instructions appended to the worker brief (optional)
```

Every script runs with `bash`, from the slot's worktree, with:

| Variable | Meaning |
| --- | --- |
| `LOOPWORKER_SLOT_DIR` | The slot's worktree (also the working directory). |
| `LOOPWORKER_PORT` | First port of the slot's band; use it and the next few for the stack. |
| `LOOPWORKER_PROJECT` | The project's forge path. |

Scripts get no stdin and no terminal. Anything that prompts fails or hangs, and a hang is killed
at the script's timeout, which marks the slot broken. Make every step non-interactive.

### `provision.sh`

Runs once per hot slot (and again after the slot breaks), or before every card on a cold slot.
Install dependencies, start services. The Manager has already pulled any Git LFS content (see
"Git LFS"). It must be idempotent: it runs again
on a slot that is half provisioned. Exit non-zero with a clear message when a prerequisite is
missing; the output tail lands in the log and the status file.

### `reset.sh`

Runs before every card on a hot slot, after the Manager has reset the worktree to the base
branch. Bring the stack back to a clean state (reset databases, clear caches that would leak
between cards). Keep it fast; it is on the critical path of every card.

### `verify.sh`

The worker runs it before it reports done, and fixes its change until it passes. It should be
what CI runs, minus anything that needs CI-only secrets: build, tests, lint. Exit non-zero on
any failure. Print enough for the worker to fix the failure from the output alone.

### `teardown.sh`

Runs when a cold slot finishes a card and when any slot is retired. Stop the stack and free its
ports. Failures are logged and ignored, so it must never be the only cleanup that matters.

### `BRIEF.md`

Appended to LoopWorker's built-in brief. Put here what a new colleague would need for an
unattended first card: the build and test commands, conventions the repo's own `AGENTS.md`
doesn't cover, and things the worker must never do. The worker also reads the repo's
`AGENTS.md`/`CLAUDE.md` itself, so don't repeat them.

## `manifest.toml`

All keys are optional; the defaults are shown. Keep the file 7-bit ASCII.

```toml
[scripts]
provision = "provision.sh"
reset     = "reset.sh"
verify    = "verify.sh"
teardown  = "teardown.sh"
provision_timeout_minutes = 45
reset_timeout_minutes     = 15
teardown_timeout_minutes  = 10

[worker]
# Card branch name. {number} is the card's number in its backlog, {slug} its title as
# lowercase words. Must contain {number}. Set this when the repo's commit hooks read the
# ticket from the branch.
branch = "loopworker-{number}-{slug}"
wallclock_cap_minutes = 90
# MCP config file (relative to this directory) that the worker gets with --strict-mcp-config.
# Unset means the worker has no MCP servers.
# mcp_config = "mcp.json"

[review]
# Ask the worker to write a storygrafter review guide, attached to the review request.
guide = false
# Move the card to review only once the pushed commit's CI passes (see below).
# The host config's finish = "merge" ignores it; "ci_then_merge" always waits.
wait_for_ci = false
# Mark the card stuck when CI hasn't finished this long after a push, or a merge stays pending this long.
ci_timeout_minutes = 120
# Worker rounds that fix a failed pipeline before the card is marked stuck.
ci_fix_attempts = 2

[lfs]
# Pull Git LFS content into the slot when the repo uses LFS. false leaves pointer files.
pull = true
# git-lfs path patterns to pull, and to skip. Empty include means everything.
include = []
exclude = []
pull_timeout_minutes = 60
```

Which environment variables reach a worker is host config (`worker_env` on the project in
`config.toml`), not contract, so a repo can't widen it.

## Waiting for CI

With `wait_for_ci = true`, `verify.sh` can be a light local gate and the review request's CI the
full verification. After opening the review request, the Manager moves the card to `verifying`,
frees the slot and polls the newest pipeline for the pushed commit every 2 minutes. A pass moves
the card to review. A failure starts a fix round: a worker on the same branch gets the failed
jobs' log tails in `ci.md` and pushes a fix, which the Manager watches again, up to
`ci_fix_attempts` times. A timeout, a cancel, no pipeline within 15 minutes, or a failure after
the last fix round marks the card stuck. CI must run for the card branch's commits, on branch
pushes or merge request pipelines; GitHub forges read the commit's check runs.

The project's `finish` in the host config can override `wait_for_ci`. `finish = "merge"` merges
the review request without reading CI, whatever `wait_for_ci` says. `finish = "ci_then_merge"`
waits for CI as described above whether `wait_for_ci` is set or not, and merges once the
pipeline passes. Both use `ci_timeout_minutes`, and `ci_then_merge` also uses `ci_fix_attempts`.
The contract can't set `finish`, so a repo can't opt itself into a merge.

## Git LFS

When any `.gitattributes` in the repo contains `filter=lfs`, the Manager handles LFS content
with the forge credentials:

- Before the slot's first script on each card (and before `provision.sh` on a hot slot), it
  pulls the LFS content of the checked-out commit into the worktree, limited by `[lfs] include`
  and `exclude`. A failed pull marks the slot broken, like a failed provision.
- Before it pushes the card branch, it uploads the LFS objects that the worker committed.

The Manager's own checkouts never download LFS content, and it configures the repo so that the
worker's checkouts don't either; files that the worker checks out stay pointer files until the
next pull. The worker's `git add` still stores tracked files in LFS.

Scripts must not run `git lfs pull` or `git lfs fetch` themselves: they have no forge
credentials. Set `pull = false` when the slot doesn't need the content, for example a repo
whose LFS files are only release assets.

The host needs `git-lfs` on `PATH`; `loopworker doctor` fails without it once a cloned project
uses LFS.

## Hot or cold

A hot slot keeps its stack and build caches between cards, so the second card starts in
seconds; it costs memory all the time. A cold slot provisions per card and tears down after.
Choose hot for projects with slow builds or heavy stacks that the host can afford to keep up,
and give heavy projects a higher `weight` in the host config so they count for more of the
budget.

## Native apps with pinned toolchains

When a repo pins its toolchain (a file naming the Xcode, Ruby or Node version), select it in
the scripts from that file at run time rather than hard-coding it, and select it per process
(`DEVELOPER_DIR`, version-manager shims) rather than system-wide, because other users of a
shared host may depend on the system default. Tests that need a specific simulator or device
should create or boot it in `provision.sh` and fail with a clear message if the runtime is
missing. Parallel slots that use simulators need one simulator each; keep such projects at one
slot until the scripts handle that.
