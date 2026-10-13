#!/usr/bin/env bash
# Fetches the package dependencies so a network problem fails here, not in verify.
set -euo pipefail
cd "$LOOPWORKER_SLOT_DIR"
swift package resolve
