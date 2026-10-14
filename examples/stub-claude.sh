#!/usr/bin/env bash
# A stand-in for `claude` that drives the whole Manager without a model. Install it as
# `claude` first on the Manager's PATH (see docs/dev_guide.md).
#
# - The auth preflight (`claude -p ...`) gets "ok".
# - A worker commits a timestamp to stub-claude.txt and reports done.
#   With STUB_OUTCOME=stuck (forward it with worker_env) it reports stuck instead.
set -euo pipefail

if [ "${1:-}" = "-p" ]; then
  echo ok
  exit 0
fi
if [ -z "${LOOPWORKER_OUTCOME:-}" ]; then
  echo "stub-claude: LOOPWORKER_OUTCOME is not set; only a LoopWorker worker runs this" >&2
  exit 2
fi

if [ "${STUB_OUTCOME:-done}" = "stuck" ]; then
  printf '{"outcome": "stuck", "blocker": "stub-claude was told to get stuck."}\n' > "$LOOPWORKER_OUTCOME"
  exit 0
fi

date -u +%Y-%m-%dT%H:%M:%SZ >> stub-claude.txt
git add stub-claude.txt
git -c user.name=stub-claude -c user.email=stub-claude@example.invalid commit -q -m "Append a timestamp to stub-claude.txt"
printf '{"outcome": "done", "title": "stub-claude change", "body": "Appends a timestamp to stub-claude.txt."}\n' > "$LOOPWORKER_OUTCOME"
