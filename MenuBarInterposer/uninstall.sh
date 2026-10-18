#!/bin/bash
set -euo pipefail

PLIST_DST="$HOME/Library/LaunchAgents/com.apple.MenuBarAgent.plist"

echo "=== MenuBarInterposer Uninstaller ==="

if [ -f "$PLIST_DST" ]; then
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    rm -f "$PLIST_DST"
    echo "Override plist removed."
else
    echo "No override plist found."
fi

echo "Reloading original MenuBarAgent..."
launchctl load /System/Library/LaunchAgents/com.apple.MenuBarAgent.plist 2>/dev/null || true
killall MenuBarAgent 2>/dev/null || true

echo "Menu bar restored."
