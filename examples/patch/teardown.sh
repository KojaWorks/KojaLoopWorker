#!/usr/bin/env bash
# Slot RETIREMENT: stop the stack and free its ports. Called only when the pool is torn
# down (e.g. Manager shutdown with --teardown), not between cards.
set -euo pipefail
cd "$LOOPWORKER_SLOT_DIR"

supabase stop || true
