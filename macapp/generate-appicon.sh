#!/usr/bin/env bash
# Regenerate the AppIcon PNG ladder from AppIcon.svg (the re-editable master).
# Uses macOS's built-in qlmanage as the SVG rasterizer -- no external deps/CDNs.
# Run after editing AppIcon.svg:  ./generate-appicon.sh
set -euo pipefail
cd "$(dirname "$0")"

SVG="AppIcon.svg"
OUT="Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for px in 16 32 64 128 256 512 1024; do
  qlmanage -t -s "$px" -o "$TMP" "$SVG" >/dev/null 2>&1
  # qlmanage always names the thumbnail "<svg>.png"; qlmanage caps at the
  # source's rendered box, so confirm we actually got the size we asked for.
  got=$(sips -g pixelWidth "$TMP/$SVG.png" | awk '/pixelWidth/{print $2}')
  [ "$got" = "$px" ] || { echo "qlmanage produced ${got}px, expected ${px}px" >&2; exit 1; }
  mv "$TMP/$SVG.png" "$OUT/icon_$px.png"
done

echo "Wrote icon_{16,32,64,128,256,512,1024}.png to $OUT"
