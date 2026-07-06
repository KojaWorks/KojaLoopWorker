# LoopWorker

An outer **Manager** that polls a shared backlog and spawns disposable **Workers** —
each implements exactly one card in its own tmux `claude` session, then exits. It moves
the build loop *out* of the Claude session (which was the fragile part) and into a small,
deterministic, non-AI orchestrator.

One Manager runs **per host** and serves every project in the shared backlog whose
`worker_manager` is this host's — cloning each repo on demand. A teammate runs their own
Manager on their own box (their compute, their `claude` login) against the same backlog,
scoped to their projects. Adding a project is: ship a `.loopworker/` contract in its repo,
add a row to the **projects** table.

See [DESIGN.md](DESIGN.md) for the full architecture and the decisions behind it.

## North star

LoopWorker is heading toward a **releasable, fully self-managing product**: a Manager you
start once that runs indefinitely and recovers from *most errors on its own* — a paused
Docker engine, a revoked credential, a hung provision, a wedged worker, an orphaned stack —
with no human restart or manual cleanup. Every failure mode should grow its own detection
and recovery in the same change that introduces it, and the dashboard/log should make the
rare thing a human *does* need to handle obvious. Self-healing and automation are the core
of the product, not polish — weigh that work accordingly.

## Status

Running in production (autonomously shipping Patch cards), built and unit-tested:

- `loopworker/host.py` — the per-host Manager: discover projects, clone on demand,
  hot/cold slot pools under a host-wide budget
- `loopworker/manager.py` — the per-project poll → reconcile → spawn → reap loop
- `loopworker/backlog/patch.py` — Patch backlog adapter over PostgREST (atomic claims,
  project-scoped to this host's `worker_manager`)
- `loopworker/slots.py` — (worktree, port, stack) pool: warm for hot projects, on-demand
  for cold, with reset-on-acquire
- `loopworker/tmux.py` — Worker session spawn / liveness / reap
- `loopworker/reconciler.py` — pure, tested decision logic
- `loopworker/dashboard.py` — local HTTP status page

## Quickstart

```bash
python3.13 -m venv .venv
./.venv/bin/pip install -e .
cp .env.example .env                       # set PATCH_PAT (mint in Patch → Settings → Tokens)
cp config.toml.example ~/.loopworker/config.toml   # set worker_manager, backlog, clones_dir, max_slots

./.venv/bin/loopworker                     # host mode: serve every project assigned to this host
```

## Run as a service (Linux)

For a headless fleet box, install with `pipx` and supervise with `systemd --user` instead
of a hand-run `tmux`:

```bash
git clone https://github.com/KojaWorks/KojaLoopWorker.git && cd KojaLoopWorker
bash packaging/install.sh          # pipx install + drop the systemd --user unit + enable it
```

Then, before the first start:

- `cp config.toml.example ~/.loopworker/config.toml` and edit it (worker_manager, backlog,
  clones_dir, max_slots).
- Put `PATCH_PAT=…` in `~/.loopworker/.env` (the service runs from there, so its `.env`
  loader picks it up). Mint the token in Patch → Settings → Tokens.
- `loopworker doctor` to confirm every host prerequisite (claude login, container engine,
  tmux, git, backlog) is green.

Day-to-day:

```bash
systemctl --user start loopworker         # start (Restart=on-failure keeps it up)
systemctl --user status loopworker        # or: loopworker status
journalctl --user -u loopworker -f        # follow the log
systemctl --user kill -s INT --kill-whom=main loopworker   # graceful drain (workers finish, none new spawn)
systemctl --user stop loopworker          # force-stop (releases in-flight cards to Backlog)
sudo loginctl enable-linger $USER         # keep it running after logout / across reboot
```

**Updating** is re-running `bash packaging/install.sh` (a `--force` pipx reinstall pulls the
latest commit), then `systemctl --user restart loopworker`. `pipx install loopworker` from
PyPI will replace the git URL once there's a second operator.

**Host mode (default).** `~/.loopworker/config.toml` is the source of truth: the backlog
connection, this host's `worker_manager` id, where to clone projects, and `max_slots` (the
host-wide RAM budget, in weighted slot-cost units). The Manager reads the **projects**
table for rows whose `worker_manager` is yours, clones each repo under `clones_dir`, and
runs them: `hot` projects keep a warm pool, `cold` projects provision a slot per card and
tear it down after, all within `max_slots`. Each project may set a `weight` (default 1) —
its relative RAM cost per slot, e.g. a warm Supabase stack (a dozen containers, several GB
resident) might be `weight = 2` next to a cold native build's `weight = 1` — so the budget
reflects that slots aren't equally expensive, not just how many are live. Each project may
also set a `model` (a CLI alias: `opus`/`fable`/`sonnet`/`haiku`) — the default a worker on
that project is spawned with; a card's own `Model` field (in the shared roadmap table)
overrides it for that one card. Neither set -> the `claude` CLI's own default, unchanged
from before this existed.

The **projects** table is live config, re-read every poll — no restart needed. Assign a new
project to your host and it's cloned + started on the next tick; unassign one and it drains +
tears down; change a project's `slots` and its pool resizes in place (a busy slot finishes its
card before it's retired). Only a `hot`⇄`cold` flip still needs a restart (it changes the whole
provisioning model); the Manager logs a note when it sees one.

**Single-project mode.** `loopworker --project ~/Dev/myproject` serves just that one working
copy (its `.loopworker/manifest.toml` is the source of truth) — handy for local testing.
Useful flags: `--slots N`, `--poll-interval S`, `--once` (single tick), `--no-dashboard`.

Pause spawning at any time by creating the killswitch file the Manager prints on start
(`state/<project>/PAUSED`); delete it to resume. Dashboard: http://127.0.0.1:8787.

**Stopping (⌃C escalates):** one `⌃C` *drains* — current workers finish, no new ones
start, then it exits. A second `⌃C` *force-stops* — kills the workers and releases their
cards back to Backlog. A third `⌃C` hard-exits immediately (dumps state; may leak). A
`SIGTERM` (e.g. from a supervisor) goes straight to force-stop.

## Making a project compatible

Add a `.loopworker/` directory to the project repo: a `manifest.toml` plus four lifecycle
scripts (`provision.sh`, `reset.sh`, `verify.sh`, `teardown.sh`). Templates are in
[`examples/`](examples/). The Manager owns git/worktree mechanics; these scripts own the
project's stack.

## Tests

```bash
./.venv/bin/pip install pytest
./.venv/bin/python -m pytest tests/ -q
```

## Host setup (needs you)

- **Credentials:** a `PATCH_PAT` in `.env` (mint in Patch → Settings → Tokens) — backlog
  access only, never the owner's LLM budget.
- **`claude` logged in** on the host (Workers spend this host's compute, not the owner's
  tokens), with the `patch` + `chrome-devtools` MCPs configured at user scope so each
  spawned Worker inherits them.
- **A projects-table row** per project this host serves, with `worker_manager` set to your
  host's id and a `repo` to clone.
