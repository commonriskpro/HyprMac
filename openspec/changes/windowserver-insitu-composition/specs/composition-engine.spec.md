# Specification: composition-engine

## Scope & Purpose
This specification defines the formal behavioural requirements, protocol contracts, and safety guarantees for the in-situ `WindowServer` composition hook subsystem within `HyprMac`.

## References & Architectural Context
- **Proposal**: `openspec/changes/windowserver-insitu-composition/proposal.md`
- **Software Design Document (SDD)**: `openspec/changes/windowserver-insitu-composition/design.md`
- **Low-Level Architecture Specification**: `docs/WINDOWSERVER_INJECTION_SPEC.md`
- **Ground Truth Implementation Artifacts**:
  - Mach Injector: `native/injector/main.c`
  - In-Process Server Hook: `native/server_hook/hook.c`
  - Wire Protocol & Shared Constants: `native/shared/protocol.h`
  - Swift Client Bridge: `Sources/HyprMac/Bridge/HyprServerBridge.swift`

---

## 1. Mach Injection, Pre-flight & Lifecycle Invariants

### REQ-WS-001: Privileged Task Port Acquisition [IMPLEMENTED]
The injector `hypr-inject` MUST run as root (effective UID 0). It SHALL locate the active `WindowServer` process and acquire its Mach task port using `task_for_pid()`. If `task_for_pid()` fails due to insufficient privilege or active kernel restrictions, the injector MUST exit with status code `1` and log an explicit failure reason to stderr without mutating process memory.

#### Feature: Privileged Task Port Acquisition and Execution Pre-Flight
```gherkin
Feature: Privileged Task Port Acquisition and Execution Pre-Flight
  Scenario: Injector invoked by non-root user
    Given an execution context where geteuid() != 0
    When hypr-inject is executed
    Then the process MUST abort immediately with error code 1
    And emit an error to stderr indicating root privileges are required

  Scenario: Clean task port acquisition
    Given an execution context where geteuid() == 0 and SIP is disabled
    When hypr-inject resolves the PID of WindowServer
    Then task_for_pid() SHALL return KERN_SUCCESS and a valid mach_port_t
```

---

### REQ-INJ-001: Idempotent Injection & Bootstrap Registry [PLANNED]
The injector `hypr-inject` MUST perform an idempotency check before initiating any Mach VM allocation or remote thread creation. The injector SHALL query the bootstrap service registry for the active hook via `bootstrap_look_up(bootstrap_port, HYPR_BOOTSTRAP_NAME, &port)` (where `HYPR_BOOTSTRAP_NAME` is `"com.hyprmac.server.hook"`). If the lookup returns `KERN_SUCCESS` and a valid port, the hook is confirmed loaded; the injector MUST release the port, log that the hook is already active, and exit with status code `2` without creating additional threads or loading the library again.

> **Implementation Status [PLANNED]:**
> The injector `native/injector/main.c` implements `check_hook_loaded()` using `bootstrap_look_up(bootstrap_port, HYPR_BOOTSTRAP_NAME, &port)`. However, `native/server_hook/hook.c` does NOT currently register `HYPR_BOOTSTRAP_NAME` (`com.hyprmac.server.hook`) with `bootstrap_register2()` or the Mach bootstrap namespace. As a result, the lookup does not detect an already loaded hook via bootstrap ports. Mach bootstrap port registration in `hook.c` is marked as `[PLANNED]`.

#### Feature: Idempotent Injection and Bootstrap Registry
```gherkin
Feature: Idempotent Injection and Bootstrap Registry
  Scenario: Injector runs while hook is already active
    Given the hook is already loaded in WindowServer
    When the injector runs again
    Then it SHALL detect the existing hook via bootstrap port lookup bootstrap_look_up("com.hyprmac.server.hook")
    And it SHALL deallocate the retrieved mach port
    And it SHALL exit with status code 2 without creating additional threads or loading the library again
```

---

### REQ-INJ-002: SIP Pre-flight Validation [IMPLEMENTED]
The injector `hypr-inject` MUST validate System Integrity Protection (SIP) configuration before attempting privileged Mach operations. When the injector starts, it SHALL inspect SIP status by executing `csrutil status` via `popen()` and parsing the output for the substring `"disabled"`. If SIP is enabled or its status cannot be confirmed disabled, the injector SHALL print an actionable diagnostic message to stderr and exit immediately with status code `1`.

#### Feature: System Integrity Protection (SIP) Pre-Flight Validation
```gherkin
Feature: System Integrity Protection (SIP) Pre-Flight Validation
  Scenario: SIP enabled without task_for_pid permission
    Given SIP is enabled on the host system
    When the injector starts
    Then it SHALL execute csrutil status via popen()
    And if the output does not contain the substring "disabled"
    Then the injector SHALL print a diagnostic error message to stderr
    And exit immediately with status code 1
```

---

### REQ-INJ-003: Boot Argument Validation (ARM64e) [IMPLEMENTED]
On Apple Silicon hardware (`arm64`/`arm64e`), the injector MUST verify kernel boot arguments before dispatching execution to an injected dynamic library. When starting on an Apple Silicon system, the injector SHALL inspect the `kern.bootargs` sysctl string for the presence of `-arm64e_preview_abi`. If the argument is absent, the injector SHALL print a diagnostic error message to stderr and exit with status code `1`.

#### Feature: Apple Silicon Boot Argument Verification
```gherkin
Feature: Apple Silicon Boot Argument Verification
  Scenario: Apple Silicon system missing required boot argument
    Given the host platform is Apple Silicon (arm64 or arm64e)
    When the injector starts
    Then it SHALL inspect sysctl kern.bootargs for -arm64e_preview_abi
    And if absent, it SHALL print an error message to stderr and exit with status code 1
```

---

### REQ-INJ-004: Post-injection Crash Watchdog [IMPLEMENTED]
Following remote thread dispatch, the injector MUST monitor initialization and `WindowServer` stability over a post-injection observation window. The injector SHALL poll for the creation of the IPC socket at `/tmp/hyprmac-server.sock` using `access(HYPR_SOCKET_PATH, F_OK)` (polling up to 100 iterations at 100ms intervals, for a maximum timeout of 10 seconds). Following socket appearance, the injector SHALL wait for 500ms and verify that the target `WindowServer` PID has not changed. If `WindowServer` restarted, the injector MUST create the safe-mode tombstone `/tmp/hyprmac.safemode` and exit with status code `1`.

#### Feature: Post-Injection Crash Watchdog and Safe-Mode Recovery
```gherkin
Feature: Post-Injection Crash Watchdog and Safe-Mode Recovery
  Scenario: Post-injection socket readiness and stability verification
    Given remote thread dispatch has executed
    When the injector waits for hook initialization
    Then it SHALL poll access(HYPR_SOCKET_PATH, F_OK) at /tmp/hyprmac-server.sock up to 10 seconds
    And upon socket detection, it SHALL wait for 500ms
    And verify that the active WindowServer PID matches the pre-injection PID
    And if the PID has changed, it SHALL create /tmp/hyprmac.safemode and exit with status code 1
```

---

### REQ-INJ-005: Two-Stage PAC-Safe Remote Execution & Thread State Conversion [IMPLEMENTED]
When dispatching code execution into `WindowServer` on ARM64e, the injector MUST employ a two-stage execution architecture rather than directly invoking `dlopen` on a raw Mach thread:

1. **Stage 1 (Raw Mach Thread Execution)**: The injector SHALL spawn a raw Mach thread whose PC is directed to a Stage 1 assembly bootstrap routine. This routine MUST invoke `pthread_create_from_mach_thread` to transition execution from an uninitialized Mach thread into a fully initialized POSIX thread. Following dispatch, Stage 1 MUST enter a spin loop writing the readiness marker `0x79616265` (`"yabe"`) into register `x0`.
2. **Stage 2 (POSIX Thread Execution with TLS)**: The POSIX thread spawned by Stage 1 SHALL execute the Stage 2 routine with full Thread-Local Storage (TLS) enabled. Stage 2 MUST call `dlopen(dylib_path, RTLD_LAZY)` and return via `retab`.
3. **ASLR Shared Cache Slide Delta Correction**: The injector MUST calculate the ASLR slide difference between the injector process and `WindowServer`. It SHALL query `task_info(target_task, TASK_DYLD_INFO, ...)` and read `dyld_all_image_infos.sharedCacheSlide` via `mach_vm_read()` to determine the remote slide, compare it to the local `sharedCacheSlide`, and apply the delta (`delta = remote_slide - local_slide`) to `pthread_create_from_mach_thread` and `dlopen` function pointers before copying them into the remote code page data slots. The injector MUST call `vm_deallocate` to symmetrically release the `mach_vm_read` buffer.
4. **PAC Pointer Authentication & State Conversion**: The injector SHALL strip PAC from local function pointers via `ptrauth_strip(..., ptrauth_key_function_pointer)`. It MUST PAC-sign the remote code entry point (PC) and stack pointer (SP) using `ptrauth_sign_unauthenticated` with key `ptrauth_key_asia` before calling `_thread_convert_thread_state(thread, 2, ARM_THREAD_STATE64, ...)`.
5. **Thread Launch**: On macOS 14.4 and later (`os_major == 14 && os_minor >= 4` or `os_major >= 15`), the injector SHALL launch the thread via `thread_create_running` using the converted machine state. On earlier macOS versions, it SHALL launch via `thread_set_state` followed by `thread_resume`. The injector SHALL NOT use `__DARWIN_ARM_THREAD_STATE64_FLAGS_NO_PTRAUTH`.
6. **Watchdog & Cleanup**: The injector SHALL poll `thread_get_state` for the Stage 1 readiness marker (`x0 == 0x79616265`), poll for the creation of `/tmp/hyprmac-server.sock`, terminate the spinning Stage 1 Mach thread via `thread_terminate`, and deallocate the Mach task port via `mach_port_deallocate`.

> **Architectural Rationale (Why Direct dlopen Crashes on Raw Mach Threads):**
> On Darwin / ARM64e systems, raw Mach threads allocated via `thread_create` possess uninitialized Thread-Local Storage: the CPU thread register `TPIDRRO_EL0` is initialized to `0`. `dlopen` internally invokes `pthread_getspecific`, libdyld initialization routines, and locale/allocator mechanisms that unconditionally dereference `TPIDRRO_EL0`. Invoking `dlopen` directly on a raw Mach thread triggers an immediate kernel panic or `SIGSEGV` crash in `WindowServer`. The two-stage loader eliminates this failure mode at the root: `pthread_create_from_mach_thread` has a dedicated kernel/libpthread bypass allowing a raw Mach thread to bootstrap a fully initialized POSIX thread with valid TLS (`TPIDRRO_EL0 != 0`) before Stage 2 calls `dlopen`.

#### Feature: Two-Stage PAC-Safe Remote Execution and Thread State Conversion
```gherkin
Feature: Two-Stage PAC-Safe Remote Execution and Thread State Conversion
  Scenario: Two-stage execution with TLS initialization via pthread_create_from_mach_thread
    Given an ARM64e target thread created inside WindowServer with TPIDRRO_EL0 = 0
    When preparing remote execution registers for dylib loading
    Then Stage 1 MUST invoke pthread_create_from_mach_thread to bootstrap a real pthread with valid TLS
    And Stage 2 MUST execute dlopen(path, RTLD_LAZY) from the real pthread context
    And Stage 1 SHALL spin with marker 0x79616265 in register x0 until terminated

  Scenario: ASLR shared cache slide delta correction
    Given injector and WindowServer operate in separate Mach task spaces
    When resolving function pointers for pthread_create_from_mach_thread and dlopen
    Then the injector SHALL read the remote sharedCacheSlide via task_info(TASK_DYLD_INFO) and mach_vm_read
    And the injector SHALL calculate slide delta = remote_slide - local_slide
    And the injector SHALL adjust remote function pointer slots by slide delta
    And the injector SHALL deallocate the mach_vm_read buffer via vm_deallocate

  Scenario: ARM64e thread state PAC domain conversion
    Given an ARM64e target thread created inside WindowServer
    When preparing remote execution registers
    Then the injector SHALL sign PC with ptrauth_sign_unauthenticated using ptrauth_key_asia
    And it SHALL use _thread_convert_thread_state to convert state into the target PAC domain
    And on macOS >= 14.4 it SHALL launch the execution via thread_create_running
    And on macOS < 14.4 it SHALL launch via thread_set_state and thread_resume
    And the injector SHALL NOT use __DARWIN_ARM_THREAD_STATE64_FLAGS_NO_PTRAUTH
```

---

### REQ-INJ-006: Developer ID Code Signing & Library Validation (CS_REQUIRE_LV) [IMPLEMENTED]
The dynamic library `libhyprserver.dylib` MUST be code-signed with a valid Developer ID certificate (or ad-hoc signed with matching designated requirements during local development) to satisfy macOS code signing constraints.
- `WindowServer` is marked with the kernel code-signing flag `CS_REQUIRE_LV` (Library Validation), which mandates that all libraries loaded via `dlopen()` must either match the team identifier of the main executable or be signed by Apple / authorized Developer ID credentials.
- When building `libhyprserver.dylib`, the build pipeline MUST invoke `codesign --force --sign <identity> libhyprserver.dylib` prior to injection.
- If library validation fails during `dlopen()`, `dlopen()` returns `NULL` and `dlerror()` emits `"code signature invalid for 'libhyprserver.dylib'"`. The injector MUST detect constructor/socket non-appearance within the watchdog window and report an actionable error indicating code signing failure.

> **Implementation Status [IMPLEMENTED]:**
> The build system (`Makefile`) signs `libhyprserver.dylib` using `codesign -s -` (ad-hoc) or Developer ID certificate, satisfying library validation requirements under `-arm64e_preview_abi` development environments.

#### Feature: Developer ID Code Signing and Library Validation
```gherkin
Feature: Developer ID Code Signing and Library Validation
  Scenario: Dylib loaded with valid code signature
    Given WindowServer enforces CS_REQUIRE_LV library validation
    And libhyprserver.dylib is signed with a valid Developer ID certificate
    When Stage 2 executes dlopen("libhyprserver.dylib", RTLD_LAZY)
    Then dlopen SHALL succeed without code signing validation errors
    And the library constructor hypr_server_init() SHALL execute

  Scenario: Unsigned or invalid dylib rejected by library validation
    Given libhyprserver.dylib has an invalid or missing signature
    When Stage 2 executes dlopen("libhyprserver.dylib", RTLD_LAZY)
    Then dlopen SHALL fail and return NULL
    And the injector watchdog SHALL time out and report failure without crashing WindowServer
```

---

### REQ-WS-002: Safe-Mode Circuit Breaker [IMPLEMENTED]
The in-process payload `libhyprserver.dylib` MUST evaluate whether the tombstone file `/tmp/hyprmac.safemode` exists prior to executing any initialization logic or allocating server resources. If present, the constructor MUST return immediately without spawning threads, binding sockets, or attaching memory hooks.

#### Feature: Safe-Mode Circuit Breaker and Emergency Abort
```gherkin
Feature: Safe-Mode Circuit Breaker and Emergency Abort
  Scenario: Safe-mode tombstone active
    Given the file /tmp/hyprmac.safemode exists on disk
    When libhyprserver.dylib is loaded into WindowServer via dlopen()
    Then the initialization worker MUST detect the tombstone
    And abort initialization immediately without binding /tmp/hyprmac-server.sock
    And log an abort message to system logs
```

---

### REQ-WS-003: Main Runloop Non-Interference [IMPLEMENTED]
The library `libhyprserver.dylib` MUST NOT block, synchronize with, or delay the main thread of `WindowServer`. All IPC operations, socket polling, and background tasks MUST execute on a dedicated detached POSIX thread spawned via `pthread_create` and `pthread_detach`. The constructor MUST complete and return in under 5 milliseconds. `WindowServer` SHALL experience zero dropped display frames during the load operation.

> **Measurement**: Frame drops are measured via `CVDisplayLink` callback timing variance on an external observer process. A frame is considered "dropped" if the inter-callback interval exceeds 1.5x the nominal refresh period (e.g., >25ms at 60Hz). The observer process MUST run for 2 seconds before injection (baseline) and 2 seconds during/after injection (measurement window).

#### Feature: WindowServer Main Runloop Non-Interference and Concurrency
```gherkin
Feature: WindowServer Main Runloop Non-Interference and Concurrency
  Scenario: Library load timing
    Given WindowServer is rendering active frames at 60Hz or 120Hz
    When dlopen() executes the dylib constructor
    Then the constructor SHALL spawn a detached worker thread via pthread_create
    And return control within under 5 milliseconds
    And WindowServer SHALL experience zero dropped display frames during the load operation
```

---

## 2. IPC Wire Protocol & Framing

### REQ-WS-004: Binary Framing & Magic Validation [IMPLEMENTED]
All communication across `/tmp/hyprmac-server.sock` MUST adhere to the binary packet layout defined by `HyprMessageHeader`. Every message header MUST start with `HYPR_MAGIC` (`0x48595052`) and a matching version number (`HYPR_PROTO_VERSION = 1`). Packets with invalid magic numbers or corrupt lengths MUST be discarded, and the server SHALL return a `HYPR_CMD_ERROR` response.

#### Feature: IPC Wire Protocol Framing and Magic Validation
```gherkin
Feature: IPC Wire Protocol Framing and Magic Validation
  Scenario: Valid Ping packet
    Given a connected Unix Domain Socket client
    When the client sends a 20-byte header with command_id = HYPR_CMD_PING
    Then the server MUST reply with a header containing command_id = HYPR_CMD_PONG

  Scenario: Invalid magic number
    Given a connected client sends a message header starting with 0xDEADBEEF
    When the server parses the incoming buffer
    Then the server MUST reply with HYPR_CMD_ERROR
    And close the client connection safely without faulting
```

---

### REQ-WS-011: Maximum Payload Size [PARTIALLY IMPLEMENTED]
Any incoming packet with `payload_size > 4096` bytes SHALL be rejected with `HYPR_ERR_INVALID_CMD`. The socket recv buffer SHALL be bounded to 8192 bytes.

> **Implementation Status [PARTIALLY IMPLEMENTED / DISCREPANCY]:**
> The current codebase exhibits an architectural discrepancy across components:
> - **Specification**: Requires a maximum payload size of 4096 bytes and socket receive buffer bounded to 8192 bytes.
> - **Swift Bridge (`Sources/HyprMac/Bridge/HyprServerBridge.swift`)**: Allows payloads up to 65536 bytes (`guard header.payloadSize <= 65536 else { throw HyprBridgeError.payloadTooLarge }`).
> - **Server Hook (`native/server_hook/hook.c`)**: Implements **no** generalized maximum payload size check (reads payload directly or drains bytes per command).
> - **Shared Protocol (`native/shared/protocol.h`)**: Defines `#define HYPR_MAX_PAYLOAD_SIZE 65536`.
> 
> Both client and server components MUST be aligned on the 4,096-byte payload ceiling and 8,192-byte socket buffer bound specified herein. Marked as `[PARTIALLY IMPLEMENTED]` pending cross-component alignment.

#### Feature: Socket Payload Bounds and Ingestion Limits
```gherkin
Feature: Socket Payload Bounds and Ingestion Limits
  Scenario: Incoming packet exceeds maximum size
    Given a connected Unix Domain Socket client
    When the client sends a packet with payload_size > 4096 bytes
    Then the server hook SHALL reject the packet with HYPR_ERR_INVALID_CMD
    And the socket receive buffer SHALL remain bounded to 8192 bytes
```

---

### REQ-WS-012: Socket Permissions & Mutual Authentication [NOT YET IMPLEMENTED]
The server socket SHALL be created with mode `0666` (world-readable and world-writable). This mode is REQUIRED because `WindowServer` runs as UID 88 (`_windowserver`), while client processes run in unprivileged user sessions (UID 501). Wire-level mutual authentication SHALL be enforced via a 16-byte (128-bit) cryptographically random token generated at injection time. The first command from any client connection SHALL be `HYPR_CMD_AUTH` carrying this 16-byte token; unauthenticated connections SHALL be closed after 1 second.

> **Implementation Status [NOT YET IMPLEMENTED]:**
> The socket currently operates with zero wire authentication. `protocol.h` does not define `HYPR_CMD_AUTH`, `hook.c` does not validate authentication tokens, and `HyprServerBridge.swift` does not transmit an auth handshake. This security requirement is planned and tracked for implementation.

#### Feature: Socket Permissions and Mutual Wire Authentication
```gherkin
Feature: Socket Permissions and Mutual Wire Authentication
  Scenario: Client authentication handshake
    Given the server socket /tmp/hyprmac-server.sock is created with mode 0666
    When a client connects and sends HYPR_CMD_AUTH with the valid 16-byte token within 1 second
    Then the hook SHALL authenticate the client connection and allow subsequent commands

  Scenario: Unauthenticated connection timeout
    Given a client connects to the server socket
    When the client fails to transmit a valid HYPR_CMD_AUTH token within 1 second
    Then the hook SHALL terminate and close the unauthenticated connection
```

---

## 3. Window Property Manipulation

### REQ-WS-005: Square Corners (0px Corner Radius) [NOT YET IMPLEMENTED]
When a client sends `HYPR_CMD_SET_CORNER_RADIUS` with a valid target `window_id` and `corner_radius = 0.0f`, `libhyprserver.dylib` MUST enforce a 0px corner clipping mask on the target window's composited surface. Surface cache invalidation SHALL be triggered via `SLSFlushSurface()` or equivalent CGS private API after modifying window properties. If the invalidation API is unavailable, the hook SHALL fall back to `SLSMoveWindow()` with zero delta as a forced redraw trigger.

> **Implementation Status [NOT YET IMPLEMENTED]:**
> `native/server_hook/hook.c` currently handles `HYPR_CMD_SET_CORNER_RADIUS` by parsing the payload, logging via `hypr_log()`, and returning a synthetic `HYPR_CMD_ACK`. Direct compositor surface clipping and CGS/SLS private API invalidation are not yet implemented.

#### Feature: Square Window Corners via In-Situ Surface Clipping
```gherkin
Feature: Square Window Corners via In-Situ Surface Clipping
  Scenario: Forcing 0px corners on focused window
    Given a target window with native Aqua 12px rounded corners
    When the client dispatches HYPR_CMD_SET_CORNER_RADIUS with window_id=wid and corner_radius=0.0f
    Then the server hook SHALL update the window's clipping mask to a 90-degree rectangle
    And the server MUST acknowledge with HYPR_CMD_ACK

  Scenario: Restore Native Corner Rounding
    Given window ID 0xBEEF has had its corners forced to 0px radius
    When the client sends HYPR_CMD_SET_CORNER_RADIUS with window_id=0xBEEF and radius=10.0
    Then the hook SHALL set the corner radius of window 0xBEEF to 10.0
    And subsequent frames SHALL render the window with 10px rounded corners

  Scenario: Set Corner Radius on Non-Existent Window
    Given no window with ID 0xDEAD exists in WindowServer
    When the client sends HYPR_CMD_SET_CORNER_RADIUS with window_id=0xDEAD
    Then the hook SHALL respond with HYPR_CMD_ERROR and error code INVALID_WID (0x0001)
    And no compositor state SHALL be modified
```

---

### REQ-WS-006: Shadow Stripping [NOT YET IMPLEMENTED]
When a client sends `HYPR_CMD_SET_SHADOW_STATE` with `shadow_enabled = 0`, `libhyprserver.dylib` MUST clear the drop-shadow rendering pass for the specified `window_id` using server-level connection credentials. Surface cache invalidation SHALL be triggered via `SLSFlushSurface()` or equivalent CGS private API.

> **Implementation Status [NOT YET IMPLEMENTED]:**
> `native/server_hook/hook.c` currently handles `HYPR_CMD_SET_SHADOW_STATE` by parsing the payload, logging via `hypr_log()`, and returning a synthetic `HYPR_CMD_ACK`. Server-level shadow suppression and surface cache invalidation are not yet implemented.

#### Feature: Native Drop Shadow Suppression
```gherkin
Feature: Native Drop Shadow Suppression
  Scenario: Eliminating window shadow
    Given an active application window rendering an exterior Aqua drop shadow
    When the client dispatches HYPR_CMD_SET_SHADOW_STATE with window_id=wid and shadow_enabled=0
    Then the outer shadow pass SHALL be omitted from the subsequent compositor frame tick
    And the physical display SHALL show the window with zero surrounding shadow

  Scenario: Restore Window Shadow
    Given window ID 0xBEEF has had its shadow stripped (shadow_enabled=0)
    When the client sends HYPR_CMD_SET_SHADOW_STATE with window_id=0xBEEF and shadow_enabled=1
    Then the hook SHALL re-enable the native shadow for window 0xBEEF
    And the shadow SHALL appear on the next composited frame

  Scenario: Strip Shadow from Non-Existent Window
    Given no window with ID 0xDEAD exists in WindowServer
    When the client sends HYPR_CMD_SET_SHADOW_STATE with window_id=0xDEAD
    Then the hook SHALL respond with HYPR_CMD_ERROR and error code INVALID_WID (0x0001)
    And no compositor state SHALL be modified
```

---

### REQ-WS-007: Native Synchronized Border Rendering [NOT YET IMPLEMENTED]
The composition hook MUST render a 1px border around managed windows at the compositor level, synchronized with the display refresh cycle.
- The border color MUST be configurable per-window via `HYPR_CMD_SET_WINDOW_BORDER`.
- The border MUST support independent active and inactive colors, determined by the window's focus state.
- The border MUST update within a single display refresh cycle (<=16.67ms at 60Hz) when window focus changes.
- The border rendering MUST NOT introduce additional draw calls visible to the application; it operates below the application's rendering surface.
- When `border_width` is set to `0.0f`, the border MUST be fully removed (no residual artifacts).

> **Implementation Status [NOT YET IMPLEMENTED]:**
> `native/server_hook/hook.c` currently handles `HYPR_CMD_SET_WINDOW_BORDER` by logging the border width and colors, and returning a synthetic `HYPR_CMD_ACK`. In-process compositor border rendering and display refresh synchronization are not yet implemented.

#### Feature: Native Synchronized Window Border Composition
```gherkin
Feature: Native Synchronized Window Border Composition
  Scenario: Apply 1px Active Border to Managed Window
    Given WindowServer is running with the composition hook loaded
    And window ID 0xBEEF is a managed tiled window with focus
    When the client sends HYPR_CMD_SET_WINDOW_BORDER with window_id=0xBEEF, border_width=1.0, color_active=0xFF00AAFF, color_inactive=0xFF444444
    Then the hook SHALL render a 1px border with color 0xFF00AAFF around window 0xBEEF
    And the border SHALL be composited below the window shadow or adjacent to the surface

  Scenario: Border Color Transitions on Focus Change
    Given window ID 0xBEEF has an active border color 0xFF00AAFF and inactive color 0xFF444444
    And window 0xBEEF currently has focus
    When window 0xBEEF loses focus
    Then the border color SHALL transition to 0xFF444444 within one display refresh cycle
    And no intermediate frame SHALL show the active color after the focus-loss event is processed

  Scenario: Remove Border
    Given window ID 0xBEEF has an active 1px border
    When the client sends HYPR_CMD_SET_WINDOW_BORDER with window_id=0xBEEF, border_width=0.0
    Then the hook SHALL remove the border entirely
    And no residual border artifacts SHALL remain on subsequent frames
```

---

### REQ-WS-008: Titlebar Stripping [NOT YET IMPLEMENTED]
The composition hook MUST support stripping the native macOS titlebar from managed windows via `HYPR_CMD_STRIP_TITLEBAR`.
- Stripping the titlebar MUST remove title text, traffic light buttons (close/minimize/zoom), and toolbar background from the compositor's rendering of the window.
- The window's content area MUST expand to fill the space previously occupied by the titlebar.
- Titlebar stripping MUST be reversible: sending `HYPR_CMD_STRIP_TITLEBAR` with `strip=0` MUST restore the native titlebar and shrink the content area back to its original bounds.

> **Implementation Status [NOT YET IMPLEMENTED]:**
> `native/server_hook/hook.c` currently handles `HYPR_CMD_STRIP_TITLEBAR` by logging the window ID and strip flag, and returning a synthetic `HYPR_CMD_ACK`. Window content expansion and native titlebar stripping in WindowServer are not yet implemented.

#### Feature: Native Titlebar Stripping and Reversible Content Expansion
```gherkin
Feature: Native Titlebar Stripping and Reversible Content Expansion
  Scenario: Strip Titlebar from Managed Window
    Given WindowServer is running with the composition hook loaded
    And window ID 0xCAFE has a native macOS titlebar visible
    When the client sends HYPR_CMD_STRIP_TITLEBAR with window_id=0xCAFE and strip=1
    Then the hook SHALL remove the titlebar rendering from window 0xCAFE
    And the window content MUST expand to occupy the full window frame

  Scenario: Restore Titlebar
    Given window ID 0xCAFE has had its titlebar stripped
    When the client sends HYPR_CMD_STRIP_TITLEBAR with window_id=0xCAFE and strip=0
    Then the hook SHALL restore the native titlebar rendering
    And the window content area MUST shrink to accommodate the restored titlebar
```

---

### REQ-WS-009: Window State Query [NOT YET IMPLEMENTED]
The composition hook MUST support querying the current decoration state of a managed window via `HYPR_CMD_QUERY_WINDOW`.
- The response MUST include: `window_id`, `corner_radius`, `shadow_enabled`, `titlebar_stripped`, `border_color`, and `border_width`.
- If the `window_id` does not correspond to a valid, existing window, the hook MUST respond with `HYPR_CMD_ERROR` and error code `0x0001` (`HYPR_ERR_INVALID_WID`).

> **Implementation Status [NOT YET IMPLEMENTED]:**
> `native/server_hook/hook.c` currently drains any incoming payload and returns `HYPR_ERR_INVALID_WID` with message `"Not impl"`. Querying active window decoration state from WindowServer internal structures is not yet implemented.

#### Feature: Window State and Decoration Query
```gherkin
Feature: Window State and Decoration Query
  Scenario: Query Existing Window State
    Given window ID 0xBEEF exists and has corner_radius=0.0, shadow_enabled=0, border_width=1.0
    When the client sends HYPR_CMD_QUERY_WINDOW with window_id=0xBEEF
    Then the hook SHALL respond with HYPR_CMD_ACK containing the full decoration state of window 0xBEEF

  Scenario: Query Non-Existent Window
    Given no window with ID 0xDEAD exists in WindowServer
    When the client sends HYPR_CMD_QUERY_WINDOW with window_id=0xDEAD
    Then the hook SHALL respond with HYPR_CMD_ERROR and error code INVALID_WID (0x0001)
    And no compositor state SHALL be modified
```

---

### REQ-WS-013: Focus State Synchronization Command [NOT YET IMPLEMENTED]
A command `HYPR_CMD_SET_WINDOW_FOCUS (0x0014)` with a 4-byte payload body `{ uint32_t window_id }` SHALL be defined. The target window identifier MUST be transmitted in the payload body (with `payload_size = 4`), in addition to the header's `window_id` field. When received, the hook SHALL mark the specified window as focused and all other managed windows as unfocused. The border color of the newly focused window SHALL transition to `color_active`, and previously focused windows SHALL transition to `color_inactive`, within one display refresh cycle (<=16.67ms at 60Hz).

> **Implementation Status [NOT YET IMPLEMENTED]:**
> `HYPR_CMD_SET_WINDOW_FOCUS` is not yet defined in `protocol.h`, not handled in `hook.c`, and not exposed in `HyprServerBridge.swift`. Focus changes are currently not tracked via this dedicated IPC command.

#### Feature: Synchronized Focus State Tracking and Border Switching
```gherkin
Feature: Synchronized Focus State Tracking and Border Switching
  Scenario: Focus State Transition
    Given window ID 0xAAAA is currently focused with active border color
    And window ID 0xBBBB is currently unfocused with inactive border color
    When the client sends HYPR_CMD_SET_WINDOW_FOCUS with window_id=0xBBBB
    Then the hook SHALL mark window 0xBBBB as focused and all others as unfocused
    And the border color of window 0xBBBB SHALL transition to color_active within one display refresh cycle
    And the border color of window 0xAAAA SHALL transition to color_inactive within one display refresh cycle
```

---

### REQ-WS-014: Window Lifecycle Invalidation [NOT YET IMPLEMENTED]
When a managed window is destroyed by the OS, the hook SHALL remove it from its internal tracking within one event loop cycle. Any subsequent command targeting a destroyed window SHALL return `HYPR_ERR_INVALID_WID (0x0001)`. The hook SHALL NOT access memory of destroyed windows.

> **Implementation Status [NOT YET IMPLEMENTED]:**
> `native/server_hook/hook.c` does not currently maintain an active window registry or subscribe to CGS/SLS window destruction notifications. Stale handle tracking and eviction are not yet implemented.

#### Feature: Window Lifecycle and Stale Handle Eviction
```gherkin
Feature: Window Lifecycle and Stale Handle Eviction
  Scenario: Window Destruction Eviction
    Given window ID 0xCAFE was previously managed by the hook
    And window 0xCAFE is destroyed by the OS
    When the hook processes the next event loop cycle
    Then the hook SHALL remove window 0xCAFE from its internal tracking within one event loop cycle
    And any subsequent command targeting window 0xCAFE SHALL return HYPR_ERR_INVALID_WID (0x0001)
    And the hook SHALL NOT access memory of destroyed window 0xCAFE
```

---

### REQ-WS-015: Global Window Decoration Policy [PLANNED]
The composition hook MUST support configuring a default global decoration policy for newly created windows via `HYPR_CMD_SET_GLOBAL_POLICY = 0x0015`.
- The command payload SHALL contain default decoration values: `corner_radius` (float, 4 bytes), `shadow_enabled` (uint8_t, 1 byte), `strip_titlebar` (uint8_t, 1 byte), `border_width` (float, 4 bytes), `color_active` (uint32_t, 4 bytes), and `color_inactive` (uint32_t, 4 bytes) for a total payload size of 18 bytes.
- When a new application window is mapped by `WindowServer`, the hook MUST automatically apply this global decoration policy without requiring individual per-window IPC commands from the client.
- Per-window decoration commands (`HYPR_CMD_SET_CORNER_RADIUS`, `HYPR_CMD_SET_SHADOW_STATE`, `HYPR_CMD_SET_WINDOW_BORDER`, `HYPR_CMD_STRIP_TITLEBAR`) SHALL override the global policy for the specified window.

> **Implementation Status [PLANNED]:**
> `HYPR_CMD_SET_GLOBAL_POLICY (0x0015)` is planned to optimize window management latency on workspace creation. Currently not defined in `protocol.h` or implemented in `hook.c`.

#### Feature: Global Window Decoration Policy Configuration
```gherkin
Feature: Global Window Decoration Policy Configuration
  Scenario: Setting global decoration policy for newly created windows
    Given the composition hook is active in WindowServer
    When the client sends HYPR_CMD_SET_GLOBAL_POLICY with corner_radius=0.0, shadow_enabled=0, border_width=1.0, color_active=0xFF00AAFF, color_inactive=0xFF444444
    Then the server MUST acknowledge with HYPR_CMD_ACK
    And any subsequent window created in WindowServer SHALL inherit the global decoration policy by default

  Scenario: Per-window override of global policy
    Given a global decoration policy is active with corner_radius=0.0
    When a new window 0xBEEF is created
    And the client sends HYPR_CMD_SET_CORNER_RADIUS with window_id=0xBEEF and corner_radius=8.0
    Then window 0xBEEF SHALL render with 8.0px corner radius overriding the global policy
```

---

## 4. Swift Client Bridge Resilience

### REQ-WS-010: Swift Client Bridge Resilience & Replay Queue [PARTIALLY IMPLEMENTED]
`HyprServerBridge.swift` MUST handle disconnection and unavailability of the composition hook gracefully.
- If the Unix domain socket is not available (hook not loaded), the bridge MUST NOT crash. It SHALL log a diagnostic warning and fall back to the existing `SkyLightBridge` out-of-process path.
- If the socket connection is lost mid-session (WindowServer crash/restart, hook unload), the bridge MUST attempt reconnection with exponential backoff (initial delay 100ms, max delay 5s, max attempts 10).
- After exhausting reconnection attempts, the bridge SHALL emit a `hyprServerHookUnavailable` notification and fall back to `SkyLightBridge`.
- The bridge MUST set a per-command timeout of 500ms. If no response is received within 500ms, the command is considered failed and the bridge MAY retry once before reporting failure to the caller.
- The Swift bridge SHALL maintain a ring buffer of up to 64 pending commands. During disconnection, new commands are enqueued. Upon successful reconnection, all queued commands SHALL be replayed in FIFO order before accepting new commands.

> **Implementation Status [PARTIALLY IMPLEMENTED]:**
> `Sources/HyprMac/Bridge/HyprServerBridge.swift` implements connection timeout handling (500ms send/recv via `SO_SNDTIMEO`/`SO_RCVTIMEO`), exponential backoff reconnection (10 attempts, 100ms initial to 5s max), and single inline command retry on socket failure. However, the **64-item FIFO ring buffer** for enqueuing commands while disconnected and replaying them on reconnection is **[NOT YET IMPLEMENTED]**.

#### Feature: Swift Client Bridge Resilience, Fallback and Replay
```gherkin
Feature: Swift Client Bridge Resilience, Fallback and Replay
  Scenario: Hook Not Installed (Graceful Fallback)
    Given HyprMac is launched without the composition hook loaded in WindowServer
    When HyprServerBridge attempts to connect to /tmp/hyprmac-server.sock
    Then the connection SHALL fail with ECONNREFUSED or ENOENT
    And the bridge SHALL log a warning indicating hook unavailability
    And all window decoration commands SHALL be routed through SkyLightBridge

  Scenario: Mid-Session Disconnection
    Given HyprServerBridge has an active connection to the composition hook
    When the socket connection is unexpectedly closed
    Then the bridge SHALL attempt reconnection with exponential backoff
    And during disconnection, the bridge SHALL maintain a ring buffer of up to 64 pending commands
    And upon successful reconnection, all queued commands SHALL be replayed in FIFO order before accepting new commands
```

---

## 5. Security & Threat Model Requirements

### REQ-SEC-001: Least-Privilege Execution & Task Port Boundary [IMPLEMENTED]
All operations requiring kernel-level task port manipulation MUST be isolated strictly to the ephemeral loader `hypr-inject`. The resident in-process library `libhyprserver.dylib` MUST execute under the unprivileged user context of `WindowServer` (`_windowserver`, UID 88). 
- `hypr-inject` MUST release acquired Mach task ports immediately via `mach_port_deallocate()` upon injection completion or failure.
- Remote memory allocations inside `WindowServer` MUST be assigned the minimum viable permissions (`VM_PROT_READ | VM_PROT_WRITE` for stack, `VM_PROT_READ` for paths, and `VM_PROT_READ | VM_PROT_EXECUTE` for executable stubs).
- No writable memory page SHALL remain executable simultaneously (`W^X` invariant).

#### Feature: Security Architecture and Privilege Boundaries
```gherkin
Feature: Security Architecture and Privilege Boundaries
  Scenario: Privileged operation boundary validation
    Given hypr-inject is executed as root (UID 0)
    When it completes or aborts task port operations on WindowServer
    Then it SHALL deallocate all acquired mach task ports via mach_port_deallocate
    And ensure remote memory mappings adhere to W^X page protection rules
```

---

### REQ-SEC-002: Compositor Blast Radius & Session Protection [PARTIALLY IMPLEMENTED]
Because `WindowServer` constitutes the root compositor daemon for the macOS user session, any fatal signal (`SIGSEGV`, `SIGBUS`, `SIGILL`) triggered inside `WindowServer` terminates the graphical session immediately. 
- All IPC message parsing within `hook.c` MUST fail-closed on malformed inputs, truncated payloads, or out-of-range parameters.
- Pointer dereferences against private `WindowServer` or CoreGraphics data structures MUST be guarded with bounds checks and validated against null invariants.
- If an unrecoverable internal condition arises, the hook MUST shut down its background worker and unlink `/tmp/hyprmac-server.sock` without crashing the host process.

#### Feature: Compositor Blast Radius Containment
```gherkin
Feature: Compositor Blast Radius Containment
  Scenario: Malformed client message handling without compositor fault
    Given a connected client sends an invalid or truncated IPC message
    When hook.c parses the message frame
    Then the server hook SHALL fail-closed and return HYPR_CMD_ERROR
    And the host WindowServer process MUST NOT crash or terminate
```

---

## 6. System Degradation & Safe-Mode Recovery Specification

### REQ-SAF-001: File-Based Safe-Mode Circuit Breaker [IMPLEMENTED]
A filesystem tombstone at `/tmp/hyprmac.safemode` MUST serve as the authoritative circuit breaker for the in-situ subsystem.
- If `/tmp/hyprmac.safemode` exists, `hypr-inject` MUST abort immediately before executing any Mach API calls.
- If `/tmp/hyprmac.safemode` exists, `libhyprserver.dylib` constructor and initialization routines MUST return immediately without binding sockets or modifying compositor state.
- If the post-injection watchdog detects that `WindowServer` PID changed within 500ms of injection, the watchdog MUST create `/tmp/hyprmac.safemode` to prevent recurring crash loops across `launchd` respawns.
- Executing `hypr-inject --uninstall` MUST touch `/tmp/hyprmac.safemode` and remove `/Library/LaunchDaemons/com.hyprmac.inject.plist`.

#### Feature: Safe-Mode Circuit Breaker Protocol
```gherkin
Feature: Safe-Mode Circuit Breaker Protocol
  Scenario: Safe-mode tombstone prevents restart loop
    Given the file /tmp/hyprmac.safemode is present on the filesystem
    When hypr-inject is invoked or WindowServer is restarted by launchd
    Then the injector SHALL abort immediately with status code 1
    And libhyprserver.dylib SHALL abort initialization immediately
    And no socket at /tmp/hyprmac-server.sock SHALL be created
```

---

### REQ-SAF-002: Graceful Degradation to User-Space Emulation [NOT YET IMPLEMENTED]
When `libhyprserver.dylib` is unavailable, uninstalled, or disabled by safe-mode, `HyprMac` MUST maintain basic window management functionality:
- The Swift application SHALL fall back to `BorderWindow.swift` (AppKit border overlays) and `SkyLightBridge.swift` within 500ms of socket unavailability.
- When the in-situ hook reconnects, AppKit overlays MUST be deactivated within 500ms to eliminate duplicate rendering passes.

> **Implementation Status [NOT YET IMPLEMENTED]:**
> Dynamic runtime switching and coordination between in-situ composition and `BorderWindow.swift` (AppKit border overlays) upon socket unavailability or reconnection is not yet wired up in `HyprServerBridge.swift`.

#### Feature: Graceful Degradation to User-Space Emulation
```gherkin
Feature: Graceful Degradation to User-Space Emulation
  Scenario: Automatic client fallback to BorderWindow overlays
    Given the in-situ WindowServer hook is disconnected or safe-mode is engaged
    When HyprMac detects hook unavailability
    Then HyprMac SHALL route border rendering through BorderWindow overlays within 500ms
    And all window management operations SHALL continue without interruption
```

---

## 7. Performance Budgets & Service Level Agreements (SLAs)

### REQ-PRF-001: Formal Latency, Timing and Frame Drop SLAs [VERIFICATION PENDING]
The in-situ composition subsystem MUST satisfy the following formal performance budgets under all operational conditions:
1. **Dylib Constructor Budget**: `hypr_server_init()` MUST complete and return to the caller in <= 5.0 milliseconds.
2. **Compositor Frame Drop SLA**: `WindowServer` SHALL experience 0 dropped frames during injection, library initialization, and steady-state operation. Frame callback intervals on 60Hz displays MUST not exceed 25.0ms (1.5x nominal period); on 120Hz ProMotion displays, intervals MUST not exceed 12.5ms.
3. **IPC Dispatch Latency**: Round-trip request-response latency across `/tmp/hyprmac-server.sock` for window modification commands MUST be < 20 microseconds in steady-state.
4. **Visual Transition Budget**: Active/inactive border transitions, corner radius changes, and shadow toggles MUST reflect on physical displays within <= 16.67 milliseconds (a single 60Hz refresh cycle) of IPC receipt.
5. **Client Command Timeout**: `HyprServerBridge.swift` SHALL enforce a 500ms timeout per command transaction.

> **Implementation Status & Verification Note [VERIFICATION PENDING]:**
> In `native/server_hook/hook.c`, `hypr_server_init()` spawns a detached pthread running `deferred_init()`, which explicitly executes `usleep(500000)` (500 ms) before initializing the IPC socket. While `hypr_server_init()` returns to the caller in <5ms, socket readiness is intentionally delayed by this 500ms sleep. Formal verification of the 20µs IPC latency and 0 dropped frames via CVDisplayLink callbacks is pending empirical profiling on hardware.

#### Feature: Performance Budgets and SLA Compliance
```gherkin
Feature: Performance Budgets and SLA Compliance
  Scenario: Dylib constructor execution budget
    Given libhyprserver.dylib is loaded into WindowServer
    When constructor hypr_server_init() runs
    Then it SHALL return in under 5.0 milliseconds

  Scenario: Zero dropped compositor frames verification
    Given WindowServer is rendering active frames
    When injection occurs and window decorations are updated
    Then display link callbacks SHALL not exceed 25ms interval at 60Hz or 12.5ms at 120Hz

  Scenario: IPC dispatch round-trip SLA
    Given an established IPC connection to /tmp/hyprmac-server.sock
    When a window decoration command is sent
    Then the round-trip acknowledgement latency SHALL be under 20 microseconds

  Scenario: Focus border visual transition budget
    Given a window focus change command is dispatched
    When the compositor processes the frame
    Then the visual border color update SHALL complete within 16.67 milliseconds
```

---

## 8. Protocol Versioning & Negotiation Requirements

### REQ-PRO-001: Strict Protocol Handshake & Version Matching [IMPLEMENTED]
The wire protocol MUST enforce strict version verification:
- Header version field `version` MUST equal `HYPR_PROTO_VERSION` (`1`).
- If an incoming message contains `version != HYPR_PROTO_VERSION`, the server MUST reject the message with `HYPR_CMD_ERROR` / `HYPR_ERR_INTERNAL` and message string `"Bad version"`, terminating the client connection.

#### Feature: Protocol Version Matching and Verification
```gherkin
Feature: Protocol Version Matching and Verification
  Scenario: Protocol version mismatch rejection
    Given a connected client sends a message header with version = 999
    When the server evaluates the header version field
    Then the server hook SHALL respond with HYPR_CMD_ERROR and error message "Bad version"
    And terminate the client connection
```

---

### REQ-PRO-002: Capability & Health Negotiation [IMPLEMENTED]
The protocol MUST support capability discovery and server health validation via `HYPR_CMD_PING` and `HYPR_CMD_PONG`:
- When receiving `HYPR_CMD_PING`, the server MUST reply with `HYPR_CMD_PONG` containing `HyprPayloadPong`.
- `HyprPayloadPong` MUST contain `server_version` formatted as `(major << 16 | minor << 8 | patch)` and `active_windows` indicating the current count of managed windows.

#### Feature: Capability and Health Negotiation
```gherkin
Feature: Capability and Health Negotiation
  Scenario: Ping-pong telemetry and capability discovery
    Given a connected client sends HYPR_CMD_PING
    When the server hook processes the ping
    Then it SHALL respond with HYPR_CMD_PONG
    And the payload SHALL contain server_version and active_windows count
```

---

## 9. Window Space Transitions (Mission Control & Stage Manager)

### REQ-WSP-001: Mission Control & Stage Manager Workspace Virtualization [NOT YET IMPLEMENTED]
The composition hook MUST accommodate native macOS space switching, Mission Control, and Stage Manager without crashing `WindowServer` or corrupting window surfaces.
- During Mission Control activation, windows are scaled and re-ordered in space. The hook MUST NOT attempt surface clipping re-computations on windows in transient animation states.
- When windows transition between virtual desktops (Spaces), the hook's internal tracking MUST preserve window state mappings.
- Upon return from Mission Control or Stage Manager, custom corner masks, shadow states, and borders MUST be retained without visual artifacts.

> **Implementation Status [NOT YET IMPLEMENTED]:**
> `native/server_hook/hook.c` does not currently hook or track Mission Control, Spaces, or Stage Manager state transitions.

#### Feature: Window Space Transitions and Stage Manager Integration
```gherkin
Feature: Window Space Transitions and Stage Manager Integration
  Scenario: Mission Control activation without visual artifacts
    Given managed windows are rendered with custom borders and 0px corners
    When the user invokes Mission Control or Stage Manager
    Then WindowServer SHALL complete space transitions without compositor faults
    And upon returning to the workspace, all custom decorations SHALL remain intact
```

---

### REQ-WSP-002: Fullscreen & Split-View Transition Compliance [NOT YET IMPLEMENTED]
When a managed window transitions into native macOS fullscreen or Split View:
- The hook MUST detect fullscreen transitions and suspend border rendering if the window occupies the full display bounds.
- Upon exiting fullscreen mode, the hook MUST automatically re-apply configured borders, corner radii, and shadow states within 1 display refresh cycle.

> **Implementation Status [NOT YET IMPLEMENTED]:**
> Fullscreen transition detection and border suspension are not yet implemented in `hook.c`.

#### Feature: Fullscreen Space Transition Compliance
```gherkin
Feature: Fullscreen Space Transition Compliance
  Scenario: Native macOS fullscreen transition handling
    Given a managed window with an active 1px border
    When the window enters native macOS fullscreen mode
    Then the hook SHALL suspend custom border rendering
    And when the window exits fullscreen mode, the 1px border SHALL be restored within one display refresh cycle
```

---

## 10. Multi-Monitor Refresh Rate Sync Requirements

### REQ-MON-001: Heterogeneous Display Refresh Rate Synchronization [NOT YET IMPLEMENTED]
On multi-monitor workstations featuring mixed refresh rates (such as a 120Hz ProMotion internal display paired with 60Hz or 144Hz external monitors):
- Border compositing and surface invalidation MUST synchronize to the refresh cycle of the specific display on which each window is located.
- When a window spans multiple displays, the hook MUST synchronize border updates to the primary display containing the greater surface area of the window.
- The hook MUST NOT introduce tearing, stutter, or frame pacing jitter when windows are dragged across displays with mismatched refresh rates.

> **Implementation Status [NOT YET IMPLEMENTED]:**
> Multi-display refresh rate tracking and per-display CVDisplayLink synchronization are not yet implemented in `hook.c`.

#### Feature: Heterogeneous Refresh Rate Synchronization
```gherkin
Feature: Heterogeneous Refresh Rate Synchronization
  Scenario: Frame pacing synchronization across mixed ProMotion and 60Hz displays
    Given Display 1 operates at 120Hz and Display 2 operates at 60Hz
    When a managed window resides on Display 2
    Then border rendering and surface updates SHALL synchronize to the 60Hz display link
    And the display pipeline SHALL experience zero frame tearing or jitter
```

---

### REQ-MON-002: Dynamic Display Reconfiguration & Hotplug Handling [NOT YET IMPLEMENTED]
When external displays are connected, disconnected, or have their resolutions/color profiles reconfigured:
- The composition hook MUST detect display topology changes within 1 display refresh cycle.
- The hook MUST re-validate all managed window display assignments and update compositor attachments accordingly.
- Stale display contexts MUST be released without leaking memory or referencing invalidated screen buffers.

> **Implementation Status [NOT YET IMPLEMENTED]:**
> Dynamic display reconfiguration listeners and display topology tracking are not yet implemented in `hook.c`.

#### Feature: Dynamic Display Reconfiguration and Hotplug Handling
```gherkin
Feature: Dynamic Display Reconfiguration and Hotplug Handling
  Scenario: Display disconnect and window migration handling
    Given an external display is disconnected while displaying managed windows
    When macOS migrates the windows to the remaining display
    Then the hook SHALL update window display associations within one refresh cycle
    And preserve all window decoration states without crashing WindowServer
```
