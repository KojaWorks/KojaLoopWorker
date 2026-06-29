#!/usr/bin/env bash
# PER-ACQUIRE: cheap. Runs before every Worker spawn. The Manager has already hard-reset
# the git worktree to a fresh branch off origin/main; this script's job is to return the
# STACK to a clean state so a (possibly crashed) previous tenant can't leak data into the
# next card. This is the test-isolation guarantee — keep it fast and total.
set -euo pipefail
cd "$LOOPWORKER_SLOT_DIR"

# Reapply migrations onto a clean database. The stack stays up; only the data resets.
supabase db reset

# Cheap to re-run; fast when the lockfile is unchanged.
npm install
git checkout -- package-lock.json 2>/dev/null || true
