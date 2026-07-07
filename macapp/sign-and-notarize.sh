#!/usr/bin/env bash
# One-command release: build → sign (Developer ID, hardened runtime) → notarize → staple → verify.
# Non-sandboxed Developer ID app (it spawns tmux/claude/git/docker), distributed outside the App
# Store; auto-update is Sparkle-on-GitHub-Releases (a later card), not TestFlight (which needs the
# App Sandbox this app can't adopt).
#
# One-time setup (already done on the build host): a "Developer ID Application" cert in the login
# keychain, and a notarytool keychain profile:
#   xcrun notarytool store-credentials koja-notary --key <p8> --key-id <id> --issuer <uuid>
set -euo pipefail

IDENTITY="${LOOPWORKER_SIGN_IDENTITY:-Developer ID Application: Nevyn Bengtsson (M4Q2TE45WT)}"
PROFILE="${LOOPWORKER_NOTARY_PROFILE:-koja-notary}"

here="$(cd "$(dirname "$0")" && pwd)"
dd="$here/build/release-dd"
ent="$here/loopworker.entitlements"
app="$dd/Build/Products/Release/LoopWorker.app"
inner="$app/Contents/Resources/loopworker"

echo "▸ Generating project + building Release (unsigned; the script signs deliberately)…"
( cd "$here" && xcodegen generate >/dev/null )
xcodebuild -project "$here/LoopWorker.xcodeproj" -scheme LoopWorker -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$dd" \
    CODE_SIGNING_ALLOWED=NO build >/dev/null
echo "  built: $app"

# Sign the embedded frozen Manager FIRST (its own entitlements), then the app seals over it.
echo "▸ Signing the embedded Manager…"
codesign --force --timestamp --options runtime --entitlements "$ent" \
    --sign "$IDENTITY" "$inner"
echo "▸ Signing the app…"
codesign --force --timestamp --options runtime \
    --sign "$IDENTITY" "$app"

echo "▸ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$app"

echo "▸ Notarizing (submits to Apple, waits — a few minutes)…"
zip="$dd/LoopWorker.zip"
rm -f "$zip"
/usr/bin/ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$PROFILE" --wait

echo "▸ Stapling the ticket…"
xcrun stapler staple "$app"

echo "▸ Gatekeeper assessment…"
spctl --assess --type execute --verbose=4 "$app"

echo "✅ Signed + notarized + stapled: $app"
echo "   Ship $zip (re-zip after stapling for distribution):"
rm -f "$zip"; /usr/bin/ditto -c -k --keepParent "$app" "$zip"; echo "   $zip"
