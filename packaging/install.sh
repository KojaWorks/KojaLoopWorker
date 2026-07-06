#!/usr/bin/env bash
# Install (or upgrade) LoopWorker as a systemd --user service on Linux.
#
#   bash packaging/install.sh
#
# Re-run any time to pull the latest code and refresh the unit -- that IS the update
# story. Override the source with LOOPWORKER_REPO=<pip spec> (e.g. a fork or a tag).
set -euo pipefail

REPO="${LOOPWORKER_REPO:-git+https://github.com/KojaWorks/KojaLoopWorker.git}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pipx >/dev/null 2>&1; then
  echo "error: pipx not found." >&2
  echo "  install it:  python3 -m pip install --user pipx && python3 -m pipx ensurepath" >&2
  echo "  then open a new shell and re-run this script." >&2
  exit 1
fi

# --force reinstalls from scratch, so a re-run always pulls the latest commit even though
# the version string is static (a plain `pipx upgrade` would see 0.1.0 and no-op).
echo "==> installing/upgrading loopworker from $REPO"
pipx install --force "$REPO"

mkdir -p "$HOME/.loopworker"

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNIT_DIR"
install -m 644 "$HERE/loopworker.service" "$UNIT_DIR/loopworker.service"
echo "==> installed unit -> $UNIT_DIR/loopworker.service"

systemctl --user daemon-reload
systemctl --user enable loopworker.service >/dev/null

cat <<EOF

LoopWorker installed. Before the first start, make sure:
  1. ~/.loopworker/config.toml exists    (cp config.toml.example there, then edit)
  2. ~/.loopworker/.env has PATCH_PAT=... (backlog token; mint in Patch > Settings > Tokens)
  3. claude is logged in on this host     (run 'loopworker doctor' to check all prerequisites)

Start:   systemctl --user start loopworker
Status:  systemctl --user status loopworker      (or:  loopworker status)
Logs:    journalctl --user -u loopworker -f
Drain:   systemctl --user kill -s INT loopworker  (graceful; current workers finish first)
Stop:    systemctl --user stop loopworker         (force; releases in-flight cards to Backlog)
Boot:    sudo loginctl enable-linger $USER        (keep running after logout / across reboot)
EOF
