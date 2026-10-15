# Tasks: windowserver-insitu-composition

## Phase 1: Shared Protocol & Safe Payload Scaffold

- [x] 1.1 [REQ-WS-004, REQ-PRO-001] Create `native/shared/protocol.h` containing `HyprMessageHeader`, command enums (`HYPR_CMD_*`), payload structures, and protocol magic constants. (Note: protocol.h requires planned commands FOCUS, AUTH, and GLOBAL_POLICY, along with expanded error codes).
- [x] 1.2 [REQ-WS-002, REQ-SAF-001] Create `native/server_hook/hook.c` with non-blocking constructor (`__attribute__((constructor))`) and safe-mode check for `/tmp/hyprmac.safemode`.
- [x] 1.3 [REQ-WS-003] Implement `pthread` worker entry in `hook.c` to handle structured logging to `/tmp/hyprserver.log`.
- [ ] 1.4 [REQ-WS-003, REQ-WS-004, REQ-WS-011] Implement non-blocking Unix Domain Socket server at `/tmp/hyprmac-server.sock` with message framing and ping/pong handling. (Note: Current implementation uses blocking accept(); kqueue migration planned.)
- [x] 1.5 Add build target / Makefile to compile `libhyprserver.dylib` for `arm64` / `arm64e` with hardened runtime exceptions.
- [x] 1.6 [REQ-WS-012, REQ-SEC-001] Ensure socket path `/tmp/hyprmac-server.sock` is accessible to both WindowServer (UID 88) and HyprMac client with 0666 permissions and stale file cleanup. (Note: Socket must be world-readable/writable because WindowServer (UID 88) creates it and the user client (UID 501) connects. Security is enforced via HYPR_CMD_AUTH token authentication, not filesystem permissions.)
- [x] 1.7 Integrate C/Assembly compilation targets into `Makefile` producing codesigned `hypr-inject` and `libhyprserver.dylib`.
- [ ] 1.8 [REQ-SAF-001] Implement log rotation and size capping for `/tmp/hyprserver.log` (1MB cap per file, up to 3 rotations capping total footprint at 4MB).

#### Task 1.4 — Socket Server & Event Multiplexing

**Objective**: Host a robust local Unix Domain Socket inside `WindowServer` without blocking compositor operations.

**Subtasks**:
- Bind AF_UNIX stream socket at `/tmp/hyprmac-server.sock`.
- Set socket receive and send timeouts to prevent unbounded worker thread stalls.
- Current implementation uses sequential blocking `accept()` loop in a detached pthread; migrate to `kqueue` non-blocking event loop to multiplex multiple client connections and prevent stalls.
- Parse 20-byte `HyprMessageHeader`, validate `HYPR_MAGIC` and `HYPR_PROTO_VERSION`, and dispatch commands.

**Acceptance Criteria**:
- Socket responds to `HYPR_CMD_PING` with `HYPR_CMD_PONG` containing valid server version.
- Malformed packets return `HYPR_CMD_ERROR` without terminating the background worker thread.

**Dependencies**: Tasks 1.1, 1.2, 1.3.

#### Task 1.6 — Socket Path & Permission Setup

**Objective**: Ensure the IPC socket path is accessible to both WindowServer (UID 88) and HyprMac client processes.

**Subtasks**:
- Use `/tmp/hyprmac-server.sock` as the canonical socket path (world-writable sticky directory, accessible to UID 88).
- In the hook's initialization worker, unlink any stale socket file before calling `bind()`.
- Set socket file permissions to `0666` via `chmod()` (world-readable and world-writable). Socket must be world-readable/writable because WindowServer (UID 88) creates it and the user client (UID 501) connects. Security is enforced via `HYPR_CMD_AUTH` token authentication, not filesystem permissions.
- Validate that the socket path does not exceed `sockaddr_un.sun_path` capacity (104 bytes).

**Acceptance Criteria**:
- Hook successfully binds the socket when running as UID 88 inside WindowServer.
- HyprMac client connects cleanly to the socket from a standard user session (UID 501).
- Stale socket files from previous sessions are cleaned up automatically without orphaned socket errors.

**Dependencies**: Tasks 1.1, 1.2.

#### Task 1.7 — Native Build System Integration

**Objective**: Integrate C/Assembly compilation targets into the project build system.

**Subtasks**:
- Create a `Makefile` at the project root that compiles:
  - `hypr-inject` (C + ARM64 ASM) -> executable binary.
  - `libhyprserver.dylib` (C) -> dynamic library with `__attribute__((constructor))`.
- Add compiler flags: `-arch arm64e`, `-target arm64e-apple-macos14.0`, and PAC-related flags (`-fptrauth-calls`, `-fptrauth-intrinsics`).
- Add `install_name_tool` step to set the dylib's install name to `@rpath/libhyprserver.dylib`.
- Document build prerequisites (Xcode CLT, SIP disabled for testing).
- Ensure the Swift Package Manager `Package.swift` build is not affected (parallel build systems).

**Acceptance Criteria**:
- `make all` produces `hypr-inject` and `libhyprserver.dylib` in `build/`.
- Both artifacts are signed for local development (`codesign -s -`).
- SPM `swift build` continues to work independently for HyprMac.

**Dependencies**: None (foundational task).

#### Task 1.8 — Log Rotation & Diagnostic File Capping

**Objective**: Prevent unbounded log growth in `/tmp/hyprserver.log` across long-running desktop sessions.

**Subtasks**:
- Inspect `/tmp/hyprserver.log` size before appending structured telemetry.
- If file size exceeds 1 MB (`HYPR_LOG_MAX_SIZE`), rotate to `/tmp/hyprserver.log.1` (with up to 3 rotations: `.1`, `.2`, `.3`).
- Ensure log writes remain guarded by `os_unfair_lock` to prevent interleaved output across concurrent threads.

**Acceptance Criteria**:
- `/tmp/hyprserver.log` does not exceed 1 MB per file and total rotated log footprint does not exceed 4 MB on disk.
- Log rotation does not block or stall the server hook.

**Dependencies**: Task 1.3.

[CHECKPOINT: Phase 1 Safety Sign-off]
- precondition_probe: `test -f /tmp/hyprmac.safemode || ls -la /tmp/hyprmac-server.sock`
- pass_criteria: Wire protocol header size exactly 20 bytes (`#pragma pack(push, 1)`), socket bound with 0666 permissions allowing cross-UID (88/501) communication, and safe-mode tombstone halts initialization before thread or memory allocation.
- rollback_action: `rm -f /tmp/hyprmac-server.sock && touch /tmp/hyprmac.safemode`

---

## Phase 2: Mach Task Port Injector

- [x] 2.1 [REQ-WS-001, REQ-SEC-001] Create `native/injector/main.c` to resolve `WindowServer` PID and verify root UID privileges.
- [x] 2.2 [REQ-WS-001, REQ-INJ-002] Implement `task_for_pid()` resolution and error reporting for kernel security denials.
- [x] 2.3 [REQ-INJ-005] Implement remote page allocation and path write via `mach_vm_allocate()` and `mach_vm_write()`.
- [x] 2.4 [REQ-INJ-005] Implement two-stage runtime attachment: Stage 1 assembly sequence calls `pthread_create_from_mach_thread` on raw Mach thread; Stage 2 pthread calls `dlopen`. ASLR slide delta resolution via `task_info(TASK_DYLD_INFO)`. PAC signing with `ptrauth_sign_unauthenticated` before `_thread_convert_thread_state`.
- [x] 2.5 [REQ-SEC-002] Sign `libhyprserver.dylib` with Developer ID certificate (`8N5N254R3B`) for WindowServer library validation (`CS_REQUIRE_LV`).
- [x] 2.6 [REQ-INJ-004, REQ-PRF-001] Add handshake verification in `hypr-inject` that polls for socket file `/tmp/hyprmac-server.sock` and asserts `WindowServer` PID stability.
- [x] 2.7 [REQ-WS-002, REQ-SAF-001] Add automatic safe-mode rollback trigger: if `WindowServer` PID changes within 500ms, touch `/tmp/hyprmac.safemode`.

#### Task 2.4 — Two-Stage Runtime Attachment Implementation

**Objective**: Execute privileged dynamic library load inside `WindowServer` via two-stage runtime attachment to guarantee Thread-Local Storage (TLS) initialization and prevent `pthread_getspecific` crashes.

**Subtasks**:
- Allocate 16 KB remote stack via `mach_vm_allocate()` and protect as `VM_PROT_READ | VM_PROT_WRITE`.
- Allocate 4 KB remote code page (`VM_PROT_READ | VM_PROT_EXECUTE`) containing ARM64e assembly bootstrap routine (`g_code_payload`).
- Write parameter block containing target dylib path and data slots for resolved symbols.
- Resolve shared cache ASLR slide delta between local loader and remote `WindowServer` using `task_info(TASK_DYLD_INFO)` on both local and target tasks.
- Adjust `pthread_create_from_mach_thread` and `dlopen` function addresses by the computed slide delta and populate code page data slots.
- Sign Stage 1 entry pointer with `ptrauth_sign_unauthenticated` using `ptrauth_key_asia`.
- Convert loader thread state to target process PAC domain via `_thread_convert_thread_state(thread, 2, ARM_THREAD_STATE64, ...)`.
- On macOS >= 14.4, launch execution via `thread_create_running()`; on earlier versions, use `thread_set_state()` and `thread_resume()`.
- Stage 1 executes on the raw Mach thread, invoking `pthread_create_from_mach_thread` to spawn Stage 2 on a real POSIX thread with full TLS (`TPIDRRO_EL0`), then spins writing the readiness marker `0x79616265` (`yabe`) into register `x0`.
- Stage 2 pthread invokes `dlopen(dylib_path, RTLD_LAZY)` safely with initialized TLS.
- Poll Stage 1 thread registers for `0x79616265` readiness marker, verify socket emergence, and terminate the Stage 1 Mach thread cleanly.

**Acceptance Criteria**:
- `libhyprserver.dylib` loads into `WindowServer` without causing a kernel panic, Mach exception, or `pthread_getspecific` crash.
- Remote Stage 1 thread confirms readiness via `0x79616265` marker and terminates cleanly after initialization.

**Dependencies**: Tasks 2.1, 2.2, 2.3.

#### Task 2.5 — Developer ID Signing for Library Validation

**Objective**: Sign `libhyprserver.dylib` with a valid Developer ID certificate to satisfy WindowServer Library Validation enforcement (`CS_REQUIRE_LV`).

**Subtasks**:
- Identify WindowServer code-signing enforcement policy requiring Library Validation (`CS_REQUIRE_LV`).
- Configure codesigning pipeline to sign `libhyprserver.dylib` with Developer ID Application certificate `8N5N254R3B`.
- Verify signature integrity via `codesign -dvvv build/libhyprserver.dylib`.
- Validate that WindowServer accepts the dylib without dyld security violation termination.

**Acceptance Criteria**:
- `libhyprserver.dylib` successfully passes WindowServer's Library Validation check on load.
- Dyld does not reject the dylib with code-signing or trust-cache errors.

**Dependencies**: Tasks 1.5, 1.7.

#### Task 2.6 — Handshake & Crash Watchdog Verification

**Objective**: Assert post-injection stability and detect immediate WindowServer crashes.

**Subtasks**:
- Poll `access(HYPR_SOCKET_PATH, F_OK)` at `/tmp/hyprmac-server.sock` for up to 10 seconds (100 iterations of 100ms).
- Once socket appears, pause execution for 500ms.
- Re-query WindowServer PID via `pgrep -x WindowServer`.
- Assert that post-injection PID equals pre-injection PID.
- If PID mismatch is detected, touch `/tmp/hyprmac.safemode` and exit with error code 1.

**Acceptance Criteria**:
- Stable injection exits with status code 0.
- Detection of an already-loaded hook exits with status code 2 without mutating process memory.
- Crashes trigger immediate safe-mode tombstone creation.

**Dependencies**: Tasks 2.1–2.5.

[CHECKPOINT: Phase 2 Safety Sign-off]
- precondition_probe: `csrutil status && nvram boot-args && pgrep -x WindowServer`
- pass_criteria: SIP confirmed disabled (`CSR_ALLOW_TASK_FOR_PID`), boot-args contain `-arm64e_preview_abi`, Developer ID code signature valid on `libhyprserver.dylib`, two-stage attachment completes without crashing WindowServer, and PID remains unchanged across a 500ms post-attachment window.
- rollback_action: `touch /tmp/hyprmac.safemode && killall -9 hypr-inject`

---

## Phase 3: Telemetry & Internal Symbol Discovery

- [ ] 3.1 [REQ-WS-003, REQ-SAF-001] Implement safe symbol resolution in `libhyprserver.dylib` using `dlsym()` on `RTLD_DEFAULT` with `SIGSEGV` sandboxing.
- [ ] 3.2 [REQ-WS-009] Probe and log `WindowServer` internal state: resolve `SLSMainConnectionID()`, active displays, and registered window IDs.
- [ ] 3.3 [REQ-WS-005, REQ-WS-006] Validate server-level connection authority: verify that `SLSSetWindowTags` called from inside `WindowServer` updates tags without silent drops.
- [ ] 3.4 [REQ-WS-005, REQ-WS-006, REQ-WS-007] Implement `SLSNewWindow` / `CGSNewWindow` interposition to apply decorations at window creation time, preventing 1-frame decoration flash on new windows.

#### Task 3.4 — Window Interposition Hook

**Objective**: Intercept window creation events at the WindowServer level to apply decorations immediately upon window instantiation.

**Subtasks**:
- Implement `SLSNewWindow` / `CGSNewWindow` interposition hook inside `hook.c`.
- Apply initial decoration properties (corner radius, shadow suppression, border state) during window creation.
- Prevent the 1-frame unstyled/native decoration flash before client configuration arrives.

**Acceptance Criteria**:
- Newly created windows instantiate with configured decoration rules immediately.
- Zero observed 1-frame visual flash on window appearance.

**Dependencies**: Tasks 3.1–3.3 (Phase 3 symbol discovery).

[CHECKPOINT: Phase 3 Safety Sign-off]
- precondition_probe: `cat /tmp/hyprserver.log | grep -E "(SLSMainConnectionID|symbols)"`
- pass_criteria: Private symbol lookup wrapped in `sigaction` (`SIGSEGV`/`SIGBUS`) sandboxing, server connection ID `SLSMainConnectionID()` resolved successfully, and tag modifications verified non-dropping in read-only validation.
- rollback_action: `touch /tmp/hyprmac.safemode && kill -HUP $(pgrep -x WindowServer)`

---

## Phase 4: Active Window Modification (Corners & Shadows)

- [ ] 4.1 [REQ-WS-006] Implement `HYPR_CMD_SET_SHADOW_STATE` handler in `hook.c` using server connection credentials to disable window drop shadows.
- [ ] 4.2 [REQ-WS-005] Implement `HYPR_CMD_SET_CORNER_RADIUS` handler in `hook.c` to force 0px clipping mask on target `CGSWindowID`.
- [ ] 4.3 [REQ-WS-007] Implement `HYPR_CMD_SET_WINDOW_BORDER` handler in `hook.c` to render borders with active/inactive colors.
- [ ] 4.4 [REQ-WS-008] Implement `HYPR_CMD_STRIP_TITLEBAR` handler in `hook.c` to hide titlebar and expand content area.
- [ ] 4.5 [REQ-WS-005, REQ-WS-006, REQ-PRF-001] Trigger surface cache invalidation on the modified window to force instantaneous display recomposition.
- [ ] 4.6 [REQ-WS-009] Implement `HYPR_CMD_QUERY_WINDOW` handler in `hook.c` to query decoration state of managed windows.
- [ ] 4.7 [REQ-WS-013] Implement `HYPR_CMD_SET_WINDOW_FOCUS` handler in `hook.c` to track focused window ID and switch border colors between active and inactive.
- [ ] 4.8 [REQ-WS-014] Implement window destruction detection in `hook.c` with a managed window hash map to purge stale entries and return `HYPR_ERR_INVALID_WID`.
- [ ] 4.9 [REQ-MON-002] Implement display reconfiguration observer in `hook.c` to detect monitor connect/disconnect and re-bind display surfaces within one refresh cycle.
- [ ] 4.10 [REQ-WSP-001] Implement Mission Control and Stage Manager space change notification observer in `hook.c` to prevent visual artifacts and stale clipping masks.

#### Task 4.3 — Implement `HYPR_CMD_SET_WINDOW_BORDER` Handler

**Objective**: Handle border rendering commands inside `hook.c`.

**Subtasks**:
- Parse `HyprPayloadBorder` from incoming IPC frame.
- Resolve the target `CGSWindowID` and apply border properties using the discovered compositor API (Phase 3 symbol resolution).
- Support active/inactive border colors with focus-state-aware transitions.
- Render the border below the shadow layer (if present) or directly adjacent to the window surface.
- Acquire `os_unfair_lock` before mutating border state; release immediately after.

**Acceptance Criteria**:
- Sending `HYPR_CMD_SET_WINDOW_BORDER` with `border_width=1.0` renders a visible 1px border.
- Sending `border_width=0.0` removes the border with no residual artifacts.
- Focus change transitions border color within one display refresh cycle.

**Dependencies**: Task 4.1 (shadow handler establishes the mutation pattern), Tasks 3.1–3.3 (symbol discovery).

#### Task 4.4 — Implement `HYPR_CMD_STRIP_TITLEBAR` Handler

**Objective**: Handle titlebar stripping commands inside `hook.c`.

**Subtasks**:
- Parse `HyprPayloadStripTitlebar` from incoming IPC frame.
- Resolve the target window and modify its titlebar visibility via the discovered compositor API.
- Ensure content area expands to fill the titlebar space when stripped.
- Support restoration (`strip=0`) to re-enable native titlebar rendering.
- Acquire `os_unfair_lock` before mutating titlebar state.

**Acceptance Criteria**:
- Sending `HYPR_CMD_STRIP_TITLEBAR` with `strip=1` hides the titlebar and expands content.
- Sending `strip=0` restores the titlebar and shrinks content area.

**Dependencies**: Task 4.2 (corner handler), Tasks 3.1–3.3 (symbol discovery).

#### Task 4.5 — Surface Cache Invalidation

**Objective**: Force instantaneous display recomposition after window property mutations.

**Subtasks**:
- Trigger surface cache invalidation on modified `CGSWindowID`.
- Ensure changes to corner radius, shadow state, and borders reflect on the immediate next frame without visual tearing or caching artifacts.

**Acceptance Criteria**:
- Window modifications become visible without requiring window focus toggles or window movement.

**Dependencies**: Tasks 4.1–4.4.

#### Task 4.6 — Implement `HYPR_CMD_QUERY_WINDOW` Handler

**Objective**: Support querying current decoration state of managed windows.

**Subtasks**:
- Parse `HyprPayloadQueryRequest` from incoming IPC frame.
- Look up the window by `window_id` in the managed window registry.
- If found, respond with `HYPR_CMD_ACK` + `HyprPayloadQueryResponse` containing current `corner_radius`, `shadow_enabled`, `titlebar_stripped`, `border_color`, and `border_width`.
- If not found, respond with `HYPR_CMD_ERROR` + error code `INVALID_WID (0x0001)`.

**Acceptance Criteria**:
- Query on a managed window returns accurate current state.
- Query on a non-existent window ID returns `HYPR_CMD_ERROR`.

**Dependencies**: Tasks 4.1–4.4 (all manipulation handlers).

#### Task 4.7 — Focus State Tracking

**Objective**: Track window focus state inside `hook.c` and dynamically switch border colors.

**Subtasks**:
- Implement `HYPR_CMD_SET_WINDOW_FOCUS` handler in `hook.c`.
- Track currently focused window ID in server state.
- Switch border colors between active and inactive configurations on focus changes.
- Swift bridge sends focus commands via `NSWorkspace.didActivateApplicationNotification` and window focus observers.

**Acceptance Criteria**:
- Focused window immediately displays active border color.
- Previously focused window transitions to inactive border color within one display refresh cycle.

**Dependencies**: Task 4.3 (border handler).

#### Task 4.8 — Window Destruction Lifecycle

**Objective**: Track window lifecycle events to prevent stale window references and resource leaks.

**Subtasks**:
- Implement window destruction detection in `hook.c`.
- Maintain an internal hash map of managed window IDs.
- Clean up stale entries and state mappings when windows are destroyed.
- Return `HYPR_ERR_INVALID_WID` for incoming IPC commands targeting destroyed or nonexistent windows.

**Acceptance Criteria**:
- Window close/destruction automatically cleans up internal tracking entries.
- Operations on closed window IDs fail-closed and return `HYPR_ERR_INVALID_WID` error response.

**Dependencies**: Tasks 4.1–4.6.

#### Task 4.9 — Display Reconfiguration Observer

**Objective**: Detect monitor connect/disconnect and dynamically re-bind display surfaces.

**Subtasks**:
- Register CoreGraphics display reconfiguration callback inside `hook.c`.
- Detect display hotplugs, resolution changes, and refresh rate adjustments.
- Re-evaluate active display attachments for all managed windows within one refresh cycle.

**Acceptance Criteria**:
- Adding or removing an external display does not crash WindowServer or leak memory.
- Window borders remain synchronized to their active monitor's refresh rate.

**Dependencies**: Tasks 4.1–4.3.

#### Task 4.10 — Mission Control & Space Transition Observer

**Objective**: Maintain decoration consistency across virtual space transitions and Mission Control invocations.

**Subtasks**:
- Listen for workspace switch notifications inside `hook.c`.
- Quiesce transient clipping re-computations during Mission Control scale animations.
- Re-assert corner clipping masks and border layers upon completion of space changes.

**Acceptance Criteria**:
- Zero orphaned border layers or visual tearing during Mission Control activation.
- Decorations persist across transitions between virtual desktops.

**Dependencies**: Tasks 4.1–4.5.

[CHECKPOINT: Phase 4 Safety Sign-off]
- precondition_probe: `test -S /tmp/hyprmac-server.sock && pgrep -x WindowServer`
- pass_criteria: All window mutations (`corner_radius`, `shadow_state`, `border`, `titlebar`) execute reversibly under `os_unfair_lock`, closed windows return `HYPR_ERR_INVALID_WID` without memory leaks, and display hotplug / space transitions produce zero visual artifacts or crashes.
- rollback_action: Execute client `restoreNativeStyle()` across all windows, or unlink `/tmp/hyprmac-server.sock` and touch `/tmp/hyprmac.safemode`.

---

## Phase 5: Swift Integration & CLI Surface

- [x] 5.1 [REQ-WS-010, REQ-WS-011, REQ-WS-012] Create `Sources/HyprMac/Bridge/HyprServerBridge.swift` implementing socket client connection, serialization, and async query/mutation methods. (Substantially implemented; remaining work: 64-item command replay buffer and HYPR_CMD_AUTH handshake).
- [ ] 5.2 [REQ-WS-010, REQ-SAF-002] Update `Sources/HyprMac/Bridge/SkyLightBridge.swift` to route `stripTitlebar` and decoration changes through `HyprServerBridge` when active.
- [ ] 5.3 [REQ-WS-010] Implement 64-item ring buffer command replay queue in `HyprServerBridge.swift` to buffer commands during disconnection and replay in FIFO order upon reconnection.
- [ ] 5.4 [REQ-WS-010, REQ-SAF-002] Modify `BorderWindow.swift` to disable AppKit window overlays when in-situ hook is active, with graceful fallback within 500ms upon disconnection.
- [ ] 5.5 [REQ-WS-005, REQ-WS-006] Add CLI commands in `Sources/HyprMac/main.swift`:
  - `hyprmac server-status`: Check if `libhyprserver.dylib` is active in `WindowServer`.
  - `hyprmac square <wid>`: Force 0px corner radius on window.
  - `hyprmac strip-shadow <wid>`: Eliminate shadow on window.
- [ ] 5.6 [REQ-WS-005, REQ-WS-006, REQ-PRF-001] End-to-end verification: verify 0px corners and shadowless rendering on live windows (e.g. Safari, Terminal) without visual lag.

#### Task 5.1 — Swift Client Bridge Implementation & Spec Alignment

**Objective**: Implement pure Swift client interface for Unix domain socket communication with `libhyprserver.dylib`.

**Status**: Substantially implemented (~685 lines in `Sources/HyprMac/Bridge/HyprServerBridge.swift`). Connection handling, framed header serialization, ping/pong, and decoration commands (`setCornerRadius`, `setShadow`, `setBorder`, `setTitlebar`, `queryWindow`) are active. Remaining work tracked in Task 5.3 (replay queue) and auth handshake.

**Subtasks**:
- Maintain serial dispatch queue (`com.hyprmac.server-bridge.ipc`) for thread-safe wire transactions.
- Implement exponential backoff reconnection logic (100ms initial delay, 5.0s max delay, 10 attempts).
- Align payload size limits: update client ceiling from 64 KB to 4,096 bytes per `REQ-WS-011`.
- Implement `HYPR_CMD_AUTH` handshake once wire token protocol is finalized (`REQ-WS-012`).
- Implement `HYPR_CMD_SET_WINDOW_FOCUS` bridge method (`REQ-WS-013`).

**Acceptance Criteria**:
- `HyprServerBridge.shared.ping()` returns true when hook is active.
- Bridge gracefully emits `hyprServerHookUnavailable` notification upon socket disconnection.

**Dependencies**: Phase 1 protocol, Phase 4 handlers.

#### Task 5.3 — Command Replay Queue

**Objective**: Ensure command delivery resilience during transient socket disconnections or WindowServer restarts.

**Subtasks**:
- Implement a 64-item ring buffer in `HyprServerBridge.swift`.
- Queue outgoing commands when socket connection is unavailable or dropped.
- Replay queued commands in strict FIFO order upon reconnection.

**Acceptance Criteria**:
- Commands issued during socket downtime are preserved and flushed upon reconnect.
- Ring buffer handles overflow safely without crashing or corrupting message order.

**Dependencies**: Task 5.1 (Swift bridge implementation).

#### Task 5.4 — BorderWindow Overlay Bypass

**Objective**: Disable duplicate AppKit window overlays when in-situ WindowServer decoration is active, with safe fallback.

**Subtasks**:
- Modify `BorderWindow.swift` to disable AppKit window overlays when the in-situ hook is active.
- Implement graceful fallback: when hook disconnects, re-enable BorderWindow overlays within 500ms.

**Acceptance Criteria**:
- Zero overlay rendering overhead when in-situ hook is active.
- Overlay decorations seamlessly restore within 500ms if in-situ hook disconnects.

**Dependencies**: Task 5.2 (SkyLightBridge update).

[CHECKPOINT: Phase 5 Safety Sign-off]
- precondition_probe: `swift test --filter HyprServerBridgeTests`
- pass_criteria: Disconnection of `/tmp/hyprmac-server.sock` falls back cleanly to AppKit `BorderWindow` overlays within 500ms, reconnection replays FIFO buffer without duplication, and zero rendering conflict occurs between AppKit overlays and in-situ borders.
- rollback_action: Unset server bridge active flag to fall back permanently to AppKit `BorderWindow` overlay pipeline.

---

## Phase 6: Integration Testing & LaunchDaemon Deployment

- [ ] 6.1 [REQ-WS-004, REQ-WS-011, REQ-WS-012] Integration Test Harness: Build `test-server-wire` C test binary covering protocol framing, all command types, error responses, and max payload rejection.
- [ ] 6.2 [REQ-INJ-001, REQ-INJ-002, REQ-INJ-003, REQ-SAF-001] LaunchDaemon Plist: Create `com.hyprmac.inject.plist` for `/Library/LaunchDaemons/` to auto-inject on login, respawn on crash, and log to `/tmp/hyprmac-inject.log`.
- [ ] 6.3 [REQ-MON-001] Multi-display stress testing with 50+ windows across mixed refresh rate monitors (120Hz ProMotion + 60Hz/144Hz external) validating frame pacing and zero visual judder.

#### Task 6.1 — Integration Test Harness

**Objective**: Build an automated integration test harness in C for socket protocol verification.

**Subtasks**:
- Build `test-server-wire` C test binary.
- Test protocol framing, all command types, error responses, and max payload rejection.

**Acceptance Criteria**:
- All tests pass with exit code 0.
- Over-sized payloads exceeding maximum buffer limits reject cleanly.

**Dependencies**: Phase 1 protocol, Phase 4 handlers.

#### Task 6.2 — LaunchDaemon Plist

**Objective**: Create and install the LaunchDaemon plist for automated `hypr-inject` execution and lifecycle persistence.

**Subtasks**:
- Create `/Library/LaunchDaemons/com.hyprmac.inject.plist` with:
  - `ProgramArguments`: path to `hypr-inject` binary.
  - `RunAtLoad`: true (auto-injects on login).
  - `UserName`: root.
  - `KeepAlive`: true (respawn on crash).
  - `StandardOutPath` / `StandardErrorPath`: `/tmp/hyprmac-inject.log`.
- Add a pre-flight check in `hypr-inject` that verifies SIP is disabled (`csrutil status`) and exits with a diagnostic message if SIP is active.
- Add an `--uninstall` flag to `hypr-inject` that removes the LaunchDaemon plist and touches `/tmp/hyprmac.safemode`.
- Document the installation procedure in the project README.

**Acceptance Criteria**:
- Auto-injects on login, respawns on crash, and logs to `/tmp/hyprmac-inject.log`.
- `hypr-inject --uninstall` cleanly removes the daemon and prevents future injection.
- SIP-enabled systems receive a clear error message instead of a cryptic failure.

**Dependencies**: Tasks 2.1–2.7 (injector complete), Tasks 5.1–5.4 (Swift bridge & overlays).

#### Task 6.3 — Multi-Display Stress Testing with 50+ Windows

**Objective**: Validate compositor stability and frame pacing across heterogeneous display topologies under heavy window loads.

**Subtasks**:
- Instantiate 50+ active managed application windows across dual displays (internal 120Hz ProMotion + external 60Hz/144Hz).
- Automate rapid window focus switching and workspace panning.
- Monitor `CVDisplayLink` inter-callback intervals and memory consumption of `WindowServer` over a 15-minute test run.

**Acceptance Criteria**:
- Zero `WindowServer` crashes or Mach port leaks over 15 minutes.
- Frame callback jitter remains strictly under 25ms on 60Hz displays and 12.5ms on 120Hz displays.
- Visual borders and corner clipping masks render without tearing or lingering artifacts.

**Dependencies**: Tasks 4.1–4.10, Phase 5 bridge integration.

[CHECKPOINT: Phase 6 Production Deployment Sign-off]
- precondition_probe: `launchctl list | grep com.hyprmac.inject`
- pass_criteria: `hypr-inject --uninstall` cleanly unloads LaunchDaemon, unlinks socket and logs, engages safe-mode tombstone, wire protocol fuzzing passes without memory corruption, and 50+ window multi-display stress test maintains frame pacing without compositor drops (<25ms jitter).
- rollback_action: `sudo launchctl bootout system /Library/LaunchDaemons/com.hyprmac.inject.plist && sudo rm -f /Library/LaunchDaemons/com.hyprmac.inject.plist /tmp/hyprmac.safemode`
