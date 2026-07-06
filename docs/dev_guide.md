# Dev guide

How to develop and test LoopWorker, and the gotchas that cost time on a live host.

## Setup + tests

```bash
python3 -m venv .venv
./.venv/bin/pip install -e ".[dev]"      # httpx (runtime) + pytest (tests)
./.venv/bin/python -m pytest tests/ -q
```

The whole suite runs in seconds and needs **no network, git, supabase, or real tmux** — it
mocks the I/O and tests the decisions. Two patterns to match when you add a test:

- **Pure decision logic lives in `reconciler.py`** and is tested directly (`test_reconciler.py`):
  feed it a slot + card + liveness and assert the `SlotAction`. Keep new reconcile decisions
  pure and put them here.
- **Manager/host behavior** is tested by monkeypatching the `tmux` module (spawn/kill/
  worker_running/capture) and using a `FakeBacklog` adapter — see `test_manager_integration.py`
  and `test_host.py`. No real process is ever spawned. `AuthGate` is inert in tests
  (`enabled=False`), so constructing a Manager never shells out to `claude`.

## Running it for real

**Single-project mode** is the way to exercise the loop locally without touching the host
config or the shared backlog wiring:

```bash
./.venv/bin/loopworker --project ~/Dev/myproject --once   # one tick, then exit
```

Useful flags: `--slots N`, `--poll-interval S`, `--once`, `--no-dashboard`. The dashboard
(host + single-project modes) serves JSON + HTML at http://127.0.0.1:8787 — `/json` is the
machine-readable snapshot.

**Host mode** (`./.venv/bin/loopworker`, no `--project`) reads `~/.loopworker/config.toml`
and serves every project assigned to this host. Don't start a second Manager against a
backlog a real one already serves — the lockfile guards one per host, and workers spend the
host's real `claude` login.

## Gotchas that cost time on the live host (miquon)

- **Worktree foot-gun.** This repo self-hosts, so you may be editing it inside
  `.claude/worktrees/<name>`. A bare `cd`/`git` or a plain file path silently targets the
  PRIMARY checkout. Use `git -C <worktree>` and worktree-absolute paths.
- **Boot the Manager so it inherits the host env.** `tmux new-session … send-keys
  './.venv/bin/loopworker'` does NOT reliably source the host's shell profile, so the Manager
  can come up without `CLAUDE_CODE_OAUTH_TOKEN` (workers then fall back to the shared keychain
  credential — the race-prone path). Launch through a login-interactive shell instead
  (`tmux new-session -d -s loopworker -c <repo> "fish -lic './.venv/bin/loopworker'"`), and
  verify from the Manager's OWN startup log line (`worker auth: … set — forwarding`), not
  `ps` (macOS truncates long envs → false negatives). Env is frozen at process start, so a
  config/`.env` change needs a fresh boot.
- **Worker auth.** Headless workers should use a long-lived `claude setup-token`
  (`CLAUDE_CODE_OAUTH_TOKEN`, forwarded by default), not the subscription keychain credential
  — concurrent claudes racing the keychain's single-use refresh token trips server-side
  session revocation that logs the account out everywhere. `max_concurrent_workers` +
  staggered starts bound the concurrency; keeping the host's `claude` keychain logged *out*
  (so only the setup-token is used) removes the race entirely.
- **Docker / OrbStack.** Supabase-backed projects (e.g. Patch) need the Docker engine up.
  OrbStack is the engine here (not Docker Desktop); it can be stopped by host **memory
  pressure** (miquon is a 16GB Mac mini — the fleet can OOM it). A down engine fails every
  Supabase provision → the affected hot slots go BROKEN. Recover with `orb start` (it may
  print a spurious "timed out" while actually Running), then let the Manager re-provision.
  Keep the fleet's footprint in check: the OrbStack VM cap (`memory_mib`),
  `max_concurrent_workers`, and per-project hot-slot counts are the levers.
- **Lifecycle scripts are foreign code.** They run under a hard per-script timeout in their
  own process group; a hang is killed as a group, not left to freeze the loop. Don't remove
  that guard.
