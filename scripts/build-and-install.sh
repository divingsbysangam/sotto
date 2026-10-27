#!/bin/bash
# Sotto Build & Install Script
# Automates: xcodegen → kill app → build → sign (stable identity) → install → launch
#
# Uses a STABLE self-signed code-signing identity so macOS remembers the
# permissions you grant (Microphone, Accessibility, Screen Recording) across
# rebuilds. Run scripts/create-signing-cert.sh once first.
#
# Always regenerates Sotto.xcodeproj from project.yml so the Xcode project
# matches the on-disk sources (avoids "Build input files cannot be found"
# after files are added/removed).

set -euo pipefail

echo "🔨 Sotto Build & Install Script"
echo "================================"

# Paths (repo-relative, so this works on any machine)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Sotto"
APP_DEST="/Applications/Sotto.app"

# Signing identity (stable self-signed). Override with SIGN_IDENTITY=... if desired.
SIGN_IDENTITY="${SIGN_IDENTITY:-Sotto Self-Signed}"

cd "$PROJECT_DIR"

# Local override (git-ignored): put SOTTO_BUNDLE_ID=com.example.old in .sotto-local.env to keep the
# bundle ID of an app you already installed. macOS ties the Microphone / Accessibility / Screen
# Recording grants and the app's settings to the bundle ID, so changing it means starting over.
# Unset, the project's own bundle ID is used.
if [ -f "$PROJECT_DIR/.sotto-local.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$PROJECT_DIR/.sotto-local.env"
    set +a
fi

# Optional per-workspace cache, also used by verification commands. Ask both build and
# showBuildSettings for the same directory so installation cannot pick a stale product.
BUILD_OPTIONS=(-project Sotto.xcodeproj -scheme Sotto -configuration Release)
if [ -n "${SOTTO_DERIVED_DATA_PATH:-}" ]; then
    BUILD_OPTIONS+=(-derivedDataPath "$SOTTO_DERIVED_DATA_PATH")
fi

# Step 0: Regenerate Xcode project from project.yml
echo ""
echo "📍 Step 0: Regenerating Xcode project (xcodegen)..."
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "❌ xcodegen not found."
    echo "   Install it first:"
    echo "     brew install xcodegen"
    echo "   Then re-run: ./scripts/build-and-install.sh"
    exit 1
fi
xcodegen generate
echo "✅ Xcode project generated from project.yml"

# Guard: xcodegen rewrites Sotto/Info.plist from project.yml info.properties.
# Fail fast if privacy keys were dropped (TCC kills the app without them).
INFO_PLIST="$PROJECT_DIR/Sotto/Info.plist"
require_plist_key() {
    local key="$1"
    if ! /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" >/dev/null 2>&1; then
        echo "❌ $INFO_PLIST is missing required key: $key"
        echo "   Add it under targets.Sotto.info.properties in project.yml, then re-run."
        exit 1
    fi
}
require_plist_key "NSMicrophoneUsageDescription"
require_plist_key "NSScreenCaptureUsageDescription"
require_plist_key "NSAppleEventsUsageDescription"
require_plist_key "SUFeedURL"
require_plist_key "SUPublicEDKey"
require_plist_key "NSServices:0:NSMessage"
require_plist_key "CFBundleURLTypes:0:CFBundleURLSchemes:0"
require_plist_key "CFBundleDocumentTypes:0:LSItemContentTypes"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$PROJECT_DIR/Sotto/Sotto.entitlements" 2>/dev/null)" != "true" ]; then
    echo "❌ Audio Input entitlement is missing. Add com.apple.security.device.audio-input under targets.Sotto.entitlements.properties in project.yml."
    exit 1
fi
echo "✅ Info.plist privacy + Sparkle keys present after xcodegen"

# Step 1: Kill running app
echo ""
echo "📍 Step 1: Stopping running Sotto..."
# Find Sotto PIDs precisely and terminate them (avoids pkill -f name matching).
for PID in $(pgrep -x "$APP_NAME" 2>/dev/null || true); do
    kill "$PID" 2>/dev/null || true
done
sleep 1

# Step 2: Resolve the signing identity
# Ad-hoc signing (codesign -s "-") changes the designated requirement every build, so
# macOS forgets Microphone / Accessibility / Screen Recording grants. Fail loudly unless
# the caller explicitly opts into that with ALLOW_ADHOC_SIGN=1.
echo "📍 Step 2: Resolving signing identity..."
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "   Using stable identity: '$SIGN_IDENTITY'"
    CODESIGN_ID="$SIGN_IDENTITY"
elif [ "${ALLOW_ADHOC_SIGN:-}" = "1" ]; then
    echo "   ⚠️  Stable identity '$SIGN_IDENTITY' not found."
    echo "   ⚠️  ALLOW_ADHOC_SIGN=1 — using ad-hoc signing (TCC grants will NOT persist across rebuilds)."
    CODESIGN_ID="-"
else
    echo "❌ Stable identity '$SIGN_IDENTITY' not found — refusing to install with ad-hoc signing."
    echo "   Ad-hoc builds cause macOS to re-ask for Screen Recording / Mic / Accessibility"
    echo "   after every rebuild because the designated requirement changes."
    echo ""
    echo "   Fix (one time):"
    echo "     ./scripts/create-signing-cert.sh"
    echo "     ./scripts/build-and-install.sh"
    echo ""
    echo "   Or force ad-hoc (not recommended): ALLOW_ADHOC_SIGN=1 ./scripts/build-and-install.sh"
    exit 1
fi

# Step 3: Build
# L5: mlx-swift compiles Metal kernels, which needs Xcode's Metal Toolchain component.
if ! xcrun -f metal >/dev/null 2>&1 || ! xcrun metal --version >/dev/null 2>&1; then
    echo "❌ Xcode's Metal Toolchain is missing (needed to build MLX for the local cleanup model)."
    echo "   Install it once: xcodebuild -downloadComponent MetalToolchain"
    exit 1
fi
echo "📍 Step 3: Building Release..."
# Capture full log; surface errors/warnings and fail if xcodebuild fails.
BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT
set +e
# Package plugins/macros (mlx-swift, swift-transformers) are trusted without Xcode's prompt.
xcodebuild "${BUILD_OPTIONS[@]}" \
    -skipPackagePluginValidation -skipMacroValidation build >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e
grep -E "(error:|warning:.*Sotto|BUILD SUCCEEDED|BUILD FAILED)" "$BUILD_LOG" | head -40 || true
if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "❌ xcodebuild failed (exit $BUILD_STATUS). Last 40 log lines:"
    tail -40 "$BUILD_LOG"
    exit "$BUILD_STATUS"
fi

# Find the built app. Ask xcodebuild for this project's products dir: several Sotto-*
# DerivedData folders can exist, and picking one with `find | head -1` may install a stale build.
BUILT_PRODUCTS_DIR=$(xcodebuild "${BUILD_OPTIONS[@]}" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = / && !found { print $2; found = 1 }' || true)
APP_PATH="$BUILT_PRODUCTS_DIR/Sotto.app"
if [ -z "$BUILT_PRODUCTS_DIR" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ Could not resolve this project's built app. Refusing to install a possibly stale build."
    exit 1
fi
echo "   Installing from: $APP_PATH"

if [ -z "$APP_PATH" ]; then
    echo "❌ Build failed - app not found"
    exit 1
fi

echo "✅ Build succeeded: $APP_PATH"

# Hosted XCTest runs embed their bundle in this same build product. Never install it.
if [ -d "$APP_PATH/Contents/PlugIns/SottoTests.xctest" ]; then
    rm -rf "$APP_PATH/Contents/PlugIns/SottoTests.xctest"
fi

# Step 3b: Apply the local bundle ID override, if any. Done before signing, which seals Info.plist.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
if [ -n "${SOTTO_BUNDLE_ID:-}" ] && [ "$SOTTO_BUNDLE_ID" != "$BUNDLE_ID" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SOTTO_BUNDLE_ID" "$APP_PATH/Contents/Info.plist"
    echo "ℹ️  Local override: bundle ID $BUNDLE_ID → $SOTTO_BUNDLE_ID (from .sotto-local.env)"
    BUNDLE_ID="$SOTTO_BUNDLE_ID"
fi

# Step 4: Sign with the stable identity (frameworks first, then the app)
echo "📍 Step 4: Signing with '$CODESIGN_ID'..."
if [ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]; then
    codesign --force --sign "$CODESIGN_ID" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
fi
# L14: the bundled `sotto` command-line tool (also the L6 agent hook).
CLI_PATH="$APP_PATH/Contents/Helpers/sotto"
if [ ! -x "$CLI_PATH" ]; then
    echo "❌ $CLI_PATH is missing (the sotto-cli target should embed it)."
    exit 1
fi
codesign --force --options runtime --sign "$CODESIGN_ID" "$CLI_PATH"
codesign --force --deep --options runtime \
    --entitlements "$PROJECT_DIR/Sotto/Sotto.entitlements" --sign "$CODESIGN_ID" "$APP_PATH"
echo "✅ Code signing complete"
echo "   Designated requirement:"
codesign -d -r- "$APP_PATH" 2>&1 | sed 's/^/     /' || true

# Step 5: Install to Applications
echo "📍 Step 5: Installing to /Applications..."
rm -rf "$APP_DEST"
cp -R "$APP_PATH" "$APP_DEST"
xattr -cr "$APP_DEST"
echo "✅ Installed to $APP_DEST"

# Step 5b: Verify the installed signature (stable identity → persistent TCC)
# codesign -dv exits non-zero for self-signed certs; with pipefail that would
# falsely fail a `codesign | grep` pipeline even when Authority= is present.
echo "📍 Step 5b: Verifying signature on $APP_DEST ..."
CS_OUT=$(codesign -dv --verbose=4 "$APP_DEST" 2>&1 || true)
echo "$CS_OUT" | grep -E 'Authority|Signature|Identifier' | sed 's/^/   /' || true
if ! echo "$CS_OUT" | grep -qxF "Identifier=$BUNDLE_ID"; then
    echo "❌ Installed app's identifier is not $BUNDLE_ID. Aborting launch."
    exit 1
fi
if ! echo "$CS_OUT" | grep -q 'flags=.*runtime'; then
    echo "❌ Installed app is missing hardened runtime. Aborting launch."
    exit 1
fi
if [ "$CODESIGN_ID" != "-" ]; then
    if ! echo "$CS_OUT" | grep -qF "Authority=$SIGN_IDENTITY"; then
        echo "❌ Installed app is not signed with '$SIGN_IDENTITY'."
        echo "   Expected Authority=$SIGN_IDENTITY (TeamIdentifier is optional)."
        echo "   TCC grants for Screen Recording will not persist. Aborting launch."
        exit 1
    fi
    if echo "$CS_OUT" | grep -qi 'Signature=adhoc'; then
        echo "❌ Installed app is still ad-hoc signed despite stable identity."
        exit 1
    fi
    echo "✅ Stable identity confirmed on installed app"
else
    echo "   (ad-hoc install — expect TCC re-prompts after the next rebuild)"
fi

# Step 6: Launch app
echo "📍 Step 6: Launching Sotto..."
open "$APP_DEST"

echo ""
echo "================================"
echo "✅ BUILD COMPLETE!"
echo "================================"
echo ""
echo "Verify signing anytime:"
echo "  codesign -dv --verbose=4 /Applications/Sotto.app 2>&1 | grep -E 'Authority|Signature|Identifier'"
echo ""
echo "First run only: grant permissions when prompted (or in System Settings →"
echo "Privacy & Security):"
echo "   1. Microphone"
echo "   2. Accessibility   (for auto-paste)"
echo "   3. Screen Recording (only if you enable Screen Context / OCR)"
echo "      Path: System Settings → Privacy & Security → Screen Recording → enable Sotto"
echo ""
echo "With the stable '$SIGN_IDENTITY' identity, these grants persist across future rebuilds."
echo "Do NOT run tccutil reset — that clears grants and forces re-prompts."
