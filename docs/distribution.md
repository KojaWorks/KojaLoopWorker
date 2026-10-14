# Distribution

Superseded by [DESIGN.md](../DESIGN.md) "Distribution". In short:

- LoopWorker ships as one universal `loopworker` binary from the `nevyn/tap` Homebrew formula
  (`brew install nevyn/tap/loopworker`). A `v*` tag runs `.github/workflows/release.yml`, which
  publishes the GitHub release and updates the tap; [packaging/homebrew/README.md](../packaging/homebrew/README.md)
  covers the formula and its `TAP_TOKEN`.
- `loopworker service install` runs the Manager under launchd, as a LaunchAgent or, with
  `--daemon`, a LaunchDaemon. `loopworker doctor` checks a host's readiness.
- Any app is a client of `state/status.json`, never a second implementation of the Manager.
