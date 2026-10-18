# Software Design Document (SDD): windowserver-insitu-composition

## Architecture Overview

### 1.1 Technical Approach & System Decomposition
The `windowserver-insitu-composition` subsystem operates as a high-leverage architectural seam inside `WindowServer` (`/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer`). Rather than struggling against client-side IPC filtering in `SkyLight.framework`, we execute inside the compositor's own address space.

The system is partitioned into three decoupled modules:
1. **The Injector (`hypr-inject`):** Ephemeral privileged loader running as root (UID 0). Performs pre-flight safety validation (SIP disabled, `-arm64e_preview_abi` boot argument, safe-mode tombstone), stages the dylib via `stage_dylib_for_windowserver()` to `/Library/GPUBundles/libhyprserver.dylib` (mode 0644) to overcome sandbox traversal restrictions, acquires the target `WindowServer` Mach task port, resolves `pthread_create_from_mach_thread`, `dlopen`, and `dlerror` from the shared cache, computes the ASLR shared cache slide delta across process boundaries, allocates remote execution pages (16KB stack, 4KB diagnostic page, 4KB code containing a two-stage assembly sequence), configures PAC-signed register state (`PC=remote_code`, `SP=remote_stack + 8192`), converts thread state across PAC domains via `_thread_convert_thread_state`, dispatches execution via `thread_create_running` (macOS ≥ 14.4) or `thread_set_state`+`thread_resume` (macOS < 14.4), polls for the Stage 1 readiness marker (`0x79616265`), unlinks `/tmp/hyprserver.ready` before starting and polls for its creation with a 10s timeout, terminates the spinning Mach thread, and verifies post-load stability via a 500ms crash watchdog.
2. **The In-Process Hook (`libhyprserver.dylib`):** Resident library running inside `WindowServer` (UID 88 / `_windowserver`). Upon initialization via `__attribute__((constructor))` (which spawns a detached worker thread executing a 500ms stabilization delay before initialization in `deferred_init`), dispatches SkyLight notification registrations to `dispatch_get_main_queue()` (satisfying `pthread_main_np() != 0` assertions), maps file-backed shared memory at `/tmp/hyprmac-ipc.shm` (64KB, `MAP_SHARED`, mode 0666), writes the readiness marker to `/tmp/hyprserver.ready`, and runs a 500μs lock-free polling loop (`shm_poll_loop`) to execute window attribute modifications (corner radius, shadow state, titlebar stripping) with native server-level credentials. (Note: Border parameters are tracked in server state, but in-situ compositor border rendering is NOT YET IMPLEMENTED; client overlays remain active).
3. **The Client Bridge (`HyprServerBridge.swift`):** Pure Swift client integrated into `HyprMac` that maps `/tmp/hyprmac-ipc.shm`, interacts via lock-free atomic command and response ring buffers, monitoring `NSWorkspace` notifications for focus synchronization with automatic readiness polling (`waitForHook`) and fallback to `SkyLightBridge`.
   > **Known Implementation Gaps in Swift Bridge:**
   > - `HyprCommand` enum in `HyprServerBridge.swift` is currently missing `HYPR_CMD_SET_WINDOW_FOCUS` (`0x0014`) and `HYPR_CMD_SET_GLOBAL_POLICY` (`0x0015`).
   > - `HyprError` enum in `HyprServerBridge.swift` is currently missing `HYPR_ERR_HOOK_UNAVAIL` (`0x0006`).

> **Shared Memory File Path & Permissions Invariant:** The IPC transport operates over a 64KB file-backed shared memory region at `/tmp/hyprmac-ipc.shm` (`MAP_SHARED`, mode `0666`) rather than Unix domain sockets. The WindowServer sandbox strictly blocks ALL socket operations (`bind()`, `listen()`, `connect()`) and Mach bootstrap registration (`bootstrap_check_in` fails with `kr=1100`), but permits file-backed shared memory in `/tmp`. `/tmp` is world-writable (`1777`), enabling `WindowServer` (UID 88 / `_windowserver`) and unprivileged client processes (UID 501) to cooperatively map and access the shared memory ring buffers. Readiness is signaled via `/tmp/hyprserver.ready`.

### 1.2 Architecture Decisions

| Decision | Choice | Alternatives Considered | Rationale |
|---|---|---|---|
| Injection Target | `WindowServer` directly (UID 88 / `_windowserver`). | Target `Dock.app` or inject individual GUI applications. | Dock lacks access to internal `WSWindow` clipping masks; per-application injection requires hooking every running and future process, which is fragile and incomplete for non-AppKit binaries. |
| Injection Vector | Two-Stage PAC-safe loader with ASLR shared cache slide correction (`task_for_pid` + `mach_vm_allocate` + `mach_vm_write` + `_thread_convert_thread_state` + `thread_create_running` + `pthread_create_from_mach_thread` → `dlopen`). | Direct `dlopen` on raw Mach thread, or `DYLD_INSERT_LIBRARIES` via `launchd.plist`. | Direct `dlopen` on a raw Mach thread crashes WindowServer fatally because externally created Mach threads lack initialized Thread-Specific Data (`TPIDRRO_EL0 = 0`), causing `pthread_getspecific` within dyld/dlopen to dereference NULL. The two-stage loader uses a raw Mach thread (Stage 1) to invoke `pthread_create_from_mach_thread` (which possesses an internal bypass to instantiate a real pthread with full TLS), which then runs Stage 2 on the real pthread to safely execute `dlopen(path, RTLD_LAZY)`. `launchd.plist` modifications risk unbootable recovery loops. |
| Dylib Staging | Stage dylib to `/Library/GPUBundles/libhyprserver.dylib` (mode 0644). | Load directly from user home directory (`/Users/...`) or `/tmp`. | WindowServer sandbox strictly blocks loading dynamic libraries from user home directories due to lack of world-traversal rights. `/Library/GPUBundles` is a standard system directory accessible to `_windowserver` (UID 88). |
| IPC Protocol | File-backed Shared Memory Ring Buffer (`/tmp/hyprmac-ipc.shm`, 64KB, `MAP_SHARED`, mode 0666) with lock-free atomic pointers. | Unix Domain Sockets, Mach Messages (`mach_msg`), or XPC. | The WindowServer sandbox blocks ALL socket operations (`bind()`, `listen()`, `connect()`) and Mach bootstrap registration (`bootstrap_check_in` fails with `kr=1100`). File-backed shared memory via `mmap()` under `/tmp` is permitted by the sandbox, provides ultra-low latency (<5μs), and eliminates socket connection overhead. |
| Threading & Concurrency Model | Dedicated background worker thread with lock-free 500μs polling loop on command ring buffer; SkyLight registrations dispatched to `dispatch_get_main_queue()`. | Hooking WindowServer's main runloop directly or socket-based event loop. | Polling the command ring buffer with a 500μs sleep consumes <0.5% CPU when idle while providing sub-millisecond command responsiveness. Isolating IPC from the main runloop avoids compositor frame drops, while dispatching SkyLight registrations to the main queue satisfies SkyLight's `pthread_main_np() != 0` assertions. |
| Failsafe Strategy | File-based circuit breaker (`/tmp/hyprmac.safemode`) + remote diagnostic page (4KB) + post-load PID watchdog + automatic client fallback. Signal sandboxing via `sigaction` + `sigsetjmp`/`siglongjmp`. | Kernel watchdogs or automatic restart scripts. | A filesystem tombstone is instantly verifiable with zero dependencies; post-mortem diagnostic page allows injector to inspect exact Stage 2 failure cause via `mach_vm_read()`; PID sampling detects immediate crashes; signal sandboxing isolates symbol discovery faults; client falls back to `BorderWindow` overlays on disconnect. |

### 1.3 Loader Architecture: Two-Stage PAC-Safe Dynamic Library Loading

#### Why Direct dlopen on Raw Mach Threads Fails
Prior loader patterns attempted to execute `dlopen` directly on an externally created Mach thread via `thread_create` / `thread_create_running`. On ARM64e macOS (macOS 14.4+ Sonoma and macOS 27 Golden Gate), **direct dlopen on a raw Mach thread crashes `WindowServer` fatally**.

In Darwin's threading implementation (`libsystem_pthread`), Mach threads created externally via kernel task ports lack an initialized POSIX thread structure (`pthread_t`) and Thread-Specific Data (TSD) block. On ARM64e, the hardware thread pointer register `TPIDRRO_EL0` (which points to the TSD block) is zero (`NULL`). During dynamic library loading, `dyld` and `libsystem` internally invoke `pthread_getspecific` or related TLS lookups. `pthread_getspecific` dereferences `TPIDRRO_EL0 + 4` (or `+ 16`), which immediately triggers an unhandled `EXC_BAD_ACCESS (SIGSEGV)` page fault at `0x0000000000000010`. Because `WindowServer` is a critical platform daemon, this crash causes `launchd` to terminate the graphical session, dumping the user to the login window.

#### The Architectural Solution: Two-Stage ARM64e Assembly Sequence
To eliminate the TLS crash invariant, `hypr-inject` uses a proven two-stage architecture (based on the ARM64e loader pattern by Jeremy Legendre in yabai, enhanced with ASLR shared cache slide delta correction):
- **Stage 1 (Raw Mach Thread):** Executes a minimal assembly sequence on the raw Mach thread. It calls `pthread_create_from_mach_thread`, which has a dedicated Libsystem initialization pathway specifically engineered to transition an uninitialized Mach thread into a fully valid POSIX thread with complete TLS/TSD. It passes the Stage 2 entry point as the start routine, moves the readiness marker `0x79616265` (`"yabe"`) into register `x0`, and enters an infinite spin loop.
- **Stage 2 (Real POSIX Thread with TLS):** Executes on the newly created POSIX thread where `TPIDRRO_EL0` is fully initialized. Stage 2 sets arguments (`x0 = &dylib_path`, `x1 = RTLD_LAZY (1)`), executes `dlopen` via `blr`, and returns cleanly via plain `ret` (`0xC0035FD6`). Per the RC4 fix, Stage 2 uses `nop` (`0x1F2003D5`) at entry instead of `pacibsp` and `ret` instead of `retab`. This is required because cross-process PAC domain constraints dictate that Stage 2 cannot use `pacibsp`/`retab`: PAC keys differ between the loader process (`hypr-inject`) and the target `WindowServer`, so PAC instructions authenticated in one process domain trap in the other.

#### 1. Remote Page Allocations
`hypr-inject` allocates three distinct memory regions in `WindowServer` address space:
1. **Remote Stack Page (16KB):** Allocated via `mach_vm_allocate(task, &remote_stack, 16384, VM_FLAGS_ANYWHERE)` and protected via `vm_protect(task, (vm_address_t)remote_stack, 16384, 1, VM_PROT_READ | VM_PROT_WRITE)`. Provides stack space for the initial Stage 1 Mach thread.
2. **Remote Diagnostic Page (4KB):** Allocated via `mach_vm_allocate(task, &remote_diag, 4096, VM_FLAGS_ANYWHERE)` and protected via `vm_protect(task, (vm_address_t)remote_diag, 4096, 1, VM_PROT_READ | VM_PROT_WRITE)`. Zero-filled RW page used by Stage 2 to record progress markers, dlopen handles, and dlerror messages for post-mortem diagnostics.
3. **Remote Code Page (4096 bytes):** Allocated via `mach_vm_allocate(task, &remote_code, 4096, VM_FLAGS_ANYWHERE)`. The page is structured with exact binary offsets matching `native/injector/main.c`:
   - `[0x00..0x57]` (88 bytes, 22 instructions): **Stage 1 Assembly Sequence**. Sets up a stack frame, prepares parameters (`x0 = &pthread_t`, `x1 = NULL`, `x2 = &stage2` signed via `paciza x2`, `x3 = NULL`), loads the slide-corrected address of `pthread_create_from_mach_thread` from offset `0x58`, calls `blr x9`, saves return code to `x20` and `pthread_t` to `x21`, sets `x0 = 0x79616265` (`movz x0, #0x6265; movk x0, #0x7961, lsl #16`), and enters a spin loop (`adr x9, #0; br x9`).
   - `[0x58..0x5F]` (8 bytes): **Data Slot: `pthread_create_from_mach_thread` (`pcfmt`) function pointer slot**. Populated at runtime with the slide-corrected remote symbol address.
   - `[0x60..0xF7]` (152 bytes, 38 instructions): **Stage 2 Assembly Sequence** (`dlopen` + diagnostic instrumentation). Starts with `nop` (`0x1F2003D5`, replacing `pacibsp` per the RC4 fix), allocates stack frame, loads remote diagnostic page pointer from offset `0x100`, writes entry marker `0xDEAD0001` at `[diag]`, writes pre-dlopen marker `0xDEAD0002` at `[diag + 4]`, sets `x1 = 1` (`RTLD_LAZY`), computes `x0 = &dylib_path` (`adr x0, #0x7C`), loads slide-corrected `dlopen` from offset `0xF8`, calls `blr x9`, and stores dlopen return handle at `[diag + 8]`. If `dlopen` returned NULL, loads slide-corrected `dlerror` from offset `0x108`, calls `blr x9`, stores dlerror pointer at `[diag + 0x18]`, and copies up to 200 bytes of dlerror string into `[diag + 0x20]`. Writes post-dlopen marker `0xDEAD0003` at `[diag + 0x10]`, restores frame, and returns via plain `ret` (`0xC0035FD6`).
   - `[0xF8..0xFF]` (8 bytes): **Data Slot: `dlopen` function pointer slot**. Populated at runtime with the slide-corrected remote symbol address.
   - `[0x100..0x107]` (8 bytes): **Data Slot: `remote_diag` page pointer slot**. Populated at runtime with the remote diagnostic page address.
   - `[0x108..0x10F]` (8 bytes): **Data Slot: `dlerror` function pointer slot**. Populated at runtime with the slide-corrected remote symbol address.
   - `[0x110..end]`: **Dylib Path String** (null-terminated). Contains the staged dylib path (`/Library/GPUBundles/libhyprserver.dylib`).
   The code page is written via `mach_vm_write` and protected via `vm_protect(task, (vm_address_t)remote_code, 4096, 0, VM_PROT_READ | VM_PROT_EXECUTE).

#### 2. ASLR Shared Cache Slide Delta Resolution
`WindowServer` runs in a separate Mach security session from the loader. While both processes map the dyld shared cache, their shared cache ASLR slides can differ across sessions. Directly using local function addresses across process boundaries results in invalid instruction jumps or PAC authentication traps.

The loader resolves this slide delta deterministically:
1. Queries the target process dyld info:
   ```c
   task_dyld_info_data_t remote_dyld_info;
   mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
   task_info(target_task, TASK_DYLD_INFO, (task_info_t)&remote_dyld_info, &count);
   ```
2. Reads `remote_dyld_info.all_image_info_addr` from the target task using `mach_vm_read()` to extract `struct dyld_all_image_infos`.
3. Verifies `remote_infos->version >= 12` and extracts `remote_slide = remote_infos->sharedCacheSlide`.
4. Symmetrically deallocates the read buffer via `vm_deallocate(mach_task_self(), read_data, read_count)` to maintain zero resource leakage.
5. Reads the local slide directly from `mach_task_self()`:
   ```c
   task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&local_dyld_info, &count);
   local_slide = ((struct dyld_all_image_infos *)local_dyld_info.all_image_info_addr)->sharedCacheSlide;
   ```
6. Computes the slide delta:
   ```c
   intptr_t slide_delta = (intptr_t)remote_slide - (intptr_t)local_slide;
   ```
7. Resolves local function pointers via `dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread")`, `dlsym(RTLD_DEFAULT, "dlopen")`, and `dlsym(RTLD_DEFAULT, "dlerror")`, strips PAC signatures via `ptrauth_strip(addr, ptrauth_key_function_pointer)`, and computes remote virtual addresses:
   ```c
   uint64_t remote_pcfmt   = pcfmt_addr   + slide_delta;
   uint64_t remote_dlopen  = dlopen_addr  + slide_delta;
   uint64_t remote_dlerror = dlerror_addr + slide_delta;
   ```
   These slide-corrected addresses and the diagnostic page pointer are written directly into the code page data slots at offsets `0x58`, `0xF8`, `0x100`, and `0x108`.

#### 3. PAC Signing Chain & Thread State Conversion
On Apple Silicon (ARM64e), pointers in thread execution state must carry valid PAC signatures:
1. **Initial Register Signing (`ptrauth_sign_unauthenticated`):**
   The loader configures the initial `arm_thread_state64_t` registers:
   - `PC`: Set to `remote_code` (entry point of Stage 1 assembly sequence at offset `0x00`), signed with PAC key `asia` using the loader's local PAC domain:
     ```c
     __darwin_arm_thread_state64_set_pc_fptr(
         thread_state,
         ptrauth_sign_unauthenticated((void *)remote_code, ptrauth_key_asia, 0));
     ```
   - `SP`: Set to the midpoint of the allocated stack (`remote_stack + 8192`), 16-byte aligned.
2. **PAC Domain Conversion (`_thread_convert_thread_state`):**
   Because the PAC signature generated by `ptrauth_sign_unauthenticated` belongs to the loader's PAC key context, the target process hardware will reject it. The loader invokes the private kernel function `_thread_convert_thread_state` (dynamically loaded from `/usr/lib/system/libsystem_kernel.dylib`):
   ```c
   kr = _thread_convert(thread, 2 /* THREAD_CONVERT_THREAD_STATE_FROM_SELF */,
                        ARM_THREAD_STATE64,
                        (thread_state_t)&thread_state, flavor_count,
                        (thread_state_t)&machine_state, &machine_count);
   ```
   The kernel strips the loader's PAC signature and re-signs `PC` and `LR` using the target `WindowServer` process's PAC keys, storing the result in `machine_state`.
3. **Thread Launch (`thread_create_running`):**
   - On macOS ≥ 14.4 (including macOS 27 Golden Gate), the initial dummy thread is terminated via `thread_terminate(thread)`, and the new thread is spawned running directly with the converted machine state:
     ```c
     thread_create_running(task, ARM_THREAD_STATE64, (thread_state_t)&machine_state, machine_count, &thread);
     ```
   - On macOS < 14.4, state is applied via `thread_set_state` followed by `thread_resume`.
   The hardware authenticates the kernel-signed `PC` in the target process domain and immediately begins executing Stage 1 assembly.

#### 4. Execution, Readiness Polling & Teardown
1. **Stage 1 Execution:** The raw Mach thread executes Stage 1 instructions, calling `pthread_create_from_mach_thread(&thread, NULL, stage2, NULL)`. Once the call returns, Stage 1 saves the return value in `x20` and `pthread_t` in `x21`, loads `0x79616265` (`CODE_MARKER_VALUE`, `"yabe"`) into `x0`, and loops indefinitely (`adr x9, #0; br x9`).
2. **Stage 2 Execution:** The new POSIX thread begins executing Stage 2 at offset `0x60`. With a valid `pthread_t` and initialized TSD (`TPIDRRO_EL0 != 0`), it writes diagnostic markers to the diagnostic page, then invokes `dlopen(path, RTLD_LAZY)`. If `dlopen` fails, it calls `dlerror()` and copies the diagnostic error message to the diagnostic page before returning cleanly via plain `ret` (`0xC0035FD6`).
3. **Constructor Initialization:** `dyld` loads `libhyprserver.dylib`, invoking its `__attribute__((constructor))` (`hypr_server_init`). The constructor immediately spawns a detached worker pthread (`deferred_init`) to manage shared memory IPC, returning quickly. Stage 2 completes and exits cleanly via plain `ret` (`0xC0035FD6`).
4. **Readiness Marker Polling:** The loader pauses 10ms, then polls `thread_get_state(thread)` up to 10 iterations (20ms intervals) checking whether `poll_state.__x[0] == 0x79616265`. Finding the marker confirms that Stage 1 successfully invoked `pthread_create_from_mach_thread` and entered the spin loop. The injector also inspects `poll_state.__x[20]` (pcfmt return value) and `poll_state.__x[21]` (`pthread_t`) to verify thread creation succeeded.
5. **Readiness Synchronization & Mach Thread Termination:** The injector unlinks `/tmp/hyprserver.ready` before injection, then polls for the creation of `/tmp/hyprserver.ready` (`HYPR_READY_PATH`) with a 10s timeout (100 iterations × 100ms). Once `/tmp/hyprserver.ready` appears, the hook has completed `deferred_init` and is actively polling the shared memory command ring. The injector terminates the spinning Stage 1 Mach thread via `thread_terminate(thread)`.
6. **Watchdog Verification & Diagnostic Inspection:** Remote pages remain allocated to guarantee stability. The loader sleeps for 500ms and re-checks `find_windowserver_pid()`. If the PID matches, loading succeeded cleanly and the loader exits with code 0. If readiness times out or WindowServer crashes, the injector reads the remote diagnostic page via `mach_vm_read()` for definitive root-cause analysis (checking markers and dlerror string).

#### 5. Remote Diagnostic Page & Post-Mortem Architecture
Because `WindowServer` executes in a sandboxed, security-hardened environment with restricted file access, debugging injection failures blindly is notoriously difficult. If `dlopen` fails, WindowServer does not log to standard output, and process termination risks terminating the user's graphical session.

To provide definitive, zero-guesswork root-cause diagnosis without modifying system logging policies:
1. **Diagnostic Page Allocation:**
   The injector allocates a 4096-byte zero-filled RW page in WindowServer address space:
   ```c
   kr = mach_vm_allocate(task, &remote_diag, 4096, VM_FLAGS_ANYWHERE);
   kr = vm_protect(task, (vm_address_t)remote_diag, 4096, 1, VM_PROT_READ | VM_PROT_WRITE);
   ```
   Its virtual address is written to the code page data slot at offset `0x100`.
2. **In-Situ Instrumentation in Stage 2 Assembly:**
   Stage 2 assembly (`[0x60..0xF7]`) writes explicit milestone markers into the diagnostic page:
   - Offset `+0x00` (4 bytes): Entry marker `0xDEAD0001` written upon Stage 2 function entry.
   - Offset `+0x04` (4 bytes): Pre-dlopen marker `0xDEAD0002` written immediately prior to `blr x9` calling `dlopen`.
   - Offset `+0x08` (8 bytes): Return handle from `dlopen` (`x0`). If `dlopen` succeeds, this contains the non-NULL dylib handle.
   - If `dlopen` returns NULL (`x0 == 0`):
     - Stage 2 invokes `dlerror()` via `blr x9` (address loaded from offset `0x108`).
     - Stores the `dlerror` string pointer at offset `+0x18`.
     - Copies up to 200 bytes of the `dlerror` error message string into offset `+0x20` (`[diag + 0x20]`).
   - Offset `+0x10` (4 bytes): Post-dlopen marker `0xDEAD0003` written before restoring the stack frame and returning.
3. **Injector Post-Mortem Analysis via `mach_vm_read()`:**
   If the hook readiness marker (`/tmp/hyprserver.ready`) is not detected within the 10-second timeout, the injector reads the diagnostic page using `mach_vm_read()`:
   ```c
   vm_offset_t data = 0;
   mach_msg_type_number_t cnt = 0;
   mach_vm_read(task, remote_diag, 64, &data, &cnt);
   ```
   - If `marker[0] != 0xDEAD0001`: Stage 2 never ran (indicates `pthread_create_from_mach_thread` failed; checked via Stage 1 register `x20`).
   - If `marker[1] != 0xDEAD0002`: Execution faulted before reaching `dlopen`.
   - If `dlopen_handle == 0`: `dlopen()` failed. The injector reads the null-terminated error string from `remote_diag + 0x20` and prints the exact dlerror message (e.g., sandbox violation, missing dependencies, or path permission error).
   - If `marker[4] != 0xDEAD0003`: Execution hung or crashed inside `dlopen()` or the dylib constructor.
   This provides instantaneous, deterministic diagnosis of loader failures.

#### 6. Dylib Staging & Sandbox Traversal (`stage_dylib_for_windowserver`)
`WindowServer` executes as UID 88 (`_windowserver`). Under modern macOS versions (macOS 14+ Sonoma and macOS 27 Golden Gate), the WindowServer sandbox profile prohibits opening and reading dynamic libraries located within user home directories (`/Users/...`) because user directories lack world-traversal and read permissions (`mode 0700` or `0750`). Attempting to `dlopen()` a dylib directly from `/Users/...` fails with `dlopen() failed: file not found / operation not permitted`.

To ensure reliable dynamic loading:
1. **Automated Dylib Staging:**
   Before acquiring task ports or allocating remote pages, `hypr-inject` invokes `stage_dylib_for_windowserver(src_path, dst_path)`:
   - Ensures the destination directory `/Library/GPUBundles` exists with permissions `0755`.
   - Copies the compiled dylib to `/Library/GPUBundles/libhyprserver.dylib`.
   - Enforces mode `0644` (`-rw-r--r--`) so that `_windowserver` (UID 88) can read and map the file.
   - If the source and destination files share the same device and inode, permissions are refreshed to `0644` without re-copying.
2. **Path Slot Population:**
   The staged path `/Library/GPUBundles/libhyprserver.dylib` is written directly into the code page at offset `0x110`.
3. **Clean Uninstallation:**
   During `hypr-inject --uninstall`, the staged dylib `/Library/GPUBundles/libhyprserver.dylib` is removed via `remove()`.

### 1.4 Multi-Monitor Display Synchronization
Apple Silicon systems frequently operate with heterogeneous displays: built-in Liquid Retina XDR displays featuring ProMotion (variable refresh rate scaling dynamically up to 120Hz, ~8.33ms nominal interval) paired with one or more external monitors operating at fixed refresh rates (e.g., 60Hz at ~16.67ms or 144Hz at ~6.94ms). In-situ window decoration adjustments (and future planned in-situ border rendering) cannot assume a single global tick or vsync interval.

In `WindowServer`, each active display (`CGDirectDisplayID`) manages an independent hardware vblank clock domain driven by its own `CADisplay` / `CVDisplayLink` thread. When an application window is modified (e.g., corner radius zeroed, border parameters updated on focus change), the hook avoids blocking synchronization against an arbitrary display's vblank. Instead, window mutations update the window's backing `CGSWindow` / `WSWindow` properties under `os_unfair_lock`, allowing the specific display engine servicing that window's visible bounds to composite the updated frame on its next immediate vblank tick. (Note: In-situ border rendering is NOT YET IMPLEMENTED; border attributes are tracked in server state, while active rendering remains delegated to client-side `BorderWindow` overlays).

When a managed window spans or transitions between monitors with differing refresh rates and Retina scaling factors (e.g., @2x ProMotion display to @1x 60Hz external display), `WindowServer` splits compositor rasterization across displays. By operating directly on the compositor's underlying window geometry and clipping masks in-situ rather than running an out-of-process client overlay window (which suffers from multi-display synchronization lag and coordinate drift), the decoration state remains coherent across both display regions without tearing, stutter, or coordinate judder.

For detailed display topology management, display bounds tracking, and reconfiguration callback integration, see Section 2.9.

---

## IPC & Sequence Flow

### 2.1 Mach Injection Sequence Flow

```mermaid
sequenceDiagram
    autonumber
    participant Injector as hypr-inject (Root / UID 0)
    participant WS as WindowServer (UID 88 / ARM64e)
    participant Kernel as Darwin Kernel / Mach Subsystem
    participant SHM as Shared Memory (/tmp/hyprmac-ipc.shm)

    Injector->>Injector: Pre-flight checks (root, SIP, -arm64e_preview_abi, safemode)
    Injector->>Injector: stage_dylib_for_windowserver() -> /Library/GPUBundles/libhyprserver.dylib (0644)
    Injector->>Kernel: task_for_pid(mach_task_self(), ws_pid, &task)
    Kernel-->>Injector: task port
    Injector->>Injector: dlsym(pcfmt, dlopen, dlerror) + ptrauth_strip()
    Injector->>Kernel: task_info(TASK_DYLD_INFO) + mach_vm_read(dyld_all_image_infos)
    Injector->>Injector: Compute ASLR slide delta = remote_slide - local_slide
    Injector->>Kernel: mach_vm_allocate(task, &remote_stack, 16KB, RW)
    Injector->>Kernel: mach_vm_allocate(task, &remote_diag, 4KB, RW)
    Injector->>Kernel: mach_vm_allocate + mach_vm_write(task, &remote_code, 4KB, RX)<br/>(Stage 1 + data slots + Stage 2 + dylib path)
    Injector->>Injector: Configure thread_state (PC=remote_code, SP=remote_stack+8KB)
    Injector->>Injector: Sign PC with ptrauth_sign_unauthenticated(remote_code, asia)
    Injector->>Kernel: thread_create(task, &thread)
    Injector->>Kernel: _thread_convert_thread_state(thread, 2, ARM_THREAD_STATE64, ...)
    alt macOS >= 14.4 / macOS 27
        Injector->>Kernel: thread_terminate(thread)
        Injector->>Kernel: thread_create_running(task, ARM_THREAD_STATE64, &machine_state, &thread)
    else macOS < 14.4
        Injector->>Kernel: thread_set_state(thread, ARM_THREAD_STATE64, &machine_state)
        Injector->>Kernel: thread_resume(thread)
    end
    WS->>WS: Stage 1 (Mach thread): pthread_create_from_mach_thread(&t, NULL, stage2, NULL)
    WS->>WS: Stage 1: Save return code to x20, pthread_t to x21
    WS->>WS: Stage 1: Write marker 0x79616265 to x0 -> spin loop (adr x9, #0; br x9)
    WS->>WS: Stage 2 (POSIX thread with TLS): Write 0xDEAD0001, 0xDEAD0002 to diag page
    WS->>WS: Stage 2: dlopen("/Library/GPUBundles/libhyprserver.dylib", RTLD_LAZY)
    WS->>WS: Stage 2: Record dlopen handle (or call dlerror + copy message to diag + 0x20)
    WS->>WS: Stage 2: Write 0xDEAD0003 to diag page -> return via ret (0xC0035FD6)
    WS->>WS: libhyprserver constructor (__attribute__((constructor)))
    WS->>WS: Spawn deferred_init worker pthread via pthread_create
    WS->>WS: deferred_init: 500ms stabilization delay
    WS->>WS: dispatch_async(dispatch_get_main_queue()): Register SkyLight callbacks
    WS->>SHM: mmap /tmp/hyprmac-ipc.shm (64KB, mode 0666, MAP_SHARED)
    WS->>SHM: Initialize HyprShmHeader (magic=0x48534D49, hook_pid, atomic store hook_ready=1)
    WS->>WS: Write readiness marker -> /tmp/hyprserver.ready
    WS->>WS: Enter shm_poll_loop (500us usleep loop on Command Ring)
    loop Poll Stage 1 Marker (up to 200ms)
        Injector->>Kernel: thread_get_state(thread) -> check x0 == 0x79616265, inspect x20
    end
    loop Poll Readiness Marker (up to 10s)
        Injector->>Injector: access("/tmp/hyprserver.ready", F_OK)
    end
    Injector->>Kernel: thread_terminate(thread) [terminate spinning Stage 1 thread]
    Injector->>Injector: Sleep 500ms; verify WindowServer PID unchanged (watchdog)
```

### 2.2 IPC Server Model: Shared Memory Ring Buffer Architecture

#### Motivation: WindowServer Sandbox Blocks Socket Operations
`WindowServer` executes as UID 88 (`_windowserver`) under a restricted system sandbox profile. On macOS 14+ Sonoma and macOS 27 Golden Gate, the sandbox **strictly blocks ALL socket operations**:
- `bind()` and `listen()` on Unix Domain Sockets (`AF_UNIX`) fail with `EPERM` / sandbox denial.
- Outbound `connect()` to client sockets fails with `EPERM`.
- Mach service registration via `bootstrap_check_in()` fails with `kr=1100` (`BOOTSTRAP_NOT_PRIVILEGED`).

Because sockets are structurally inoperable from within WindowServer, `windowserver-insitu-composition` uses a **file-backed shared memory ring buffer** at `/tmp/hyprmac-ipc.shm` (`MAP_SHARED`, mode `0666`). `/tmp` is world-writable (`1777`), enabling both `WindowServer` (UID 88) and user-space client processes (UID 501) to open, truncate, and map the shared memory region without requiring elevated privileges.

#### Shared Memory Memory Layout
The shared memory file is sized to exactly 64KB (`HYPR_SHM_SIZE = 65536` bytes), partitioned into a fixed header followed by two unidirectional, non-overlapping ring buffers:

```
/tmp/hyprmac-ipc.shm (64KB)
┌────────────────────────────────────┐
│ Header (256 bytes) — HyprShmHeader │
├────────────────────────────────────┤
│ Command Ring (28KB) Swift → Hook   │
├────────────────────────────────────┤
│ Response Ring (28KB) Hook → Swift  │
└────────────────────────────────────┘
```

- **Header Offset `0x0000` (256 bytes):** Contains `HyprShmHeader`, storing protocol magic, versioning, daemon PID, readiness status, and atomic read/write position pointers.
- **Command Ring Offset `0x0100` (28KB = 28672 bytes):** Dedicated ring buffer for commands sent from the Swift client (`HyprServerBridge`) to the resident compositor hook (`libhyprserver.dylib`).
- **Response Ring Offset `0x7100` (28KB = 28672 bytes):** Dedicated ring buffer for responses and acknowledgments sent from the hook to the Swift client.
- **Reserved Tail (7.75KB = 7936 bytes):** Alignment pad reserving expansion space for future event streaming rings.

#### Header Structure (`HyprShmHeader`)
The 256-byte header is defined in `native/shared/protocol.h`:

```c
typedef struct __attribute__((packed)) {
    uint32_t magic;             // HYPR_SHM_MAGIC (0x48534D49, "HSMI")
    uint32_t version;           // HYPR_SHM_VERSION (1)
    uint32_t hook_pid;          // PID of WindowServer (written by hook)
    uint32_t hook_ready;        // 1 when hook has mapped and is polling

    // Command ring: Swift writes, Hook reads
    uint32_t cmd_write_pos;     // Written by Swift (byte offset within cmd ring)
    uint32_t cmd_read_pos;      // Written by Hook (byte offset within cmd ring)

    // Response ring: Hook writes, Swift reads
    uint32_t rsp_write_pos;     // Written by Hook (byte offset within rsp ring)
    uint32_t rsp_read_pos;      // Written by Swift (byte offset within rsp ring)

    uint8_t  _reserved[224];    // Pad to 256 bytes
} HyprShmHeader;
```

#### Lock-Free SPSC Ring Buffer Protocol
Communication over both rings follows a lock-free Single-Producer Single-Consumer (SPSC) protocol with explicit memory barriers:
1. **Atomic Store & Load Ordering:**
   - **Producer (Writer):** Writes message data into the ring buffer, then updates `write_pos` using `__atomic_store_n(write_pos, next_pos, __ATOMIC_RELEASE)` (or `OSMemoryBarrier()` in Swift). This guarantees the consumer does not observe the advanced write position before payload bytes are fully committed to memory.
   - **Consumer (Reader):** Loads `write_pos` using `__atomic_load_n(write_pos, __ATOMIC_ACQUIRE)` (or `OSMemoryBarrier()`). Once the message is consumed, the consumer advances `read_pos` with `__atomic_store_n(read_pos, next_pos, __ATOMIC_RELEASE)`.
2. **Message Framing:**
   Every message written into a ring buffer begins with a 4-byte length prefix followed by the standard 20-byte `HyprMessageHeader` and optional payload bytes:
   ```
   [uint32_t msg_len (4 bytes)] [HyprMessageHeader (20 bytes)] [Payload (msg_len - 20 bytes)]
   ```
3. **Ring Wrap-Around & Skip Marker Protocol:**
   Messages are **never fragmented or split across the ring buffer boundary**. This eliminates complex reassembly logic:
   - When the remaining space between the current `write_pos` and the end of the ring (`ring_size`) is insufficient to hold the complete message (`sizeof(uint32_t) + msg_len`):
     - The producer writes a 4-byte zero skip marker (`msg_len = 0` / `magic = 0`) at the current `write_pos`.
     - The producer wraps its write target to offset `0` of the ring buffer and writes the message there (verifying space exists before `read_pos`).
     - The producer publishes the new `write_pos` via atomic release.
   - When the consumer reads `msg_len == 0` at its current `read_pos`, it recognizes the skip marker, wraps `read_pos` to offset `0`, and consumes the message starting at offset `0`.

#### Worker Polling Loop (`shm_poll_loop`)
The resident hook processes incoming commands on a dedicated POSIX worker pthread spawned during library initialization:
1. **Command Processing:**
   - Inside `shm_poll_loop()`, the worker continuously calls `shm_ring_read()` on the Command Ring.
   - For each message, validates `HyprMessageHeader.magic == HYPR_MAGIC` (`0x48595052`) and `version == HYPR_PROTO_VERSION`.
   - Dispatches the command via `dispatch_command()` to execute window mutations under `os_unfair_lock(&g_state_lock)`.
   - Transmits acknowledgments or error responses back through `shm_send_response()`, which invokes `shm_ring_write()` on the Response Ring.
2. **500μs Polling Sleep (<0.5% Idle CPU):**
   - If commands are processed, the loop immediately checks for additional messages without sleeping.
   - When the Command Ring is empty (`cmd_read_pos == cmd_write_pos`), the worker thread executes `usleep(500)` (a 500-microsecond pause).
   - Profiling confirms this 500μs sleep consumes **less than 0.5% CPU** when idle, while providing sub-millisecond responsiveness for interactive window operations.
3. **Debounce Timer Integration:**
   - The worker initializes a `kqueue` instance (`g_kq`) to service display and space transition debounce timers.
   - On each poll iteration, it checks `kevent(kq, NULL, 0, events, 16, &ts)` with a zero-timeout (`struct timespec ts = {0, 0}`).
   - Handles `HYPR_TIMER_SPACE_DEBOUNCE` and `HYPR_TIMER_DISPLAY_DEBOUNCE` asynchronously without blocking ring buffer I/O.

#### Deferred Initialization Lifecycle in `deferred_init`
1. **Stabilization Delay:** Thread enters `deferred_init`, executing `usleep(500000)` (500ms delay) to ensure Stage 2 exits cleanly and WindowServer's internal runloop settles.
2. **Safe-Mode Assertion:** Verifies `/tmp/hyprmac.safemode` is absent.
3. **Symbol Discovery & Interposition:** Invokes `resolve_symbols_and_probe()` to resolve SkyLight symbols and `install_interposition()` to intercept `SLSNewWindow`.
4. **SkyLight Main-Thread Dispatch:**
   SkyLight APIs (`SLSRegisterNotifyProc`, `SLSRegisterConnectionNotifyProc`, `SLSGetActiveDisplayList`) assert main-thread execution (`pthread_main_np() != 0`). Invoking them on a background pthread triggers fatal assertions inside WindowServer. Therefore, `deferred_init` dispatches all SkyLight notification registrations asynchronously to the main runloop:
   ```c
   dispatch_async(dispatch_get_main_queue(), ^{
       register_display_callbacks();
       register_space_callbacks();
   });
   ```
5. **Shared Memory Mapping:**
   - Opens `/tmp/hyprmac-ipc.shm` with `O_RDWR | O_CREAT`, mode `0666`.
   - Truncates the file to 64KB (`HYPR_SHM_SIZE`).
   - Maps the region with `mmap(NULL, HYPR_SHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0)`.
   - Initializes `HyprShmHeader`, writes `hook_pid = getpid()`, and performs an atomic store setting `hook_ready = 1`.
6. **Readiness Marker Creation:**
   Writes `/tmp/hyprserver.ready` (`HYPR_READY_PATH`), notifying the injector that initialization is complete.
7. **Polling Loop Entry:**
   Enters `shm_poll_loop(base)` to service commands permanently.

### 2.3 Runtime Window Modification Flow

```mermaid
sequenceDiagram
    autonumber
    participant Client as HyprMac Swift Client / Bridge
    participant SHM as /tmp/hyprmac-ipc.shm (Command/Response Rings)
    participant Server as libhyprserver (shm_poll_loop)
    participant WS as WindowServer Compositor Memory

    Client->>SHM: Write HyprMessageHeader (CMD_AUTH, seq=1, size=16) + HyprPayloadAuth to Command Ring
    Client->>SHM: Atomic store cmd_write_pos (RELEASE)
    Server->>SHM: shm_ring_read (ACQUIRE) -> dispatch_command()
    Server->>Server: Validate token matches g_auth_token
    Server->>SHM: Write HyprMessageHeader (CMD_ACK, seq=1, size=68) + HyprPayloadAck ("Authenticated") to Response Ring
    Server->>SHM: Atomic store rsp_write_pos (RELEASE)
    Client->>SHM: shm_ring_read (ACQUIRE) -> Receive ACK
    Client->>SHM: Write HyprMessageHeader (CMD_SET_CORNER_RADIUS, wid=0x2A, seq=2, size=4) + HyprPayloadCornerRadius to Command Ring
    Client->>SHM: Atomic store cmd_write_pos (RELEASE)
    Server->>SHM: shm_ring_read (ACQUIRE) -> dispatch_command()
    Server->>Server: Validate HYPR_MAGIC & HYPR_PROTO_VERSION
    Server->>Server: Validate window_id in managed registry
    Server->>WS: Acquire os_unfair_lock (&g_state_lock)
    Server->>WS: Apply SLS / WSWindow corner clipping mask = 0.0f
    Server->>WS: Release os_unfair_lock (&g_state_lock)
    Server->>WS: Invalidate surface cache (SLSFlushSurface / CATransaction.flush)
    Server->>SHM: Write HyprMessageHeader (CMD_ACK, seq=2, size=68) + HyprPayloadAck (status=0x0000, message="OK") to Response Ring
    Server->>SHM: Atomic store rsp_write_pos (RELEASE)
    Client->>SHM: shm_ring_read (ACQUIRE) -> Receive ACK response
```

### 2.4 Compositor Surface Cache Invalidation Strategy
In macOS's compositor architecture, window contents and decorations are cached across GPU surfaces managed by QuartzCore (`CAWindowServer`) and SkyLight. Mutating internal window flags or zeroing clipping masks (`WSWindow` corner mask) in memory does not automatically cause the GPU compositor to invalidate its cached raster tiles. Without explicit surface invalidation, visual changes may not render until the client application next posts a new frame buffer or triggers a window move.

To force immediate compositor re-rasterization upon IPC command execution:
1. **Primary Invalidation:** Invoke `SLSFlushSurface()` or `SLSReassociateWindowsWithSpaces()` using the hook's in-process server-level connection (`SLSMainConnectionID()`), marking the window's composited layer hierarchy as dirty.
2. **Transaction Flush:** Commit an explicit CoreAnimation transaction via `CATransaction.flush()` / `CA::Transaction::commit()` within the compositor context to ensure the modified layer properties are immediately submitted to Metal render passes.
3. **Forced Redraw Fallback:** If direct surface flush symbols are non-exported or unresolved on a given OS build, trigger forced invalidation via `SLSMoveWindow()` with a zero coordinate delta `(dx=0, dy=0)`. This forces `WindowServer`'s damage tracking system to recalculate visible window regions and issue a full repaint on the subsequent display frame.

Surface invalidation must occur immediately after releasing the `os_unfair_lock` that protects window attribute mutation. Holding synchronization locks during GPU surface flushes or IPC callbacks would stall WindowServer's render thread, introducing dropped frames (jank).

### 2.5 Window Lifecycle Event Detection, Interposition & Global Decoration Policy
Imperative commands (`HYPR_CMD_SET_CORNER_RADIUS`, `HYPR_CMD_SET_SHADOW_STATE`) require external knowledge of window IDs and operate after a window is already visible. To eliminate the "flash of native decoration" on newly created windows:
- **In-Process Interposition:** The hook installs an in-process interposition on `SLSNewWindow` / `CGSNewWindow` via Mach-O symbol rebinding (see Section 2.8) to intercept window creation events at the source.
- **Pre-Composite Decoration Policy via `HYPR_CMD_SET_GLOBAL_POLICY`:**
  To configure the default decoration applied by `SLSNewWindow` interposition, the protocol defines `HYPR_CMD_SET_GLOBAL_POLICY (0x0015)` with payload `HyprPayloadGlobalPolicy` (16 bytes packed). When an application creates a window, the hook applies this policy synchronously before the window's first frame is submitted to the compositor, ensuring zero visual flicker or Aqua frame flash.
- **Window Destruction Eviction:** When an application closes or unmaps a window, `WindowServer` destroys the underlying `CGSWindow` structure. The hook maintains an in-memory hash map of active managed window IDs. Commands targeting closed or destroyed windows return `HYPR_ERR_INVALID_WID` (`0x0001`) immediately without dereferencing invalid pointers.

### 2.6 Focus State Synchronization
Window border rendering distinguishes between active (focused) and inactive windows using the dual-color parameters in `HyprPayloadBorder` (`color_active` and `color_inactive`).

- **Command:** `HYPR_CMD_SET_WINDOW_FOCUS (0x0014)` with a 4-byte payload `HyprPayloadFocus` containing `{ uint32_t window_id; }` (packed, 4 bytes). The target window ID can also be specified directly in `HyprMessageHeader.window_id`.
  > **Known Gap:** `HyprPayloadFocus` is currently defined locally in `native/server_hook/hook.c` (lines 68-71) as a packed struct `{ uint32_t window_id; }`, but is missing from the shared protocol header `native/shared/protocol.h`. This is a known gap that needs resolution (consolidating `HyprPayloadFocus` into `protocol.h`).
- **Event Source:** The Swift client bridge (`HyprServerBridge`) monitors `NSWorkspace` focus change notifications (`NSWorkspace.didActivateApplicationNotification`, `NSWorkspace.activeSpaceDidChangeNotification`, and window focus change events via accessibility observers) and is intended to send `HYPR_CMD_SET_WINDOW_FOCUS` whenever the focused window changes.
  > **Note:** `HyprServerBridge.swift` currently lacks `HYPR_CMD_SET_WINDOW_FOCUS` (`0x0014`) in its `HyprCommand` enum; this must be added to enable end-to-end focus synchronization over the socket.
- **Hook Handling:** On receiving `HYPR_CMD_SET_WINDOW_FOCUS`:
  1. Validates compositor availability and resolves private SkyLight focus management symbols (`SLSSetWindowFocused` / `CGSSetWindowFocused` and connection authority via `MainConnectionID`).
  2. Acquires `g_state_lock` (`os_unfair_lock`) to update focus state in the managed window registry (`g_managed_windows`), marking `is_focused = (wid == target_wid)`.
  3. Releases `g_state_lock` and triggers surface invalidation via `invalidate_window(cid, target_wid)`.
  4. The hook updates the focus state and border parameters in `g_managed_windows` and invalidates the window surface via `invalidate_window(cid, target_wid)`. **Note:** In-situ border rendering is **NOT YET IMPLEMENTED** in the compositor hook; the hook does not invoke any compositor rendering routine. Visible active/inactive border changes currently rely on the client-side `BorderWindow` overlay.
  5. Returns `send_ack(..., HYPR_ERR_SUCCESS, "OK")`.

### 2.7 Wire Authentication Handshake
The shared memory file at `/tmp/hyprmac-ipc.shm` is created with mode `0666` so unprivileged user processes (UID 501) can map and write commands to `WindowServer` (UID 88). To prevent unauthorized local processes from manipulating the window hierarchy, the system implements cryptographic authentication over the shared memory transport:

- **Token Generation:** During `deferred_init()`, the hook invokes `init_auth_token()`:
  - Generates a 16-byte cryptographically secure random token using `arc4random_buf(g_auth_token, sizeof(g_auth_token))`.
  - Unlinks any stale token file and writes the token to `/tmp/hyprmac-auth-token` with restricted permissions (mode `0600`, owned by `_windowserver` / UID 88).
- **Client Handshake:** Upon mapping the shared memory file, the authorized client reads the 16-byte token from `/tmp/hyprmac-auth-token` and immediately transmits `HYPR_CMD_AUTH (0x0030)` carrying `HyprPayloadAuth` (`uint8_t token[16]`) over the Command Ring.
- **Enforcement:**
  - When the hook receives `HYPR_CMD_AUTH`, it verifies that the supplied token matches `g_auth_token`.
  - On match, the connection state is marked authenticated, and the server emits `HYPR_CMD_ACK` with `HYPR_ERR_SUCCESS` ("Authenticated") into the Response Ring.
  - If the token mismatches or if a client transmits window modification commands before authenticating, the server rejects the request with `HYPR_ERR_UNAUTHORIZED` and ignores subsequent commands until authenticated.

### 2.8 Dynamic Image Rebinding Engine
Imperative IPC commands apply window modifications after a window is created and mapped. However, native macOS applications briefly flash default Aqua decorations (rounded corners, standard drop shadows, default titlebars) during the initial compositor frame before client IPC commands can be processed. To achieve true zero-frame flicker, `libhyprserver.dylib` implements an in-process dynamic image rebinding engine that intercepts window creation at the compositor level.

1. **Interposition Setup (`install_interposition`):**
   - Resolves the real `SLSNewWindow` (or `CGSNewWindow`) symbol via `safe_resolve_symbol()`.
   - Attempts modern dynamic interposition via `dyld_dynamic_interpose` if exposed by the dynamic linker.
   - Enumerates all currently loaded Mach-O images in `WindowServer` using `_dyld_image_count()`, `_dyld_get_image_header()`, and `_dyld_get_image_vmaddr_slide()`.
   - Registers `on_dyld_image_added` via `_dyld_register_func_for_add_image()` so newly loaded frameworks or bundles are automatically processed.
2. **Mach-O Header & Symbol Table Traversal (`rebind_image_symbols`):**
   - Inspects 64-bit Mach-O headers (`mach_header_64`, `MH_MAGIC_64`).
   - Iterates load commands (`LC_SEGMENT_64`, `LC_SYMTAB`, `LC_DYSYMTAB`) to resolve `__LINKEDIT` segment base addresses, symbol tables (`nlist_64`), string tables, and indirect symbol tables (`dysymtab_cmd->indirectsymoff`).
   - Identifies symbol pointer sections within `__DATA`, `__DATA_CONST`, and `__AUTH_CONST` segments matching `S_LAZY_SYMBOL_POINTERS`, `S_NON_LAZY_SYMBOL_POINTERS`, `__got`, and `__auth_got`.
3. **Section Rebinding & PAC Signing (`rebind_section`):**
   - For each indirect symbol index matching `_SLSNewWindow` or `_CGSNewWindow`, locates the indirect symbol pointer binding.
   - Applies `vm_protect(mach_task_self(), addr, sizeof(void *), FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)` to make the symbol pointer writable.
   - On ARM64e architectures with Pointer Authentication (`__has_feature(ptrauth_calls)`):
     - Strips any existing pointer signature from `my_SLSNewWindow` via `ptrauth_strip(..., ptrauth_key_function_pointer)`.
     - Re-signs the target pointer using `ptrauth_sign_unauthenticated(raw_target, ptrauth_key_asia, (uintptr_t)&indirect_symbol_bindings[i])` to satisfy hardware PAC validation upon indirect branch invocation.
   - On standard architectures, writes `(void *)my_SLSNewWindow` directly into the binding slot.
4. **Window Creation Interception (`my_SLSNewWindow`):**
   - When any application or internal SkyLight component calls `SLSNewWindow(cid, type, x, y, shape, &outWid)`:
     - Delegates to the original function pointer (`g_orig_SLSNewWindow`).
     - On successful creation (`err == 0` and `*outWid != 0`), immediately calls `apply_global_policy_to_window(cid, *outWid)`.
     - `apply_global_policy_to_window()` checks `g_global_policy` under `g_state_lock`. If configured, it zeroes corner radii, strips shadows, strips titlebars, and configures borders synchronously before the window's backing surface is composited into the render pipeline.
     - Guarantees zero-frame flicker for all newly spawned application windows.

### 2.9 Display Topology Management
Heterogeneous multi-monitor configurations (combining high-refresh ProMotion displays with external 60Hz/144Hz monitors) require dynamic display awareness to track window geometry, bounds, and refresh domains:

1. **Topology State (`HyprDisplayInfo` & `g_displays`):**
   The hook maintains an internal display topology table bounded by `HYPR_MAX_DISPLAYS` (8 displays):
   ```c
   typedef struct {
       CGDirectDisplayID display_id;
       CGRect            bounds;
       double            refresh_rate;
       bool              active;
       bool              is_promotion;
   } HyprDisplayInfo;

   static HyprDisplayInfo g_displays[HYPR_MAX_DISPLAYS];
   static size_t g_display_count = 0;
   ```
2. **Topology Discovery (`update_display_topology`):**
   - Safe-mode aware: halts execution immediately if `is_safe_mode_active()` is asserted.
   - Invokes `CGGetActiveDisplayList()` (with fallback to `CGMainDisplayID()`) to enumerate active `CGDirectDisplayID` identifiers.
   - Under `os_unfair_lock(&g_state_lock)`:
     - Clears previous topology entries and records display bounds via `CGDisplayBounds(did)`.
     - Queries display modes via `CGDisplayCopyDisplayMode(did)` and extracts nominal refresh rates via `CGDisplayModeGetRefreshRate(mode)`.
     - Flags displays with refresh rates ≥ 119.0 Hz as `is_promotion = true`.
     - Releases display modes via `CGDisplayModeRelease(mode)`.
3. **Reconfiguration Callback Integration & Main-Thread Dispatch:**
   - **SkyLight Main-Thread Dispatch Requirement:** Inside `WindowServer`, SkyLight registration routines (`SLSRegisterNotifyProc`, `SLSRegisterConnectionNotifyProc`, `SLSGetActiveDisplayList`) assert main-thread execution (`pthread_main_np() != 0`). Invoking them from a background pthread triggers fatal assertion failures. Therefore, all notification registrations (`register_display_callbacks()` and `register_space_callbacks()`) are dispatched to the main runloop via `dispatch_async(dispatch_get_main_queue(), ...)`.
   - **Display Callback Registration:** In `register_display_callbacks()`, the hook registers `on_display_reconfiguration` via `CGDisplayRegisterReconfigurationCallback()` (with fallback to SkyLight's `RegisterConnectionNotifyProc` event 100 for screen resolution changes).
   - **Notification Filtering:** `on_display_reconfiguration()` receives notification flags (`kCGDisplayBeginConfigurationFlag`, `kCGDisplayAddFlag`, `kCGDisplayRemoveFlag`, `kCGDisplayMovedFlag`, `kCGDisplaySetModeFlag`). It ignores begin-configuration notifications (`kCGDisplayBeginConfigurationFlag`) to avoid intermediate display hardware instability.
   - **Debounce Timer:** For completion flags, arms a 150ms debounce timer via kqueue (`EVFILT_TIMER` with `HYPR_TIMER_DISPLAY_DEBOUNCE`).
   - **Space Notification Note:** Because `SLSRegisterNotifyProc` triggers an internal assertion inside WindowServer even on the main thread, space transition events are handled via `RegisterConnectionNotifyProc` (event 1401) and Darwin Notification Center (`com.apple.spaces.currentspacechanged`).
4. **Topology Settlement & Window Re-association (`handle_display_reconfiguration_settled`):**
   - When the 150ms debounce timer fires, the hook invokes `handle_display_reconfiguration_settled()`.
   - Updates `g_displays[]` via `update_display_topology()`.
   - Iterates all managed windows:
     - Validates window liveness using `is_window_alive(cid, wid)` (calling `SLSGetWindowBounds()`); if a window was destroyed during monitor disconnect, it is cleanly evicted from `g_managed_windows` (`managed_window_evict`).
     - Maps each window's bounds to its primary intersecting display via `find_display_for_bounds()`.
     - Re-applies decoration attributes (`reapply_decorations_to_window`), ensuring corner clipping masks, shadow state, and titlebar configurations seamlessly adjust across monitor shifts and resolution changes without visual artifacts. (Border parameters in `g_managed_windows` are preserved, though in-situ border rendering remains unimplemented).

---

## Memory Layout & Struct Alignment

### 3.1 Wire Protocol Headers (C11)

All protocol structures are strictly aligned to 1-byte boundaries using `#pragma pack(push, 1)` and `__attribute__((packed))`.

```c
#ifndef HYPR_PROTOCOL_H
#define HYPR_PROTOCOL_H

#include <stdint.h>

#define HYPR_MAGIC 0x48595052  // "HYPR" in ASCII
#define HYPR_PROTO_VERSION 1

// Shared memory IPC configuration (replaces socket transport)
#define HYPR_SHM_PATH "/tmp/hyprmac-ipc.shm"
#define HYPR_SHM_SIZE (64 * 1024)  // 64KB total

// Ring buffer sizes
#define HYPR_CMD_RING_SIZE  (28 * 1024)  // 28KB: Swift -> Hook commands
#define HYPR_RSP_RING_SIZE  (28 * 1024)  // 28KB: Hook -> Swift responses

// Shared memory layout offsets
#define HYPR_SHM_HEADER_OFF   0
#define HYPR_SHM_HEADER_SIZE  256
#define HYPR_SHM_CMD_RING_OFF HYPR_SHM_HEADER_SIZE
#define HYPR_SHM_RSP_RING_OFF (HYPR_SHM_CMD_RING_OFF + HYPR_CMD_RING_SIZE)

// Magic and version for shared memory header
#define HYPR_SHM_MAGIC 0x48534D49  // "HSMI" (HyprSharedMemoryIPC)
#define HYPR_SHM_VERSION 1

// Readiness marker written by the hook after deferred_init completes
#define HYPR_READY_PATH "/tmp/hyprserver.ready"

// Deprecated socket path (retained for legacy reference)
#define HYPR_SOCKET_PATH "/tmp/hyprmac-server.sock"

// Safe-mode tombstone
#define HYPR_SAFEMODE_PATH "/tmp/hyprmac.safemode"

// Log path for handshake
#define HYPR_LOG_PATH "/tmp/hyprserver.log"
#define HYPR_LOG_PATH_ROTATED "/tmp/hyprserver.log.1"
#define HYPR_LOG_MAX_SIZE (1024 * 1024)  // 1MB rotation threshold
#define HYPR_MAX_PAYLOAD_SIZE 65536      // Maximum incoming payload size (64KB)

// Bootstrap service name (obsoleted under WindowServer sandbox)
#define HYPR_BOOTSTRAP_NAME "com.hyprmac.server.hook"

typedef uint16_t HyprCommand;
enum {
    HYPR_CMD_PING               = 0x0001,
    HYPR_CMD_PONG               = 0x0002,
    HYPR_CMD_ACK                = 0x0003,
    HYPR_CMD_ERROR              = 0x0004,

    // Window Operations
    HYPR_CMD_SET_CORNER_RADIUS  = 0x0010,
    HYPR_CMD_SET_SHADOW_STATE   = 0x0011,
    HYPR_CMD_SET_WINDOW_BORDER  = 0x0012,
    HYPR_CMD_STRIP_TITLEBAR     = 0x0013,
    HYPR_CMD_SET_WINDOW_FOCUS   = 0x0014,
    HYPR_CMD_SET_GLOBAL_POLICY  = 0x0015,
    HYPR_CMD_QUERY_WINDOW       = 0x0020,

    // Authentication
    HYPR_CMD_AUTH               = 0x0030
};

// Error codes
#define HYPR_ERR_SUCCESS              0x0000
#define HYPR_ERR_INVALID_WID          0x0001
#define HYPR_ERR_INVALID_CMD          0x0002
#define HYPR_ERR_UNAUTHORIZED         0x0003
#define HYPR_ERR_HOOK_UNAVAIL         0x0006
#define HYPR_ERR_INTERNAL             0x00FF

// Error codes [PLANNED: extended taxonomy]
#define HYPR_ERR_PAYLOAD_TOO_LARGE    0x0004
#define HYPR_ERR_INVALID_WID_PLANNED  0x0005
#define HYPR_ERR_RATE_LIMITED         0x0007
#define HYPR_ERR_INTERNAL_PLANNED     0x0008
#define HYPR_ERR_NOT_IMPL             0x0009

#pragma pack(push, 1)

typedef struct {
    uint32_t magic;          // HYPR_MAGIC
    uint16_t version;        // HYPR_PROTO_VERSION
    uint16_t command_id;     // HyprCommand
    uint32_t sequence;       // Client-generated sequence number
    uint32_t window_id;      // Target CGWindowID (0 for non-window commands)
    uint32_t payload_size;   // Byte length of trailing payload
} HyprMessageHeader;

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

// KNOWN GAP: HyprPayloadFocus is defined locally in native/server_hook/hook.c (lines 68-71),
// not in the shared protocol header (protocol.h). This needs resolution.
typedef struct __attribute__((packed)) {
    uint32_t window_id;
} HyprPayloadFocus;  // 4 bytes (defined locally in hook.c, missing from protocol.h)

typedef struct __attribute__((packed)) {
    uint8_t  auto_square_corners;   // 1
    uint8_t  auto_strip_shadow;     // 1
    uint8_t  auto_strip_titlebar;   // 1
    uint8_t  auto_set_border;       // 1
    float    border_width;          // 4
    uint32_t border_color_active;   // 4
    uint32_t border_color_inactive; // 4
} HyprPayloadGlobalPolicy;          // 16 bytes

typedef struct __attribute__((packed)) {
    uint8_t token[16];
} HyprPayloadAuth;

// Query Window Request Payload
typedef struct {
    // Empty — window_id is in HyprMessageHeader
} HyprPayloadQueryRequest;

// Query Window Response Payload
typedef struct {
    float    corner_radius;
    uint8_t  shadow_enabled;
    uint8_t  titlebar_stripped;
    uint32_t border_color;     // Current active ARGB
    float    border_width;
} HyprPayloadQueryResponse;

// Pong Payload (echoes server state)
typedef struct {
    uint32_t server_version;   // (major << 16 | minor << 8 | patch)
    uint32_t active_windows;
} HyprPayloadPong;

// Ack / Error Payload
typedef struct {
    uint32_t status;         // HYPR_ERR_* code
    char     message[64];
} HyprPayloadAck;

#pragma pack(pop)

/* ---- Shared Memory IPC (mmap-based) ---- */

// Shared memory header (256 bytes, at offset 0 of /tmp/hyprmac-ipc.shm)
// All position fields are byte offsets within their respective ring buffers.
// Writers advance write_pos after writing a complete message.
// Readers advance read_pos after consuming a complete message.
// Use __atomic_load_n / __atomic_store_n with __ATOMIC_ACQUIRE / __ATOMIC_RELEASE.
typedef struct __attribute__((packed)) {
    uint32_t magic;             // HYPR_SHM_MAGIC (0x48534D49)
    uint32_t version;           // HYPR_SHM_VERSION (1)
    uint32_t hook_pid;          // PID of WindowServer (written by hook)
    uint32_t hook_ready;        // 1 when hook has mapped and is polling

    // Command ring: Swift writes, Hook reads
    uint32_t cmd_write_pos;     // Written by Swift
    uint32_t cmd_read_pos;      // Written by Hook

    // Response ring: Hook writes, Swift reads
    uint32_t rsp_write_pos;     // Written by Hook
    uint32_t rsp_read_pos;      // Written by Swift

    uint8_t  _reserved[224];    // Pad to 256 bytes
} HyprShmHeader;

#endif // HYPR_PROTOCOL_H
```

### 3.2 Protocol Framing & Response Semantics
- **Sequence Correlation:** All request headers include a client-generated `sequence` number. Response messages set `HyprMessageHeader.command_id` to `HYPR_CMD_ACK` or `HYPR_CMD_ERROR`, matching the client's `sequence` number for unambiguous transaction tracking.
- **Payload Alignment & Validation:** Incoming packets are validated for exact payload sizes (`sizeof(HyprPayloadCornerRadius) == 4`, `sizeof(HyprPayloadShadow) == 1`, `sizeof(HyprPayloadBorder) == 12`, `sizeof(HyprPayloadStripTitlebar) == 1`, `sizeof(HyprPayloadFocus) == 4`, `sizeof(HyprPayloadGlobalPolicy) == 16`, `sizeof(HyprPayloadAuth) == 16`). Mismatched payload sizes are rejected immediately with `send_ack(..., HYPR_ERR_INTERNAL, "Bad payload size")` or `send_ack(..., HYPR_ERR_UNAUTHORIZED, "Unauthorized")`.
  - **Resolved**: `HYPR_MAX_PAYLOAD_SIZE` reduced from 65536 to 4096 bytes. All protocol payloads are well under 100 bytes; 4096 provides >40x headroom while fitting within the 28KB ring buffer. The legacy `CLIENT_READ_BUF_SIZE` define has been removed from `hook.c`. A compile-time assertion in `protocol.h` ensures the max message size never exceeds ring capacity.
- **Query Operations:** `HYPR_CMD_QUERY_WINDOW` passes the target window ID in `HyprMessageHeader.window_id` with an empty payload. The response returns `HYPR_CMD_ACK` with `HyprPayloadQueryResponse` (14 bytes), directly unpackable in `HyprServerBridge.swift`.

#### Swift Client Bridge Integration & Protocol Gaps
`Sources/HyprMac/Bridge/HyprServerBridge.swift` defines Swift representations of the protocol enums and headers. The following divergences exist against `native/shared/protocol.h` and `native/server_hook/hook.c`:
- **Missing `HyprCommand` Cases:**
  - `HYPR_CMD_SET_WINDOW_FOCUS = 0x0014`: Defined in `protocol.h` and handled in `hook.c`, but missing from `HyprCommand` in `HyprServerBridge.swift`.
  - `HYPR_CMD_SET_GLOBAL_POLICY = 0x0015`: Defined in `protocol.h` and handled in `hook.c`, but missing from `HyprCommand` in `HyprServerBridge.swift`.
- **Missing `HyprError` Cases:**
  - `HYPR_ERR_HOOK_UNAVAIL = 0x0006`: Defined in `protocol.h` and emitted by `hook.c` when compositor symbols are unresolved, but missing from `HyprError` in `HyprServerBridge.swift`.

#### In-Situ Border Rendering Status (NOT YET IMPLEMENTED)
While `HYPR_CMD_SET_WINDOW_BORDER (0x0012)` and `HyprPayloadBorder` are defined in the protocol and accepted by `hook.c`, **in-situ border rendering is NOT YET IMPLEMENTED in the compositor hook**:
- Upon receiving `HYPR_CMD_SET_WINDOW_BORDER`, `hook.c` records `border_width`, `color_active`, and `color_inactive` in the managed window struct (`HyprManagedWindow`) and invokes `invalidate_window(cid, wid)`.
- `invalidate_window()` only calls `SLSFlushSurface()` and `SLSMoveWindow()`; it does not invoke any compositor drawing, CALayer border, or Metal rendering routines.
- Client applications (`HyprMac`) must continue to render borders via out-of-process overlay windows (`BorderWindow.swift`) until in-situ compositor border rendering is implemented.

### 3.3 Pointer Authentication (PAC) on ARM64e
WindowServer runs as an ARM64e platform binary with hardware pointer authentication enabled. Injecting into an ARM64e process and performing dynamic execution requires strict adherence to PAC invariants:
1. **Local Address Resolution & PAC Stripping:** The injector resolves `pthread_create_from_mach_thread` and `dlopen` locally via `dlsym(RTLD_DEFAULT, ...)`. Function pointers resolved in the injector process contain PAC signatures authenticated with the injector's keys and cannot be jumped to in WindowServer. The injector strips PAC bits via `ptrauth_strip(addr, ptrauth_key_function_pointer)` before computing slide-corrected virtual addresses.
2. **ASLR Shared Cache Slide Correction:** Local addresses are adjusted by `slide_delta = remote_slide - local_slide` (extracted via `task_info(TASK_DYLD_INFO)` and `dyld_all_image_infos`) before patching into data slots at offsets `0x58` (`pcfmt`), `0xF8` (`dlopen`), `0x100` (`remote_diag`), and `0x108` (`dlerror`) in the remote code page.
3. **In-Situ PAC Signing in Stage 1 & Plain Return in Stage 2 (RC4 Fix):** In Stage 1 assembly, the Stage 2 entry point is signed dynamically using `paciza x2` before being passed to `pthread_create_from_mach_thread`. In Stage 2, `pacibsp` and `retab` are replaced with `nop` (`0x1F2003D5`) at entry (offset `0x60`) and plain `ret` (`0xC0035FD6`) at exit (offset `0xF4`) per the RC4 fix. Because the loader and WindowServer operate in distinct PAC domains with different PAC keys, using `pacibsp` and `retab` across process boundaries would trigger hardware PAC authentication failures upon return.
4. **PAC Domain Conversion (`_thread_convert_thread_state`):** The loader configures initial registers (`PC = remote_code`, signed via `ptrauth_sign_unauthenticated((void *)remote_code, ptrauth_key_asia, 0)`, and `SP = remote_stack + 8192`). It invokes `_thread_convert_thread_state` with direction `2` (`THREAD_CONVERT_THREAD_STATE_FROM_SELF`) so the kernel re-signs the register state in the target process PAC domain.
5. **Hardware Launch:** On macOS ≥ 14.4 (including macOS 27), `thread_create_running` verifies the kernel-re-signed state and loads it directly into hardware registers.

### 3.4 Internal Symbol & Struct Discovery Strategy (Phase 3)
`WSWindow` and `CGSWindow` are private structures whose layouts change across macOS versions. The hook MUST NOT hardcode struct offsets. Instead, Phase 3 employs a multi-strategy discovery approach:
1. **Class-dump / Mach-O introspection:** Use `objc_getClass("CAWindowServer")` and `class_copyIvarList` to discover Objective-C ivar offsets for `CAWindowServerWindow` properties (corner radius, shadow).
2. **Pattern scanning:** For C-struct-only paths, scan the `__DATA` segment of `SkyLight.framework` for known constant patterns adjacent to the target fields.
3. **Hooked accessor functions:** Prefer hooking `SLSSetWindowShape` / `SLSSetWindowShadowProperties` / `CGSSetWindowCornerRadius` (if exported as private symbols) to intercept and override values at the API boundary. This is version-resilient.

### 3.5 Comprehensive Error Taxonomy
The protocol error codes encompass both currently implemented codes (in `protocol.h` and `hook.c`) and planned domain failure modes across client-server interaction:

**Currently Implemented Error Codes:**
- `HYPR_ERR_SUCCESS (0x0000)`: Operation applied cleanly.
- `HYPR_ERR_INVALID_WID (0x0001)`: Specified `window_id` does not exist or has been destroyed.
- `HYPR_ERR_INVALID_CMD (0x0002)`: Unrecognized command ID.
- `HYPR_ERR_UNAUTHORIZED (0x0003)`: Client connection failed shared-secret token authentication or attempted unauthenticated commands.
- `HYPR_ERR_HOOK_UNAVAIL (0x0006)`: Hook subsystem, symbols, or compositor connection unavailable. *(Note: Missing from `HyprError` enum in `HyprServerBridge.swift`).*
- `HYPR_ERR_INTERNAL (0x00FF)`: Internal compositor fault or allocation failure.

**Planned Error Codes [PLANNED]:**
- `HYPR_ERR_PAYLOAD_TOO_LARGE (0x0004)`: [PLANNED] Incoming packet payload exceeds maximum boundary (`HYPR_MAX_PAYLOAD_SIZE` = 65536 bytes / 64KB).
- `HYPR_ERR_INVALID_WID (0x0005)`: [PLANNED] Extended invalid window ID classification.
- `HYPR_ERR_RATE_LIMITED (0x0007)`: [PLANNED] Command mutation rate exceeded safety threshold.
- `HYPR_ERR_INTERNAL (0x0008)`: [PLANNED] Extended internal compositor transaction fault.
- `HYPR_ERR_NOT_IMPL (0x0009)`: [PLANNED] Command recognized but not implemented in current runtime.

---

## Fail-Safe Circuit Breakers

### 4.1 Safe-Mode Circuit Breaker & Crash Watchdog
1. **Safe-Mode Probe:**
   ```c
   if (access("/tmp/hyprmac.safemode", F_OK) == 0) {
       syslog(LOG_WARNING, "[HyprServer] Safe-mode tombstone detected. Aborting hook initialization.");
       return;
   }
   ```
2. **Crash Watchdog in Injector:**
   The injector samples the PID of `WindowServer` before injection and again 500ms after remote thread creation. If the PID has changed, it asserts that a crash occurred, immediately creates `/tmp/hyprmac.safemode`, and outputs a red diagnostic alert without attempting retry loops.

### 4.2 Signal Sandboxing & Fault Recovery
To guarantee that private symbol probing and dynamic state queries cannot crash `WindowServer`, `hook.c` implements signal sandboxing using POSIX signal handling and non-local jumps:

1. **Signal Sandbox Architecture:**
   During initialization in `resolve_symbols_and_probe()`, the hook installs `probe_signal_handler` for `SIGSEGV` and `SIGBUS` via `sigaction()`:
   ```c
   static sigjmp_buf g_probe_jmp;
   static volatile sig_atomic_t g_probe_active = 0;

   static void probe_signal_handler(int sig) {
       if (g_probe_active) {
           siglongjmp(g_probe_jmp, sig);
       }
   }
   ```
2. **Safe Symbol Discovery (`safe_resolve_symbol` / `safe_resolve_variants`):**
   - Sets `g_probe_active = 1`.
   - Executes `dlsym(RTLD_DEFAULT, name)` inside a `sigsetjmp(g_probe_jmp, 1)` block.
   - If a fault occurs during symbol lookup, the signal handler intercepts `SIGSEGV` / `SIGBUS` and invokes `siglongjmp(g_probe_jmp, sig)`.
   - The probe routine logs `Signal caught while resolving '<name>'`, returns `NULL`, and resets `g_probe_active = 0`.
3. **Internal State Validation Probing:**
   - Wraps calls to `probe_internal_state()` and `validate_server_authority()` (which probe `SLSGetWindowCount`, `SLSGetWindowList`, `SLSGetWindowTags`) in the same `sigsetjmp` harness.
   - Recovers execution state without letting exceptions propagate to Mach exception handlers or the kernel.
   - Restores the original signal handlers (`old_segv`, `old_bus`) once symbol discovery completes.

### 4.3 Injection Idempotency (Bootstrap Check-In Obsoleted & SHM State)
To prevent duplicate dynamic library loading and resource collisions:

1. **Obsoletion of Mach Bootstrap Check-In:**
   The initial design attempted to register a Mach service port via `bootstrap_check_in(bootstrap_port, "com.hyprmac.server.hook", &port)`. Under the WindowServer sandbox profile, `bootstrap_check_in()` fails unconditionally with `kr=1100` (`BOOTSTRAP_NOT_PRIVILEGED`). WindowServer processes are strictly forbidden from checking in arbitrary Mach services. Consequently, `bootstrap_check_in` has been removed from `deferred_init()` and marked obsolete.
2. **Shared Memory Idempotency Verification:**
   Idempotency is now enforced directly via the shared memory header (`HyprShmHeader`) and single-instance coordination:
   - When the hook is running, `HyprShmHeader.hook_ready == 1` and `HyprShmHeader.hook_pid == ws_pid`.
   - The injector unlinks `/tmp/hyprserver.ready` before injection and waits for the fresh hook instance to create it.
   - The Swift client driver (`HyprServerBridge`) manages single-instance authority and does not spawn redundant injection tasks if `isHookReady` is already asserted.
   - If WindowServer restarts, launchd assigns a new PID, invalidating any previous SHM header state and triggering automatic re-injection.

### 4.4 Thread Safety & Synchronization Locks
The hook's POSIX listener thread receives IPC commands and mutates compositor-internal structures (`WSWindow`, SkyLight layer properties), while WindowServer's render threads traverse these structures on display refresh cycles.

- **Window State Mutex (`g_state_lock`):** Shared compositor state is protected by `g_state_lock` (`os_unfair_lock`, initialized via `OS_UNFAIR_LOCK_INIT`):
  - Synchronizes access to `g_managed_windows[]` registry (insertion, lookup, eviction, tag updates, corner radius, shadow state, border parameters, and focus states).
  - Protects global decoration policy updates (`HYPR_CMD_SET_GLOBAL_POLICY`).
  - Protects multi-monitor topology structures (`g_displays[]`, `g_display_count`) during display reconfiguration and query handling.
  - Actively used across all window mutation command handlers (`HYPR_CMD_SET_CORNER_RADIUS`, `HYPR_CMD_SET_SHADOW_STATE`, `HYPR_CMD_SET_WINDOW_BORDER`, `HYPR_CMD_STRIP_TITLEBAR`, `HYPR_CMD_SET_WINDOW_FOCUS`, `HYPR_CMD_SET_GLOBAL_POLICY`, `HYPR_CMD_QUERY_WINDOW`).
- **Minimal Critical Sections:** Lock hold times are strictly minimal (<5μs) in memory. Locks are always released *before* calling compositor flushes (`SLSFlushSurface`, `invalidate_window`) or performing I/O to avoid priority inversion or stalling compositor frame rendering.
- **Structured Logging Synchronization (`g_log_lock`):** File writes and rotation for `/tmp/hyprserver.log` are serialized via `g_log_lock` (`os_unfair_lock`).

### 4.5 Dylib Destructor & Clean Unload Path
`WindowServer` is a root daemon managed by `launchd` that persists for the entire lifetime of the OS session. Restarting WindowServer forcibly terminates all GUI applications and logs the user out. To facilitate clean library unloads and prevent resource leaks:

1. **Dylib Destructor Implementation:**
   The hook implements `__attribute__((destructor)) static void hypr_server_fini(void)` in `hook.c`:
   ```c
   __attribute__((destructor))
   static void hypr_server_fini(void) {
       unlink(HYPR_AUTH_TOKEN_PATH);
       unlink(HYPR_READY_PATH);
   }
   ```
   - Automatically invoked by `dyld` if the dylib is unloaded or during process termination.
   - Unlinks the ephemeral auth token file (`/tmp/hyprmac-auth-token`) and readiness marker (`/tmp/hyprserver.ready`).
2. **Dynamic Reload Considerations:** While `dlclose()` can decrement the dylib reference count, macOS dynamic linker (`dyld`) semantics do not guarantee physical unloading of shared libraries that have registered Objective-C classes or thread-local storage blocks. For complete version upgrades where binary layout changes, the system supports disabling old hook mutation handlers or coordinating user logout/re-login when deep symbol swizzles are modified.

### 4.6 State Rollback on Unload / Crash
If the hook terminates or WindowServer restarts:
- **Destructor Cleanup:** The hook's destructor (`__attribute__((destructor)) static void hypr_server_fini(void)`) unlinks `/tmp/hyprmac-auth-token` and `/tmp/hyprserver.ready`.
- **Client Fallback on Abnormal Termination:** If abnormal termination prevents destructor execution, the Swift bridge detects hook unreadiness in shared memory and falls back to `BorderWindow` overlays.
- **Reconciliation on Next Injection:** On next injection, the hook re-enumerates all windows and applies the configured style.

---

## File Changes & Project Organization

| File | Action | Purpose |
|---|---|---|
| `openspec/config.yaml` | Modified | OpenSpec configuration, SDD rules, platform requirements, and sign-off rollback rules. |
| `openspec/changes/windowserver-insitu-composition/proposal.md` | Created | Formal proposal, intent, scope, and rollback. |
| `openspec/changes/windowserver-insitu-composition/design.md` | Modified | This Software Design Document. |
| `openspec/changes/windowserver-insitu-composition/specs/composition-engine.spec.md` | Created | RFC 2119 requirements & Given/When/Then scenarios. |
| `openspec/changes/windowserver-insitu-composition/tasks.md` | Created | Phased implementation task breakdown. |
| `native/injector/main.c` | Created | Two-stage PAC-safe Mach task port loader (`hypr-inject`). |
| `native/server_hook/hook.c` | Created | In-process dylib implementation (`libhyprserver.dylib`). |
| `native/shared/protocol.h` | Created | Common binary wire protocol definitions. |
| `Sources/HyprMac/Bridge/HyprServerBridge.swift` | Created | Swift client driver for shared memory IPC communication. |
| `Sources/HyprMac/Bridge/SkyLightBridge.swift` | Modify | Forward window decoration mutations to server hook. |
| `Sources/HyprMac/main.swift` | Modify | CLI commands to inspect and trigger server modifications. |
