#!/usr/bin/env bash
# The gate: the worker reports done only when this passes.
set -euo pipefail
cd "$LOOPWORKER_SLOT_DIR"
swift build
swift test
