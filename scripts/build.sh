#!/bin/bash
# Sotto build-only script
# Generates the Xcode project, then builds (or tests) Sotto into ./build/DerivedData.
# It does not need a signing identity and never installs anything, so it is the way to check
# that a fresh clone builds, and what CI runs. To run the app with persistent macOS
# permissions, use scripts/build-and-install.sh instead.
#
# Usage:
#   ./scripts/build.sh            # build (Debug)
#   ./scripts/build.sh test       # build and run the unit tests
#
# Environment:
#   CONFIGURATION          Debug (default) or Release
#   SOTTO_DERIVED_DATA_PATH  where to build (default: build/DerivedData)
#   RESULT_BUNDLE_PATH     write an .xcresult here (test runs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

ACTION="${1:-build}"
case "$ACTION" in
    build|test) ;;
    *) echo "Usage: $0 [build|test]"; exit 2 ;;
esac

CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED="${SOTTO_DERIVED_DATA_PATH:-build/DerivedData}"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "❌ xcodegen not found. Install it: brew install xcodegen"
    exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
    echo "❌ Xcode is not installed or not selected. Install Xcode 26 or later, then:"
    echo "     sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi
# mlx-swift compiles Metal kernels, which needs Xcode's separately downloaded Metal toolchain.
if ! xcrun metal --version >/dev/null 2>&1; then
    echo "❌ Xcode's Metal toolchain is missing. Install it once:"
    echo "     xcodebuild -downloadComponent MetalToolchain"
    exit 1
fi

echo "📍 Generating Sotto.xcodeproj from project.yml..."
xcodegen generate >/dev/null

ARGS=(
    -project Sotto.xcodeproj
    -scheme Sotto
    -configuration "$CONFIGURATION"
    -destination 'platform=macOS,arch=arm64'
    -derivedDataPath "$DERIVED"
    # Package plugins and macros (mlx-swift, swift-transformers) are trusted without Xcode's prompt.
    -skipPackagePluginValidation -skipMacroValidation
)
if [ -n "${RESULT_BUNDLE_PATH:-}" ]; then
    ARGS+=(-resultBundlePath "$RESULT_BUNDLE_PATH")
fi

# Ad-hoc signed or unsigned: enough to compile and test. The macOS permission grants
# (microphone, Accessibility) do not persist across such builds.
SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO)

echo "📍 xcodebuild $ACTION ($CONFIGURATION)..."
# `test` also builds, but keep `build` explicit so the app target compiles even if tests are skipped.
if [ "$ACTION" = "test" ]; then
    xcodebuild "${ARGS[@]}" "${SIGNING[@]}" build test
else
    xcodebuild "${ARGS[@]}" "${SIGNING[@]}" build
fi

echo ""
echo "✅ $ACTION succeeded"
echo "   App: $DERIVED/Build/Products/$CONFIGURATION/Sotto.app"
