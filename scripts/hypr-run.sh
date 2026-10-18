#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DYLIB="${REPO_DIR}/build/libhyprclient.dylib"

if [[ ! -f "$DYLIB" ]]; then
    echo "[!] libhyprclient.dylib not found. Building with make client..."
    make -C "$REPO_DIR" client
fi

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <app-name-or-path> [args...]"
    echo "Example: $0 Ghostty"
    echo "Example: $0 /System/Applications/TextEdit.app"
    exit 1
fi

TARGET="$1"
shift

APP_BUNDLE=""
if [[ "$TARGET" == *.app ]]; then
    APP_BUNDLE="$TARGET"
elif [[ -d "/Applications/${TARGET}.app" ]]; then
    APP_BUNDLE="/Applications/${TARGET}.app"
elif [[ -d "/System/Applications/${TARGET}.app" ]]; then
    APP_BUNDLE="/System/Applications/${TARGET}.app"
elif [[ -d "/System/Applications/Utilities/${TARGET}.app" ]]; then
    APP_BUNDLE="/System/Applications/Utilities/${TARGET}.app"
elif [[ -d "${HOME}/Applications/${TARGET}.app" ]]; then
    APP_BUNDLE="${HOME}/Applications/${TARGET}.app"
elif command -v "$TARGET" >/dev/null 2>&1; then
    BIN_PATH="$(command -v "$TARGET")"
else
    BIN_PATH="$TARGET"
fi

if [[ -n "$APP_BUNDLE" ]]; then
    echo "[+] Launching app bundle $APP_BUNDLE with libhyprclient.dylib interposer..."
    if [[ $# -gt 0 ]]; then
        exec open -n -a "$APP_BUNDLE" --env DYLD_INSERT_LIBRARIES="$DYLIB" --args "$@"
    else
        exec open -n -a "$APP_BUNDLE" --env DYLD_INSERT_LIBRARIES="$DYLIB"
    fi
else
    echo "[+] Launching $BIN_PATH with libhyprclient.dylib interposer..."
    exec env DYLD_INSERT_LIBRARIES="$DYLIB" "$BIN_PATH" "$@"
fi

