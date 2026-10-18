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

### REQ-INJ-001: Idempotent Injection & Bootstrap Registry [IMPLEMENTED]
The injector `hypr-inject` MUST perform an idempotency check before initiating any Mach VM allocation or remote thread creation. Registration via `bootstrap_check_in` / `bootstrap_look_up` on `"com.hyprmac.server.hook"` fails under the `WindowServer` sandbox profile (`kr=1100`, `BOOTSTRAP_NOT_PRIVILEGED`). Therefore, idempotency MUST be validated via checking the `hook_ready` flag in the shared memory header (`/tmp/hyprmac-ipc.shm`, `HyprShmHeader.hook_ready == 1`) or through dyld image enumeration via `task_info(target_task, TASK_DYLD_INFO, ...)`. If the hook is confirmed loaded and active, the injector MUST log that the hook is already active and exit with status code `2` without creating additional threads or loading the library again.

#### Feature: Idempotent Injection and Bootstrap Registry
```gherkin
Feature: Idempotent Injection and Bootstrap Registry
  Scenario: Injector runs while hook is already active
    Given the hook is already loaded in WindowServer
    When the injector runs again
    Then it SHALL detect the existing hook via shared memory header hook_ready == 1 or dyld image enumeration
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
Following remote thread dispatch, the injector MUST monitor initialization and `WindowServer` stability over a post-injection observation window. The injector SHALL poll for the creation of the readiness marker at `/tmp/hyprserver.ready` (`HYPR_READY_PATH`) using `access(HYPR_READY_PATH, F_OK)` (polling up to 100 iterations at 100ms intervals, for a maximum timeout of 10 seconds). Following readiness marker appearance, the injector SHALL wait for 500ms and verify that the target `WindowServer` PID has not changed. If `WindowServer` restarted, the injector MUST create the safe-mode tombstone `/tmp/hyprmac.safemode` and exit with status code `1`.

#### Feature: Post-Injection Crash Watchdog and Safe-Mode Recovery
```gherkin
Feature: Post-Injection Crash Watchdog and Safe-Mode Recovery
  Scenario: Post-injection readiness probe and stability verification
    Given remote thread dispatch has executed
    When the injector waits for hook initialization
    Then it SHALL poll access(HYPR_READY_PATH, F_OK) at /tmp/hyprserver.ready up to 10 seconds
    And upon readiness marker detection, it SHALL wait for 500ms
    And verify that the active WindowServer PID matches the pre-injection PID
    And if the PID has changed, it SHALL create /tmp/hyprmac.safemode and exit with status code 1
```

---

### REQ-INJ-005: Two-Stage PAC-Safe Remote Execution & Thread State Conversion [IMPLEMENTED]
When dispatching code execution into `WindowServer` on ARM64e, the injector MUST employ a two-stage execution architecture rather than directly invoking `dlopen` on a raw Mach thread, and MUST allocate a dedicated diagnostic page to capture post-mortem failure telemetry:

1. **Remote Memory Allocations**:
   - **Remote Stack Page (16KB)**: Allocated via `mach_vm_allocate(task, &remote_stack, 16384, VM_FLAGS_ANYWHERE)` with permissions `VM_PROT_READ | VM_PROT_WRITE`.
   - **Remote Code Page (4096 bytes)**: Allocated via `mach_vm_allocate(task, &remote_code, 4096, VM_FLAGS_ANYWHERE)` and protected as `VM_PROT_READ | VM_PROT_EXECUTE`.
   - **Remote Diagnostic Page (4096 bytes)**: Allocated via `mach_vm_allocate(task, &remote_diag, 4096, VM_FLAGS_ANYWHERE)` with permissions `VM_PROT_READ | VM_PROT_WRITE`. Allows post-mortem inspection of loading progress, return codes, and error strings across task boundaries.

2. **Remote Code Page Layout**:
   - `[0x00..0x57]` (88 bytes, 22 instructions): **Stage 1 Assembly Sequence**. Invokes `pthread_create_from_mach_thread` via the pointer at slot `0x58`, saves return code to `x20` and `pthread_t` to `x21`, sets `x0 = 0x79616265` (`"yabe"`), and enters an infinite spin loop (`adr x9, #0; br x9`).
   - `[0x58..0x5F]` (8 bytes): **Data Slot: `pthread_create_from_mach_thread` address**. Populated at runtime with the slide-corrected remote symbol address.
   - `[0x60..0xF7]` (152 bytes, 38 instructions): **Stage 2 Assembly Sequence**.
     - Starts with `nop` (`0x1F2003D5`, omitting `pacibsp` due to cross-process PAC key divergence).
     - Allocates stack frame (`sub sp, sp, #0x30; stp x29, x30, [sp, #0x20]`).
     - Loads `remote_diag` base address from slot `0x100` into `x22`.
     - Writes entry marker `0xDEAD0001` into diagnostic page offset `0x0` (`[x22]`).
     - Writes pre-dlopen marker `0xDEAD0002` into diagnostic page offset `0x4` (`[x22, #4]`).
     - Sets `x1 = 1` (`RTLD_LAZY`) and computes `x0 = &dylib_path` (at offset `0x110`).
     - Loads slide-corrected `dlopen` address from slot `0xF8` into `x9`, calls `blr x9`.
     - Stores `dlopen` result pointer to diagnostic page offset `0x8` (`[x22, #8]`).
     - If `dlopen` returns `NULL` (`cbz x0`), loads `dlerror` address from slot `0x108` into `x9`, calls `blr x9`, stores `dlerror` string pointer to diagnostic page offset `0x18` (`[x22, #0x18]`), and copies up to 200 bytes of the error message into diagnostic page offset `0x20` (`[x22, #0x20]`).
     - Restores stack frame and returns via plain `ret` (`0xC0035FD6`, omitting `retab`).
   - `[0xF8..0xFF]` (8 bytes): **Data Slot: `dlopen` address**. Populated at runtime with the slide-corrected remote symbol address.
   - `[0x100..0x107]` (8 bytes): **Data Slot: `remote_diag` address**. Populated with the remote diagnostic page base address.
   - `[0x108..0x10F]` (8 bytes): **Data Slot: `dlerror` address**. Populated at runtime with the slide-corrected remote symbol address.
   - `[0x110..end]`: **Dylib Path String**. Null-terminated string pointing to the staged library path (`/Library/GPUBundles/libhyprserver.dylib`).

3. **ASLR Shared Cache Slide Delta Correction**: The injector MUST calculate the ASLR slide difference between the injector process and `WindowServer`. It SHALL query `task_info(target_task, TASK_DYLD_INFO, ...)` and read `dyld_all_image_infos.sharedCacheSlide` via `mach_vm_read()` to determine the remote slide, compare it to the local `sharedCacheSlide`, and apply the delta (`delta = remote_slide - local_slide`) to `pthread_create_from_mach_thread`, `dlopen`, and `dlerror` function pointers before copying them into the remote code page data slots. The injector MUST call `vm_deallocate` to symmetrically release the `mach_vm_read` buffer.
4. **PAC Pointer Authentication & State Conversion**: The injector SHALL strip PAC from local function pointers via `ptrauth_strip(..., ptrauth_key_function_pointer)`. It MUST PAC-sign the remote code entry point (PC) and stack pointer (SP) using `ptrauth_sign_unauthenticated` with key `ptrauth_key_asia` before calling `_thread_convert_thread_state(thread, 2, ARM_THREAD_STATE64, ...)`.
5. **Thread Launch**: On macOS 14.4 and later (`os_major == 14 && os_minor >= 4` or `os_major >= 15`), the injector SHALL launch the thread via `thread_create_running` using the converted machine state. On earlier macOS versions, it SHALL launch via `thread_set_state` followed by `thread_resume`. The injector SHALL NOT use `__DARWIN_ARM_THREAD_STATE64_FLAGS_NO_PTRAUTH`.
6. **Watchdog, Post-Mortem Diagnostics & Cleanup**: The injector SHALL poll `thread_get_state` for the Stage 1 readiness marker (`x0 == 0x79616265`), poll for the creation of `/tmp/hyprserver.ready`, terminate the spinning Stage 1 Mach thread via `thread_terminate`, and deallocate the Mach task port via `mach_port_deallocate`. If readiness polling times out or fails, the injector SHALL read `remote_diag` via `mach_vm_read()` to evaluate post-mortem markers (`0xDEAD0001`, `0xDEAD0002`), `dlopen` return pointer, and any captured `dlerror` message.

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

  Scenario: Diagnostic page allocation and post-mortem telemetry
    Given remote memory allocations prepared for WindowServer
    When remote_diag is allocated at offset 0x100 of the remote code page slots
    Then Stage 2 SHALL record entry marker 0xDEAD0001 and pre-dlopen marker 0xDEAD0002
    And if dlopen returns NULL, Stage 2 SHALL invoke dlerror and copy error text to remote_diag + 0x20
    And the injector SHALL inspect remote_diag via mach_vm_read upon watchdog failure

  Scenario: ASLR shared cache slide delta correction
    Given injector and WindowServer operate in separate Mach task spaces
    When resolving function pointers for pthread_create_from_mach_thread, dlopen, and dlerror
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
- If library validation fails during `dlopen()`, `dlopen()` returns `NULL` and `dlerror()` emits `"code signature invalid for 'libhyprserver.dylib'"`. The injector MUST detect constructor/readiness non-appearance within the watchdog window and report an actionable error indicating code signing failure.

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

### REQ-INJ-007: Sandbox Traversal Dylib Staging [IMPLEMENTED]
The injector `hypr-inject` MUST stage `libhyprserver.dylib` into a system-accessible directory before initiating remote thread execution in `WindowServer`.
- `WindowServer` runs as UID 88 (`_windowserver`) under a strict macOS sandbox profile that forbids filesystem access to user home directories (`/Users/*`), `/tmp`, or arbitrary third-party application paths during `dlopen()`. Attempting to load `libhyprserver.dylib` directly from user workspace paths results in `dlopen()` returning `NULL` with `dlerror()` reporting `"Operation not permitted"` or sandbox file-read violations.
- Before allocating remote task memory or converting thread state, `hypr-inject` MUST copy `libhyprserver.dylib` to `/Library/GPUBundles/libhyprserver.dylib` (verifying that the directory `/Library/GPUBundles` exists, creating it if needed with mode `0755`).
- The staged dylib MUST be assigned file permissions `0644` (`S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH`), ensuring read access for `_windowserver` (UID 88).
- The dylib path passed to remote Stage 2 execution MUST reference `/Library/GPUBundles/libhyprserver.dylib`.

#### Feature: Sandbox Traversal Dylib Staging
```gherkin
Feature: Sandbox Traversal Dylib Staging
  Scenario: Dylib staged to /Library/GPUBundles before remote execution
    Given hypr-inject is executing as root (UID 0)
    When preparing remote execution parameters for WindowServer
    Then the injector SHALL copy libhyprserver.dylib to /Library/GPUBundles/libhyprserver.dylib with mode 0644
    And the remote code page dylib path slot SHALL reference /Library/GPUBundles/libhyprserver.dylib

  Scenario: Prevent sandbox traversal violation
    Given WindowServer (UID 88) operates under sandbox filesystem restrictions
    When Stage 2 executes dlopen("/Library/GPUBundles/libhyprserver.dylib", RTLD_LAZY)
    Then the sandbox SHALL permit reading the dylib from /Library/GPUBundles
    And dlopen SHALL proceed without sandbox containment errors
```

---

### REQ-WS-002: Safe-Mode Circuit Breaker [IMPLEMENTED]
The in-process payload `libhyprserver.dylib` MUST evaluate whether the tombstone file `/tmp/hyprmac.safemode` exists prior to executing any initialization logic or allocating server resources. If present, the constructor MUST return immediately without spawning threads, mapping shared memory, touching readiness markers, or attaching memory hooks.

#### Feature: Safe-Mode Circuit Breaker and Emergency Abort
```gherkin
Feature: Safe-Mode Circuit Breaker and Emergency Abort
  Scenario: Safe-mode tombstone active
    Given the file /tmp/hyprmac.safemode exists on disk
    When libhyprserver.dylib is loaded into WindowServer via dlopen()
    Then the initialization worker MUST detect the tombstone
    And abort initialization immediately without mapping /tmp/hyprmac-ipc.shm or touching /tmp/hyprserver.ready
    And log an abort message to system logs
```

---

### REQ-WS-003: Main Runloop Non-Interference [IMPLEMENTED]
The library `libhyprserver.dylib` MUST NOT block, synchronize with, or delay the main thread of `WindowServer`. All IPC operations, shared memory ring buffer polling, and background tasks MUST execute on a dedicated detached POSIX thread spawned via `pthread_create` and `pthread_detach`. The constructor MUST complete and return in under 5 milliseconds. `WindowServer` SHALL experience zero dropped display frames during the load operation.

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

### REQ-WS-016: SkyLight Main-Thread Notification Dispatch [IMPLEMENTED]
ALL SkyLight notification registrations (`SLSRegisterNotifyProc`, `SLSRegisterConnectionNotifyProc`) and display enumerations (`SLSGetActiveDisplayList`) MUST be dispatched to the main runloop via `dispatch_async(dispatch_get_main_queue(), ...)`.
- Inside `WindowServer`, internal SkyLight notification and connection dispatch routines explicitly assert main-thread execution via `pthread_main_np() != 0`.
- Calling SkyLight notification registration APIs from background worker pthreads triggers an assertion failure and causes `WindowServer` to crash immediately.
- The background initialization thread (`deferred_init()`) MUST decouple background IPC ring buffer setup from SkyLight notification registration by dispatching all space transition observers (`register_space_callbacks()`) and display reconfiguration observers (`register_display_callbacks()`) asynchronously to `dispatch_get_main_queue()`.

#### Feature: SkyLight Main-Thread Notification Dispatch
```gherkin
Feature: SkyLight Main-Thread Notification Dispatch
  Scenario: Asynchronous dispatch of SkyLight notification registrations
    Given libhyprserver.dylib is initializing on a background pthread
    When registering space transition or display reconfiguration callbacks
    Then the registrations MUST be dispatched via dispatch_async to dispatch_get_main_queue()
    And execution on the main queue SHALL satisfy pthread_main_np() != 0 without triggering assertions
    And WindowServer SHALL NOT crash during callback registration
```

---

## 2. Shared Memory IPC Architecture & Wire Protocol

### REQ-SHM-001: File-Backed Shared Memory IPC Channel [IMPLEMENTED]
The in-process hook `libhyprserver.dylib` MUST create and map `/tmp/hyprmac-ipc.shm` (`HYPR_SHM_PATH`) as a 64KB (`HYPR_SHM_SIZE = 65536` bytes) file-backed shared memory region with permissions `0666` and `MAP_SHARED`. The Swift client bridge `HyprServerBridge.swift` MUST open and map the same file with `MAP_SHARED`.
- Memory Layout Partitioning:
  - `[0x0000..0x00FF]` (Offset 0, 256 bytes): **Header Region (`HyprShmHeader`)**.
    - `magic` (`uint32_t`): `0x48534D49` (`HYPR_SHM_MAGIC`, ASCII `"HSMI"`).
    - `version` (`uint32_t`): `1` (`HYPR_SHM_VERSION`).
    - `hook_pid` (`uint32_t`): PID of `WindowServer` written by the hook during initialization.
    - `hook_ready` (`uint32_t`): Set to `1` atomically by the hook once memory mapping and ring buffers are ready.
    - `cmd_write_pos` (`uint32_t`): Current byte offset in Command Ring written by Swift client.
    - `cmd_read_pos` (`uint32_t`): Current byte offset in Command Ring written by Hook reader.
    - `rsp_write_pos` (`uint32_t`): Current byte offset in Response Ring written by Hook writer.
    - `rsp_read_pos` (`uint32_t`): Current byte offset in Response Ring written by Swift reader.
    - `_reserved` (`uint8_t[224]`): Reserved padding up to 256 bytes.
  - `[0x0100..0x70FF]` (Offset 256, 28KB = 28,672 bytes): **Command Ring Buffer (`HYPR_CMD_RING_SIZE`)**.
  - `[0x7100..0xE0FF]` (Offset 28928, 28KB = 28,672 bytes): **Response Ring Buffer (`HYPR_RSP_RING_SIZE`)**.
  - `[0xE100..0xFFFF]` (Offset 57600, 7,936 bytes): Trailing reserved space.

#### Feature: File-Backed Shared Memory IPC Channel
```gherkin
Feature: File-Backed Shared Memory IPC Channel
  Scenario: Shared memory channel initialization and mapping
    Given libhyprserver.dylib initializes inside WindowServer
    When the hook creates /tmp/hyprmac-ipc.shm with mode 0666 and size 65536 bytes
    Then it SHALL map the file with MAP_SHARED and initialize HyprShmHeader with magic 0x48534D49
    And the Swift client SHALL open and map the identical shared memory region
```

---

### REQ-SHM-002: Dual Lock-Free Ring Buffer [IMPLEMENTED]
All command dispatch and response delivery MUST be mediated through dual lock-free unidirectional ring buffers:
1. **Command Ring (`HYPR_CMD_RING_SIZE` = 28KB, 28,672 bytes)**: The Swift client acts as the single producer, advancing `cmd_write_pos`. The server hook acts as the single consumer, advancing `cmd_read_pos`.
2. **Response Ring (`HYPR_RSP_RING_SIZE` = 28KB, 28,672 bytes)**: The server hook acts as the single producer, advancing `rsp_write_pos`. The Swift client acts as the single consumer, advancing `rsp_read_pos`.

- **Lock-Free Memory Synchronization**: Synchronization across process boundaries MUST use atomic memory operations with acquire-release semantics (`__ATOMIC_ACQUIRE` / `__ATOMIC_RELEASE`). No POSIX mutexes, semaphores, or kernel locks are permitted in steady-state ring operations.
- **Message Boundary Invariant (Skip Marker)**: Messages MUST NOT straddle the physical boundary at the end of a 28KB ring buffer:
  - If enqueuing a message (`sizeof(HyprMessageHeader) + payload_size`) would exceed the contiguous bytes remaining at the end of the ring, the writer MUST write a 4-byte zero skip marker (`uint32_t magic = 0`) at the current write position.
  - The writer MUST wrap around and write the complete message starting at offset `0` of the ring buffer.
  - When a reader observes `magic == 0` at its current read offset, it MUST immediately reset its read offset to `0` and parse the next message frame from offset `0`.

#### Feature: Dual Lock-Free Ring Buffer Communication
```gherkin
Feature: Dual Lock-Free Ring Buffer Communication
  Scenario: Command and response transaction over ring buffers
    Given an established shared memory mapping
    When the Swift client writes a command into the command ring and advances cmd_write_pos with release semantics
    Then the server hook SHALL read the frame using acquire semantics, process the command, and write a response into the response ring
    And the server hook SHALL advance rsp_write_pos with release semantics

  Scenario: Ring boundary wrap with zero skip marker
    Given a ring buffer with fewer contiguous trailing bytes remaining than the pending message frame
    When the writer writes the message
    Then the writer SHALL write 4 zero bytes as a skip marker at the current write position
    And the writer SHALL place the complete message frame at offset 0 of the ring buffer
    And the reader SHALL detect the zero skip marker and wrap its read position to 0
```

---

### REQ-SHM-003: Shared Memory Handshake & Liveness [IMPLEMENTED]
The shared memory channel MUST enforce explicit handshake verification and continuous liveness tracking:
- **Hook Readiness Handshake**: During initialization, the hook MUST write its active PID to `header.hook_pid`, initialize the ring pointers, and atomically store `1` into `header.hook_ready` using `__ATOMIC_RELEASE`.
- **Client Protocol Validation**: Upon mapping `/tmp/hyprmac-ipc.shm`, the Swift client MUST verify that `header.magic == HYPR_SHM_MAGIC (0x48534D49)` and `header.version == HYPR_SHM_VERSION (1)`. The client MUST poll until `header.hook_ready == 1` (with a timeout of 500ms) before dispatching commands.
- **Process Liveness Monitoring**: The Swift client bridge MUST track `header.hook_pid` to detect crashes or restarts of `WindowServer`. If `kill(hook_pid, 0) != 0` or the process PID terminates, the bridge MUST mark the hook as disconnected, emit `.hyprServerHookUnavailable`, and schedule reconnection with exponential backoff.

#### Feature: Shared Memory Handshake and Liveness Detection
```gherkin
Feature: Shared Memory Handshake and Liveness Detection
  Scenario: Successful client handshake with ready hook
    Given libhyprserver.dylib has set hook_ready = 1 in /tmp/hyprmac-ipc.shm
    When the Swift client maps the shared memory file
    Then the client SHALL validate magic 0x48534D49 and version 1
    And the client SHALL proceed with command dispatch

  Scenario: WindowServer crash and PID liveness failure
    Given an active shared memory IPC session with hook_pid = P
    When WindowServer process P terminates unexpectedly
    Then the Swift client SHALL detect liveness loss via kill(P, 0)
    And transition to disconnected state and route commands through fallback overlays
```

---

### REQ-WS-004: Binary Framing & Magic Validation [IMPLEMENTED]
All IPC communication between `HyprMac` and `WindowServer` runs over the file-backed shared memory ring buffers at `/tmp/hyprmac-ipc.shm` (64KB, mode `0666`), NOT a Unix domain socket. Communication across the shared memory ring buffers MUST adhere to the binary packet layout defined by `HyprMessageHeader`. Every message header MUST start with `HYPR_MAGIC` (`0x48595052`) and a matching version number (`HYPR_PROTO_VERSION = 1`). Packets with invalid magic numbers or corrupt lengths MUST be discarded, and the server SHALL write a `HYPR_CMD_ERROR` response to the response ring.

#### Header Layout (`HyprMessageHeader`):
- `magic` (`uint32_t`): `0x48595052` (`"HYPR"`)
- `version` (`uint16_t`): `HYPR_PROTO_VERSION` (`1`)
- `command_id` (`uint16_t`): Command identifier (`HyprCommand`)
- `sequence` (`uint32_t`): Client-generated monotonic sequence number
- `window_id` (`uint32_t`): Target `CGWindowID` (or `0` for global commands)
- `payload_size` (`uint32_t`): Byte length of trailing payload

#### Framing Payloads & Structs:
Commands transmitting payload bodies require packed C structures matching the command definition.

##### Focus Synchronization Payload (`HyprPayloadFocus`):
```c
#pragma pack(push, 1)
typedef struct {
    uint32_t window_id;      // Target window ID to focus (4 bytes)
} HyprPayloadFocus;
#pragma pack(pop)
```
> **Implementation Note on `HyprPayloadFocus`:**
> The `HyprPayloadFocus` struct (4 bytes, `{ uint32_t window_id; }`) is currently defined only in `native/server_hook/hook.c` (lines 84-88) and is not yet present in `native/shared/protocol.h`. It needs to be moved to the shared `protocol.h` header to eliminate split-brain definitions between client and server.

#### Feature: IPC Wire Protocol Framing and Magic Validation
```gherkin
Feature: IPC Wire Protocol Framing and Magic Validation
  Scenario: Valid Ping packet over shared memory ring buffer
    Given an initialized shared memory IPC channel at /tmp/hyprmac-ipc.shm
    When the client writes a 20-byte header to the command ring with command_id = HYPR_CMD_PING
    Then the server MUST reply with a header in the response ring containing command_id = HYPR_CMD_PONG

  Scenario: Invalid magic number
    Given a client writes a message header starting with 0xDEADBEEF to the command ring
    When the server parses the incoming buffer
    Then the server MUST write HYPR_CMD_ERROR to the response ring
    And advance past the invalid frame safely without faulting
```

---

### REQ-WS-011: Maximum Payload Size [IMPLEMENTED]
Within the shared memory ring buffer message framing, any incoming packet with `payload_size > 65536` bytes (defined by `HYPR_MAX_PAYLOAD_SIZE` in `protocol.h`) SHALL be rejected with `HYPR_CMD_ERROR` / `HYPR_ERR_INTERNAL` ("Payload too large"). Furthermore, because the command and response rings each possess a capacity of 28KB (`HYPR_CMD_RING_SIZE` = 28,672 bytes), an individual message's combined header and payload size (`sizeof(HyprMessageHeader) + payload_size`) cannot exceed the ring buffer capacity. Both the client bridge (`HyprServerBridge.swift`) and server hook (`hook.c`) MUST enforce this bound.
Packets exceeding the ring buffer capacity or spec bound SHALL NOT be written to the ring, or if encountered, SHALL be rejected with `HYPR_CMD_ERROR`.

#### Feature: Shared Memory Payload Bounds and Ingestion Limits
```gherkin
Feature: Shared Memory Payload Bounds and Ingestion Limits
  Scenario: Incoming packet exceeds maximum size
    Given an active shared memory IPC session
    When a client attempts to enqueue a packet with payload_size > 65536 bytes
    Then the operation SHALL be rejected with HYPR_CMD_ERROR and error message "Payload too large"
    And the ring buffer write position SHALL remain unmodified
```

---

### REQ-WS-012: Shared Memory File Permissions & Mutual Authentication [IMPLEMENTED]
The shared memory file `/tmp/hyprmac-ipc.shm` SHALL be created with mode `0666` (world-readable and world-writable). This mode is REQUIRED because `WindowServer` runs as UID 88 (`_windowserver`), while client processes run in unprivileged user sessions (UID 501). Mutual authentication SHALL be enforced via a 16-byte (128-bit) cryptographically random token generated at injection time and stored in `/tmp/hyprmac-auth-token` (readable only by owner, mode `0600`). The first command transmitted across the command ring from any client connection SHALL be `HYPR_CMD_AUTH` (0x0030) carrying this 16-byte token (`HyprPayloadAuth`). If a client fails to transmit a valid `HYPR_CMD_AUTH` token within 1000ms of handshake, or transmits any non-auth command while unauthenticated, the hook SHALL reject the command with `HYPR_ERR_UNAUTHORIZED`.

#### Feature: Shared Memory Permissions and Mutual Authentication
```gherkin
Feature: Shared Memory Permissions and Mutual Authentication
  Scenario: Client authentication handshake over shared memory
    Given the shared memory file /tmp/hyprmac-ipc.shm is created with mode 0666
    When a client maps the shared memory and sends HYPR_CMD_AUTH with the valid 16-byte token within 1 second
    Then the hook SHALL authenticate the client session and allow subsequent commands

  Scenario: Unauthenticated connection timeout
    Given a client has mapped /tmp/hyprmac-ipc.shm but has not sent HYPR_CMD_AUTH
    When the client sends a window decoration command
    Then the hook SHALL reject the command with HYPR_ERR_UNAUTHORIZED
```

---

## 3. Window Property Manipulation

### REQ-WS-005: Square Corners (0px Corner Radius) [IMPLEMENTED]
When a client sends `HYPR_CMD_SET_CORNER_RADIUS` with a valid target `window_id` and `corner_radius = 0.0f`, `libhyprserver.dylib` MUST enforce a 0px corner clipping mask on the target window's composited surface via `SetWindowCornerRadius` and `SetWindowCornerMask`. Surface cache invalidation SHALL be triggered via `SLSFlushSurface()` or equivalent CGS private API (`invalidate_window`) after modifying window properties. If the invalidation API is unavailable, the hook SHALL fall back to `SLSMoveWindow()` with zero delta as a forced redraw trigger.

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

### REQ-WS-006: Shadow Stripping [IMPLEMENTED]
When a client sends `HYPR_CMD_SET_SHADOW_STATE` with `shadow_enabled = 0`, `libhyprserver.dylib` MUST clear the drop-shadow rendering pass for the specified `window_id` using server-level connection credentials via `SLSSetWindowShadowParameters` and window tag clearing (`ClearWindowTags`). Surface cache invalidation SHALL be triggered via `SLSFlushSurface()` or equivalent CGS private API (`invalidate_window`).

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

### REQ-WS-007: Native Synchronized Border Rendering [NOT IMPLEMENTED]
The composition hook MUST render a border around managed windows at the compositor level, synchronized with the display refresh cycle.

> **Implementation Status Note [NOT IMPLEMENTED]:**
> Border parameter storage is implemented but no compositor-level rendering is performed. Current visual borders use AppKit overlay windows (BorderWindow.swift).

- The border parameters (width, active color, inactive color) MUST be configurable per-window via `HYPR_CMD_SET_WINDOW_BORDER` and recorded in `HyprManagedWindow`.
- The border MUST support independent active and inactive colors, determined by the window's focus state.
- The border MUST update within a single display refresh cycle (<=16.67ms at 60Hz) when window focus changes, triggering surface redraws and invalidation.
- The border rendering MUST NOT introduce additional draw calls visible to the application; it operates below the application's rendering surface.
- When `border_width` is set to `0.0f`, the border MUST be fully removed (no residual artifacts).

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

### REQ-WS-008: Titlebar Stripping [IMPLEMENTED]
The composition hook MUST support stripping the native macOS titlebar from managed windows via `HYPR_CMD_STRIP_TITLEBAR`.
- Stripping the titlebar mutates window tags `(1 << 9) | (1 << 18)` via `SetWindowTags` / `ClearWindowTags` to remove title text, traffic light buttons (close/minimize/zoom), and toolbar background from the compositor's rendering of the window.
- The window's content area MUST expand to fill the space previously occupied by the titlebar.
- Titlebar stripping MUST be reversible: sending `HYPR_CMD_STRIP_TITLEBAR` with `strip=0` MUST restore the native titlebar and shrink the content area back to its original bounds.

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

### REQ-WS-009: Window State Query [IMPLEMENTED]
The composition hook MUST support querying the current decoration state of a managed window via `HYPR_CMD_QUERY_WINDOW`.
- The response MUST return `HyprPayloadQueryResponse` containing: `corner_radius`, `shadow_enabled`, `titlebar_stripped`, `border_color`, and `border_width`.
- If the `window_id` does not correspond to a valid, existing window, the hook MUST respond with `HYPR_CMD_ERROR` and error code `0x0001` (`HYPR_ERR_INVALID_WID`).

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

### REQ-WS-013: Focus State Synchronization Command [IMPLEMENTED]
A command `HYPR_CMD_SET_WINDOW_FOCUS (0x0014)` with a 4-byte payload body `{ uint32_t window_id }` (`HyprPayloadFocus`) SHALL be defined. The target window identifier MUST be transmitted in the payload body (with `payload_size = 4`), in addition to the header's `window_id` field. When received, the hook SHALL mark the specified window as focused and all other managed windows as unfocused, triggering surface invalidation. The border color of the newly focused window SHALL transition to `color_active`, and previously focused windows SHALL transition to `color_inactive`, within one display refresh cycle (<=16.67ms at 60Hz).

> **Note on `HyprPayloadFocus`:** The `HyprPayloadFocus` struct is currently defined only in `native/server_hook/hook.c` (not in `native/shared/protocol.h`) and needs to be moved to the shared header.

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

### REQ-WS-014: Window Lifecycle Invalidation [IMPLEMENTED]
When a managed window is destroyed by the OS, the hook SHALL probe window liveness via `is_window_alive()` and remove stale handles via `managed_window_evict()` within one event loop cycle. Any subsequent command targeting a destroyed window SHALL return `HYPR_ERR_INVALID_WID (0x0001)`. The hook SHALL NOT access memory of destroyed windows.

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

### REQ-WS-015: Global Window Decoration Policy [IMPLEMENTED]
The composition hook MUST support configuring a default global decoration policy for newly created windows via `HYPR_CMD_SET_GLOBAL_POLICY = 0x0015`.
- The command payload `HyprPayloadGlobalPolicy` is a 16-byte packed structure:
  ```c
  typedef struct __attribute__((packed)) {
      uint8_t  auto_square_corners;   // 1
      uint8_t  auto_strip_shadow;     // 1
      uint8_t  auto_strip_titlebar;   // 1
      uint8_t  auto_set_border;       // 1
      float    border_width;          // 4
      uint32_t border_color_active;   // 4
      uint32_t border_color_inactive; // 4
  } HyprPayloadGlobalPolicy;          // 16 bytes
  ```
- When a new application window is mapped by `WindowServer` (intercepted via `my_SLSNewWindow` interposition), the hook MUST automatically apply this global decoration policy without requiring individual per-window IPC commands from the client.
- Per-window decoration commands (`HYPR_CMD_SET_CORNER_RADIUS`, `HYPR_CMD_SET_SHADOW_STATE`, `HYPR_CMD_SET_WINDOW_BORDER`, `HYPR_CMD_STRIP_TITLEBAR`) SHALL override the global policy for the specified window.

#### Feature: Global Window Decoration Policy Configuration
```gherkin
Feature: Global Window Decoration Policy Configuration
  Scenario: Setting global decoration policy for newly created windows
    Given the composition hook is active in WindowServer
    When the client sends HYPR_CMD_SET_GLOBAL_POLICY with auto_square_corners=1, auto_strip_shadow=1, auto_strip_titlebar=1, auto_set_border=1, border_width=1.0, border_color_active=0xFF00AAFF, border_color_inactive=0xFF444444
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

### REQ-WS-010: Swift Client Bridge Resilience & Replay Queue [IMPLEMENTED]
`HyprServerBridge.swift` MUST handle disconnection and unavailability of the composition hook gracefully.
- If the shared memory IPC channel `/tmp/hyprmac-ipc.shm` is not available or the hook is not ready (`hook_ready != 1`), the bridge MUST NOT crash. It SHALL log a diagnostic warning and fall back to the existing `SkyLightBridge` out-of-process path.
- If the shared memory connection is lost mid-session (WindowServer crash/restart, hook unload detected via PID liveness), the bridge MUST attempt reconnection with exponential backoff (initial delay 100ms, max delay 5s, max attempts 10).
- After exhausting reconnection attempts, the bridge SHALL emit a `hyprServerHookUnavailable` notification and fall back to `SkyLightBridge`.
- The bridge MUST set a per-command timeout of 500ms. If no response is received within 500ms, the command is considered failed and the bridge MAY retry once before reporting failure to the caller.
- The Swift bridge maintains a `CommandRingBuffer` with a capacity of 64 pending commands. During disconnection or following write failure, commands are enqueued. When the buffer is full (capacity = 64), the oldest entry is overwritten using circular drop-oldest eviction semantics.
- Upon successful reconnection, all queued commands SHALL be replayed in FIFO order before accepting new commands. If command replay encounters an IPC error, unplayed commands are re-enqueued and reconnection is re-scheduled.

#### Feature: Swift Client Bridge Resilience, Fallback and Replay
```gherkin
Feature: Swift Client Bridge Resilience, Fallback and Replay
  Scenario: Hook Not Installed (Graceful Fallback)
    Given HyprMac is launched without the composition hook loaded in WindowServer
    When HyprServerBridge attempts to map /tmp/hyprmac-ipc.shm
    Then the mapping SHALL fail or hook_ready SHALL be 0
    And the bridge SHALL log a warning indicating hook unavailability
    And all window decoration commands SHALL be routed through SkyLightBridge

  Scenario: Mid-Session Disconnection
    Given HyprServerBridge has an active connection to the composition hook
    When the shared memory connection is lost or WindowServer restarts
    Then the bridge SHALL attempt reconnection with exponential backoff
    And during disconnection, the bridge SHALL maintain a ring buffer of up to 64 pending commands
    And upon successful reconnection, all queued commands SHALL be replayed in FIFO order before accepting new commands

  Scenario: Ring Buffer Capacity and Circular Drop-Oldest Eviction
    Given HyprServerBridge is disconnected and 64 commands are already buffered
    When a new window decoration command is enqueued
    Then the oldest buffered command SHALL be dropped
    And the new command SHALL be appended at the tail of the buffer
    And the total buffer count SHALL remain at 64
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

### REQ-SEC-002: Compositor Blast Radius & Session Protection [IMPLEMENTED]
Because `WindowServer` constitutes the root compositor daemon for the macOS user session, any fatal signal (`SIGSEGV`, `SIGBUS`, `SIGILL`) triggered inside `WindowServer` terminates the graphical session immediately. 
- All IPC message parsing within `hook.c` MUST fail-closed on malformed inputs, truncated payloads, or out-of-range parameters.
- Pointer dereferences against private `WindowServer` or CoreGraphics data structures MUST be guarded with bounds checks and validated against null invariants.
- If an unrecoverable internal condition arises, the hook MUST shut down its background worker and unlink `/tmp/hyprmac-ipc.shm` and `/tmp/hyprserver.ready` without crashing the host process.

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
- If `/tmp/hyprmac.safemode` exists, `libhyprserver.dylib` constructor and initialization routines MUST return immediately without initializing shared memory, touching readiness markers, or modifying compositor state.
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
    And no shared memory at /tmp/hyprmac-ipc.shm or ready file at /tmp/hyprserver.ready SHALL be created
```

---

### REQ-SAF-002: Graceful Degradation to User-Space Emulation [IMPLEMENTED]
When `libhyprserver.dylib` is unavailable, uninstalled, or disabled by safe-mode, `HyprMac` MUST maintain basic window management functionality:
- The Swift application SHALL fall back to `BorderWindow.swift` (AppKit border overlays) and `SkyLightBridge.swift` within 500ms of hook unavailability.
- In `BorderWindow.swift`, notifications `.hyprServerHookAvailable` and `.hyprServerHookUnavailable` actively toggle overlay visibility: when the in-situ hook connects, AppKit overlays are deactivated and hidden (`orderOut`), and when the hook disconnects or is unavailable, AppKit overlays are restored.

> **WARNING:**
> Because in-situ border rendering (REQ-WS-007) is not yet implemented, activating the hook while BorderWindow is configured to hide will result in NO visible borders.

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
1. **Dylib Constructor & Deferred Initialization Budget**: The dylib constructor `hypr_server_init()` MUST complete and return to the caller in <= 5.0 milliseconds by offloading setup to a detached thread. Deferred initialization (`deferred_init()`) enforces an intentional 500-millisecond delay (`usleep(500000)`) prior to shared memory initialization and readiness marker creation, allowing WindowServer subsystems and process environment to fully stabilize. Total elapsed time from injection to IPC readiness is bounded to <= 600 milliseconds.
2. **Compositor Frame Drop SLA**: `WindowServer` SHALL experience 0 dropped frames during injection, library initialization, and steady-state operation. Frame callback intervals on 60Hz displays MUST not exceed 25.0ms (1.5x nominal period); on 120Hz ProMotion displays, intervals MUST not exceed 12.5ms.
3. **IPC Dispatch Latency**: Round-trip request-response latency across `/tmp/hyprmac-ipc.shm` for window modification commands MUST be < 20 microseconds in steady-state.
4. **Visual Transition Budget**: Active/inactive border transitions, corner radius changes, and shadow toggles MUST reflect on physical displays within <= 16.67 milliseconds (a single 60Hz refresh cycle) of IPC receipt.
5. **Client Command Timeout**: `HyprServerBridge.swift` SHALL enforce a 500ms timeout per command transaction.

> **Implementation Status & Verification Note [VERIFICATION PENDING]:**
> In `native/server_hook/hook.c`, `hypr_server_init()` executes minimally and returns to the caller in < 5.0ms, satisfying the constructor execution budget by spawning a detached pthread running `deferred_init()`. However, `deferred_init()` explicitly calls `usleep(500000)` (500 ms) to allow WindowServer process state and internal Mach subsystems to stabilize before resolving symbols, checking in the Mach bootstrap service port, and initializing `/tmp/hyprmac-ipc.shm` and `/tmp/hyprserver.ready`. Consequently, client connection attempts must account for this 500ms stabilization window. Formal verification of the 20µs IPC latency and 0 dropped frames via CVDisplayLink callbacks is pending empirical profiling on hardware.

#### Feature: Performance Budgets and SLA Compliance
```gherkin
Feature: Performance Budgets and SLA Compliance
  Scenario: Dylib constructor execution budget
    Given libhyprserver.dylib is loaded into WindowServer
    When constructor hypr_server_init() runs
    Then it SHALL return in under 5.0 milliseconds
    And deferred shared memory initialization SHALL complete after a 500ms subsystem stabilization delay

  Scenario: Zero dropped compositor frames verification
    Given WindowServer is rendering active frames
    When injection occurs and window decorations are updated
    Then display link callbacks SHALL not exceed 25ms interval at 60Hz or 12.5ms at 120Hz

  Scenario: IPC dispatch round-trip SLA
    Given an established IPC session over /tmp/hyprmac-ipc.shm
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
- If an incoming message contains `version != HYPR_PROTO_VERSION`, the server MUST reject the message with `HYPR_CMD_ERROR` / `HYPR_ERR_INTERNAL` and message string `"Bad version"`, rejecting further command processing.

#### Feature: Protocol Version Matching and Verification
```gherkin
Feature: Protocol Version Matching and Verification
  Scenario: Protocol version mismatch rejection
    Given a client writes a message header with version = 999 to the command ring
    When the server evaluates the header version field
    Then the server hook SHALL respond with HYPR_CMD_ERROR and error message "Bad version"
    And reject further command processing for the session
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

### REQ-WSP-001: Mission Control & Stage Manager Workspace Virtualization [IMPLEMENTED]
The composition hook MUST accommodate native macOS space switching, Mission Control, and Stage Manager without crashing `WindowServer` or corrupting window surfaces.
- In `native/server_hook/hook.c`, `register_space_callbacks()` registers SkyLight notification procs for event 1401 (`CGSWorkspaceChanged`) and handles transitions with settled debouncing (`handle_space_transition_settled()`).
- During Mission Control activation, windows are scaled and re-ordered in space. The hook MUST NOT attempt surface clipping re-computations on windows in transient animation states.
- When windows transition between virtual desktops (Spaces), the hook's internal tracking MUST preserve window state mappings.
- Upon return from Mission Control or Stage Manager, custom corner masks, shadow states, and borders MUST be retained without visual artifacts.

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

### REQ-WSP-002: Fullscreen & Split-View Transition Compliance [IMPLEMENTED]
When a managed window transitions into native macOS fullscreen or Split View:
- The hook MUST detect fullscreen transitions (registered via SkyLight notification procs for events 106 `CGSClientEnterFullscreen` and 107 `CGSClientExitFullscreen`, checking window tag bit `1 << 14`) and suspend border rendering if the window occupies fullscreen bounds.
- Upon exiting fullscreen mode, the hook MUST automatically re-apply configured borders, corner radii, and shadow states within 1 display refresh cycle.

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

### REQ-MON-001: Heterogeneous Display Refresh Rate Synchronization [IMPLEMENTED]
On multi-monitor workstations featuring mixed refresh rates (such as a 120Hz ProMotion internal display paired with 60Hz or 144Hz external monitors):
- Display topology and refresh rate tracking are registered in `native/server_hook/hook.c` via `register_display_callbacks()` and `update_display_topology()`.
- Border compositing and surface invalidation MUST synchronize to the refresh cycle of the specific display on which each window is located.
- When a window spans multiple displays, the hook MUST synchronize border updates to the primary display containing the greater surface area of the window.
- The hook MUST NOT introduce tearing, stutter, or frame pacing jitter when windows are dragged across displays with mismatched refresh rates.

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

### REQ-MON-002: Dynamic Display Reconfiguration & Hotplug Handling [IMPLEMENTED]
When external displays are connected, disconnected, or have their resolutions/color profiles reconfigured:
- In `native/server_hook/hook.c`, `register_display_callbacks()` registers CGDisplayReconfiguration callbacks and updates display topology via `update_display_topology()` upon hotplug and reconfiguration events.
- The composition hook MUST detect display topology changes within 1 display refresh cycle.
- The hook MUST re-validate all managed window display assignments and update compositor attachments accordingly.
- Stale display contexts MUST be released without leaking memory or referencing invalidated screen buffers.

#### Feature: Dynamic Display Reconfiguration and Hotplug Handling
```gherkin
Feature: Dynamic Display Reconfiguration and Hotplug Handling
  Scenario: Display disconnect and window migration handling
    Given an external display is disconnected while displaying managed windows
    When macOS migrates the windows to the remaining display
    Then the hook SHALL update window display associations within one refresh cycle
    And preserve all window decoration states without crashing WindowServer
```
