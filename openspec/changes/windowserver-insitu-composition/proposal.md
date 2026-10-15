# Proposal: windowserver-insitu-composition

## Intent

Implement a native, in-situ window composition subsystem for HyprMac that injects directly into macOS's root compositor daemon, `WindowServer` (`/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer`). This bypasses client-side IPC isolation in `SkyLight.framework` to achieve true Wayland/Hyprland window styling: zero-pixel corner radii, eliminated drop shadows, and zero-latency synchronized borders without cosmetic user-space overlays.

## Scope

### In Scope
- Mach task port loader (`hypr-inject`) executing privileged two-stage runtime attachment into `WindowServer` (UID 88 / `_windowserver`; WindowServer's PID is dynamically assigned by `launchd` at boot and varies across restarts, resolved at runtime via `pgrep WindowServer` or by scanning the process table). Remote execution utilizes a two-stage architecture to ensure thread-local storage (TLS) availability:
  - **Stage 1 (Raw Mach Thread Bootstrap)**: The loader allocates a remote 16 KB stack (`VM_PROT_READ | VM_PROT_WRITE`), a 4096-byte code page (`VM_PROT_READ | VM_PROT_EXECUTE`), and writes a parameter block with resolved symbol addresses and the target dylib path. Entry points for `pthread_create_from_mach_thread` and `dlopen` are resolved from the shared cache and adjusted using a cross-process ASLR slide delta calculated via `task_info(TASK_DYLD_INFO)`. An ARM64e assembly sequence is written to the code page with its entry point signed via `ptrauth_sign_unauthenticated` (`ptrauth_key_asia`, 0). The loader converts the thread state to the target PAC domain via `_thread_convert_thread_state` and launches execution via `thread_create_running` (macOS ≥14.4) or `thread_set_state` + `thread_resume` (macOS <14.4). On the raw Mach thread, Stage 1 invokes `pthread_create_from_mach_thread` (which establishes a dedicated stack and initializes TLS registers) to spawn Stage 2 on a real POSIX thread, then enters a spin loop writing the readiness marker `0x79616265` (`yabe`) into register `x0`.
  - **Stage 2 (POSIX Pthread with TLS)**: The newly created pthread, running with full Thread-Local Storage (`TPIDRRO_EL0` populated), safely executes Stage 2: invoking `dlopen(path, RTLD_LAZY)` to load `libhyprserver.dylib` signed with a valid Developer ID certificate (`8N5N254R3B`) to satisfy WindowServer Library Validation (`CS_REQUIRE_LV`). Once the loader polls and detects the `0x79616265` readiness marker and verifies socket availability, the Stage 1 Mach thread is cleanly terminated.
- Defensive in-process payload (`libhyprserver.dylib`) running a decoupled POSIX worker thread and diagnostic logging to `/tmp/hyprserver.log`.
- Dedicated local IPC channel over a Unix Domain Socket (`/tmp/hyprmac-server.sock`) using a binary framed protocol.
- Server-side CGS execution using `SLSMainConnectionID()` inside `WindowServer` to modify window tags and shadow properties.
- Dynamic memory patching of `WSWindow` / `CGSWindow` to enforce 0px square corners (`_cornerMask = 0.0`).
- Circuit breaker failsafe (`/tmp/hyprmac.safemode`) to prevent recurring WindowServer bootloops.
- Swift client bridge (`Sources/HyprMac/Bridge/HyprServerBridge.swift`) integrating into existing `HyprMac` CLI commands.

### Out of Scope
- Direct KMS/DRM display driver replacement (impossible without custom kernel extensions).
- Modifying Cocoa event loops or replacing Quartz WindowServer event distribution.
- Bypassing SIP on systems where SIP is enabled (the user host already has SIP disabled and `-arm64e_preview_abi` active).
- Wayland Linux application compatibility layers (Xwayland / Wayland protocol endpoints).

### Edge Cases & System Transitions (In Scope)
- **Multi-monitor setups with heterogeneous refresh rates**: Rendering and border synchronization across mixed ProMotion (120Hz variable refresh rate on internal Apple Silicon displays) and fixed external monitors (60Hz / 144Hz) without tearing, judder, or frame pacing degradation.
- **Mission Control / Stage Manager / full-screen transitions**: Managing temporary window layer reparenting, workspace virtualization, and Stage Manager animations without leaving orphaned border masks or crashing the compositor during native macOS space switching.
- **Fast User Switching / Lock Screen session transitions**: Responding to console lock/unlock events and Fast User Switching where WindowServer transitions the active console session to `loginwindow` or another user account (UID != 501), safely quiescing hook IPC dispatch and reconnecting cleanly on session reactivation.

## Capabilities

### New Capabilities
- `windowserver-mach-injection`: Root-level Mach task port resolution, remote memory mapping (`mach_vm_write`), and ARM64 remote thread execution.
- `insitu-composition-hook`: In-process dylib inside `WindowServer` hosting socket IPC and manipulating internal window properties.
- `hyprserver-ipc-driver`: Swift binary framed client communicating with the in-process server hook.

### Modified Capabilities
- `SkyLightBridge`: Updated to route window attribute changes (strip titlebar, remove shadow, set corner radius) through `HyprServerBridge` when the server hook is detected.

## Approach

1. **Isolation First:** `libhyprserver.dylib` initializes defensively on a separate thread, leaving `WindowServer`'s main runloop untouched.
2. **Authority Escalation:** The hook leverages `WindowServer`'s internal connection ID (`SLSMainConnectionID`), which possesses root authority to change window tags without the silent rejections encountered by external processes.
3. **Structured Recovery:** Any injection failure automatically writes a circuit breaker tombstone to abort subsequent hooks until explicitly cleared.

### Architecture Decision Record: Two-Stage Runtime Attachment vs. Direct dlopen
- **Context**: Initial prototypes attempted direct `dlopen` execution within `WindowServer` by allocating a remote stack and code stub, configuring thread registers (`PC = dlopen`, `x0 = path`, `x1 = RTLD_LAZY`, `LR = spin_stub`), and invoking `thread_create_running`.
- **Root Cause of Failure**: Direct `dlopen` caused an immediate and reproducible crash inside `WindowServer` at `pthread_getspecific + 4`. Under Apple Silicon macOS, threads created via raw Mach `thread_create` / `thread_create_running` have no POSIX execution context; their Thread-Local Storage (TLS) register `TPIDRRO_EL0` is zero (`0`). Dynamic linking via `dlopen` and library initialization routines in `libdyld` / `libsystem_c` immediately call functions that depend on TLS (`pthread_getspecific`, `pthread_self`, `os_log`). When `TPIDRRO_EL0` is null, offset dereferencing causes an unhandled `EXC_BAD_ACCESS` / `SIGSEGV` crash.
- **Decision**: Adopt a two-stage runtime attachment architecture:
  1. **Stage 1 (Bootstrap Routine)**: The raw Mach thread executes a minimal ARM64e assembly routine that invokes `pthread_create_from_mach_thread`. This function has a dedicated internal setup routine that constructs a full POSIX thread structure and initializes `TPIDRRO_EL0`. After dispatching `pthread_create_from_mach_thread`, the Stage 1 thread enters a spin loop writing the readiness marker `0x79616265` (`yabe`) into register `x0`.
  2. **Stage 2 (POSIX Pthread Execution)**: Stage 2 executes on the newly created `pthread` with fully initialized TLS, safely invoking `dlopen(dylib_path, RTLD_LAZY)`.
  3. **Cross-Process ASLR Delta Correction**: Memory addresses for `pthread_create_from_mach_thread` and `dlopen` are resolved in the loader's local space and translated to the target `WindowServer` address space by computing the shared cache ASLR slide delta via `task_info(TASK_DYLD_INFO)`.
  4. **Pointer Authentication (PAC)**: Entry point pointers are signed using `ptrauth_sign_unauthenticated` with key `ptrauth_key_asia` and converted into the target PAC domain via `_thread_convert_thread_state`.
  5. **Library Validation Compatibility**: `libhyprserver.dylib` is signed with Developer ID Application certificate (`8N5N254R3B`) to satisfy WindowServer's `CS_REQUIRE_LV` constraint.
- **Consequences**: Eliminates TLS-related compositor crashes, ensures deterministic attachment confirmation via marker polling, and successfully loads `libhyprserver.dylib` into `WindowServer`.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `hypr-inject` (new binary) | New | `[IMPLEMENTED]` Two-stage PAC-safe loader written in C11/ARM64e assembly. |
| `libhyprserver.dylib` (new dylib) | New | `[SUBSTANTIALLY IMPLEMENTED]` In-process hook library targeting `WindowServer`, hosting local socket server and safe-mode check; full display link synchronization across heterogeneous refresh rates (120Hz/60Hz), Stage Manager/Mission Control space switches, and session transitions planned. |
| `Sources/HyprMac/Bridge/HyprServerBridge.swift` | New | `[SUBSTANTIALLY IMPLEMENTED]` Swift client adapter for IPC over `/tmp/hyprmac-server.sock` (~685 lines); command replay ring buffer and token authentication planned. |
| `Sources/HyprMac/Bridge/SkyLightBridge.swift` | Modify | `[NOT YET MODIFIED]` Intercepts `stripTitlebar` and tag mutations to prefer server hook (currently has zero hook integration). |
| `Sources/HyprMac/Render/BorderWindow.swift` | Modify | `[NOT YET MODIFIED]` When the in-process composition hook is active, `BorderWindow` overlay rendering is bypassed; currently has no hook availability checks. The AppKit overlay path is retained as a fallback when the hook is unavailable. |
| `Sources/HyprMac/main.swift` | Modify | `[NOT YET IMPLEMENTED]` Integrates composition hook status and window decoration commands (`server-status`, `square`, `strip-shadow` do not exist yet) alongside existing CLI subcommands (`probe`, `border`, `strip`, `tile`, `daemon`, `bar`, `session`, `parse-config`, and `test-*` harnesses). |

## Threat Model & Blast Radius

#### Threat Model

| Threat | Likelihood | Impact | Mitigation |
|--------|-----------|--------|------------|
| **WindowServer crash during runtime attachment** | Medium | Critical — all GUI sessions terminate, user is logged out | Two-stage runtime attachment isolates `dlopen` onto a real pthread with full TLS (`TPIDRRO_EL0`), preventing immediate TLS crashes (`pthread_getspecific + 4`); ASLR slide delta is resolved dynamically via `TASK_DYLD_INFO`; safe-mode circuit breaker (`/tmp/hyprmac.safemode`); `launchd` auto-respawns WindowServer within ~1s; loader validates Mach-O header before thread creation |
| **Library validation rejection (`CS_REQUIRE_LV`)** | High | Critical — WindowServer rejects dylib load, aborting hook | WindowServer enforces Library Validation (`CS_REQUIRE_LV`). Custom dynamic libraries signed ad-hoc fail verification. Mitigation: `libhyprserver.dylib` is codesigned using a valid Developer ID certificate (`8N5N254R3B`) and loaded with `-arm64e_preview_abi` boot argument active. |
| **WindowServer deadlock or main thread freeze** | Low | Critical — GUI freezes without crashing; launchd does not auto-restart deadlocked processes | In-situ hook operates strictly on a dedicated detached worker thread with zero synchronous blocking on WindowServer's main runloop; IPC uses non-blocking I/O (`O_NONBLOCK`) with strict 50ms operation deadlines; internal watchdog heartbeat self-terminates or triggers circuit breaker if compositor thread hangs. |
| **Double injection (duplicate hook load)** | Low | High — duplicate listener threads, port conflicts, undefined behavior | Idempotency guard via bootstrap port `com.hyprmac.server.hook`; injector checks before proceeding |
| **Data race on compositor structures** | Medium | High — visual corruption, potential crash | `os_unfair_lock` synchronization on all window property mutations (see design.md) |
| **Malicious IPC commands from unauthorized process** | Low | Medium — attacker could alter window decorations | Socket bound to `/tmp/hyprmac-server.sock` with `chmod 0666` to allow cross-privilege IPC across UID 88 (`_windowserver`) and UID 501 (user) in world-writable `/tmp`. Currently, the socket operates unauthenticated with `0666` permissions. Wire protocol authentication via `HYPR_CMD_AUTH` and a shared secret token exchanged during loader staging is `[PLANNED]` to restrict command dispatch. |
| **macOS update changes private API layout** | High | Medium — hook fails to find symbols, falls back safely | Version manifest (`hypr-offsets.plist`); Phase 3 symbol discovery with graceful fallback; hook aborts initialization if required symbols are not found |
| **SIP re-enabled by user** | Medium | Low — injection fails cleanly | `hypr-inject` checks `csrutil status` before attempting `task_for_pid`; exits with diagnostic message |
| **Unbounded diagnostic log growth** | Low | Low — disk space exhaustion in `/tmp` | Log rotation policy enforced in `libhyprserver.dylib` (`[PLANNED]`): maximum 1MB per log file with up to 3 rotated generations (`/tmp/hyprserver.log.1..3`), capping maximum log footprint at 4MB. |

#### Cross-Privilege IPC & Security Note
WindowServer runs as daemon user `_windowserver` (UID 88), whereas the HyprMac client process runs in the user GUI session as UID 501. Because the Unix Domain Socket is located at `/tmp/hyprmac-server.sock` within a world-writable directory (`/tmp`), socket permissions must be set to `chmod 0666` to permit bidirectional cross-privilege communication. To prevent unauthorized local processes from sending arbitrary IPC commands over the world-accessible socket, the binary framed wire protocol SHALL implement authentication via a shared secret token exchanged during injection staging (`[PLANNED]`): the loader will generate a high-entropy 128-bit (16-byte) authentication token, provisioning it to both the injected hook and the HyprMac client session. In the current development implementation, the socket is bound with `chmod 0666` without authentication.

#### Blast Radius

- **Failure domain**: A fatal error in `libhyprserver.dylib` affects only the WindowServer process. `launchd` respawns WindowServer automatically, restoring the GUI session within ~1 second.
- **User data risk**: None. WindowServer does not manage persistent user data. A crash results in temporary GUI session loss (equivalent to a logout), with all applications remaining alive and reconnecting to the new WindowServer instance.
- **System stability**: The hook is confined to a single daemon process. It does not modify kernel state, filesystems, or other system daemons. No kernel extensions or DriverKit drivers are involved.
- **Rollback**: Touching `/tmp/hyprmac.safemode` prevents future injection attempts. Removing the LaunchDaemon plist (`com.hyprmac.inject.plist`, `[PLANNED]`) and rebooting fully reverts the system.

## Acceptance Criteria

| Criterion | Target | Measurement Method |
|-----------|--------|--------------------|
| Injection latency | < 50ms from `hypr-inject` invocation to hook `__constructor` completion | Timestamp logging in injector and hook |
| Border synchronization latency | < 1 display refresh cycle (≤16.67ms at 60Hz, ≤8.33ms at 120Hz ProMotion) | `CVDisplayLink` observer measuring frame-aligned border updates |
| Frame drops during injection | 0 dropped frames | External `CVDisplayLink` observer (baseline 2s pre-injection, 2s measurement window) |
| WindowServer memory overhead | < 2MB resident base increase | `vmmap` before/after injection comparison |
| Memory scaling | < 2MB base + < 512 bytes per managed window | `vmmap` heap analysis measuring incremental delta up to 100+ windows |
| Hook CPU utilization (idle) | < 0.5% of one CPU core | `sample` / `top -pid $(pgrep WindowServer) -stats cpu` during steady state |
| Hook CPU utilization (active) | < 2.0% of one CPU core | CPU monitoring during continuous window drag/resize/tiling operations |
| High-concurrency window capacity | 100+ concurrent managed windows without degradation | Synthetic stress harness managing 100+ active windows simultaneously |
| Reconnection after WindowServer respawn | < 3 seconds | HyprServerBridge reconnection timer with exponential backoff |
| Degradation fallback detection | < 500ms to engage AppKit `BorderWindow` overlays upon hook failure | Automated fault-injection test killing hook worker thread |
| Session transition quiescence | < 100ms to quiesce on lock/switch, < 200ms to resume | Fast User Switching / console lock automated test harness |
| Multi-monitor ProMotion sync | 0 dropped frames, < 1 refresh cycle border latency across 120Hz & 60Hz/144Hz | Dual-display `CVDisplayLink` frame pacing observer |

## Graceful Degradation & Fallback Strategy

When the in-situ composition hook fails at runtime (due to a WindowServer crash, daemon restart, socket disconnection, or safemode activation), HyprMac SHALL fall back to AppKit `BorderWindow` overlays automatically.

1. **Failure Detection Deadline**: The `HyprServerBridge` must detect hook unavailability within 500ms via socket EOF, broken pipe (`EPIPE`), or ping-pong heartbeat timeout.
2. **Automatic Rendering Path Switch**: Upon detecting hook unavailability, the bridge immediately switches the rendering pipeline back to AppKit `BorderWindow` overlays, maintaining window borders seamlessly without user intervention or process restarts.
3. **Automatic Re-escalation**: When `WindowServer` respawns and `hypr-inject` reinstates the in-situ hook, `HyprServerBridge` automatically reconnects, completes the auth handshake, and retires the `BorderWindow` overlays in favor of synchronized in-situ composition.

## Deployment & Installation Requirements

Installation and execution of the in-situ composition subsystem require satisfying low-level macOS security and hardware prerequisites:

1. **System Integrity Protection (SIP) Disabled**:
   - SIP must be disabled (`csrutil disable` via Recovery OS) to allow task port acquisition (`task_for_pid`) on Apple-signed system daemons like `WindowServer`.
2. **Root Privileges for Injection**:
   - `hypr-inject` requires root privileges (`sudo` or a privileged LaunchDaemon helper) to obtain the Mach task port for WindowServer (`mach_task_self()` to target PID) and execute `mach_vm_write` and remote thread creation.
3. **`-arm64e_preview_abi` Boot Argument (Apple Silicon)**:
   - On Apple Silicon hardware, Pointer Authentication Codes (PAC) enforce binary signing invariants on arm64e binaries. Executing custom dylibs inside arm64e system binaries requires booting with the `-arm64e_preview_abi` boot argument:
     ```bash
     sudo nvram boot-args="-arm64e_preview_abi"
     ```
4. **Developer ID Code Signing & Library Validation**:
   - All binaries require code signing. Crucially, because WindowServer enforces Library Validation (`CS_REQUIRE_LV`), `libhyprserver.dylib` MUST be signed with a valid Developer ID Application certificate (certificate identifier `8N5N254R3B`, established during RC3 testing) to permit dynamic loading into WindowServer. The loader (`hypr-inject`) is signed with debugging and Mach task entitlements (`get-task-allow`, `com.apple.security.cs.debugger`).

## Rollback Plan

If `WindowServer` becomes unstable or misbehaves:
1. Touch `/tmp/hyprmac.safemode` (causes the dylib constructor to abort instantly on load).
2. If `WindowServer` crashes, `launchd` respawns it cleanly within 200ms. Because injection is dynamic and does NOT alter files in `/System`, a respawned `WindowServer` is 100% vanilla Apple code.
3. Remove the socket file `/tmp/hyprmac-server.sock` and kill any running `hypr-inject` daemon.

## Security & Authorization Model

Execution and IPC in the in-situ composition subsystem operate under a strict defense-in-depth model that respects Apple's platform security architecture while establishing authorized privileged boundaries. The loader binary (`hypr-inject`) and in-process dylib (`libhyprserver.dylib`) require ad-hoc code signing (`codesign -s - --force --preserve-metadata=identifier,entitlements`) accompanied by explicit debugging and Mach task acquisition entitlements (`get-task-allow`, `com.apple.security.cs.debugger`). Because `WindowServer` runs as a protected system daemon (`_windowserver`, UID 88), acquiring its Mach task port via `task_for_pid()` requires root execution (effective UID 0) and System Integrity Protection disabled (`csrutil disable`).

On Apple Silicon hardware, Apple Mobile File Integrity (AMFI) enforces trust cache verification and prevents execution of non-platform dynamic libraries inside system processes. HyprMac leverages the standard kernel boot argument `-arm64e_preview_abi` (`sudo nvram boot-args="-arm64e_preview_abi"`), which relaxes Pointer Authentication Code (PAC) strict enforcement for development binaries and permits loading custom dylibs across Mach task ports without kernel authorization traps.

Cross-privilege IPC security is enforced at the transport and protocol boundaries. The Unix Domain Socket at `/tmp/hyprmac-server.sock` is created with `chmod 0666` to permit communication between `WindowServer` (UID 88) and the unprivileged user session (UID 501). To prevent unauthorized local applications in `/tmp` from manipulating window state, the protocol mandates an authentication handshake (`[PLANNED]`): the loader generates a cryptographically secure 128-bit (16-byte) random token during injection staging, and the server hook closes any incoming connection that fails to provide this token via `HYPR_CMD_AUTH` within 1 second. (Currently, the development socket operates unauthenticated with `0666` permissions).

## Backward Compatibility & OS Upgrade Matrix

Because the composition hook operates inside `WindowServer` and interacts directly with internal symbols from `SkyLight.framework` (`SLSMainConnectionID`, `SLSSetWindowTags`, `SLSSetWindowShadowProperties`) and private `WSWindow` / `CGSWindow` structures, it is subject to private ABI shifts across macOS updates. Apple routinely refactors symbol visibility, function signatures, and struct field offsets between macOS minor releases.

To prevent OS updates from destabilizing `WindowServer`, `libhyprserver.dylib` implements defensive dynamic symbol resolution. All private entry points are resolved at runtime via `dlsym(RTLD_DEFAULT, ...)` wrapped in POSIX signal sandboxing (`SIGSEGV` / `SIGBUS` handlers with `sigsetjmp` / `siglongjmp`). Memory offsets are validated against structural heuristics rather than assumed as static constants. If an update alters the layout such that a symbol cannot be resolved or an offset verification fails, the hook aborts initialization cleanly, creates the safe-mode tombstone (`/tmp/hyprmac.safemode`), and leaves `WindowServer` untouched.

The compatibility matrix categorizes supported OS release behaviors:
- **macOS 14.0–14.3 (Sonoma)**: Two-stage runtime attachment with Stage 1 launched via `thread_set_state` + `thread_resume`; standard SkyLight private exports available.
- **macOS 14.4–14.7 (Sonoma)**: Two-stage runtime attachment requires `thread_create_running` due to Mach thread state lifecycle enforcement; PAC domain conversion via `_thread_convert_thread_state`.
- **macOS 15.x (Sequoia)**: Two-stage runtime attachment via `thread_create_running`; dynamic symbol discovery with `sigaction` sandboxing; strict AMFI preview ABI enforcement.
- **macOS 27.x (Golden Gate)**: Modern Metal-based compositor structures; automated fallback to `SkyLightBridge` user-space overlay when internal `WSWindow` structure layouts diverge.

## Monitoring, Observability & Telemetry

The in-situ composition subsystem incorporates structured observability across the loader, hook, and client bridge to enable real-time health inspection and rapid post-mortem diagnostics. The in-process hook maintains a dedicated structured log stream at `/tmp/hyprserver.log` with an automated log rotation policy (`[PLANNED]`): log files are capped at 1MB per generation with up to 3 rotated generations (`/tmp/hyprserver.log.1..3`), bounding disk space to a maximum of 4MB.

In-band telemetry is supported via the `HYPR_CMD_PING` and `HYPR_CMD_PONG` protocol transactions. Clients query server health at runtime, receiving server version bits (`major << 16 | minor << 8 | patch`) and the current count of managed windows. The client bridge (`HyprServerBridge.swift`) exports telemetry to Apple Unified Logging (`os_log`) under subsystem `com.hyprmac.server-bridge`, recording transaction latencies, connection states, and fallback transitions.

Compositor performance metrics are collected using high-resolution `mach_absolute_time()` timers. Border synchronization latency, surface invalidation duration, and IPC packet round-trip times are monitored continuously. If command execution latency exceeds a 50ms deadline, a diagnostic warning event is logged to detect compositor stalls before they cause perceptible UI frame drops.

## Window Lifecycle Coverage

Managed application windows transition through complex lifecycle states in macOS, including minimization, workspace changes, and fullscreen modes. The in-situ composition hook ensures consistent decoration state without graphical artifacts or compositor memory leaks across all window lifecycle transitions.

When a managed window is minimized (`kCGSOrderOut` / Dock minimize animation) or hidden (`NSApplication.hide`), the hook temporarily suspends active border rendering and clipping masks to prevent visual shearing during macOS window transform animations. Upon unminimization or unhiding (`kCGSOrderIn`), decoration properties (square corners, suppressed shadows, active border) are re-asserted synchronously before the window's first composited frame is presented.

During Mission Control invocation, Stage Manager interactions, or Spaces (virtual desktop) transitions, `WindowServer` translates surfaces and reparents window layers. The hook coordinates with `WindowServer` window tag events, maintaining border attachment and clipping geometry across space pans. Windows entering native macOS fullscreen mode (`kCGSWindowIsFullScreen`) have custom borders and corner masks automatically suppressed, restoring native geometry cleanly and re-applying HyprMac styling upon return to tiled or floating window layouts.

## Uninstallation Procedure

The uninstallation procedure provides an orderly, complete deprovisioning sequence that removes all system integration components, frees allocated memory, and restores native macOS Aqua decorations without requiring a system restart.

Executing `hypr-inject --uninstall` (`[PLANNED]`) performs the following operations:
1. **Daemon Unregistration**: Unloads and removes the LaunchDaemon plist at `/Library/LaunchDaemons/com.hyprmac.inject.plist` (`[PLANNED]`).
2. **Safe-Mode Activation**: Writes the safe-mode circuit breaker tombstone to `/tmp/hyprmac.safemode`, preventing subsequent hook initialization attempts if `WindowServer` restarts.
3. **Socket & File Cleanup**: Closes all active IPC connections, unlinks the Unix Domain Socket at `/tmp/hyprmac-server.sock`, and purges diagnostic logs in `/tmp/hyprserver.log*`.
4. **Decoration Restoration**: The in-process hook iterates through all managed windows in its tracking registry, restoring native 10px-12px rounded corner masks, re-enabling standard Aqua drop shadows, clearing custom borders, and restoring titlebar visibility.
5. **Client Degradation**: `HyprServerBridge` detects socket termination and transitions back to standard `SkyLightBridge` / AppKit overlay behavior or exits cleanly.

## Cross-References & Upstream Specifications

This proposal defines the project change scope for in-situ composition. For technical architecture details, protocol specifications, and task tracking, refer to:
- **In-Situ Injection Engine Architecture**: `docs/WINDOWSERVER_INJECTION_SPEC.md`
- **Composition Engine Formal Specification**: `specs/composition-engine.spec.md`
- **Technical Design Document (SDD)**: `openspec/changes/windowserver-insitu-composition/design.md`
- **Implementation Tasks & Milestones**: `openspec/changes/windowserver-insitu-composition/tasks.md`
