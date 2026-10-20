#!/usr/bin/env bash
set -euo pipefail

# HyprMac Automated Installer for macOS on Apple Silicon
# Installs pre-compiled binaries, configures LaunchDaemon & LaunchAgent

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD}       HyprMac System Installer (macOS ARM64e)   ${NC}"
echo -e "${BOLD}==================================================${NC}"

# 1. Architecture check
ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
    echo -e "${RED}[!] Error: HyprMac requires Apple Silicon (arm64/arm64e). Detected: $ARCH${NC}"
    exit 1
fi

# 2. SIP status check
if csrutil status | grep -q "enabled"; then
    echo -e "${YELLOW}[!] Warning: System Integrity Protection (SIP) is fully enabled.${NC}"
    echo -e "${YELLOW}    HyprMac requires SIP disabled or debugging unrestricted to hook WindowServer.${NC}"
    echo -e "${YELLOW}    Boot into Recovery Mode (hold TouchID/Power) and run: csrutil disable${NC}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SOURCE="${SCRIPT_DIR}/build/HyprMac.app"
if [[ ! -d "$APP_SOURCE" ]]; then
    APP_SOURCE="/Applications/HyprMac.app"
fi
INJECT_BIN="${SCRIPT_DIR}/build/hypr-inject"
SERVER_DYLIB="${SCRIPT_DIR}/build/libhyprserver.dylib"
INJECT_PLIST="${SCRIPT_DIR}/native/injector/com.hyprmac.inject.plist"
DAEMON_PLIST="${SCRIPT_DIR}/native/daemon/com.hyprmac.daemon.plist"

# Verify pre-built binaries exist
if [[ ! -f "$INJECT_BIN" || ! -f "$SERVER_DYLIB" || ! -d "$APP_SOURCE" ]]; then
    echo -e "${YELLOW}[*] Pre-built binaries not found in build/. Building release artifacts...${NC}"
    make all
fi

# Verify Developer ID / valid code signing (never ad-hoc for Accessibility stability)
echo -e "${BOLD}[1/4] Verifying code signature integrity...${NC}"
SIG_INFO=$(codesign -dvv "$APP_SOURCE" 2>&1 || true)
if echo "$SIG_INFO" | grep -q "Signature=adhoc"; then
    echo -e "${RED}[!] Warning: /Applications/HyprMac.app has an ad-hoc signature.${NC}"
    echo -e "${RED}    macOS TCC will fail to retain Accessibility permissions across runs.${NC}"
    echo -e "${YELLOW}    Ensure a valid Developer ID Application certificate is installed.${NC}"
else
    echo -e "${GREEN}[+] Valid signature verified: $(echo "$SIG_INFO" | grep 'Authority=' | head -n 1 || echo 'Signed')${NC}"
fi

# 3. Install binaries and app
echo -e "${BOLD}[2/4] Installing application and binaries (requires sudo)...${NC}"
sudo mkdir -p /usr/local/bin /usr/local/lib /Library/LaunchDaemons
sudo cp -f "$INJECT_BIN" /usr/local/bin/hypr-inject
sudo chmod 755 /usr/local/bin/hypr-inject
sudo chown root:wheel /usr/local/bin/hypr-inject

sudo cp -f "$SERVER_DYLIB" /usr/local/lib/libhyprserver.dylib
sudo chmod 755 /usr/local/lib/libhyprserver.dylib
sudo chown root:wheel /usr/local/lib/libhyprserver.dylib

if [[ "$APP_SOURCE" != "/Applications/HyprMac.app" ]]; then
    sudo rm -rf /Applications/HyprMac.app
    sudo cp -R "$APP_SOURCE" /Applications/HyprMac.app
fi
sudo chown -R "$(id -un):admin" /Applications/HyprMac.app

# Create CLI symlinks
sudo ln -sf /Applications/HyprMac.app/Contents/MacOS/HyprMac /usr/local/bin/HyprMac
sudo ln -sf /Applications/HyprMac.app/Contents/MacOS/HyprMac /usr/local/bin/hyprmac

# Clean any stale IPC state
sudo rm -f /tmp/hyprmac-ipc.shm /tmp/hyprserver.ready

# 4. Install LaunchDaemon (Root hook)
echo -e "${BOLD}[3/4] Registering WindowServer LaunchDaemon...${NC}"
sudo cp -f "$INJECT_PLIST" /Library/LaunchDaemons/com.hyprmac.inject.plist
sudo chown root:wheel /Library/LaunchDaemons/com.hyprmac.inject.plist
sudo chmod 644 /Library/LaunchDaemons/com.hyprmac.inject.plist
sudo launchctl unload /Library/LaunchDaemons/com.hyprmac.inject.plist 2>/dev/null || true
sudo launchctl load -w /Library/LaunchDaemons/com.hyprmac.inject.plist

# 5. Install LaunchAgent (User desktop session)
echo -e "${BOLD}[4/4] Registering User Desktop LaunchAgent...${NC}"
USER_AGENTS_DIR="${HOME}/Library/LaunchAgents"
mkdir -p "$USER_AGENTS_DIR"
cp -f "$DAEMON_PLIST" "${USER_AGENTS_DIR}/com.hyprmac.daemon.plist"
chmod 644 "${USER_AGENTS_DIR}/com.hyprmac.daemon.plist"

CURRENT_UID="$(id -u)"
launchctl bootout "gui/${CURRENT_UID}/com.hyprmac.daemon" 2>/dev/null || true
launchctl bootstrap "gui/${CURRENT_UID}" "${USER_AGENTS_DIR}/com.hyprmac.daemon.plist" 2>/dev/null || \
launchctl load -w "${USER_AGENTS_DIR}/com.hyprmac.daemon.plist"

echo -e "\n${GREEN}${BOLD}✓ HyprMac successfully installed and activated!${NC}"
echo -e "• Global CLI available: ${BOLD}hyprmac --help${NC}"
echo -e "• Server hook status:   ${BOLD}hyprmac server-status${NC}"
echo -e "• Desktop daemon logs:  ${BOLD}tail -f /tmp/hyprmac-daemon.log${NC}"
echo -e "\n${YELLOW}Note: If prompted, grant Accessibility permissions to ${BOLD}HyprMac.app${NC} in System Settings -> Privacy & Security -> Accessibility.${NC}"
