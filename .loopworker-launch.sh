#!/usr/bin/env bash
set -euo pipefail
cd "/Users/nevyn/Dev/loopworker-clones/kojaloopworker.loopworker-slots/slot-0"
PROMPT="$(cat .loopworker-prompt.txt)"
export LOOPWORKER=1
unset USER
exec claude --permission-mode auto --model opus "$PROMPT"
