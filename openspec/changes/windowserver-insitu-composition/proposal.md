# Proposal: windowserver-insitu-composition

## Intent

Implement a native, in-situ window composition subsystem for HyprMac that injects directly into macOS's root compositor daemon, `WindowServer` (`/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer`). This bypasses client-side IPC isolation in `SkyLight.framework` to achieve true Wayland/Hyprland window styling: zero-pixel corner radii and eliminated drop shadows in-situ.

*(Status Note on Border Rendering: Native in-situ border drawing inside WindowServer is **NOT YET IMPLEMENTED**; `hook.c` currently only records border attributes in its managed window registry. Border rendering continues to be handled via AppKit floating overlay panels implemented in `BorderWindow.swift`).*

## Scope

### In Scope
- Mach task port loader (`hypr-inject`) executing privileged two-stage runtime attachment into `WindowServer` (UID 88 / `_windowserver`; WindowServer's PID is dynamically assigned by `launchd` at boot and varies across restarts, resolved at runtime via `pgrep WindowServer` or by scanning the process table). Remote execution utilizes a two-stage architecture to ensure thread-local storage (TLS) availability:
  - **Stage 1 (Raw Mach Thread Bootstrap)**: The loader allocates a remote 16 KB stack (`VM_PROT_READ | VM_PROT_WRITE`), a 4096-byte code page (`VM_PROT_READ | VM_PROT_EXECUTE`), and writes a parameter block with resolved symbol addresses and the target dylib path. Entry points for `pthread_create_from_mach_thread` and `dlopen` are resolved from the shared cache and adjusted using a cross-process ASLR slide delta calculated via `task_info(TASK_DYLD_INFO)`. An ARM64e assembly sequence is written to the code page with its entry point signed via `ptrauth_sign_unauthenticated` (`ptrauth_key_asia`, 0). The loader converts the thread state to the target PAC domain via `_thread_convert_thread_state` and launches execution via `thread_create_running` (macOS ≥14.4) or `thread_set_state` + `thread_resume` (macOS <14.4). On the raw Mach thread, Stage 1 invokes `pthread_create_from_mach_thread` (which establishes a dedicated stack and initializes TLS registers) to spawn Stage 2 on a real POSIX thread, then enters a spin loop writing the readiness marker `0x79616265` (`yabe`) into register `x0`.
- **Stage 2 (POSIX Pthread with TLS)**: The newly created pthread, running with full Thread-Local Storage (`TPIDRRO_EL0` populated), safely executes Stage 2: invoking `dlopen(path, RTLD_LAZY)` to load `libhyprserver.dylib`. While the native Makefile defaults to ad-hoc codesigning (`SIGN_IDENTITY ?= -`), Developer ID codesigning is supported via `make SIGN_IDENTITY="Developer ID Application: ..."` to satisfy WindowServer Library Validation (`CS_REQUIRE_LV`) in hardened environments. Once the loader polls and detects the `0x79616265` readiness marker and verifies readiness probe availability via `/tmp/hyprserver.ready` (`HYPR_READY_PATH`), the Stage 1 Mach thread is cleanly terminated.
- **Dylib Staging (`stage_dylib_for_windowserver`)**: `hypr-inject` stages `libhyprserver.dylib` to `/Library/GPUBundles/libhyprserver.dylib` (mode `0644`) before triggering runtime attachment because `WindowServer` (UID 88 / `_windowserver`) cannot access user home directories due to path traversal permissions, and sandbox constraints block executable mappings from world-writable directories such as `/tmp/`.
- Defensive in-process payload (`libhyprserver.dylib`) running a decoupled POSIX worker thread polling shared memory ring buffers, and diagnostic logging to `/tmp/hyprserver.log` (with single-file rotation to `/tmp/hyprserver.log.1`, capping footprint at ~2MB).
- Dedicated local IPC channel over file-backed shared memory (`/tmp/hyprmac-ipc.shm`, 64KB, `MAP_SHARED`, mode `0666`) featuring dual lock-free ring buffers: Command Ring (Swift→Hook, 32KB) and Response Ring (Hook→Swift, 31KB) with atomic acquire/release synchronization, eliminating BSD socket operations because the `WindowServer` sandbox (`com.apple.WindowServer.sb`) blocks ALL BSD socket operations.
- Dynamic Mach-O symbol interposition (`rebind_image_symbols`) intercepting `SLSNewWindow` / `CGSNewWindow` to apply decoration policies at window creation, eliminating 1-frame unstyled flicker.
- Server-side CGS execution using `SLSMainConnectionID()` inside `WindowServer` to modify window tags and shadow properties.
- Invocation of private SkyLight C-APIs (dynamically resolved `SLSWindowSetCornerRadius` / `SLSSetWindowCornerMask`) with root connection credentials (`SLSMainConnectionID()`) to enforce 0px square corners, rather than raw struct memory patching.
- Circuit breaker failsafe (`/tmp/hyprmac.safemode`) to prevent recurring WindowServer bootloops.
- Swift client bridge (`Sources/HyprMac/Bridge/HyprServerBridge.swift`) with 64-command ring buffer replay and shared memory ring buffer IPC integrating into existing `HyprMac` CLI commands (`server-status`, `square`, `strip-shadow`, `test-bridge`).

### Out of Scope
- Direct KMS/DRM display driver replacement (impossible without custom kernel extensions).
- Modifying Cocoa event loops or replacing Quartz WindowServer event distribution.
- Bypassing SIP on systems where SIP is enabled (the user host already has SIP disabled and `-arm64e_preview_abi` active).
- Wayland Linux application compatibility layers (Xwayland / Wayland protocol endpoints).

### Edge Cases & System Transitions (In Scope)
- **Multi-monitor setups with heterogeneous refresh rates**: Rendering and border synchronization across mixed ProMotion (120Hz variable refresh rate on internal Apple Silicon displays) and fixed external monitors (60Hz / 144Hz) without tearing, judder, or frame pacing degradation.
- **Mission Control / Stage Manager / full-screen transitions**: Managing temporary window layer reparenting, workspace virtualization, and Stage Manager animations without leaving orphaned border masks or crashing the compositor during native macOS space switching.
- **Fast User Switching / Lock Screen session transitions [PLANNED, NOT IMPLEMENTED]**: Responding to console lock/unlock events and Fast User Switching where WindowServer transitions the active console session to `loginwindow` or another user account (UID != 501), safely quiescing hook IPC dispatch and reconnecting cleanly on session reactivation. (Note: Multi-user session lifecycle handling is planned for a future release and is not currently implemented in `hook.c` or `hypr-inject`).

## Capabilities

### New Capabilities
- `windowserver-mach-injection`: Root-level Mach task port resolution, remote memory mapping (`mach_vm_write`), and ARM64 remote thread execution.
- `insitu-composition-hook`: In-process dylib inside `WindowServer` hosting file-backed shared memory ring buffer IPC (`/tmp/hyprmac-ipc.shm`), dynamic Mach-O `SLSNewWindow` interposition for zero-flicker window creation, and manipulating internal window properties.
- `hyprserver-ipc-driver`: Swift binary framed client communicating with the in-process server hook over file-backed shared memory dual ring buffers (`/tmp/hyprmac-ipc.shm`) with 64-slot command replay buffer.

### Modified Capabilities
- `SkyLightBridge`: Updated to route window attribute changes (strip titlebar, remove shadow, set corner radius, set border) through `HyprServerBridge` when the server hook is detected.
- `BorderWindow`: Retains active responsibility for border rendering via AppKit floating overlay windows. While designed to observe server hook lifecycle notifications (`.hyprServerHookAvailable`, `.hyprServerHookUnavailable`), in-situ border drawing inside WindowServer is **NOT YET IMPLEMENTED** in `hook.c` (which only stores border attributes in memory). AppKit overlay windows remain active for all border visual rendering.

## Approach

1. **Isolation First & Shared Memory IPC:** `libhyprserver.dylib` initializes defensively on a separate thread, leaving `WindowServer`'s main runloop untouched. Because the WindowServer sandbox (`com.apple.WindowServer.sb`) blocks ALL BSD socket operations, the IPC transport is implemented via file-backed shared memory at `/tmp/hyprmac-ipc.shm` (64KB, `MAP_SHARED`, mode `0666`). Communication uses dual lock-free ring buffers: a Command Ring (Swift→Hook, 32KB) and a Response Ring (Hook→Swift, 31KB) synchronized using atomic acquire/release memory fences. The worker thread polls the Command Ring via a non-blocking `kqueue` timer (`EVFILT_TIMER`) without blocking WindowServer's main runloop.
2. **Authority Escalation:** The hook leverages `WindowServer`'s internal connection ID (`SLSMainConnectionID`), which possesses root authority to change window tags without the silent rejections encountered by external processes.
3. **Structured Recovery:** Any injection failure automatically writes a circuit breaker tombstone to abort subsequent hooks until explicitly cleared.
4. **SLSNewWindow Dynamic Interposition (Zero-Flicker Creation):** The hook uses dynamic Mach-O image rebinding (`rebind_image_symbols`) across loaded and newly added dyld images (`_dyld_register_func_for_add_image`) to intercept `SLSNewWindow` and `CGSNewWindow`. When an application creates a window, the interposition immediately applies configured global decoration policies (0px square corners, stripped shadows/titlebars, custom borders) in-situ before the window's first composited frame is presented, completely eliminating 1-frame unstyled flicker.
5. **Dylib Staging & Readiness Signaling:** `hypr-inject` stages `libhyprserver.dylib` to `/Library/GPUBundles/libhyprserver.dylib` (mode `0644`) before initiating attachment because `WindowServer` (UID 88 / `_windowserver`) cannot access user home directories, and the sandbox forbids executable mappings from world-writable directories such as `/tmp/`. Following injection, `hypr-inject` confirms hook initialization by awaiting the creation of the readiness probe file `/tmp/hyprserver.ready` (`HYPR_READY_PATH`).

### Architecture Decision Record: Two-Stage Runtime Attachment vs. Direct dlopen
- **Context**: Initial prototypes attempted direct `dlopen` execution within `WindowServer` by allocating a remote stack and code stub, configuring thread registers (`PC = dlopen`, `x0 = path`, `x1 = RTLD_LAZY`, `LR = spin_stub`), and invoking `thread_create_running`.
- **Root Cause of Failure**: Direct `dlopen` caused an immediate and reproducible crash inside `WindowServer` at `pthread_getspecific + 4`. Under Apple Silicon macOS, threads created via raw Mach `thread_create` / `thread_create_running` have no POSIX execution context; their Thread-Local Storage (TLS) register `TPIDRRO_EL0` is zero (`0`). Dynamic linking via `dlopen` and library initialization routines in `libdyld` / `libsystem_c` immediately call functions that depend on TLS (`pthread_getspecific`, `pthread_self`, `os_log`). When `TPIDRRO_EL0` is null, offset dereferencing causes an unhandled `EXC_BAD_ACCESS` / `SIGSEGV` crash.
- **Decision**: Adopt a two-stage runtime attachment architecture:
  1. **Stage 1 (Bootstrap Routine)**: The raw Mach thread executes a minimal ARM64e assembly routine that invokes `pthread_create_from_mach_thread`. This function has a dedicated internal setup routine that constructs a full POSIX thread structure and initializes `TPIDRRO_EL0`. After dispatching `pthread_create_from_mach_thread`, the Stage 1 thread enters a spin loop writing the readiness marker `0x79616265` (`yabe`) into register `x0`.
  2. **Stage 2 (POSIX Pthread Execution)**: Stage 2 executes on the newly created `pthread` with fully initialized TLS, safely invoking `dlopen(dylib_path, RTLD_LAZY)`.
  3. **Cross-Process ASLR Delta Correction**: Memory addresses for `pthread_create_from_mach_thread` and `dlopen` are resolved in the loader's local space and translated to the target `WindowServer` address space by computing the shared cache ASLR slide delta via `task_info(TASK_DYLD_INFO)`.
  4. **Pointer Authentication (PAC)**: Entry point pointers are signed using `ptrauth_sign_unauthenticated` with key `ptrauth_key_asia` and converted into the target PAC domain via `_thread_convert_thread_state`.
  5. **Library Validation Compatibility**: While the build system defaults to ad-hoc code signing (`SIGN_IDENTITY ?= -`), Developer ID code signing is supported via `make SIGN_IDENTITY="Developer ID Application: ..."` to satisfy WindowServer's `CS_REQUIRE_LV` constraint when required.
- **Consequences**: Eliminates TLS-related compositor crashes, ensures deterministic attachment confirmation via marker polling, and successfully loads `libhyprserver.dylib` into `WindowServer`.

#### Resolution History (RC1–RC6 Engineering Sequence)
During development and integration testing of the runtime attachment subsystem, six successive critical failure modes (Release Candidates 1 through 6) were diagnosed and resolved:
- **RC1: TLS Crash**: Direct `dlopen` invocation on a raw Mach thread crashed reproducibly at `pthread_getspecific+4` due to missing TLS (`TPIDRRO_EL0 == 0`). Solved with the two-stage `pthread_create_from_mach_thread` architecture, creating a legitimate POSIX thread with initialized TLS before invoking `dlopen`.
- **RC2: ASLR Slide Mismatch**: Local `dlsym` addresses in `hypr-inject` diverged from WindowServer's address space due to differing shared-cache ASLR slides. Solved with dynamic `task_info(TASK_DYLD_INFO)` delta calculation to rebase all remote function pointers.
- **RC3: Library Validation**: When WindowServer enforces Library Validation (`CS_REQUIRE_LV`), ad-hoc codesigned dynamic libraries can be rejected even with SIP disabled. The build system supports overriding the default ad-hoc signing (`SIGN_IDENTITY ?= -`) with a trusted Developer ID certificate via `make SIGN_IDENTITY="Developer ID Application: ..."`.
- **RC4: Cross-Process PAC Failure**: Stage 2 assembly's standard `pacibsp` and `retab` instructions authenticated return addresses using process-local keys that mismatched in WindowServer, triggering PAC authentication traps on return. Solved by replacing `pacibsp`/`retab` with `nop`/`ret` (thread start routines executed via `pthread_create_from_mach_thread` do not need PAC frame signing).
- **RC5: Sandbox Blocks Executable Mapping from `/tmp/`**: WindowServer sandbox (`com.apple.WindowServer.sb`) forbids `mmap(PROT_EXEC)` from world-writable paths like `/tmp/`, causing `dlopen` to fail. Solved by staging `libhyprserver.dylib` via `hypr-inject` to `/Library/GPUBundles/libhyprserver.dylib` (mode `0644`), an authorized system location accessible to UID 88.
- **RC6: SkyLight Main-Thread Assertions**: Private SkyLight APIs (`SLSRegisterNotifyProc`, `SLSRegisterConnectionNotifyProc`, `SLSGetActiveDisplayList`) assert `pthread_main_np() != 0` within WindowServer. Calling them directly from the worker thread caused assertion abort crashes. Solved by dispatching all SkyLight registrations to the main runloop via `dispatch_async(dispatch_get_main_queue(), ^{ ... })` and completely removing `SLSRegisterNotifyProc` (using `RegisterConnectionNotifyProc` event 1401 instead).

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `hypr-inject` (new binary) | New | `[IMPLEMENTED]` Two-stage PAC-safe loader written in C11/ARM64e assembly. Stages `libhyprserver.dylib` to `/Library/GPUBundles/libhyprserver.dylib` (mode `0644`) and verifies readiness via `/tmp/hyprserver.ready`. |
| `libhyprserver.dylib` (new dylib) | New | `[IMPLEMENTED]` In-process hook library targeting `WindowServer`, hosting file-backed shared memory dual ring buffer IPC (`/tmp/hyprmac-ipc.shm`, 64KB), safe-mode circuit breaker, dynamic Mach-O `SLSNewWindow` interposition, and display link synchronization across heterogeneous refresh rates (120Hz/60Hz) and Stage Manager/Mission Control space switches. Writes readiness marker to `/tmp/hyprserver.ready`. *(Note: In-situ border drawing and multi-user session transitions are PLANNED, NOT IMPLEMENTED; hook.c only stores border attributes).* |
| `Sources/HyprMac/Bridge/HyprServerBridge.swift` | New | `[IMPLEMENTED]` Swift client adapter for IPC over file-backed shared memory (`/tmp/hyprmac-ipc.shm`); `CommandRingBuffer` (64 capacity) and shared memory dual ring buffer communication (Command/Response rings) are active. |
| `Sources/HyprMac/Bridge/SkyLightBridge.swift` | Modify | `[IMPLEMENTED]` Routes all window attribute and decoration calls (`stripTitlebar`, `restoreTitlebar`, `setCornerRadius`, `setShadow`, `setBorder`) through `HyprServerBridge.shared.isAvailable` when the server hook is active, falling back to private SkyLight APIs when unavailable. |
| `Sources/HyprMac/Render/BorderWindow.swift` | Modify | `[IMPLEMENTED / ACTIVE]` Manages AppKit floating overlay panels for border rendering. In-situ border drawing within WindowServer is NOT YET IMPLEMENTED in `hook.c` (only attribute storage is implemented); `BorderWindow` overlays therefore remain active rather than deactivated. |
| `Sources/HyprMac/main.swift` | Modify | `[IMPLEMENTED]` Fully implements `server-status`, `square`, `strip-shadow`, and `test-bridge` subcommands alongside existing CLI subcommands (`probe`, `border`, `strip`, `tile`, `daemon`, `bar`, `session`, `parse-config`, and `test-*` harnesses). |

## Threat Model & Blast Radius

#### Threat Model

| Threat | Likelihood | Impact | Mitigation |
|--------|-----------|--------|------------|
| **WindowServer crash during runtime attachment** | Medium | Critical — all GUI sessions terminate, user is logged out | Two-stage runtime attachment isolates `dlopen` onto a real pthread with full TLS (`TPIDRRO_EL0`), preventing immediate TLS crashes (`pthread_getspecific + 4`); ASLR slide delta is resolved dynamically via `TASK_DYLD_INFO`; safe-mode circuit breaker (`/tmp/hyprmac.safemode`); `launchd` auto-respawns WindowServer within ~1s; loader validates Mach-O header before thread creation |
| **WindowServer sandbox restrictions** | High | Critical — blocks Mach bootstrap, sockets, and execution | The WindowServer sandbox (`com.apple.WindowServer.sb`) blocks Mach bootstrap lookups (`kr=1100`), all BSD socket operations (`bind`, `connect`, `listen`), and forbids `mmap(PROT_EXEC)` from `/tmp/`. Mitigation: file-backed shared memory IPC (`/tmp/hyprmac-ipc.shm`, 64KB, `MAP_SHARED`, mode 0666) with dual lock-free ring buffers, and dylib staging to `/Library/GPUBundles/libhyprserver.dylib` (mode 0644). |
| **SkyLight thread assertions** | High | Critical — compositor crash (`SIGABRT` / assertion failure) | Private SkyLight registration APIs assert `pthread_main_np() != 0`. Invoking them on a secondary POSIX worker thread aborts WindowServer. Mitigation: dispatch all SkyLight callback registrations to the main runloop via `dispatch_async(dispatch_get_main_queue(), ^{ ... })`, and eliminate `SLSRegisterNotifyProc` in favor of connection notifications. |
| **Library validation rejection (`CS_REQUIRE_LV`)** | High | Critical — WindowServer rejects dylib load, aborting hook | WindowServer may enforce Library Validation (`CS_REQUIRE_LV`), where custom dynamic libraries signed ad-hoc fail verification. Mitigation: While the Makefile defaults to ad-hoc signing (`SIGN_IDENTITY ?= -`) for local development, Developer ID signing is fully supported via `make SIGN_IDENTITY="Developer ID Application: ..."` (with `--timestamp`) and loaded with `-arm64e_preview_abi` boot argument active. |
| **WindowServer deadlock or main thread freeze** | Low | Critical — GUI freezes without crashing; launchd does not auto-restart deadlocked processes | In-situ hook operates strictly on a dedicated detached worker thread with zero synchronous blocking on WindowServer's main runloop; IPC uses lock-free shared memory ring buffers with non-blocking polling; internal watchdog heartbeat self-terminates or triggers circuit breaker if compositor thread hangs. |
| **Double injection (duplicate hook load)** | Low | High — duplicate listener threads, port conflicts, undefined behavior | Idempotency guard via bootstrap port `com.hyprmac.server.hook`; injector checks before proceeding |
| **Data race on compositor structures** | Medium | High — visual corruption, potential crash | `os_unfair_lock` synchronization on all window property mutations (see design.md) |
| **Malicious IPC commands from unauthorized process** | Low | Medium — attacker could alter window decorations | File-backed shared memory at `/tmp/hyprmac-ipc.shm` created with mode `0666` to allow cross-privilege IPC across UID 88 (`_windowserver`) and UID 501 (user) in world-writable `/tmp`. Binary framed wire protocol validates header magic (`0x48534D49`), protocol version, message lengths, and atomic write/read sequence indices. Optional token authentication (`HYPR_CMD_AUTH`) via `/tmp/hyprmac-auth-token` (mode `0600`) validates caller credentials. |
| **macOS update changes private API layout** | High | Medium — hook fails to find symbols, falls back safely | Version manifest (`hypr-offsets.plist`); Phase 3 symbol discovery with graceful fallback; hook aborts initialization if required symbols are not found |
| **SIP re-enabled by user** | Medium | Low — injection fails cleanly | `hypr-inject` checks `csrutil status` before attempting `task_for_pid`; exits with diagnostic message |
| **Unbounded diagnostic log growth** | Low | Low — disk space exhaustion in `/tmp` | Log rotation policy enforced in `libhyprserver.dylib` (`[IMPLEMENTED]`): single rotation step via `rename(HYPR_LOG_PATH, HYPR_LOG_PATH_ROTATED)` rotating solely to `/tmp/hyprserver.log.1` when size exceeds 1MB (`HYPR_LOG_MAX_SIZE`), bounding maximum log footprint to ~2MB (active + 1 rotated). |

#### Cross-Privilege IPC & Security Note
WindowServer runs as daemon user `_windowserver` (UID 88), whereas the HyprMac client process runs in the user GUI session as UID 501. Because the WindowServer sandbox (`com.apple.WindowServer.sb`) blocks all BSD socket operations, communication is established over file-backed shared memory at `/tmp/hyprmac-ipc.shm` (64KB, `MAP_SHARED`, mode `0666`) located within `/tmp`. This permits bidirectional cross-privilege IPC between UID 88 and UID 501 without violating sandbox socket constraints. The transport consists of dual lock-free ring buffers (Command Ring Swift→Hook, Response Ring Hook→Swift) governed by atomic acquire/release memory fences. To prevent unauthorized local processes from sending arbitrary IPC commands, the binary framed wire protocol enforces strict header validation (magic `0x48534D49`, protocol version 1, payload length boundaries). Additionally, wire authentication via a shared secret token (`HYPR_CMD_AUTH`) is supported: `libhyprserver.dylib` generates a high-entropy 128-bit (16-byte) token via `arc4random_buf` written to `/tmp/hyprmac-auth-token` with mode `0600` (readable only by the local user session/root), which `HyprServerBridge.swift` reads to authorize command dispatch.

#### Blast Radius

- **Failure domain**: A fatal error in `libhyprserver.dylib` affects only the WindowServer process. `launchd` respawns WindowServer automatically, restoring the GUI session within ~1 second.
- **User data risk**: None. WindowServer does not manage persistent user data. A crash results in temporary GUI session loss (equivalent to a logout), with all applications remaining alive and reconnecting to the new WindowServer instance.
- **System stability**: The hook is confined to a single daemon process. It does not modify kernel state, filesystems, or other system daemons. No kernel extensions or DriverKit drivers are involved.
- **Rollback**: Touching `/tmp/hyprmac.safemode` prevents future injection attempts. Removing the LaunchDaemon plist (`com.hyprmac.inject.plist`, configured with `KeepAlive: false`, `[IMPLEMENTED]`) or executing `hypr-inject --uninstall` and rebooting fully reverts the system.

## Acceptance Criteria

| Criterion | Target | Measurement Method |
|-----------|--------|--------------------|
| Injection & initialization latency | < 50ms Mach thread bootstrap + 500ms deferred initialization delay (`usleep(500000)` in `deferred_init()` in `hook.c` waiting for WindowServer subsystems, runloop, and Mach ports to stabilize before initializing shared memory and signaling readiness via `/tmp/hyprserver.ready`) | Timestamp logging in injector and hook (`/tmp/hyprserver-diag.log`) |
| Border synchronization latency | < 1 display refresh cycle (≤16.67ms at 60Hz, ≤8.33ms at 120Hz ProMotion) via AppKit overlay windows; in-situ WindowServer border drawing is NOT YET IMPLEMENTED (hook.c only caches border parameters in g_managed_windows) | `CVDisplayLink` observer measuring frame-aligned border updates |
| Frame drops during injection | 0 dropped frames | External `CVDisplayLink` observer (baseline 2s pre-injection, 2s measurement window) |
| WindowServer memory overhead | < 2MB resident base increase | `vmmap` before/after injection comparison |
| Memory scaling | < 2MB base + < 512 bytes per managed window | `vmmap` heap analysis measuring incremental delta up to 100+ windows |
| Hook CPU utilization (idle) | < 0.5% of one CPU core | `sample` / `top -pid $(pgrep WindowServer) -stats cpu` during steady state |
| Hook CPU utilization (active) | < 2.0% of one CPU core | CPU monitoring during continuous window drag/resize/tiling operations |
| High-concurrency window capacity | 100+ concurrent managed windows without degradation | Synthetic stress harness managing 100+ active windows simultaneously |
| Reconnection after WindowServer respawn | Exponential backoff: initial 100ms, doubling each attempt up to `maxBackoff` 5.0s, with up to `maxReconnectAttempts` 10 (reconnects within 100ms–500ms on fast respawns; full retry sequence spans up to ~26s before posting failure notification) | HyprServerBridge reconnection timer with exponential backoff (`Sources/HyprMac/Bridge/HyprServerBridge.swift`) |
| Degradation fallback detection | < 500ms to engage AppKit `BorderWindow` overlays upon hook failure | Automated fault-injection test killing hook worker thread |
| Session transition quiescence [PLANNED, NOT IMPLEMENTED] | < 100ms to quiesce on lock/switch, < 200ms to resume (Planned for multi-user phase; currently not implemented) | Fast User Switching / console lock automated test harness |
| Multi-monitor ProMotion sync | 0 dropped frames, < 1 refresh cycle border latency across 120Hz & 60Hz/144Hz | Dual-display `CVDisplayLink` frame pacing observer |

## Graceful Degradation & Fallback Strategy

When the in-situ composition hook fails at runtime (due to a WindowServer crash, daemon restart, shared memory disconnection, or safemode activation), HyprMac SHALL fall back to AppKit `BorderWindow` overlays automatically.

*(Note on Border Overlay Status: Because in-situ border drawing is not yet implemented in `hook.c`, `BorderWindow` AppKit overlay panels currently remain active as the primary border rendering mechanism, rather than being retired upon hook connection).*

1. **Failure Detection Deadline**: The `HyprServerBridge` must detect hook unavailability within 500ms via shared memory heartbeat timeout, ring buffer invalidation, or loss of readiness file `/tmp/hyprserver.ready`.
2. **Automatic Rendering Path Switch**: Upon detecting hook unavailability, the bridge immediately switches the rendering pipeline back to AppKit `BorderWindow` overlays, maintaining window borders seamlessly without user intervention or process restarts.
3. **Automatic Re-escalation**: When `WindowServer` respawns and `hypr-inject` reinstates the in-situ hook, `HyprServerBridge` automatically reconnects to `/tmp/hyprmac-ipc.shm`, detects hook readiness, and retires the `BorderWindow` overlays in favor of synchronized in-situ composition.

## Deployment & Installation Requirements

Installation and execution of the in-situ composition subsystem require satisfying low-level macOS security and hardware prerequisites:

1. **System Integrity Protection (SIP) Disabled**:
   - SIP must be disabled (`csrutil disable` via Recovery OS) to allow task port acquisition (`task_for_pid`) on Apple-signed system daemons like `WindowServer`.
2. **Root Privileges for Injection**:
   - `hypr-inject` requires root privileges (`sudo` or a privileged LaunchDaemon helper `com.hyprmac.inject.plist` configured with `KeepAlive: false`) to obtain the Mach task port for WindowServer (`mach_task_self()` to target PID) and execute `mach_vm_write` and remote thread creation.
3. **`-arm64e_preview_abi` Boot Argument (Apple Silicon)**:
   - On Apple Silicon hardware, Pointer Authentication Codes (PAC) enforce binary signing invariants on arm64e binaries. Executing custom dylibs inside arm64e system binaries requires booting with the `-arm64e_preview_abi` boot argument:
     ```bash
     sudo nvram boot-args="-arm64e_preview_abi"
     ```
4. **Code Signing & Library Validation Options**:
   - All binaries require code signing. In the build system, `SIGN_IDENTITY` defaults to ad-hoc (`-`) for local development. When WindowServer enforces Library Validation (`CS_REQUIRE_LV`), `libhyprserver.dylib` can be signed with a valid Developer ID Application certificate via `make SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"` (which automatically appends `--timestamp`). The loader (`hypr-inject`) is signed with debugging and Mach task entitlements (`get-task-allow`, `com.apple.security.cs.debugger`).

## Rollback Plan

If `WindowServer` becomes unstable or misbehaves:
1. Touch `/tmp/hyprmac.safemode` (causes the dylib constructor to abort instantly on load).
2. If `WindowServer` crashes, `launchd` respawns it cleanly within 200ms. Because injection is dynamic and does NOT alter files in `/System`, a respawned `WindowServer` is 100% vanilla Apple code.
3. Remove the shared memory file `/tmp/hyprmac-ipc.shm`, readiness marker `/tmp/hyprserver.ready`, staged dylib `/Library/GPUBundles/libhyprserver.dylib`, and kill any running `hypr-inject` daemon.

## Security & Authorization Model

Execution and IPC in the in-situ composition subsystem operate under a strict defense-in-depth model that respects Apple's platform security architecture while establishing authorized privileged boundaries. The loader binary (`hypr-inject`) and in-process dylib (`libhyprserver.dylib`) require ad-hoc code signing (`codesign -s - --force --preserve-metadata=identifier,entitlements`) accompanied by explicit debugging and Mach task acquisition entitlements (`get-task-allow`, `com.apple.security.cs.debugger`). Because `WindowServer` runs as a protected system daemon (`_windowserver`, UID 88), acquiring its Mach task port via `task_for_pid()` requires root execution (effective UID 0) and System Integrity Protection disabled (`csrutil disable`).

On Apple Silicon hardware, Apple Mobile File Integrity (AMFI) enforces trust cache verification and prevents execution of non-platform dynamic libraries inside system processes. HyprMac leverages the standard kernel boot argument `-arm64e_preview_abi` (`sudo nvram boot-args="-arm64e_preview_abi"`), which relaxes Pointer Authentication Code (PAC) strict enforcement for development binaries and permits loading custom dylibs across Mach task ports without kernel authorization traps.

Cross-privilege IPC security is enforced at transport and protocol boundaries. Because the WindowServer sandbox (`com.apple.WindowServer.sb`) strictly blocks all BSD socket operations, IPC uses file-backed shared memory at `/tmp/hyprmac-ipc.shm` (64KB, `MAP_SHARED`, mode `0666`) in world-writable `/tmp`, allowing communication between `WindowServer` (UID 88) and the unprivileged user session (UID 501). Dual lock-free ring buffers (Command Ring Swift→Hook, Response Ring Hook→Swift) synchronize via atomic acquire/release barriers. To prevent unauthorized local applications in `/tmp` from manipulating window state, the protocol uses framed binary messages with strict magic (`0x48534D49`), version, and length checks, alongside shared secret token authentication (`HYPR_CMD_AUTH` via `/tmp/hyprmac-auth-token`, mode `0600` generated by `libhyprserver.dylib`). Dylib staging to `/Library/GPUBundles/libhyprserver.dylib` (mode `0644`) guarantees UID 88 accessibility and satisfies sandbox path requirements.

## Backward Compatibility & OS Upgrade Matrix

Because the composition hook operates inside `WindowServer` and interacts directly with internal symbols from `SkyLight.framework` (`SLSMainConnectionID`, `SLSSetWindowTags`, `SLSSetWindowShadowProperties`, `SLSWindowSetCornerRadius` / `SLSSetWindowCornerMask`), it is subject to private ABI shifts across macOS updates. Apple routinely refactors symbol visibility, function signatures, and struct field offsets between macOS minor releases.

To prevent OS updates from destabilizing `WindowServer`, `libhyprserver.dylib` implements defensive dynamic symbol resolution. All private entry points are resolved at runtime via `dlsym(RTLD_DEFAULT, ...)` wrapped in POSIX signal sandboxing (`SIGSEGV` / `SIGBUS` handlers with `sigsetjmp` / `siglongjmp`). Symbol availability and function variants are probed dynamically rather than relying on raw structure memory patching. If an update alters symbol availability such that required functions cannot be resolved, the hook aborts initialization cleanly, creates the safe-mode tombstone (`/tmp/hyprmac.safemode`), and leaves `WindowServer` untouched.

The compatibility matrix categorizes supported OS release behaviors:
- **macOS 14.0–14.3 (Sonoma)**: Two-stage runtime attachment with Stage 1 launched via `thread_set_state` + `thread_resume`; standard SkyLight private exports available.
- **macOS 14.4–14.7 (Sonoma)**: Two-stage runtime attachment requires `thread_create_running` due to Mach thread state lifecycle enforcement; PAC domain conversion via `_thread_convert_thread_state`.
- **macOS 15.x (Sequoia)**: Two-stage runtime attachment via `thread_create_running`; dynamic symbol discovery with `sigaction` sandboxing; strict AMFI preview ABI enforcement.
- **macOS 27.x (Golden Gate)**: Modern Metal-based compositor structures; automated fallback to `SkyLightBridge` user-space overlay when private SkyLight C-APIs diverge or fail to resolve.

## Monitoring, Observability & Telemetry

The in-situ composition subsystem incorporates structured observability across the loader, hook, and client bridge to enable real-time health inspection and rapid post-mortem diagnostics. The in-process hook maintains a dedicated structured log stream at `/tmp/hyprserver.log` with an automated log rotation policy (`[IMPLEMENTED]`): when the active log file exceeds 1MB (`HYPR_LOG_MAX_SIZE`), a single rotation step executes `rename(HYPR_LOG_PATH, HYPR_LOG_PATH_ROTATED)` rotating solely to `/tmp/hyprserver.log.1`, bounding disk space to a maximum of ~2MB (active + 1 rotated).

In-band telemetry is supported via the `HYPR_CMD_PING` and `HYPR_CMD_PONG` protocol transactions. Clients query server health at runtime, receiving server version bits (`major << 16 | minor << 8 | patch`) and the current count of managed windows. The client bridge (`HyprServerBridge.swift`) exports telemetry to Apple Unified Logging (`os_log`) under subsystem `com.hyprmac.server-bridge`, recording transaction latencies, connection states, and fallback transitions.

Compositor performance metrics are collected using high-resolution `mach_absolute_time()` timers. Border synchronization latency, surface invalidation duration, and IPC packet round-trip times are monitored continuously. If command execution latency exceeds a 50ms deadline, a diagnostic warning event is logged to detect compositor stalls before they cause perceptible UI frame drops.

## Window Lifecycle Coverage

Managed application windows transition through complex lifecycle states in macOS, including minimization, workspace changes, and fullscreen modes. The in-situ composition hook ensures consistent decoration state without graphical artifacts or compositor memory leaks across all window lifecycle transitions.

When a managed window is minimized (`kCGSOrderOut` / Dock minimize animation) or hidden (`NSApplication.hide`), the hook temporarily suspends active border rendering and clipping masks to prevent visual shearing during macOS window transform animations. Upon unminimization or unhiding (`kCGSOrderIn`), decoration properties (square corners, suppressed shadows, active border) are re-asserted synchronously before the window's first composited frame is presented.

During Mission Control invocation, Stage Manager interactions, or Spaces (virtual desktop) transitions, `WindowServer` translates surfaces and reparents window layers. The hook coordinates with `WindowServer` window tag events, maintaining border attachment and clipping geometry across space pans. Windows entering native macOS fullscreen mode (`kCGSWindowIsFullScreen`) have custom borders and corner masks automatically suppressed, restoring native geometry cleanly and re-applying HyprMac styling upon return to tiled or floating window layouts.

## Uninstallation Procedure

The uninstallation procedure provides an orderly, complete deprovisioning sequence that removes all system integration components, frees allocated memory, and restores native macOS Aqua decorations without requiring a system restart.

Executing `hypr-inject --uninstall` (`[IMPLEMENTED]`) performs the following operations:
1. **Daemon Unregistration**: Unloads and removes the LaunchDaemon plist at `/Library/LaunchDaemons/com.hyprmac.inject.plist` (configured with `KeepAlive: false`, `[IMPLEMENTED]`).
2. **Safe-Mode Activation**: Writes the safe-mode circuit breaker tombstone to `/tmp/hyprmac.safemode`, preventing subsequent hook initialization attempts if `WindowServer` restarts.
3. **Shared Memory & File Cleanup**: Closes active IPC channels, unlinks the shared memory file at `/tmp/hyprmac-ipc.shm`, the readiness file `/tmp/hyprserver.ready`, removes staged dylib `/Library/GPUBundles/libhyprserver.dylib`, and purges diagnostic logs in `/tmp/hyprserver.log*`.
4. **Decoration Restoration**: The in-process hook iterates through all managed windows in its tracking registry, restoring native 10px-12px rounded corner masks, re-enabling standard Aqua drop shadows, clearing custom borders, and restoring titlebar visibility.
5. **Client Degradation**: `HyprServerBridge` detects shared memory disconnection or readiness file removal and transitions back to standard `SkyLightBridge` / AppKit overlay behavior or exits cleanly.

## Cross-References & Upstream Specifications

This proposal defines the project change scope for in-situ composition. For technical architecture details, protocol specifications, and task tracking, refer to:
- **In-Situ Injection Engine Architecture**: `docs/WINDOWSERVER_INJECTION_SPEC.md`
- **Composition Engine Formal Specification**: `specs/composition-engine.spec.md`
- **Technical Design Document (SDD)**: `openspec/changes/windowserver-insitu-composition/design.md`
- **Implementation Tasks & Milestones**: `openspec/changes/windowserver-insitu-composition/tasks.md`
