"""LoopWorker — a deterministic Manager that spawns disposable one-card Workers.

See DESIGN.md for the architecture. The package is laid out as:

  config.py        manifest.toml -> Manifest
  models.py        Card / Worker / Slot value types + the canonical card statuses
  backlog/base.py  BacklogAdapter interface (list_workable / claim / release / ...)
  backlog/patch.py Patch adapter over PostgREST
  slots.py         SlotPool: warm worktree+stack pool, reset-on-acquire
  tmux.py          spawn / reap / liveness for Worker sessions
  reconciler.py    one tick: reconcile live sessions against card state
  manager.py       the long-lived loop wiring it together
  dashboard.py     local HTTP status page
"""

__version__ = "0.1.0"
