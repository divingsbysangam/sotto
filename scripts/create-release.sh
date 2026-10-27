#!/bin/bash
# Sotto release script
# Builds a signed Release, zips it, signs the zip for Sparkle, and writes this version's
# entry into appcast.xml. It never tags, pushes, or uploads: it prints those commands.
#
# The version and build number come from project.yml (MARKETING_VERSION and
# CURRENT_PROJECT_VERSION), the single source of truth, and are checked against the built app.
# Sparkle compares the build number, so it must increase with every release.
#
# Prerequisites:
#   - xcodegen, and Xcode 26 with its Metal toolchain
#   - the self-signed identity from scripts/create-signing-cert.sh
#   - the Sparkle EdDSA private key in your login keychain (Sparkle's generate_keys), or a key file
#     given as SPARKLE_KEY_FILE=/path/to/key. Never commit the key.
#
# Usage:
#   ./scripts/create-release.sh
#   RELEASE_NOTES_FILE=notes.html ./scripts/create-release.sh   # HTML shown in the update dialog
#   SIGN_IDENTITY="My Cert" ./scripts/create-release.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

REPO="divingsbysangam/sotto"
SIGN_IDENTITY="${SIGN_IDENTITY:-Sotto Self-Signed}"

read_setting() {
    sed -n "s/^[[:space:]]*$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" project.yml | head -1
}
VERSION="$(read_setting MARKETING_VERSION)"
BUILD_NUMBER="$(read_setting CURRENT_PROJECT_VERSION)"
if [ -z "$VERSION" ] || [ -z "$BUILD_NUMBER" ]; then
    echo "❌ Could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml"
    exit 1
fi
TAG="v$VERSION"

echo "📦 Creating release $TAG (build $BUILD_NUMBER)"

# Sparkle needs a numeric, increasing build number.
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "❌ CURRENT_PROJECT_VERSION must be an integer, got '$BUILD_NUMBER'"
    exit 1
fi

for tool in xcodegen python3 ditto; do
    command -v "$tool" >/dev/null 2>&1 || { echo "❌ $tool not found"; exit 1; }
done
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "❌ Signing identity '$SIGN_IDENTITY' not found. Run ./scripts/create-signing-cert.sh"
    exit 1
fi
if ! xcrun metal --version >/dev/null 2>&1; then
    echo "❌ Xcode's Metal toolchain is missing: xcodebuild -downloadComponent MetalToolchain"
    exit 1
fi

OUT_DIR="$PROJECT_DIR/build/release"
DERIVED="${SOTTO_DERIVED_DATA_PATH:-$OUT_DIR/DerivedData}"
RELEASE_DIR="$OUT_DIR/$TAG"
ZIP="$RELEASE_DIR/Sotto.zip"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

echo ""
echo "Step 1: Generating the Xcode project and building Release..."
xcodegen generate >/dev/null
xcodebuild -project Sotto.xcodeproj -scheme Sotto -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" ARCHS=arm64 \
    -skipPackagePluginValidation -skipMacroValidation build >"$OUT_DIR/build.log" 2>&1 \
    || { echo "❌ Build failed. Last lines of $OUT_DIR/build.log:"; tail -30 "$OUT_DIR/build.log"; exit 1; }

APP_PATH="$DERIVED/Build/Products/Release/Sotto.app"
[ -d "$APP_PATH" ] || { echo "❌ Built app not found at $APP_PATH"; exit 1; }
rm -rf "$APP_PATH/Contents/PlugIns/SottoTests.xctest"

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
if [ "$BUILT_VERSION" != "$VERSION" ] || [ "$BUILT_BUILD" != "$BUILD_NUMBER" ]; then
    echo "❌ Built app reports $BUILT_VERSION ($BUILT_BUILD) but project.yml says $VERSION ($BUILD_NUMBER)"
    exit 1
fi
echo "   $BUNDLE_ID $BUILT_VERSION ($BUILT_BUILD)"

echo ""
echo "Step 2: Signing with '$SIGN_IDENTITY' (same order as build-and-install.sh)..."
if [ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/Helpers/sotto"
codesign --force --deep --options runtime \
    --entitlements "$PROJECT_DIR/Sotto/Sotto.entitlements" --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
echo "   signature verified"

echo ""
echo "Step 3: Creating the zip..."
# ditto keeps the code signature and extended attributes intact; plain zip can break them.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP"
SIZE="$(stat -f%z "$ZIP")"
SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "   $ZIP ($SIZE bytes)"

echo ""
echo "Step 4: Signing the zip for Sparkle..."
SIGN_UPDATE="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || { echo "❌ sign_update not found at $SIGN_UPDATE"; exit 1; }
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
    SIGN_OUT="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" "$ZIP")"
else
    SIGN_OUT="$("$SIGN_UPDATE" "$ZIP")"
fi
ED_SIGNATURE="$(printf '%s' "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIGNATURE" ] || { echo "❌ Could not read the EdDSA signature from sign_update output"; exit 1; }

echo ""
echo "Step 5: Writing the $TAG entry in appcast.xml..."
NOTES_FILE="${RELEASE_NOTES_FILE:-}"
export VERSION BUILD_NUMBER SIZE ED_SIGNATURE REPO TAG NOTES_FILE
python3 -I - <<'PY'
import os, re, email.utils, xml.etree.ElementTree as ET

version = os.environ["VERSION"]
build = os.environ["BUILD_NUMBER"]
size = os.environ["SIZE"]
signature = os.environ["ED_SIGNATURE"]
repo = os.environ["REPO"]
tag = os.environ["TAG"]
notes_path = os.environ.get("NOTES_FILE", "")

notes = f"<h2>Sotto {version}</h2>"
if notes_path:
    with open(notes_path, encoding="utf-8") as fh:
        notes = fh.read().strip()
if "]]>" in notes:
    raise SystemExit("release notes may not contain ']]>'")

item = f"""    <item>
      <title>Version {version}</title>
      <description><![CDATA[
        {notes}
      ]]></description>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/{repo}/releases/download/{tag}/Sotto.zip"
                 sparkle:edSignature="{signature}"
                 length="{size}"
                 type="application/octet-stream"/>
    </item>
"""

path = "appcast.xml"
text = open(path, encoding="utf-8").read()
ET.fromstring(text)  # the existing feed must already be valid

# Drop an existing entry for this version, so re-running the script replaces it.
items = re.findall(r"    <item>.*?</item>\n", text, flags=re.S)
kept = [i for i in items if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" not in i]
head = text.split("    <item>")[0].split("  </channel>")[0]
new = head + item + "".join(kept) + "  </channel>\n</rss>\n"
ET.fromstring(new)
open(path, "w", encoding="utf-8").write(new)
PY
echo "   appcast.xml updated"

cat <<EOF

=========================================
Release $TAG (build $BUILD_NUMBER) is ready
=========================================
Zip:     $ZIP
SHA-256: $SHA256
Size:    $SIZE bytes

Next steps (nothing has been tagged, pushed, or uploaded):
  1. Review the change:      git diff appcast.xml
  2. Commit it, push to main
  3. Create the release and upload the zip:
       gh release create $TAG "$ZIP" --repo $REPO --title "Sotto $VERSION" --notes-file <notes.md>
  4. Check the feed and the download:
       curl -fsSL https://raw.githubusercontent.com/$REPO/main/appcast.xml
       curl -fsSLI https://github.com/$REPO/releases/download/$TAG/Sotto.zip
EOF
