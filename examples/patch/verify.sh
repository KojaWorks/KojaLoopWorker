#!/usr/bin/env bash
# THE MERGE GATE. The Worker runs this before opening its PR; a nonzero exit means "do
# not ship". Keep it to the fast, deterministic checks — deeper observable verification
# (browser via Chrome DevTools MCP, iOS simulator) is driven by the Worker per the brief.
set -euo pipefail
cd "$LOOPWORKER_SLOT_DIR"

npm run typecheck
npm test
