#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DYLIB_PATH="$SCRIPT_DIR/libMenuBarInterposer.dylib"
PLIST_DST="$HOME/Library/LaunchAgents/com.apple.MenuBarAgent.plist"

echo "=== MenuBarInterposer Installer (MenuBarAgent) ==="

# Build if needed
if [ ! -f "$DYLIB_PATH" ]; then
    echo "Building interposer..."
    cd "$SCRIPT_DIR" && make
fi

# Ad-hoc sign the dylib
codesign -fs- "$DYLIB_PATH" 2>/dev/null || true

echo "Creating launchd override plist..."
mkdir -p "$(dirname "$PLIST_DST")"
cat > "$PLIST_DST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.apple.MenuBarAgent</string>
    <key>Program</key>
    <string>/System/Library/CoreServices/MenuBarAgent.app/Contents/MacOS/MenuBarAgent</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>DYLD_INSERT_LIBRARIES</key>
        <string>${DYLIB_PATH}</string>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>LoginWindow</string>
        <string>Aqua</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>POSIXSpawnType</key>
    <string>App</string>
    <key>MachServices</key>
    <dict>
        <key>com.apple.MenuBarAgent.systemservices</key>
        <true/>
        <key>com.apple.PreloginSystemBannerService</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

echo "Override plist created at: $PLIST_DST"

# Unload system plist, load override, restart
launchctl unload /System/Library/LaunchAgents/com.apple.MenuBarAgent.plist 2>/dev/null || true
launchctl load "$PLIST_DST" 2>/dev/null || true
killall MenuBarAgent 2>/dev/null || true

echo "MenuBarAgent will relaunch with the interposer. Menu bar killed."
