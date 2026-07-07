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

# Homebrew tools (xcodegen) aren't on a CI runner's minimal PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

IDENTITY="${LOOPWORKER_SIGN_IDENTITY:-Developer ID Application: Nevyn Bengtsson (M4Q2TE45WT)}"
PROFILE="${LOOPWORKER_NOTARY_PROFILE:-koja-notary}"

here="$(cd "$(dirname "$0")" && pwd)"
dd="$here/build/release-dd"
ent="$here/loopworker.entitlements"
app="$dd/Build/Products/Release/LoopWorker.app"
inner="$app/Contents/Resources/loopworker"

# Optional version injection — CI passes the git tag; locally we keep project.yml's defaults.
ver_args=""
[ -n "${LOOPWORKER_MARKETING_VERSION:-}" ] && ver_args="$ver_args MARKETING_VERSION=$LOOPWORKER_MARKETING_VERSION"
[ -n "${LOOPWORKER_BUILD_VERSION:-}" ] && ver_args="$ver_args CURRENT_PROJECT_VERSION=$LOOPWORKER_BUILD_VERSION"

echo "▸ Generating project + building Release (unsigned; the script signs deliberately)…"
( cd "$here" && xcodegen generate >/dev/null )
# shellcheck disable=SC2086  # ver_args is deliberately word-split into xcodebuild settings
xcodebuild -project "$here/LoopWorker.xcodeproj" -scheme LoopWorker -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$dd" \
    CODE_SIGNING_ALLOWED=NO $ver_args build >/dev/null
echo "  built: $app"

# Sign the embedded frozen Manager FIRST (its own entitlements), then the app seals over it.
echo "▸ Signing the embedded Manager…"
codesign --force --timestamp --options runtime --entitlements "$ent" \
    --sign "$IDENTITY" "$inner"

# Sparkle ships helper code inside its framework — XPC services, the Autoupdate tool, and Updater.app.
# codesign on the outer app does NOT reach into a nested framework, so each helper must be signed on
# its own (timestamp + hardened runtime), inside-out, or notarization rejects the framework. Guarded
# so a Sparkle-less build still signs clean.
fw="$app/Contents/Frameworks/Sparkle.framework"
if [ -d "$fw" ]; then
    echo "▸ Signing Sparkle's embedded helpers…"
    v="$fw/Versions/Current"
    for item in \
        "$v/XPCServices/Downloader.xpc" \
        "$v/XPCServices/Installer.xpc" \
        "$v/Autoupdate" \
        "$v/Updater.app"; do
        [ -e "$item" ] && codesign --force --timestamp --options runtime --sign "$IDENTITY" "$item"
    done
    codesign --force --timestamp --options runtime --sign "$IDENTITY" "$fw"
fi

echo "▸ Signing the app…"
codesign --force --timestamp --options runtime \
    --sign "$IDENTITY" "$app"

echo "▸ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$app"

zip="$dd/LoopWorker.zip"
if [ -n "${LOOPWORKER_SKIP_NOTARIZE:-}" ]; then
    echo "▸ LOOPWORKER_SKIP_NOTARIZE set — signed but NOT notarized/stapled (dry run)."
    rm -f "$zip"; /usr/bin/ditto -c -k --keepParent "$app" "$zip"
    echo "✅ Signed (not notarized): $zip"
    exit 0
fi

echo "▸ Notarizing (submits to Apple, waits — a few minutes)…"
rm -f "$zip"
/usr/bin/ditto -c -k --keepParent "$app" "$zip"
# Notary auth: an ASC API key (CI, keychain-independent) when provided, else the stored profile.
if [ -n "${LOOPWORKER_NOTARY_KEY:-}" ]; then
    xcrun notarytool submit "$zip" \
        --key "$LOOPWORKER_NOTARY_KEY" --key-id "$LOOPWORKER_NOTARY_KEY_ID" \
        --issuer "$LOOPWORKER_NOTARY_ISSUER" --wait
else
    xcrun notarytool submit "$zip" --keychain-profile "$PROFILE" --wait
fi

echo "▸ Stapling the ticket…"
xcrun stapler staple "$app"

echo "▸ Gatekeeper assessment…"
spctl --assess --type execute --verbose=4 "$app"

echo "✅ Signed + notarized + stapled: $app"
echo "   Ship $zip (re-zip after stapling for distribution):"
rm -f "$zip"; /usr/bin/ditto -c -k --keepParent "$app" "$zip"; echo "   $zip"
