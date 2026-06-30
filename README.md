# LoopWorker

An outer **Manager** that polls a project's backlog and spawns disposable **Workers** —
each implements exactly one card in its own tmux `claude` session, then exits. It moves
the build loop *out* of the Claude session (which was the fragile part) and into a small,
deterministic, non-AI orchestrator.

See [DESIGN.md](DESIGN.md) for the full architecture and the decisions behind it.

## Status

v1 skeleton, built and unit-tested:

- `loopworker/manager.py` — the long-lived poll → reconcile → spawn → reap loop
- `loopworker/backlog/patch.py` — Patch backlog adapter over PostgREST (atomic claims)
- `loopworker/slots.py` — warm (worktree, port, stack) pool with reset-on-acquire
- `loopworker/tmux.py` — Worker session spawn / liveness / reap
- `loopworker/reconciler.py` — pure, tested decision logic
- `loopworker/dashboard.py` — local HTTP status page

Not yet wired for a live run — see "What's left" below.

## Quickstart

```bash
python3.13 -m venv .venv
./.venv/bin/pip install -e .
cp .env.example .env            # set PATCH_PAT (mint in Patch → Settings → Tokens)

# the target project must ship a .loopworker/ contract (see examples/)
./.venv/bin/loopworker --project ~/Dev/myproject
```

The working copy's `.loopworker/manifest.toml` is the source of truth; CLI flags override
it. Useful flags: `--slots N`, `--poll-interval S`, `--once` (single tick), `--no-dashboard`.

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

## What's left (needs you)

- **Credentials / host:** a `PATCH_PAT` (mint in Patch → Settings → Tokens), `claude` logged
  in on the host, and the `patch` + `chrome-devtools` MCPs configured at user scope so each
  spawned Worker inherits them.
