#!/usr/bin/env bash
# THE MERGE GATE. The Worker runs this before opening its PR; nonzero exit = don't ship.
set -euo pipefail
cd "$LOOPWORKER_SLOT_DIR"

.venv/bin/python -m pytest tests/ -q
