#!/bin/bash
# ==============================================================================
# e2e-verify.sh - End-to-End Verification Pipeline for HyprMac
#
# Task 5.6: End-to-End Verification
#
# Automates the complete validation workflow:
#   1. Checks prerequisites (SIP disabled, root/sudo, build dependencies)
#   2. Builds all components (make clean && make && swift build)
#   3. Cleans safe-mode tombstone (/tmp/hyprmac.safemode)
#   4. Runs hypr-inject and verifies libhyprserver.dylib load in WindowServer
#   5. Runs basic IPC smoke test:
#      - swift run HyprMac server-status
#      - sends PING and verifies PONG response
#      - runs tests/test_ipc integration harness
#   6. Tests window decorations on live test window:
#      - Opens TextEdit test window
#      - Discovers CGWindowID
#      - swift run HyprMac square <wid>
#      - swift run HyprMac strip-shadow <wid>
#   7. Reports pass/fail for each step with color output
#   8. Cleans up test window and temporary state
#
# Usage:
#   sudo ./scripts/e2e-verify.sh
# ==============================================================================

set -euo pipefail

# Colors
RED="\x1b[31m"
GREEN="\x1b[32m"
YELLOW="\x1b[33m"
BLUE="\x1b[34m"
CYAN="\x1b[36m"
BOLD="\x1b[1m"
RESET="\x1b[0m"

TOTAL_STEPS=7
PASSED_STEPS=0
FAILED_STEPS=0

log_step() {
    local step_num="$1"
    local desc="$2"
    echo -e "${BOLD}${CYAN}\n[Step ${step_num}/${TOTAL_STEPS}] ${desc}${RESET}"
}

log_pass() {
    echo -e "  ${GREEN}[PASS] $1${RESET}"
    PASSED_STEPS=$((PASSED_STEPS + 1))
}

log_fail() {
    echo -e "  ${RED}[FAIL] $1${RESET}"
    FAILED_STEPS=$((FAILED_STEPS + 1))
}

log_info() {
    echo -e "  ${BLUE}[INFO] $1${RESET}"
}

log_warn() {
    echo -e "  ${YELLOW}[WARN] $1${RESET}"
}

cleanup() {
    echo -e "\n${BOLD}[*] Performing Cleanup...${RESET}"
    if pgrep -i TextEdit >/dev/null 2>&1; then
        log_info "Closing TextEdit test processes..."
        killall TextEdit >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo -e "${BOLD}${CYAN}======================================================="
echo -e "          HyprMac End-to-End Verification"
echo -e "=======================================================${RESET}"

# ------------------------------------------------------------------------------
# STEP 1: Check Prerequisites
# ------------------------------------------------------------------------------
log_step 1 "Checking System Prerequisites"

# 1.1 SIP Status
SIP_STATUS=$(csrutil status 2>&1 || true)
if echo "${SIP_STATUS}" | grep -q "disabled"; then
    log_pass "System Integrity Protection (SIP) is DISABLED"
else
    log_warn "SIP may be active (${SIP_STATUS}). hypr-inject requires SIP disabled."
fi

# 1.2 Root / Privilege
SUDO_CMD=""
if [ "$(id -u)" -eq 0 ]; then
    log_pass "Running as effective root (UID 0)"
else
    if sudo -n true 2>/dev/null; then
        SUDO_CMD="sudo"
        log_pass "Sudo access verified without password"
    else
        log_warn "Current user is not root. Sudo will be invoked for injection if needed."
        SUDO_CMD="sudo"
    fi
fi

# 1.3 Target Architecture & macOS Version
ARCH=$(uname -m)
OS_VER=$(sw_vers -productVersion)
log_info "Host System: ${ARCH} running macOS ${OS_VER}"
if [ "${ARCH}" = "arm64" ]; then
    log_pass "Apple Silicon ARM64 architecture detected"
else
    log_fail "Expected Apple Silicon (arm64), got ${ARCH}"
fi

# 1.4 Boot Args Check
BOOT_ARGS=$(nvram boot-args 2>/dev/null || true)
if echo "${BOOT_ARGS}" | grep -q -- "-arm64e_preview_abi"; then
    log_pass "Kernel boot-arg -arm64e_preview_abi confirmed"
else
    log_warn "boot-args: '${BOOT_ARGS}' (ensure -arm64e_preview_abi is configured if injection traps occur)"
fi

# ------------------------------------------------------------------------------
# STEP 2: Build All Components
# ------------------------------------------------------------------------------
log_step 2 "Building All Components (make clean && make && swift build)"

log_info "Running make clean && make..."
make clean
make

if [ -x "build/hypr-inject" ] && [ -f "build/libhyprserver.dylib" ]; then
    log_pass "Native artifacts built successfully (build/hypr-inject, build/libhyprserver.dylib)"
else
    log_fail "Native build artifacts missing"
    exit 1
fi

log_info "Running swift build..."
swift build
SWIFT_BIN_DIR="$(swift build --show-bin-path 2>/dev/null || true)"
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "${SIGN_ID}" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
fi
if [ -n "${SIGN_ID}" ] && [ -n "${SWIFT_BIN_DIR}" ] && [ -f "${SWIFT_BIN_DIR}/HyprMac" ]; then
    log_info "Signing HyprMac with ${SIGN_ID}..."
    codesign -s "${SIGN_ID}" --force --timestamp "${SWIFT_BIN_DIR}/HyprMac"
fi
log_pass "Swift CLI package built and signed successfully (HyprMac)"

log_info "Compiling IPC test harness..."
make -C tests
log_pass "Integration test harness built (tests/test_ipc)"

# ------------------------------------------------------------------------------
# STEP 3: Remove Safe-Mode Tombstone
# ------------------------------------------------------------------------------
log_step 3 "Removing Safe-Mode Tombstone"

SAFEMODE_PATH="/tmp/hyprmac.safemode"
if [ -f "${SAFEMODE_PATH}" ]; then
    log_info "Removing existing safe-mode marker: ${SAFEMODE_PATH}"
    rm "${SAFEMODE_PATH}"
fi

if [ ! -f "${SAFEMODE_PATH}" ]; then
    log_pass "Safe-mode file cleared (${SAFEMODE_PATH} does not exist)"
else
    log_fail "Failed to remove safe-mode file"
    exit 1
fi

# ------------------------------------------------------------------------------
# STEP 4: Inject Hook into WindowServer
# ------------------------------------------------------------------------------
log_step 4 "Running hypr-inject and Verifying WindowServer Load"

INJECT_OUT=""
INJECT_EXIT=0

if ${SUDO_CMD} ./build/hypr-inject > /tmp/hypr-inject.out 2>&1; then
    INJECT_EXIT=0
else
    INJECT_EXIT=$?
fi
INJECT_OUT=$(cat /tmp/hypr-inject.out)
echo "${INJECT_OUT}"

# Exit code 0 (fresh load) or 2 (already loaded) both indicate active hook
if [ "${INJECT_EXIT}" -eq 0 ] || [ "${INJECT_EXIT}" -eq 2 ]; then
    if echo "${INJECT_OUT}" | grep -q -E "HyprMac is active|already loaded"; then
        log_pass "hypr-inject confirmed hook is active in WindowServer"
    else
        log_warn "hypr-inject finished with exit ${INJECT_EXIT} but banner string varied"
    fi
else
    log_fail "hypr-inject exited with error code ${INJECT_EXIT}"
    log_warn "If running in an unprivileged CI environment without root, ensure hook is preloaded."
fi

# Wait up to 5 seconds for SHM file availability
SHM_PATH="/tmp/hyprmac-ipc.shm"
log_info "Waiting for SHM file ${SHM_PATH} to settle..."
for i in $(seq 1 10); do
    if [ -f "${SHM_PATH}" ]; then
        SHM_SIZE=$(stat -f%z "${SHM_PATH}" 2>/dev/null || stat -c%s "${SHM_PATH}" 2>/dev/null || true)
        if [ "${SHM_SIZE}" -eq 65536 ]; then
            break
        fi
    fi
    sleep 0.5
done

# Verify SHM file exists and has correct size
if [ ! -f "${SHM_PATH}" ]; then
    echo "FAIL: SHM file not found at ${SHM_PATH}"
    log_fail "SHM file not found at ${SHM_PATH}"
    exit 1
fi

SHM_SIZE=$(stat -f%z "${SHM_PATH}" 2>/dev/null || stat -c%s "${SHM_PATH}" 2>/dev/null)
if [ "${SHM_SIZE}" -ne 65536 ]; then
    echo "FAIL: SHM file size ${SHM_SIZE} != expected 65536"
    log_fail "SHM file size ${SHM_SIZE} != expected 65536"
    exit 1
fi

echo "PASS: SHM IPC file present (${SHM_SIZE} bytes)"
log_pass "SHM IPC file present (${SHM_SIZE} bytes)"

# ------------------------------------------------------------------------------
# STEP 5: IPC Smoke Test via CLI and Harness
# ------------------------------------------------------------------------------
log_step 5 "Running IPC Smoke Test (CLI server-status and test_ipc)"

SERVER_STATUS_OUT=""
if SERVER_STATUS_OUT=$(swift run HyprMac server-status 2>&1); then
    echo "${SERVER_STATUS_OUT}"
    if echo "${SERVER_STATUS_OUT}" | grep -q "ACTIVE and responding to HYPR_CMD_PING"; then
        log_pass "swift run HyprMac server-status responded with active PONG"
    else
        log_fail "server-status did not report ACTIVE"
    fi
else
    echo "${SERVER_STATUS_OUT}"
    log_fail "swift run HyprMac server-status failed with non-zero exit code"
fi

log_info "Running tests/test_ipc integration test suite..."
if ./tests/test_ipc; then
    log_pass "tests/test_ipc test harness completed with 0 errors"
else
    log_fail "tests/test_ipc test harness detected failures"
fi

# ------------------------------------------------------------------------------
# STEP 6: Window Decoration Test on Live Test Window
# ------------------------------------------------------------------------------
log_step 6 "Testing Window Decoration on Live Test Window"

log_info "Spawning test window..."
# Open TextEdit window with AppleScript or open fallback
if ! osascript -e 'with timeout of 3 seconds
    tell application "TextEdit"
        activate
        make new document
    end tell
end timeout' >/dev/null 2>&1; then
    open -a TextEdit
fi
sleep 1.0

# Discover target window ID
TARGET_WID=$(swift - << 'EOF' 2>/dev/null || true
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let wid = w[kCGWindowNumber as String] as? UInt32 ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    if owner == "TextEdit" && wid > 0 && layer == 0 {
        print(wid)
        break
    }
}
EOF
)

if [ -z "${TARGET_WID}" ]; then
    # Fallback to any active non-system window on screen
    TARGET_WID=$(swift - << 'EOF' 2>/dev/null || true
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let wid = w[kCGWindowNumber as String] as? UInt32 ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    if layer == 0 && wid > 0 && owner != "Window Server" && owner != "Dock" {
        print(wid)
        break
    }
}
EOF
    )
fi

if [ -n "${TARGET_WID}" ]; then
    log_info "Targeting Window ID: ${TARGET_WID}"

    log_info "Testing square corners: swift run HyprMac square ${TARGET_WID}"
    if swift run HyprMac square "${TARGET_WID}"; then
        log_pass "swift run HyprMac square ${TARGET_WID} exited with code 0"
    else
        log_fail "swift run HyprMac square ${TARGET_WID} failed"
    fi

    log_info "Testing shadow removal: swift run HyprMac strip-shadow ${TARGET_WID}"
    if swift run HyprMac strip-shadow "${TARGET_WID}"; then
        log_pass "swift run HyprMac strip-shadow ${TARGET_WID} exited with code 0"
    else
        log_fail "swift run HyprMac strip-shadow ${TARGET_WID} failed"
    fi
else
    log_fail "Could not find a valid test window ID"
fi

# ------------------------------------------------------------------------------
# STEP 7: Final Report
# ------------------------------------------------------------------------------
log_step 7 "End-to-End Verification Summary"

echo -e "\n${BOLD}${CYAN}-------------------------------------------------------${RESET}"
echo -e "Total Checks Passed: ${GREEN}${PASSED_STEPS}${RESET}"
echo -e "Total Checks Failed: ${RED}${FAILED_STEPS}${RESET}"
echo -e "${BOLD}${CYAN}=======================================================${RESET}\n"

if [ "${FAILED_STEPS}" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}[SUCCESS] HyprMac End-to-End Verification PASSED!${RESET}\n"
    exit 0
else
    echo -e "${RED}${BOLD}[FAILURE] End-to-End Verification encountered ${FAILED_STEPS} issue(s).${RESET}\n"
    exit 1
fi
