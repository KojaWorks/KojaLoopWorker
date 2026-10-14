# Dev guide

How to build and test LoopWorker, how to run a real Manager without touching a live one, and
the gotchas that cost time on a live host.

## Build and test

```bash
swift build
swift test
.build/debug/loopworker --help
```

The suite needs no network, no tmux, no claude and no forge. CI runs the same two commands on
GitHub's `macos-15` image (Swift 6.1), so don't use anything newer.

## How the tests fake the world

Every piece of I/O sits behind a protocol, and the tests swap in an in-memory fake:

| Protocol | Fake | Where |
| --- | --- | --- |
| `ProcessRunning` | `ScriptedRunner` records each `ProcessSpec` and answers from a closure, so no test runs a real `claude`. | `Tests/LoopWorkerCoreTests/Fakes/` |
| `TmuxDriving` | `FakeTmux`: sessions in memory; a test sets pane text and liveness to play a worker. | same |
| `GitDriving` | `FakeGit` records calls; `cloneOrFetch` creates the clone dir so a test's contract is found. | same |
| `SlotLifecycle`, `EngineRecovering` | `FakeLifecycle`, `FakeEngine`: record calls, inject failures per verb. | same |
| `Backlog`, `Forge` | `FakeBacklog`, `FakeForge`: cards and review requests in memory. | same |
| GitLab HTTP | `FakeGitLab` stubs REST and GraphQL by method and path; `World` sets up one trusted card. | `Tests/GitLabBackendTests/` |
| Patch HTTP | `FakePatch`: the PAT exchange and a PostgREST subset. | `Tests/PatchBackendTests/` |

`ManagerHarness` wires a real `Manager` to all of these in a fresh `LOOPWORKER_HOME`, with a
`TestClock` that moves only when the test advances it. A Manager test claims a card, writes the
worker's outcome file itself, ticks, and asserts what the Manager did to the fakes. `Reconciler`
is pure, so its decisions are tested without a harness.

## Running a real Manager end to end

Never start a Manager against a live host's `LOOPWORKER_HOME`: one Manager per home holds the
lock, and the live one serves a real backlog. This recipe runs the whole loop (claim, slot,
tmux worker, outcome, push, merge request, labels) against a sandbox, with a stub instead of a
model:

1. Make a throwaway home with a short path. The Manager's tmux socket is
   `$LOOPWORKER_HOME/state/tmux`, and a Unix socket path must fit in 104 bytes, so stay in
   `/tmp`:

   ```bash
   export LOOPWORKER_HOME=$(mktemp -d /tmp/lw.XXXX)
   ```

2. Create a private sandbox project on the forge with a `.loopworker/` contract: copy
   `examples/loopworker-manifest.toml` to `.loopworker/manifest.toml` and add four scripts
   that `exit 0`.

3. Write `$LOOPWORKER_HOME/config.toml` with only that project (see the README's
   "Configuration"; `allowed` should name only the sandbox's group), and put the sandbox token
   in `secrets.env`:

   ```bash
   printf 'LOOPWORKER_GITLAB_TOKEN=...\n' > $LOOPWORKER_HOME/secrets.env
   chmod 600 $LOOPWORKER_HOME/secrets.env
   ```

4. Put the stub first on `PATH` as `claude`. It answers the auth preflight, and as a worker it
   commits a change and writes `$LOOPWORKER_OUTCOME`:

   ```bash
   mkdir $LOOPWORKER_HOME/bin
   cp examples/stub-claude.sh $LOOPWORKER_HOME/bin/claude
   export PATH=$LOOPWORKER_HOME/bin:$PATH
   ```

   To exercise the stuck path, add `worker_env = ["STUB_OUTCOME"]` to the project and run
   with `STUB_OUTCOME=stuck`.

5. Check and run:

   ```bash
   .build/debug/loopworker doctor
   .build/debug/loopworker
   ```

6. On a sandbox issue, assign yourself and add `loopworker::next`. Within a tick or two the
   Manager claims it; `loopworker status` (with the same `LOOPWORKER_HOME`) shows the slot, and
   `$LOOPWORKER_HOME/state/manager.log` the steps. The issue ends at `loopworker::review` with a
   merge request linked in a note. Ctrl-C drains and exits.

## Gotchas on a live host

- **Worktree foot-gun.** This repo self-hosts, so you may be editing it inside
  `.claude/worktrees/<name>`. A plain `git` or file path silently targets the primary checkout.
  Use `git -C <worktree>` and worktree-absolute paths.
- **Worker auth.** Give workers a long-lived `claude setup-token` as `CLAUDE_CODE_OAUTH_TOKEN`
  in `secrets.env`. Concurrent workers on the interactive keychain login race its single-use
  refresh token, which can revoke the session everywhere. `max_concurrent_workers` bounds the
  concurrency.
- **`claude -p` exits 0 when it isn't logged in.** It prints "Not logged in" instead; the auth
  gate and doctor both match that text rather than trust the exit status.
- **Container engine.** Projects whose scripts start containers need the engine up. OrbStack
  can be stopped by memory pressure; a down engine fails every provision and the hot slots go
  broken. With `[engine] recover = true` the Manager runs `start_command` and re-provisions.
  The levers on memory are the engine VM's cap, `max_concurrent_workers` and hot slot counts.
- **Lifecycle scripts are foreign code.** They run in their own process group under a hard
  timeout, and a hang is killed as a group. Don't remove that guard.
