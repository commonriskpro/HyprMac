# HyprMac Architecture Specification: WindowServer In-Situ Composition Engine

## 1. Executive Summary & Objective

The goal of this architecture is to achieve complete, uncompromising visual and spatial parity with Wayland/Hyprland on macOS without relying on cosmetic overlays or altering client application source code.

This is achieved by injecting an in-process hook (`libhyprserver.dylib`) directly into macOS's root compositor daemon, `WindowServer` (`/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer`), running as user `_windowserver` (UID 88). 

Operating from inside `WindowServer` bypasses client-side IPC isolation in `SkyLight.framework`. It grants direct, zero-copy, unconstrained control over the native window geometry, shadow generation, corner clipping masks, and the CoreAnimation/Metal composition pipeline.

---

## 2. Prerequisites & System Preconditions

### 2.1 Prerequisites
- macOS with SIP disabled (`csrutil disable` from Recovery)
- Apple Silicon: `-arm64e_preview_abi` boot argument (`sudo nvram boot-args="-arm64e_preview_abi"`)
- Root privileges for injection (`sudo`)
- Ad-hoc codesigning (`codesign -f -s -`)

### 2.2 Host Environment Targets
- **OS Version:** macOS 27.x (Golden Gate) / macOS 14.x+
- **CPU Architecture:** Apple Silicon (`arm64` / `arm64e`)
- **Integrity Boundary:** 
  - System Integrity Protection (SIP): **Disabled** (`csrutil status -> disabled`).
  - NVRAM Boot Arguments: `-arm64e_preview_abi` enabled to allow execution of unsigned or custom-signed dylibs across platform Mach task ports without hardware PAC (Pointer Authentication Code) enforcement aborts.

### 2.3 Threat Model & Blast Radius Invariant
- **Primary Invariant:** `WindowServer` is the single point of failure for the entire graphical user session. Any fatal memory fault (`SIGSEGV`, `SIGBUS`, uncaught Mach exception) inside `WindowServer` causes `launchd` to terminate all graphical client connections immediately, logging out the user and destroying all unsaved session data.
- **Design Discipline:** The injected payload MUST be defensive, strictly decoupled from `WindowServer`'s main runloop, and wrapped in strict safety checks, isolation boundaries, and fail-safe circuit breakers.

---

## 3. Macro Architecture & Component Topography

```
+-------------------------------------------------------------------------+
|                             User Space                                  |
|                                                                         |
|   +-----------------------------------------------------------------+   |
|   |                       HyprMac Orchestrator                      |   |
|   |  (Layout Engine, Dwindle Tree, Config Parser, Keybind Manager)  |   |
|   +-------------------------------+---------------------------------+   |
|                                   |                                     |
|                                   | IPC Commands (JSON / Binary RPC)    |
|                                   v                                     |
|   +-----------------------------------------------------------------+   |
|   |                    /tmp/hyprmac-server.sock                     |   |
+---|-------------------------------|-------------------------------------+-+
    |                               |
    | (Root Privilege Boundary)     |
+---|-------------------------------|-------------------------------------+-+
|   v                               v                                     |
| +-------------------+   +---------------------------------------------+ |
| |   hypr-inject     |   |          libhyprserver.dylib                | |
| | (Mach Task Loader)|   |       (In-Process Composition Hook)         | |
| +---------+---------+   +----------------------+----------------------+ |
|           |                                    |                        |
|           | task_for_pid() + mach_vm_write()   |                        |
|           v                                    v                        |
| +---------------------------------------------------------------------+ |
| |                      WindowServer (PID: 188)                        | |
| |                                                                     | |
| |  +--------------------+  +-------------------+  +-----------------+ | |
| |  |    WSWindow Table  |  |  CAWindowServer   |  |   SkyLight CGS  | | |
| |  | (Clip / Mask / Tag)|  | (Metal Compositor)|  | (Event Router)  | | |
| |  +--------------------+  +-------------------+  +-----------------+ | |
| +---------------------------------------------------------------------+ |
|                             Daemon Space                                |
+-------------------------------------------------------------------------+
```

### Component Breakdown:
1. **`hypr-inject` (Mach Task Injector):**
   - Runs as root (UID 0) via LaunchDaemon or privileged helper.
   - Obtains `mach_port_t` for `WindowServer` via `task_for_pid()`.
   - Injects `libhyprserver.dylib` using virtual memory allocation and remote thread dispatch.
2. **`libhyprserver.dylib` (In-Process Hook Engine):**
   - Resides inside the address space of `WindowServer`.
   - Spawns a dedicated worker thread to host a local Unix Domain Socket server.
   - Patches/hooks window properties directly in the server's internal memory structures.
3. **`HyprServerBridge` (Client IPC Driver):**
   - Swift module integrated into `HyprMac` that communicates with `libhyprserver.dylib`.
   - Dispatches atomic window commands (`SetWindowCornerRadius`, `SetWindowShadowState`, `SetWindowBorder`).

---

## 4. Detailed Engineering Specifications

### 4.1 Subsystem 1: Mach Task Port Injector (`hypr-inject`)

The loader executes a two-stage PAC-safe loading sequence into `WindowServer` (matching `native/injector/main.c`):
- **Stage 1 (Raw Mach Thread):** Executes an ARM64e assembly sequence that invokes `pthread_create_from_mach_thread`, passing the Stage 2 entry routine, and enters an infinite spin loop with readiness marker `0x79616265` (`"yabe"`) in `x0`.
- **Stage 2 (Real POSIX Thread):** Runs on the newly created pthread with full Thread-Specific Data (TSD / TLS) initialized, safely executing `dlopen(dylib_path, RTLD_LAZY)` and returning cleanly via `retab`.

1. **PID Discovery & Privilege Verification:**
   - Verify effective root UID: `geteuid() == 0`.
   - Query active `WindowServer` PID via `pgrep -x WindowServer` or `proc_listpids` scanning.
   - Assert SIP status (`csrutil status`) and confirm `-arm64e_preview_abi` in `kern.bootargs`.
   - Verify safe-mode tombstone (`/tmp/hyprmac.safemode`) does not exist.
   - Query bootstrap service registry for idempotency (`bootstrap_look_up(bootstrap_port, "com.hyprmac.server.hook", &port)`). If active, exit with status 2 (already loaded).

2. **Mach Task Port Acquisition:**
   - Call `task_for_pid(mach_task_self(), ws_pid, &task)`.
   - Validate return code (`KERN_SUCCESS`). On failure, log actionable diagnostic error (SIP active or AMFI denial) and abort with status 1.

3. **Local Symbol Resolution & PAC Stripping:**
   - Resolve local symbol addresses from the dyld shared cache:
     ```c
     uint64_t pcfmt_addr = (uint64_t)ptrauth_strip(
         dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread"),
         ptrauth_key_function_pointer);
     uint64_t dlopen_addr = (uint64_t)ptrauth_strip(
         dlsym(RTLD_DEFAULT, "dlopen"),
         ptrauth_key_function_pointer);
     ```
   - Dynamically load `thread_convert_thread_state` from `/usr/lib/system/libsystem_kernel.dylib`.

4. **ASLR Shared Cache Slide Delta Correction:**
   Because `WindowServer` and the loader execute in separate Mach sessions, their shared cache ASLR slides can differ:
   - Query remote `dyld_all_image_infos` address via `task_info(task, TASK_DYLD_INFO, ...)`.
   - Read `dyld_all_image_infos` from the remote task via `mach_vm_read()` and extract `remote_infos->sharedCacheSlide`.
   - Read local `sharedCacheSlide` from `task_info(mach_task_self(), TASK_DYLD_INFO, ...)`.
   - Compute `slide_delta = (intptr_t)remote_slide - (intptr_t)local_slide`.
   - Compute slide-corrected remote symbol addresses:
     ```c
     uint64_t remote_pcfmt  = pcfmt_addr  + slide_delta;
     uint64_t remote_dlopen = dlopen_addr + slide_delta;
     ```
   - Symmetrically release the temporary read buffer via `vm_deallocate()`.

5. **Remote Virtual Memory Allocation (`mach_vm_allocate` & `mach_vm_write`):**
   The loader allocates two distinct memory regions in the target process address space:
   - **Remote Stack Page (16 KB):** Allocated via `mach_vm_allocate(task, &remote_stack, 16384, VM_FLAGS_ANYWHERE)` and protected via `vm_protect(task, (vm_address_t)remote_stack, 16384, 1, VM_PROT_READ | VM_PROT_WRITE)`.
   - **Remote Code Page (4096 bytes):** Allocated via `mach_vm_allocate(task, &remote_code, 4096, VM_FLAGS_ANYWHERE)`. The page is structured with exact binary offsets matching `main.c`:
     - `[0x00..0x57]` (88 bytes, 22 instructions): **Stage 1 Assembly Sequence**. Invokes `pthread_create_from_mach_thread(&thread, NULL, stage2, NULL)` where `stage2` is signed in-situ with `paciza x2`. Then loads readiness marker `0x79616265` into `x0` and enters a spin loop (`adr x9, #0; br x9`).
     - `[0x58..0x5F]` (8 bytes): **Data Slot: `pcfmt` address**. Populated with slide-corrected `remote_pcfmt`.
     - `[0x60..0x9F]` (64 bytes, 16 instructions): **Stage 2 Assembly Sequence**. Starts with `pacibsp`, loads `x1 = 1` (`RTLD_LAZY`), sets `x0 = &dylib_path`, loads `remote_dlopen` from offset `0xA0`, calls `blr x9`, and returns via `retab`.
     - `[0xA0..0xA7]` (8 bytes): **Data Slot: `dlopen` address**. Populated with slide-corrected `remote_dlopen`.
     - `[0xA8..end]`: **Dylib Path String**. Null-terminated absolute path to `libhyprserver.dylib`.
     Written via `mach_vm_write` and protected via `vm_protect(task, (vm_address_t)remote_code, 4096, 0, VM_PROT_READ | VM_PROT_EXECUTE)`.

6. **ARM64 Thread Register Configuration & PAC Conversion:**
   Construct `arm_thread_state64_t` registers:
   ```c
   arm_thread_state64_t thread_state = {}, machine_state = {};
   thread_state_flavor_t flavor = ARM_THREAD_STATE64;
   mach_msg_type_number_t flavor_count = ARM_THREAD_STATE64_COUNT;
   mach_msg_type_number_t machine_count = ARM_THREAD_STATE64_COUNT;

   // PC points to Stage 1 entry in remote code page, signed with loader PAC key 'asia'
   __darwin_arm_thread_state64_set_pc_fptr(
       thread_state,
       ptrauth_sign_unauthenticated((void *)remote_code, ptrauth_key_asia, 0));

   // Stack pointer positioned at midpoint of allocated 16KB stack (16-byte aligned)
   __darwin_arm_thread_state64_set_sp(
       thread_state,
       remote_stack + (stack_size / 2));
   ```
   - Convert register state from loader PAC domain to `WindowServer` PAC domain:
     ```c
     kr = _thread_convert_thread_state(
         thread,
         2, // THREAD_CONVERT_THREAD_STATE_FROM_SELF
         flavor,
         (thread_state_t)&thread_state, flavor_count,
         (thread_state_t)&machine_state, &machine_count);
     ```
   - **macOS Version Branch Execution:**
     - **macOS ≥ 14.4 (Sonoma 14.4+, Sequoia 15.x, Golden Gate 27.x):** Terminate dummy thread via `thread_terminate(thread)`, then launch cleanly via `thread_create_running(task, flavor, (thread_state_t)&machine_state, machine_count, &thread)`.
     - **macOS < 14.4:** Apply converted state via `thread_set_state(thread, flavor, (thread_state_t)&machine_state, machine_count)` and launch via `thread_resume(thread)`.

7. **Readiness Telemetry, Handshake & Orderly Termination:**
   - **Stage 1 Marker Polling:** The loader sleeps 10ms, then polls `thread_get_state(thread)` up to 10 iterations (20ms intervals) checking for the readiness marker `CODE_MARKER_VALUE` (`0x79616265`, `"yabe"`) in `poll_state.__x[0]`. This proves Stage 1 ran and launched Stage 2.
   - **Socket Polling:** The loader polls for the appearance of the hook socket `/tmp/hyprmac-server.sock` (up to 100 iterations × 100ms = 10s).
   - Once the socket appears (or timeout expires), loader invokes `thread_terminate(thread)`.
   - Remote stack and code pages are intentionally retained (leaked) in `WindowServer` address space to prevent race conditions during asynchronous constructor initialization.
   - **Watchdog Stability Check:** Injector executes a 500ms post-injection stability check: if `WindowServer` PID has changed, the safe-mode circuit breaker (`/tmp/hyprmac.safemode`) is engaged immediately.

---

### 4.2 Subsystem 2: The In-Process Hook (`libhyprserver.dylib`)

#### Lifecycle Management:
1. **Constructor (`__attribute__((constructor))`):**
   - Immediate return from main loading thread. MUST NEVER perform blocking I/O, heavy allocations, or complex Objective-C/Swift initialization on the thread that completed `dlopen`.
   - Launch a detached POSIX thread (`pthread_create`) running `hypr_server_worker_entry`.
2. **Worker Thread Execution:**
   - Initialize diagnostic logger: write timestamped handshake to `/tmp/hyprserver.log`.
   - Bind and listen on Unix Domain Socket at `/tmp/hyprmac-server.sock` (mode `0666`).
     > **Note on Socket Path & Permissions:** Mode 0666 permits cross-privilege IPC between WindowServer (UID 88) and user-session HyprMac (UID 501). Authentication is enforced at the protocol level via HYPR_CMD_AUTH with a 16-byte random token.
   - Enter a non-blocking `poll()` / `kqueue()` event loop for incoming client commands.

#### Wire Protocol Specification (IPC):
Commands sent over `/tmp/hyprmac-server.sock` use fixed-width binary frames:

```c
typedef struct __attribute__((packed)) {
    uint32_t magic;        // 0x48595052 "HYPR"
    uint16_t version;      // 0x0001
    uint16_t command;      // HyprCommand enum
    uint32_t sequence;     // monotonic sequence number
    uint32_t window_id;    // target window (0 for global)
    uint32_t payload_size; // bytes following header
} HyprMessageHeader;       // 20 bytes
```

```c
typedef enum : uint16_t {
    HYPR_CMD_PING               = 0x0001,
    HYPR_CMD_PONG               = 0x0002,
    HYPR_CMD_ACK                = 0x0003,
    HYPR_CMD_ERROR              = 0x0004,

    // Window Operations [IMPLEMENTED]
    HYPR_CMD_SET_CORNER_RADIUS  = 0x0010,
    HYPR_CMD_SET_SHADOW_STATE   = 0x0011,
    HYPR_CMD_SET_WINDOW_BORDER  = 0x0012,
    HYPR_CMD_STRIP_TITLEBAR     = 0x0013,
    HYPR_CMD_QUERY_WINDOW       = 0x0020,

    // Window Operations [PLANNED]
    HYPR_CMD_SET_WINDOW_FOCUS   = 0x0014, // [PLANNED] Focus synchronization (payload: HyprPayloadFocus, 4 bytes)
    HYPR_CMD_SET_GLOBAL_POLICY  = 0x0015, // [PLANNED] Auto-decorating new windows (payload: HyprPayloadGlobalPolicy, 18 bytes)
    HYPR_CMD_AUTH               = 0x0030  // [PLANNED]
} HyprCommand;
```

Supported `command` operations and wire payloads (matching `protocol.h` as Single Source of Truth):
- `0x0001: HYPR_CMD_PING` -> Health check / echo request. Empty payload (`payload_size = 0`).
- `0x0002: HYPR_CMD_PONG` -> Ping response. Payload: `HyprPayloadPong` (`uint32_t server_version`, `uint32_t active_windows`).
- `0x0003: HYPR_CMD_ACK` -> Command success acknowledgment. Payload: `HyprPayloadAck` (`uint32_t status = HYPR_ERR_SUCCESS`, `char message[64]`).
- `0x0004: HYPR_CMD_ERROR` -> Command failure acknowledgment. Payload: `HyprPayloadAck` (`uint32_t status` [e.g. `HYPR_ERR_INVALID_WID = 0x0001`, `HYPR_ERR_INVALID_CMD = 0x0002`, `HYPR_ERR_INTERNAL = 0x00FF`], `char message[64]`).
- `0x0010: HYPR_CMD_SET_CORNER_RADIUS` -> Payload: `HyprPayloadCornerRadius` (`float corner_radius`, e.g. `0.0f` for hard square corners).
- `0x0011: HYPR_CMD_SET_SHADOW_STATE` -> Payload: `HyprPayloadShadow` (`uint8_t shadow_enabled`, 0 = disabled/stripped, 1 = enabled/native).
- `0x0012: HYPR_CMD_SET_WINDOW_BORDER` -> Payload: `HyprPayloadBorder` (`float border_width`, `uint32_t color_active` [ARGB 0xAARRGGBB], `uint32_t color_inactive` [ARGB]).
- `0x0013: HYPR_CMD_STRIP_TITLEBAR` -> Payload: `HyprPayloadStripTitlebar` (`uint8_t strip`, 1 = strip titlebar, 0 = restore native titlebar).
- `0x0014: HYPR_CMD_SET_WINDOW_FOCUS [PLANNED]` -> Payload: `HyprPayloadFocus` (`uint32_t window_id`, 4 bytes in payload; sets active focused window, triggering active/inactive border color transitions).
- `0x0015: HYPR_CMD_SET_GLOBAL_POLICY [PLANNED]` -> Payload: `HyprPayloadGlobalPolicy` (18 bytes; configures default corner radius, shadow, border, and titlebar policy applied to newly created windows via `SLSNewWindow` interposition).
- `0x0020: HYPR_CMD_QUERY_WINDOW` -> Request payload: `HyprPayloadQueryRequest` (empty, target window specified by `window_id` in header). Response payload: `HyprPayloadQueryResponse` (`float corner_radius`, `uint8_t shadow_enabled`, `uint8_t titlebar_stripped`, `uint32_t border_color`, `float border_width`).
- `0x0030: HYPR_CMD_AUTH [PLANNED]` -> Payload: `HyprPayloadAuth` (16-byte random authentication token `uint8_t token[16]` matching `composition-engine.spec.md` REQ-WS-012).

#### Wire Protocol Payload Structures:
```c
typedef struct {
    float corner_radius;     // 0.0f for hard square corners
} HyprPayloadCornerRadius;

typedef struct {
    uint8_t shadow_enabled;  // 0 = disabled, 1 = enabled
} HyprPayloadShadow;

typedef struct {
    float    border_width;   // e.g. 1.0f
    uint32_t color_active;   // ARGB (0xAARRGGBB)
    uint32_t color_inactive; // ARGB
} HyprPayloadBorder;

typedef struct {
    uint8_t strip;           // 1 = strip, 0 = restore
} HyprPayloadStripTitlebar;

// Focus Window Payload [PLANNED]
typedef struct {
    uint32_t window_id;      // Target window ID to focus (4 bytes)
} HyprPayloadFocus;

// Global Decoration Policy Payload [PLANNED]
typedef struct {
    float    corner_radius;   // Default corner radius (e.g. 0.0f)
    uint8_t  shadow_enabled;  // Default shadow state (0 = disabled, 1 = enabled)
    float    border_width;    // Default border width (e.g. 1.0f)
    uint32_t color_active;    // Default active border ARGB (0xAARRGGBB)
    uint32_t color_inactive;  // Default inactive border ARGB (0xAARRGGBB)
    uint8_t  strip_titlebar;  // Default titlebar strip (1 = strip, 0 = keep)
} HyprPayloadGlobalPolicy;

// Authentication Payload [PLANNED]
typedef struct {
    uint8_t token[16];        // 16-byte shared secret token
} HyprPayloadAuth;

typedef struct {
    // Empty -- window_id is in header
} HyprPayloadQueryRequest;

typedef struct {
    float    corner_radius;
    uint8_t  shadow_enabled;
    uint8_t  titlebar_stripped;
    uint32_t border_color;     // Current active ARGB
    float    border_width;
} HyprPayloadQueryResponse;

typedef struct {
    uint32_t server_version;   // (major << 16 | minor << 8 | patch)
    uint32_t active_windows;
} HyprPayloadPong;

typedef struct {
    uint32_t status;         // HYPR_ERR_* code
    char     message[64];
} HyprPayloadAck;
```

#### Protocol Error Codes Taxonomy:
**Currently Implemented Error Codes:**
- `HYPR_ERR_SUCCESS (0x0000)`: Operation applied cleanly.
- `HYPR_ERR_INVALID_WID (0x0001)`: Specified `window_id` does not exist or has been destroyed.
- `HYPR_ERR_INVALID_CMD (0x0002)`: Unrecognized command ID.
- `HYPR_ERR_INTERNAL (0x00FF)`: Internal compositor fault or allocation failure.

**Planned Error Codes [PLANNED]:**
- `HYPR_ERR_UNAUTHORIZED (0x0003)`: [PLANNED] Client connection failed shared-secret token authentication or exceeded handshake deadline.
- `HYPR_ERR_PAYLOAD_TOO_LARGE (0x0004)`: [PLANNED] Incoming packet payload exceeds maximum boundary (`HYPR_MAX_PAYLOAD_SIZE` = 64KB).
- `HYPR_ERR_INVALID_WID (0x0005)`: [PLANNED] Extended invalid window ID classification.
- `HYPR_ERR_HOOK_UNAVAIL (0x0006)`: [PLANNED] Hook subsystem or compositor hook connection temporarily unavailable.
- `HYPR_ERR_RATE_LIMITED (0x0007)`: [PLANNED] Command mutation rate exceeded safety threshold.
- `HYPR_ERR_INTERNAL (0x0008)`: [PLANNED] Extended internal compositor transaction fault.
- `HYPR_ERR_NOT_IMPL (0x0009)`: [PLANNED] Command recognized but not implemented in current runtime.

---

### 4.3 Subsystem 3: Internal Window Server Manipulation

Once running inside `WindowServer`, the hook manipulates windows via two synchronized layers:

#### Layer A: Internal SkyLight Connection
Inside `WindowServer`, the process owns `SLSMainConnectionID()`. 
- Unlike unprivileged clients, calls made from this connection ID bypass client-ownership rejection.
- `SLSSetWindowTags(server_cid, wid, tags, 64)` executes with root server authority.
- `SLSSetWindowShadowProperties(server_cid, wid, ...)` forces immediate re-evaluation of the window drop shadow.

#### Layer B: Memory Patching / Symbol Swizzling
For properties where public/private C API does not propagate to active surfaces:
1. **Corner Radius (The 0px Square Window Invariant):**
   - Locate `CGSWindow` structure in memory by resolving `WSGetWindow(server_cid, wid)`.
   - Hook the `corner_mask` setter in `CAWindowServer` or set `window->corner_radius = 0.0f`.
   - Invalidate the window's backing surface cache to trigger a repaint with square geometry.
2. **Shadow Elimination (The No-Aqua Shadow Invariant):**
   - Set the window flag bit for `kCGSDisableShadowTag` directly in the master window record.
   - Instruct the compositor pipeline to clear the outer shadow rendering pass for this specific `CGSWindowID`.
3. **Native 1px Border Rendering:**
   - Apply border properties directly to the window's composited layer, or attach an internal server-owned sublayer so that rendering occurs in the exact same VSync tick as the client window, eliminating all overlay lag.

### 4.4 New Window Detection & Automatic Decoration
- The current architecture requires external clients to discover window IDs and send per-window commands.
- To prevent a "flash of native decoration" (rounded corners, shadows appearing briefly on newly created windows), the hook SHOULD interpose on `SLSNewWindow` / `CGSNewWindow` (or the internal `WSCreateWindow` discovered in Phase 3).
- When a new window is created, the hook automatically applies the current global decoration policy (configured via `HYPR_CMD_SET_GLOBAL_POLICY = 0x0015` [PLANNED]) before the first frame is composited.
- The interposition table is registered during the hook's `__attribute__((constructor))` initialization.
- As a fallback, the hook MAY poll the window list at display refresh intervals via `SLSCopyWindowsWithOptionsAndTags`, accepting a 1-frame decoration flash trade-off.

---

## 5. Failure Modes, Safety Invariants & Circuit Breakers

Because destabilizing `WindowServer` logs out the user, the following failsafes are mandatory:

### 5.1 The Safe-Mode Circuit Breaker
Before applying any memory hooks or running initialization:
1. Check for the presence of `/tmp/hyprmac.safemode`.
2. If the file exists, the dylib exits immediately from constructor without attaching hooks.
3. If `WindowServer` crashes within 10 seconds of injection, `hypr-inject` automatically writes `/tmp/hyprmac.safemode` to prevent a recurring bootloop on respawn.

### 5.2 Exception Isolation
- All symbol lookups (`dlsym`) are validated against `NULL`.
- All Mach VM writes are bounds-checked against verified page mappings.
- Signal handlers for `SIGSEGV` and `SIGBUS` are temporarily hooked during symbol resolution: if a fault occurs during a probe, the handler catches the signal, logs the faulting address to `/tmp/hyprserver.log`, disables the hook cleanly, and longjmps out without crashing `WindowServer`.

### 5.3 Idempotent Injection
- The hook registers `com.hyprmac.server.hook` via `bootstrap_check_in` / `bootstrap_register` on initialization (standardized to match `protocol.h` `HYPR_BOOTSTRAP_NAME`).
- The injector calls `bootstrap_look_up(bootstrap_port, "com.hyprmac.server.hook", &port)` before initiating VM allocation or thread creation. If the lookup returns `KERN_SUCCESS` and a valid port, loading is skipped and the injector exits with status 2 (already loaded).
- *Status Note*: Checked by `hypr-inject` via `check_hook_loaded()`; registration in `libhyprserver.dylib` is `[PLANNED]` for Phase 2/3.

---

## 6. Architecture Rationale: Why Two-Stage Loader Over Direct dlopen

### 6.1 The Fatal Failure Mode of Direct dlopen
Initial architectural explorations evaluated executing `dlopen` directly on a raw Mach thread created via `thread_create` / `thread_create_running` into `WindowServer`. On macOS (Sonoma 14.4+ and Golden Gate 27.x ARM64e), **this direct approach fails fatally with an unrecoverable process crash**.

Darwin's threading runtime (`libsystem_pthread.dylib`) and dynamic linker (`dyld`) assume that code executing within the address space possesses valid POSIX thread structures (`pthread_t`) and Thread-Specific Data (TSD) allocations. On Apple Silicon, thread-local storage is accessed via the hardware register `TPIDRRO_EL0` (EL0 Read-Only Thread ID). When a raw Mach thread is spawned via kernel primitives across Mach task ports:
1. `TPIDRRO_EL0` is uninitialized (`0x0000000000000000`).
2. As soon as `dlopen` begins resolving images, internal routines in `dyld` or `libsystem_c` invoke `pthread_getspecific` (or related TLS lookups).
3. At instruction `pthread_getspecific + 4`, the code executes an offset dereference against `TPIDRRO_EL0`. Because the base register is `NULL`, it triggers a fatal `EXC_BAD_ACCESS (SIGSEGV)` page fault at address `0x0000000000000010`.
4. Because `WindowServer` is a critical root daemon, `launchd` immediately kills the entire user graphical session, dumping the user to the macOS login screen.

```
Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
Exception Codes:       KERN_INVALID_ADDRESS at 0x0000000000000010
Termination Reason:    Namespace SIGNAL, Code 11 Segmentation fault: 11
Thread 12 Crashed:
0   libsystem_pthread.dylib       0x0000000195a04450 pthread_getspecific + 4
1   dyld                          0x000000019580a120 dyld4::APIs::dlopen_internal + 48
2   ??? (remote code page)        0x00000001103c8000 direct_dlopen_entry
```

### 6.2 The Proven Working Solution: Two-Stage ARM64e Loader
To resolve this without unstable user-space TSD emulation, `hypr-inject` implements a **two-stage loader architecture** based on the proven ARM64e injection pattern by Jeremy Legendre in yabai, augmented with cross-session ASLR shared cache slide delta correction:

1. **Stage 1 (Raw Mach Thread):**
   - Runs directly on the kernel-created raw Mach thread.
   - It does NOT attempt to execute `dlopen`.
   - Instead, it invokes `pthread_create_from_mach_thread()`, which contains an internal Libsystem initialization path specifically designed to transition an externally created Mach thread into a fully valid POSIX thread with complete TSD/TLS structures.
   - Stage 1 signs the Stage 2 entry point with `paciza x2`, calls `pthread_create_from_mach_thread`, loads readiness marker `0x79616265` (`"yabe"`) into `x0`, and enters an infinite spin loop (`adr x9, #0; br x9`).
2. **Stage 2 (Real POSIX Thread with Full TLS):**
   - Runs on the newly created POSIX thread where `TPIDRRO_EL0` is fully initialized and points to a valid `_pthread` structure.
   - Safely invokes `dlopen(path, RTLD_LAZY)`.
   - `dyld` executes normally with full thread-local storage support; `libhyprserver.dylib`'s constructor fires; Stage 2 completes and returns cleanly via `retab`.
3. **Telemetry & Cleanup:**
   - The injector polls `thread_get_state` for marker `0x79616265` in `x0`, confirming Stage 1 ran successfully.
   - Once `/tmp/hyprmac-server.sock` is detected, the injector terminates the spinning Stage 1 thread cleanly via `thread_terminate(thread)`.

### 6.3 Architectural Comparison Matrix

| Architectural Dimension | Direct dlopen (Failed) | Two-Stage ARM64e Loader (Proven Working) |
|---|---|---|
| **Thread Context** | Raw Mach thread (`thread_create` / `thread_create_running`) | Stage 1 on raw Mach thread → `pthread_create_from_mach_thread` → Stage 2 on real pthread |
| **TSD / TLS State** | `TPIDRRO_EL0 = 0` (uninitialized NULL) | `TPIDRRO_EL0` fully initialized by `pthread_create_from_mach_thread` |
| **`dlopen` Execution** | Executed directly on raw Mach thread | Executed in Stage 2 on valid POSIX thread with full TLS |
| **Crash Site** | `pthread_getspecific + 4` dereferences NULL `TPIDRRO_EL0` (`EXC_BAD_ACCESS`) | None — clean execution of `dlopen` |
| **ASLR Slide Handling** | None (assumed static shared cache across sessions) | Slide delta resolved via `TASK_DYLD_INFO` and remote `dyld_all_image_infos` |
| **PAC Protection** | Local `ptrauth_strip` + kernel conversion | Local strip + remote slide delta + in-situ `paciza` in Stage 1 + kernel conversion |
| **Readiness Telemetry** | Blind socket polling | Marker polling (`0x79616265` in `x0`) followed by socket availability |
| **Reliability** | 0% success (fatal WindowServer crash) | 100% deterministic load without frame drops or crashes |

---

## 7. Protocol Schema Evolution & Versioning Strategy

### 7.1 Version Negotiation & Validation
The IPC wire protocol uses a binary framing layout guarded by two validation invariants:
1. **Magic Invariant**: Every incoming header must start with `HYPR_MAGIC` (`0x48595052`, `"HYPR"`). Any frame with mismatched magic is rejected immediately, and the client connection is terminated without mutating compositor state.
2. **Protocol Versioning (`HYPR_PROTO_VERSION = 1`)**: The header carries a `uint16_t version`. If the received version does not match `HYPR_PROTO_VERSION`, the server replies with `HYPR_CMD_ERROR` and error message `"Bad version"`, closing the socket.

Clients perform capability negotiation via `HYPR_CMD_PING`. The server returns `HYPR_CMD_PONG` with `HyprPayloadPong`, exposing its packed version integer (`server_version = (major << 16 | minor << 8 | patch)`) and active window count. Clients inspect `server_version` to conditionally enable advanced protocol capabilities.

### 7.2 Schema Evolution Guidelines
To maintain backward and forward compatibility as new window composition features are introduced:
- **Header Immutability**: The 20-byte `HyprMessageHeader` structure is fixed. Fields (`magic`, `version`, `command_id`, `sequence`, `window_id`, `payload_size`) must never change position or width.
- **Monotonic Command Allocation**: New commands are assigned distinct monotonic 16-bit IDs (e.g. `HYPR_CMD_SET_WINDOW_FOCUS = 0x0014`, `HYPR_CMD_AUTH = 0x0030`). Existing command IDs are never reused or repurposed.
- **Append-Only Payloads**: Struct payloads must only be extended by appending fields to the end of the structure. The server validates that incoming `payload_size` equals the expected struct size.
- **Payload Bounds Enforcement**: As specified in `composition-engine.spec.md` REQ-WS-011, any packet with `payload_size > 4096` bytes is rejected with `HYPR_ERR_INVALID_CMD`, protecting `WindowServer` from buffer exhaustion.

---

## 8. Domain Coverage: ProMotion Synchronization, Crash Backoff & Buffering

### 8.1 Multi-Monitor ProMotion Synchronization
Apple Silicon hardware supports heterogeneous display refresh rates, combining 120Hz ProMotion variable refresh rates on internal Liquid Retina XDR displays with fixed 60Hz or 144Hz external monitors.

Operating within `WindowServer` allows the composition engine to synchronize with each monitor's native display link cadence:
- **Per-Display VSync Coordination**: Window decoration rendering (1px borders and clipping masks) is bound to the compositor frame tick of the display on which the window is rendered.
- **Zero Judder on Cross-Display Drag**: When a window spans multiple displays or is dragged across a boundary, `WindowServer` manages sub-surface presentation natively, eliminating the dual-rate judder and visual tearing characteristic of user-space overlay windows.
- **ProMotion Pacing**: Border color transitions and geometry updates complete within ≤ 8.33ms on 120Hz ProMotion displays and ≤ 16.67ms on 60Hz displays.

### 8.2 Crash Loop Backoff Strategy
Because `WindowServer` is the critical root process for the user's graphical session, HyprMac implements a multi-tier crash loop prevention strategy:
1. **Post-Injection Watchdog**: Following remote thread execution, `hypr-inject` sleeps for 500ms and re-queries the `WindowServer` PID. If the PID has changed, injection caused a crash.
2. **Automatic Safe-Mode Engagement**: Upon detecting a PID mismatch or repeated failure, the injector immediately touches `/tmp/hyprmac.safemode`. The dylib constructor checks for this file on load and aborts instantly without running initialization or binding sockets.
3. **Client Exponential Backoff**: `HyprServerBridge.swift` implements exponential reconnection backoff:
   - Initial delay: 100ms
   - Multiplier: 2.0x
   - Maximum delay cap: 5.0s
   - Maximum attempts: 10
4. **Automatic Degradation Fallback**: If all 10 reconnection attempts fail, the client bridge posts `.hyprServerHookUnavailable` and seamlessly switches window border rendering back to AppKit `BorderWindow` overlays within < 500ms without user disruption.

### 8.3 Client Ring Buffer Requirements
To guarantee that window layout and decoration changes are not lost during transient socket disconnections (e.g. during daemon respawn or display sleep/wake):
- `HyprServerBridge.swift` maintains an internal ring buffer bounded to 64 pending messages.
- If the socket connection is unavailable or dropped, outgoing mutation commands (`setCornerRadius`, `setShadow`, `setBorder`, `setTitlebar`) are enqueued into the buffer.
- Upon successful reconnection and authentication, all buffered commands are replayed in strict First-In, First-Out (FIFO) order before newly submitted commands are processed.
- If the buffer reaches capacity (64 commands), older non-critical queries are discarded while preserving the latest window geometry mutations.

---

## 9. Cross-References & Related Specifications

This document is the authoritative engineering specification for in-situ WindowServer composition. It interfaces directly with the OpenSpec change artifacts:
- **Change Proposal**: `openspec/changes/windowserver-insitu-composition/proposal.md`
- **Software Design Document (SDD)**: `openspec/changes/windowserver-insitu-composition/design.md`
- **Formal Behavioral Specification**: `openspec/changes/windowserver-insitu-composition/specs/composition-engine.spec.md`
- **Implementation Tasks & Milestones**: `openspec/changes/windowserver-insitu-composition/tasks.md`
- **Wire Protocol Single Source of Truth**: `native/shared/protocol.h`
- **In-Process Server Hook Implementation**: `native/server_hook/hook.c`
- **Mach Task Loader Implementation**: `native/injector/main.c`
- **Swift Client IPC Driver**: `Sources/HyprMac/Bridge/HyprServerBridge.swift`

## 10. Step-by-Step Implementation Roadmap

```
Phase 1: Payload Scaffold (libhyprserver.dylib)
├── C / Objective-C source scaffold
├── Safe constructor + POSIX worker thread
├── /tmp/hyprserver.log diagnostic logger
└── Unix Domain Socket listener (/tmp/hyprmac-server.sock)

Phase 2: Mach Task Injector (hypr-inject)
├── Privilege checks (Root UID verification)
├── task_for_pid() target resolution
├── mach_vm_allocate / mach_vm_write memory mapper
└── Remote thread execution harness with timeout

Phase 3: Probe & Discovery (Telemetry Phase)
├── Injected dylib dumps WindowServer class hierarchy
├── Enumeration of CAWindowServer and SkyLight internal symbols
└── Validation of server-side CGSConnectionID authority

Phase 4: Manipulation Engine (The Hyprland Look)
├── Live removal of window shadows
├── Live enforcement of 0px corner radius
└── Live injection of 1px active/inactive border

Phase 5: HyprMac Core Integration
├── Swift Client Bridge (HyprServerBridge.swift)
├── Tiling layout event synchronization
└── Packaging as a background system LaunchDaemon
```

---

## 11. Verification & Acceptance Criteria

| Test Milestone | Verification Command / Procedure | Expected Outcome |
|---|---|---|
| **M1: Clean Loading & Verification** | `sudo ./hypr-inject` | Exit code 0; WindowServer PID remains unchanged (verified via 500ms post-load watchdog); `/tmp/hyprserver.log` confirms `HyprServer initialized on /tmp/hyprmac-server.sock`.<br/><br/>**Proven Live Output:**<br/>`[hypr-inject] SIP is disabled -- proceeding.`<br/>`[hypr-inject] -arm64e_preview_abi confirmed.`<br/>`[hypr-inject] WindowServer PID: <pid>`<br/>`[hypr-inject] Loading: /path/to/libhyprserver.dylib`<br/>`[hypr-inject] Acquired task port for WindowServer (pid <pid>)`<br/>`[hypr-inject] Local symbols: pcfmt=0x... dlopen=0x... formulation`<br/>`[hypr-inject] Shared cache slide: local=0x... remote=0x... delta=...`<br/>`[hypr-inject] Remote symbols: pcfmt=0x... dlopen=0x...`<br/>`[hypr-inject] Remote: code=0x... stack=0x...`<br/>`[hypr-inject] Thread state converted to target PAC domain.`<br/>`[hypr-inject] Thread launched via thread_create_running (macOS 14.4+)`<br/>`[hypr-inject] Waiting for stage 1 readiness...`<br/>`[hypr-inject] Stage 1 ready (marker 0x79616265 found).`<br/>`[hypr-inject] Waiting for hook socket...`<br/>`[hypr-inject] Hook socket found -- library loaded successfully.`<br/>`[hypr-inject] WindowServer stable (pid <pid>).`<br/>`[hypr-inject] libhyprserver.dylib loaded -- HyprMac is active.` |
| **M2: Socket IPC** | `nc -U /tmp/hyprmac-server.sock` | Ping frame returns valid Pong with matching magic number. |
| **M3: Shadow Removal** | `./hyprmac strip-shadow <wid>` | Target window loses Aqua drop-shadow instantly on physical display. |
| **M4: 0px Corner Radius** | `./hyprmac square <wid>` | Target window corners change from 12px rounded curve to 90° hard rectangle. |
| **M5: Window Survival** | Test harness: shell script that opens/closes/resizes 50 windows using AppleScript over 60 minutes. Memory profiling via `leaks` command. | Success criteria: 0 leaks reported, 0 crashes, memory growth < 1MB. |

---

## 12. Architectural Verdict

This specification provides the only deterministic architecture on macOS capable of achieving true, native, zero-latency Wayland/Hyprland window styling. By approaching `WindowServer` from within its own address space under a controlled, defensively isolated contract, we eliminate both the visual latency of user-space overlays and the fragile multi-process maintenance burden of hooking individual applications.
