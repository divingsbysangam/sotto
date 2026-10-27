#!/bin/bash
# Sotto - Install a LaunchAgent for reliable always-on startup (optional)
# =====================================================================
# This is an ALTERNATIVE to the in-app "Launch at Login" toggle. It installs a
# per-user LaunchAgent that:
#   - starts Sotto at login (RunAtLoad)
#   - relaunches Sotto if it CRASHES (KeepAlive on unsuccessful exit only)
#     — quitting Sotto yourself is a clean exit, so it will NOT fight you.
#
# If you use this, turn OFF "Launch at Login" inside Sotto to avoid double-launch.
#
# Usage:
#   ./scripts/install-launch-agent.sh            # install + load
#   ./scripts/install-launch-agent.sh --uninstall
#
set -euo pipefail

LABEL="com.divingsbysangam.sotto"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
APP_BIN="/Applications/Sotto.app/Contents/MacOS/Sotto"
GUI_DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "--uninstall" ]; then
    echo "📍 Uninstalling LaunchAgent..."
    launchctl bootout "$GUI_DOMAIN" "$PLIST" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "✅ Removed $PLIST"
    exit 0
fi

if [ ! -x "$APP_BIN" ]; then
    echo "❌ $APP_BIN not found. Build & install Sotto first: ./scripts/build-and-install.sh"
    exit 1
fi

echo "📍 Writing LaunchAgent to $PLIST ..."
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP_BIN}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

echo "📍 Loading LaunchAgent..."
launchctl bootout "$GUI_DOMAIN" "$PLIST" 2>/dev/null || true
launchctl bootstrap "$GUI_DOMAIN" "$PLIST" 2>/dev/null || launchctl load "$PLIST"

echo "✅ Installed and loaded. Sotto will start at login and relaunch if it crashes."
echo "   Remember to turn OFF 'Launch at Login' inside Sotto to avoid double-launch."
echo "   To remove: ./scripts/install-launch-agent.sh --uninstall"
