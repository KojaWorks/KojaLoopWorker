#!/usr/bin/env bash
# Freeze the loopworker Manager into a standalone binary for bundling in the app, so
# "update the app" == "update the Manager" (docs/distribution.md, the one-update-mechanism
# principle) AND the app works with no `loopworker` on the user's machine at all. The Manager
# is near-stdlib (httpx only), so this is a small, fast freeze.
#
# Idempotent: skips the (slow) PyInstaller run when the frozen binary is newer than every
# loopworker source file, so it's cheap to call on every Xcode build. Output:
#   macapp/build/manager/loopworker   (a --onefile binary; needs no Python at runtime)
set -euo pipefail

# Xcode Run Script phases run with a restricted PATH; make Homebrew pythons reachable.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
build="$here/build"
venv="$build/freeze-venv"
out="$build/manager"
bin="$out/loopworker"

# The Manager needs 3.11+ (tomllib). macOS's system /usr/bin/python3 is 3.9 — reject it.
find_python() {
    for c in python3.14 python3.13 python3.12 python3.11 python3; do
        p="$(command -v "$c" 2>/dev/null)" || continue
        if "$p" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
            echo "$p"; return 0
        fi
    done
    return 1
}

# Up-to-date check: no source newer than the binary -> nothing to do.
if [ -x "$bin" ] && [ -z "$(find "$repo/loopworker" "$here/loopworker_entry.py" -name '*.py' -newer "$bin" -print -quit 2>/dev/null)" ]; then
    echo "frozen Manager up to date: $bin"
    exit 0
fi

py="$(find_python)" || { echo "error: need python 3.11+ to freeze the Manager (found none)"; exit 1; }
echo "freezing loopworker Manager with $py -> $bin"

if [ ! -x "$venv/bin/python" ]; then
    "$py" -m venv "$venv"
fi
"$venv/bin/pip" install -q --upgrade pip
"$venv/bin/pip" install -q "$repo" pyinstaller

rm -rf "$build/pyi"
"$venv/bin/pyinstaller" --onefile --name loopworker --noconfirm \
    --distpath "$out" --workpath "$build/pyi/work" --specpath "$build/pyi" \
    --collect-all httpx --collect-all certifi --collect-all httpcore \
    "$here/loopworker_entry.py"

echo "frozen: $bin"
