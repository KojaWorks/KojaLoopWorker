#!/usr/bin/env bash
# PER-ACQUIRE: cheap. The Manager already hard-reset the git worktree; just make the
# venv match the fresh checkout (.venv is gitignored, so it survives git clean -fd).
set -euo pipefail
cd "$LOOPWORKER_SLOT_DIR"

[ -x .venv/bin/pip ] || python3 -m venv .venv
.venv/bin/pip install -q -e ".[dev]"
