#!/usr/bin/env bash
set -euo pipefail

# HyprMac Automated Uninstaller for macOS
# Unloads services and purges installed binaries

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD}       HyprMac System Uninstaller                ${NC}"
echo -e "${BOLD}==================================================${NC}"

CURRENT_UID="$(id -u)"
USER_AGENTS_DIR="${HOME}/Library/LaunchAgents"

# 1. Unload and remove LaunchAgent
echo -e "${BOLD}[1/3] Stopping User Desktop LaunchAgent...${NC}"
if launchctl list | grep -q "com.hyprmac.daemon"; then
    launchctl bootout "gui/${CURRENT_UID}/com.hyprmac.daemon" 2>/dev/null || \
    launchctl unload "${USER_AGENTS_DIR}/com.hyprmac.daemon.plist" 2>/dev/null || true
fi
rm -f "${USER_AGENTS_DIR}/com.hyprmac.daemon.plist"

# 2. Unload and remove LaunchDaemon
echo -e "${BOLD}[2/3] Stopping WindowServer LaunchDaemon (requires sudo)...${NC}"
if sudo launchctl list | grep -q "com.hyprmac.inject" 2>/dev/null; then
    sudo launchctl bootout system/com.hyprmac.inject 2>/dev/null || \
    sudo launchctl unload /Library/LaunchDaemons/com.hyprmac.inject.plist 2>/dev/null || true
fi
sudo rm -f /Library/LaunchDaemons/com.hyprmac.inject.plist

# 3. Remove binaries, symlinks, and app
echo -e "${BOLD}[3/3] Purging binaries and application...${NC}"
sudo rm -f /usr/local/bin/hypr-inject
sudo rm -f /usr/local/bin/HyprMac
sudo rm -f /usr/local/bin/hyprmac
sudo rm -f /usr/local/lib/libhyprserver.dylib
sudo rm -rf /Applications/HyprMac.app
sudo rm -f /tmp/hyprmac-ipc.shm /tmp/hyprserver.ready /tmp/hyprmac-daemon.log /var/log/hyprmac-inject.log

echo -e "\n${GREEN}${BOLD}✓ HyprMac completely uninstalled from system.${NC}"
