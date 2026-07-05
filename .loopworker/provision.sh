#!/usr/bin/env bash
# FIRST time per slot: build the venv. No stack, no ports; LOOPWORKER_PORT is unused.
set -euo pipefail
cd "$LOOPWORKER_SLOT_DIR"

python3 -m venv .venv
.venv/bin/pip install -q -e ".[dev]"
