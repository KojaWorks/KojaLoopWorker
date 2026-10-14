# LoopWorker project brief

This is the Manager's own codebase: you are a worker improving the tool that spawned you.

## Verify

- `swift build && swift test` is `verify.sh`. The suite fakes tmux, git, processes and HTTP
  behind protocols and runs in seconds; run it often.
- There is no dev server or stack; verification means tests. Manager behavior is tested with
  `ManagerHarness` and the fakes in `Tests/LoopWorkerCoreTests/Fakes/`.
- Never start a real Manager here: this host already runs the live one, with a real backlog
  and a real claude login. `docs/dev_guide.md` describes a throwaway setup.

## Gotchas

- A change reaches a host only when its `loopworker` binary is updated and the Manager
  restarted. If your change needs that to matter, say so in the review request.
- Config files (`*.toml`, `*.yml`, `*.sh`, examples) are 7-bit ASCII: no em-dashes or smart
  quotes.
- CI runs on GitHub's `macos-15` image (Swift 6.1): don't use language or library features
  newer than that.
