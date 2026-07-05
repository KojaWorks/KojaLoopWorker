# LoopWorker project brief

Project-specific addendum to the generic Managed Agent Loop protocol. This is the
Manager's own codebase — you are a worker improving the tool that spawned you.

## Verify (the merge gate)

- `.venv/bin/python -m pytest tests/ -q` — this is `verify.sh`. The whole suite mocks
  tmux/git/network and runs in seconds; run it often.
- There is no dev server or stack; "observable" verification means tests. Manager
  behaviors (spawn/reap/reconcile) are tested by monkeypatching the `tmux` module —
  see `tests/test_manager_integration.py` for the pattern.
- Do NOT start a real Manager to test: this host already runs the live one (shared
  lockfile, real backlog). Never write test data to the prod backlog.

## Merge convention

- `gh pr merge <n> --merge` — **never squash**.
- CI (GitHub Actions) runs pytest on Python 3.11 and 3.14; wait for green before merge.

## Gotchas

- Your changes only take effect when the host's running Manager restarts — it serves
  the live backlog from its own checkout. If a change needs a restart to matter, say
  so in the PR body.
- Config files in this repo (`*.toml`, `*.yml`, `*.sh`, examples) are 7-bit ASCII
  only — no em-dashes or smart quotes.
- Lifecycle scripts run under hard timeouts (`[scripts] *_timeout_minutes` in a
  project's manifest); keep provision/reset fast and never let them wait on input.
