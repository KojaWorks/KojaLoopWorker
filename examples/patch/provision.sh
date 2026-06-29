#!/usr/bin/env bash
# FIRST-time-per-slot setup: heavy, idempotent. Brings the stack up once; the slot is
# then reused across many cards. Runs with LOOPWORKER_SLOT_DIR / LOOPWORKER_PORT in env,
# cwd = the slot worktree. Print `LOOPWORKER_PORT=<n>` on stdout to tell the Manager the
# port the stack actually bound (e.g. when the project derives the port itself).
set -euo pipefail
cd "$LOOPWORKER_SLOT_DIR"

# Install deps (the worktree is a fresh checkout). On macOS this strips libc hints from
# package-lock.json — restore it so it isn't committed by accident.
npm install
git checkout -- package-lock.json 2>/dev/null || true

# Bring up the project's isolated Supabase stack. KojaPatch derives per-worktree ports
# from the worktree path via scripts/worktree.mjs; a simpler project can honor
# LOOPWORKER_PORT directly in supabase/config.toml. We start without the edge runtime
# (matches the loop brief: `supabase start -x edge-runtime`).
supabase start -x edge-runtime

# Report the API port the Manager should associate with this slot.
API_PORT="$(supabase status -o env 2>/dev/null | sed -n 's/^API_URL=.*:\([0-9]*\).*/\1/p')"
[ -n "${API_PORT:-}" ] && echo "LOOPWORKER_PORT=${API_PORT}"
