#!/bin/bash
# Sotto Dev Watch Script
# Builds + installs + launches Sotto, then rebuilds automatically whenever app sources change.
#
# Each rebuild runs scripts/build-and-install.sh (xcodegen → kill → build → sign → install → launch),
# so /Applications/Sotto.app always matches the working tree. Pure bash polling (no fswatch needed).
#
# Watched: Sotto/**/*.swift, SottoCLI/*.swift, asset catalogs, Sotto/Resources/**, project.yml.
# Ignored: Info.plist, entitlements and Sotto.xcodeproj — xcodegen regenerates them from
# project.yml on every build, so watching them would rebuild forever.
#
# Usage: ./scripts/dev-watch.sh        (Ctrl-C to stop)
#   POLL_SECONDS=2  QUIET_SECONDS=3    (optional tuning)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
POLL_SECONDS="${POLL_SECONDS:-2}"
QUIET_SECONDS="${QUIET_SECONDS:-3}"

cd "$PROJECT_DIR"

STAMP="$(mktemp -t sotto-dev-watch)"
trap 'rm -f "$STAMP"; echo ""; echo "👋 Stopped watching."; exit 0' INT TERM

# Prints watched files modified after the given marker file (empty when nothing changed).
changed_since() {
    {
        find Sotto \( -name '*.swift' -o -path 'Sotto/Resources/*' -o -path '*.xcassets/*' \) \
            -type f ! -name '.DS_Store' -newer "$1" 2>/dev/null
        find SottoCLI -name '*.swift' -type f -newer "$1" 2>/dev/null
        find project.yml -newer "$1" 2>/dev/null
    } || true
}

build() {
    # Stamp before building so edits made during the build trigger another one.
    touch "$STAMP"
    echo ""
    echo "🔁 $(date '+%H:%M:%S') Rebuilding Sotto..."
    if "$SCRIPT_DIR/build-and-install.sh"; then
        echo "✅ $(date '+%H:%M:%S') Sotto rebuilt and relaunched. Watching for changes..."
    else
        echo "❌ $(date '+%H:%M:%S') Build failed — fix the error above; watching for changes..."
    fi
}

echo "👀 Sotto dev watch — rebuilds on changes to Sotto/ sources and project.yml (Ctrl-C to stop)"
build

while true; do
    sleep "$POLL_SECONDS"
    CHANGES="$(changed_since "$STAMP")"
    [ -z "$CHANGES" ] && continue

    # Debounce: wait until nothing new has changed for QUIET_SECONDS, so a multi-file
    # edit or a git checkout produces one build.
    while true; do
        QUIET_MARK="$(mktemp -t sotto-dev-watch-quiet)"
        sleep "$QUIET_SECONDS"
        MORE="$(changed_since "$QUIET_MARK")"
        rm -f "$QUIET_MARK"
        [ -z "$MORE" ] && break
        CHANGES="$(printf '%s\n%s' "$CHANGES" "$MORE")"
    done

    echo ""
    echo "📝 Changed:"
    printf '%s\n' "$CHANGES" | sort -u | sed 's/^/   /'
    build
done
