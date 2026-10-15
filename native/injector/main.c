/**
 * hypr-inject: Two-stage PAC-safe loader for HyprMac
 *
 * Loads libhyprserver.dylib into WindowServer using a two-stage approach:
 * Stage 1 (raw Mach thread): calls pthread_create_from_mach_thread
 * Stage 2 (real pthread with TLS): calls dlopen(path, RTLD_LAZY)
 *
 * Based on yabai's proven ARM64e injection pattern by Jeremy Legendre,
 * with ASLR shared-cache slide correction for cross-session targets.
 *
 * Requires SIP disabled, -arm64e_preview_abi boot arg, and root.
 */

#include "../shared/protocol.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/thread_act.h>
#include <mach-o/dyld_images.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <bootstrap.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <libproc.h>

/* ---- Output helpers ------------------------------------------------------- */

#define RED     "\033[31m"
#define GREEN   "\033[32m"
#define YELLOW  "\033[33m"
#define RESET   "\033[0m"

#define LOG_OK(fmt, ...)   fprintf(stderr, GREEN  "[hypr-inject] " fmt RESET "\n", ##__VA_ARGS__)
#define LOG_ERR(fmt, ...)  fprintf(stderr, RED    "[hypr-inject] " fmt RESET "\n", ##__VA_ARGS__)
#define LOG_WARN(fmt, ...) fprintf(stderr, YELLOW "[hypr-inject] " fmt RESET "\n", ##__VA_ARGS__)
#define LOG_INFO(fmt, ...) fprintf(stderr,        "[hypr-inject] " fmt "\n",       ##__VA_ARGS__)

/* ---- Constants ------------------------------------------------------------ */

#define SAFEMODE_PATH      "/tmp/hyprmac.safemode"
#define LAUNCHDAEMON_PLIST "/Library/LaunchDaemons/com.hyprmac.inject.plist"

/* Private kernel function loaded via dlsym at runtime. */
typedef kern_return_t (*thread_convert_fn)(
    thread_act_t thread, int direction,
    thread_state_flavor_t flavor,
    thread_state_t in_state, mach_msg_type_number_t in_count,
    thread_state_t out_state, mach_msg_type_number_t *out_count);

/*
 * Two-stage ARM64e shellcode (based on yabai by Jeremy Legendre).
 *
 * Layout in the remote code page:
 *   [0x00..0x57]  Stage 1: calls pthread_create_from_mach_thread,
 *                 then spins with a readiness marker in x0.
 *   [0x58..0x5F]  Data slot: pthread_create_from_mach_thread address.
 *   [0x60..0x9F]  Stage 2: calls dlopen(path, RTLD_LAZY), returns via retab.
 *   [0xA0..0xA7]  Data slot: dlopen address.
 *   [0xA8..end]   Dylib path string (NUL-terminated).
 *
 * Stage 1 runs on the raw Mach thread (no TLS). It creates a real
 * pthread via pthread_create_from_mach_thread (which has a dedicated
 * bypass for raw Mach threads), passing Stage 2 as the start routine.
 * Stage 2 runs on the new pthread (with full TLS), so dlopen can
 * safely call pthread_getspecific and other TLS-dependent functions.
 *
 * Function addresses in the data slots are raw (PAC-stripped) and
 * adjusted by the shared-cache ASLR slide delta so they resolve
 * correctly inside WindowServer.
 */
static uint8_t g_code_payload[] = {
    /* ---- Stage 1 (offset 0x00, 22 instructions = 88 bytes) ---- */
    0xFF, 0xC3, 0x00, 0xD1,  /* sub   sp, sp, #0x30                */
    0xFD, 0x7B, 0x02, 0xA9,  /* stp   x29, x30, [sp, #0x20]       */
    0xFD, 0x83, 0x00, 0x91,  /* add   x29, sp, #0x20               */
    0xA0, 0xC3, 0x1F, 0xB8,  /* stur  w0, [x29, #-0x4]            */
    0xE1, 0x0B, 0x00, 0xF9,  /* str   x1, [sp, #0x10]             */
    0xE0, 0x23, 0x00, 0x91,  /* add   x0, sp, #0x8  (pthread_t*)  */
    0x08, 0x00, 0x80, 0xD2,  /* mov   x8, #0                      */
    0xE8, 0x07, 0x00, 0xF9,  /* str   x8, [sp, #0x8]              */
    0xE1, 0x03, 0x08, 0xAA,  /* mov   x1, x8         (attr=NULL)  */
    0xE2, 0x01, 0x00, 0x10,  /* adr   x2, #0x3C      (&stage2)    */
    0xE2, 0x23, 0xC1, 0xDA,  /* paciza x2                         */
    0xE3, 0x03, 0x08, 0xAA,  /* mov   x3, x8         (arg=NULL)   */
    0x49, 0x01, 0x00, 0x10,  /* adr   x9, #0x28      (&pcfmt)     */
    0x29, 0x01, 0x40, 0xF9,  /* ldr   x9, [x9]                    */
    0x20, 0x01, 0x3F, 0xD6,  /* blr   x9  (pthread_create_from_mach_thread) */
    0xA0, 0x4C, 0x8C, 0xD2,  /* movz  x0, #0x6265    (marker lo)  */
    0x20, 0x2C, 0xAF, 0xF2,  /* movk  x0, #0x7961, lsl #16        */
    0x09, 0x00, 0x00, 0x10,  /* adr   x9, #0         (spin)       */
    0x20, 0x01, 0x1F, 0xD6,  /* br    x9                          */
    /* dead code (never reached after spin) */
    0xFD, 0x7B, 0x42, 0xA9,  /* ldp   x29, x30, [sp, #0x20]      */
    0xFF, 0xC3, 0x00, 0x91,  /* add   sp, sp, #0x30               */
    0xC0, 0x03, 0x5F, 0xD6,  /* ret                               */

    /* ---- Data slot at offset 0x58: pcfmt address (8 bytes) ---- */
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

    /* ---- Stage 2 (offset 0x60, 16 instructions = 64 bytes) ---- */
    0x1F, 0x20, 0x03, 0xD5,  /* nop (skip pacibsp - cross-process PAC) */
    0xFF, 0xC3, 0x00, 0xD1,  /* sub   sp, sp, #0x30               */
    0xFD, 0x7B, 0x02, 0xA9,  /* stp   x29, x30, [sp, #0x20]      */
    0xFD, 0x83, 0x00, 0x91,  /* add   x29, sp, #0x20              */
    0xA0, 0xC3, 0x1F, 0xB8,  /* stur  w0, [x29, #-0x4]           */
    0xE1, 0x0B, 0x00, 0xF9,  /* str   x1, [sp, #0x10]            */
    0x21, 0x00, 0x80, 0xD2,  /* mov   x1, #1          (RTLD_LAZY) */
    0x60, 0x01, 0x00, 0x10,  /* adr   x0, #0x2C       (&path)    */
    0x09, 0x01, 0x00, 0x10,  /* adr   x9, #0x20       (&dlopen)  */
    0x29, 0x01, 0x40, 0xF9,  /* ldr   x9, [x9]                   */
    0x20, 0x01, 0x3F, 0xD6,  /* blr   x9              (dlopen)   */
    0x09, 0x00, 0x80, 0x52,  /* mov   w9, #0                     */
    0xE0, 0x03, 0x09, 0xAA,  /* mov   x0, x9                     */
    0xFD, 0x7B, 0x42, 0xA9,  /* ldp   x29, x30, [sp, #0x20]     */
    0xFF, 0xC3, 0x00, 0x91,  /* add   sp, sp, #0x30              */
    0xC0, 0x03, 0x5F, 0xD6,  /* ret (plain return - no PAC auth)  */

    /* ---- Data slot at offset 0xA0: dlopen address (8 bytes) ---- */
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

    /* ---- Path area at offset 0xA8 (filled at runtime) ---- */
};

#define CODE_PCFMT_OFFSET   0x58
#define CODE_DLOPEN_OFFSET  0xA0
#define CODE_PATH_OFFSET    0xA8
#define CODE_MARKER_VALUE   0x79616265u  /* "yabe" — readiness marker */

/* ===========================================================================
 * find_windowserver_pid
 */
static pid_t find_windowserver_pid(void)
{
    FILE *fp = popen("pgrep -x WindowServer", "r");
    if (!fp) { LOG_ERR("popen(pgrep) failed"); return -1; }
    char buf[32] = {0};
    if (!fgets(buf, sizeof(buf), fp)) {
        pclose(fp); LOG_ERR("WindowServer not found"); return -1;
    }
    pclose(fp);
    pid_t pid = (pid_t)atoi(buf);
    if (pid <= 0) { LOG_ERR("Failed to parse PID"); return -1; }
    return pid;
}

/* ===========================================================================
 * check_sip_status — returns 1=disabled, 0=enabled, -1=unknown
 */
static int check_sip_status(void)
{
    FILE *fp = popen("csrutil status", "r");
    if (!fp) { LOG_WARN("Could not run csrutil"); return -1; }
    char buf[256] = {0};
    int disabled = 0;
    while (fgets(buf, sizeof(buf), fp)) {
        if (strstr(buf, "disabled")) { disabled = 1; break; }
    }
    pclose(fp);
    return disabled;
}

/* ===========================================================================
 * check_arm64e_bootargs
 */
static int check_arm64e_bootargs(void)
{
    char bootargs[512] = {0};
    size_t len = sizeof(bootargs);
    if (sysctlbyname("kern.bootargs", bootargs, &len, NULL, 0) != 0)
        return -1;
    return strstr(bootargs, "-arm64e_preview_abi") ? 1 : 0;
}

/* ===========================================================================
 * get_macos_version
 */
static void get_macos_version(int *major, int *minor)
{
    char version[32] = {0};
    size_t len = sizeof(version);
    *major = 0; *minor = 0;
    if (sysctlbyname("kern.osproductversion", version, &len, NULL, 0) == 0)
        sscanf(version, "%d.%d", major, minor);
}

/* ===========================================================================
 * check_hook_loaded
 */
static int check_hook_loaded(void)
{
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port,
                                          HYPR_BOOTSTRAP_NAME, &port);
    if (kr == KERN_SUCCESS && MACH_PORT_VALID(port)) {
        mach_port_deallocate(mach_task_self(), port);
        return 1;
    }
    return 0;
}

/* ===========================================================================
 * handle_uninstall
 */
static void handle_uninstall(void)
{
    if (access(LAUNCHDAEMON_PLIST, F_OK) == 0) {
        if (remove(LAUNCHDAEMON_PLIST) == 0)
            LOG_OK("Removed %s", LAUNCHDAEMON_PLIST);
        else
            LOG_ERR("Failed to remove %s", LAUNCHDAEMON_PLIST);
    } else {
        LOG_INFO("LaunchDaemon plist not present");
    }
    FILE *sf = fopen(SAFEMODE_PATH, "w");
    if (sf) { fclose(sf); LOG_OK("Safe-mode engaged: %s", SAFEMODE_PATH); }
    LOG_OK("Uninstall complete.");
}

/* ===========================================================================
 * resolve_dylib_path
 */
static const char *resolve_dylib_path(const char *argv0, const char *explicit_path)
{
    static char resolved[PATH_MAX];
    if (explicit_path) {
        if (access(explicit_path, F_OK) != 0) {
            LOG_ERR("Dylib not found: %s", explicit_path); return NULL;
        }
        strncpy(resolved, explicit_path, PATH_MAX - 1);
        resolved[PATH_MAX - 1] = '\0';
        return resolved;
    }
    char exe_real[PATH_MAX];
    if (!realpath(argv0, exe_real)) {
        LOG_ERR("realpath(%s) failed", argv0); return NULL;
    }
    char *sep = strrchr(exe_real, '/');
    if (!sep) { LOG_ERR("No '/' in argv[0]"); return NULL; }
    *sep = '\0';
    int n = snprintf(resolved, sizeof(resolved), "%s/libhyprserver.dylib", exe_real);
    if (n < 0 || (size_t)n >= sizeof(resolved)) {
        LOG_ERR("Path too long"); return NULL;
    }
    if (access(resolved, F_OK) != 0) {
        LOG_ERR("Not found: %s", resolved); return NULL;
    }
    return resolved;
}

/* ===========================================================================
 * resolve_shared_cache_slide_delta
 */
static int resolve_shared_cache_slide_delta(mach_port_t target_task, intptr_t *out_slide_delta)
{
    if (!out_slide_delta) {
        LOG_ERR("out_slide_delta is NULL");
        return -1;
    }

    /* 1. Calls task_info(target_task, TASK_DYLD_INFO, ...) to get remote all_image_info_addr */
    task_dyld_info_data_t remote_dyld_info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(target_task, TASK_DYLD_INFO,
                                 (task_info_t)&remote_dyld_info, &count);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("task_info(target_task, TASK_DYLD_INFO) failed: %s", mach_error_string(kr));
        return -1;
    }
    if (remote_dyld_info.all_image_info_addr == 0) {
        LOG_ERR("remote all_image_info_addr is NULL");
        return -1;
    }

    /* 2. Calls mach_vm_read(target_task, remote_all_image_info_addr, sizeof(struct dyld_all_image_infos), ...) */
    vm_offset_t read_data = 0;
    mach_msg_type_number_t read_count = 0;
    kr = mach_vm_read(target_task,
                      remote_dyld_info.all_image_info_addr,
                      sizeof(struct dyld_all_image_infos),
                      &read_data,
                      &read_count);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("mach_vm_read(remote dyld_all_image_infos) failed: %s", mach_error_string(kr));
        return -1;
    }
    if (read_count < sizeof(struct dyld_all_image_infos)) {
        LOG_ERR("mach_vm_read returned partial data (%u bytes)", read_count);
        vm_deallocate(mach_task_self(), (vm_address_t)read_data, (vm_size_t)read_count);
        return -1;
    }

    /* 3. Extracts remote_infos->sharedCacheSlide */
    const struct dyld_all_image_infos *remote_infos =
        (const struct dyld_all_image_infos *)read_data;
    if (remote_infos->version < 12) {
        LOG_ERR("remote dyld_all_image_infos version (%u) < 12, sharedCacheSlide unavailable",
                remote_infos->version);
        vm_deallocate(mach_task_self(), (vm_address_t)read_data, (vm_size_t)read_count);
        return -1;
    }
    uintptr_t remote_slide = remote_infos->sharedCacheSlide;

    /* 4. Calls vm_deallocate to release the mach_vm_read buffer (symmetric lifecycle) */
    vm_deallocate(mach_task_self(), (vm_address_t)read_data, (vm_size_t)read_count);

    /* 5. Gets LOCAL slide by reading local_dyld_info.all_image_info_addr directly */
    task_dyld_info_data_t local_dyld_info;
    count = TASK_DYLD_INFO_COUNT;
    kr = task_info(mach_task_self(), TASK_DYLD_INFO,
                   (task_info_t)&local_dyld_info, &count);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("task_info(mach_task_self, TASK_DYLD_INFO) failed: %s", mach_error_string(kr));
        return -1;
    }
    if (local_dyld_info.all_image_info_addr == 0) {
        LOG_ERR("local all_image_info_addr is NULL");
        return -1;
    }
    const struct dyld_all_image_infos *local_infos =
        (const struct dyld_all_image_infos *)local_dyld_info.all_image_info_addr;
    if (local_infos->version < 12) {
        LOG_ERR("local dyld_all_image_infos version (%u) < 12, sharedCacheSlide unavailable",
                local_infos->version);
        return -1;
    }
    uintptr_t local_slide = local_infos->sharedCacheSlide;

    /* 6. Computes delta = remote_slide - local_slide */
    intptr_t delta = (intptr_t)remote_slide - (intptr_t)local_slide;
    *out_slide_delta = delta;

    LOG_INFO("Shared cache slide: local=0x%lx remote=0x%lx delta=%+ld (0x%lx)",
             (unsigned long)local_slide,
             (unsigned long)remote_slide,
             (long)delta,
             (unsigned long)delta);

    return 0;
}

/* ===========================================================================
 * load_library_into_windowserver
 *
 * Two-stage approach (based on yabai by Jeremy Legendre):
 * Stage 1 (Mach thread): pthread_create_from_mach_thread -> spin
 * Stage 2 (pthread with TLS): dlopen(path, RTLD_LAZY) -> retab
 *
 * 1. Allocate stack (16 KB, R|W)
 * 2. Build code page: shellcode + data slots + path string (R|X)
 * 3. Resolve symbols (pcfmt, dlopen), apply ASLR slide delta
 * 4. thread_create -> convert -> thread_create_running (macOS >=14.4)
 * 5. Poll for readiness marker in x0, then wait for hook socket
 * 6. Terminate the spinning thread
 */
static int load_library_into_windowserver(pid_t ws_pid, const char *dylib_path)
{
    kern_return_t kr;

    /* 1. Acquire task port */
    mach_port_t task = MACH_PORT_NULL;
    kr = task_for_pid(mach_task_self(), ws_pid, &task);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("task_for_pid(%d) failed: %s", ws_pid, mach_error_string(kr));
        return -1;
    }
    LOG_OK("Acquired task port for WindowServer (pid %d)", ws_pid);

    /* 2. Resolve symbols from shared cache, strip PAC */
    uint64_t pcfmt_addr = (uint64_t)ptrauth_strip(
        dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread"),
        ptrauth_key_function_pointer);
    uint64_t dlopen_addr = (uint64_t)ptrauth_strip(
        dlsym(RTLD_DEFAULT, "dlopen"),
        ptrauth_key_function_pointer);

    if (!pcfmt_addr || !dlopen_addr) {
        LOG_ERR("dlsym failed (pcfmt=0x%llx dlopen=0x%llx)",
                (unsigned long long)pcfmt_addr,
                (unsigned long long)dlopen_addr);
        goto fail;
    }
    LOG_INFO("Local symbols: pcfmt=0x%llx dlopen=0x%llx",
             (unsigned long long)pcfmt_addr,
             (unsigned long long)dlopen_addr);

    /* 3. Resolve shared cache slide delta */
    intptr_t slide_delta = 0;
    if (resolve_shared_cache_slide_delta(task, &slide_delta) != 0) {
        LOG_ERR("resolve_shared_cache_slide_delta failed");
        goto fail;
    }
    uint64_t remote_pcfmt  = pcfmt_addr  + slide_delta;
    uint64_t remote_dlopen = dlopen_addr + slide_delta;
    LOG_INFO("Remote symbols: pcfmt=0x%llx dlopen=0x%llx",
             (unsigned long long)remote_pcfmt,
             (unsigned long long)remote_dlopen);

    /* 4. Allocate stack (16 KB) */
    mach_vm_address_t remote_stack = 0;
    vm_size_t stack_size = 16 * 1024;

    kr = mach_vm_allocate(task, &remote_stack, stack_size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("mach_vm_allocate(stack) failed: %s", mach_error_string(kr));
        goto fail;
    }
    kr = vm_protect(task, (vm_address_t)remote_stack, stack_size,
                    1, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("vm_protect(stack) failed: %s", mach_error_string(kr));
        goto fail;
    }

    /* 5. Build code page: shellcode + data slots + path */
    size_t path_len = strlen(dylib_path) + 1;
    size_t code_size = CODE_PATH_OFFSET + path_len;
    if (code_size > 4096) code_size = 4096;  /* cap at one page */

    /* Patch data slots with slide-corrected addresses */
    memcpy(g_code_payload + CODE_PCFMT_OFFSET,  &remote_pcfmt,  8);
    memcpy(g_code_payload + CODE_DLOPEN_OFFSET, &remote_dlopen, 8);

    mach_vm_address_t remote_code = 0;
    kr = mach_vm_allocate(task, &remote_code, 4096, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("mach_vm_allocate(code) failed: %s", mach_error_string(kr));
        goto fail;
    }
    /* Write shellcode + data slots */
    kr = mach_vm_write(task, remote_code,
                       (vm_address_t)g_code_payload,
                       (mach_msg_type_number_t)sizeof(g_code_payload));
    if (kr != KERN_SUCCESS) {
        LOG_ERR("mach_vm_write(code) failed: %s", mach_error_string(kr));
        goto fail;
    }
    /* Write dylib path into path area */
    kr = mach_vm_write(task, remote_code + CODE_PATH_OFFSET,
                       (vm_address_t)dylib_path,
                       (mach_msg_type_number_t)path_len);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("mach_vm_write(path) failed: %s", mach_error_string(kr));
        goto fail;
    }
    kr = vm_protect(task, (vm_address_t)remote_code, 4096,
                    0, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("vm_protect(code R|X) failed: %s", mach_error_string(kr));
        goto fail;
    }

    LOG_INFO("Remote: code=0x%llx stack=0x%llx",
             (unsigned long long)remote_code,
             (unsigned long long)remote_stack);

    /* 6. Load _thread_convert_thread_state */
    void *libkernel = dlopen("/usr/lib/system/libsystem_kernel.dylib",
                             RTLD_GLOBAL | RTLD_LAZY);
    thread_convert_fn _thread_convert = NULL;
    if (libkernel) {
        _thread_convert = (thread_convert_fn)dlsym(
            libkernel, "thread_convert_thread_state");
        dlclose(libkernel);
    }
    if (!_thread_convert) {
        LOG_ERR("Could not load thread_convert_thread_state");
        goto fail;
    }

    /* 7. Configure thread state:
     *    PC  = remote_code     (stage 1 shellcode entry)
     *    SP  = stack midpoint  (16-byte aligned)
     */
    arm_thread_state64_t thread_state = {}, machine_state = {};
    thread_state_flavor_t flavor = ARM_THREAD_STATE64;
    mach_msg_type_number_t flavor_count = ARM_THREAD_STATE64_COUNT;
    mach_msg_type_number_t machine_count = ARM_THREAD_STATE64_COUNT;

    __darwin_arm_thread_state64_set_pc_fptr(
        thread_state,
        ptrauth_sign_unauthenticated(
            (void *)remote_code, ptrauth_key_asia, 0));
    __darwin_arm_thread_state64_set_sp(
        thread_state,
        remote_stack + (stack_size / 2));

    /* 8. Create thread, convert state */
    thread_act_t thread = MACH_PORT_NULL;

    kr = thread_create(task, &thread);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("thread_create failed: %s", mach_error_string(kr));
        goto fail;
    }

    kr = _thread_convert(thread, 2, flavor,
                         (thread_state_t)&thread_state, flavor_count,
                         (thread_state_t)&machine_state, &machine_count);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("thread_convert failed: %s", mach_error_string(kr));
        thread_terminate(thread);
        goto fail;
    }
    LOG_OK("Thread state converted to target PAC domain.");

    /* 9. macOS version branch */
    int os_major = 0, os_minor = 0;
    get_macos_version(&os_major, &os_minor);

    if ((os_major == 14 && os_minor >= 4) || os_major >= 15) {
        thread_terminate(thread);
        kr = thread_create_running(task, flavor,
                                   (thread_state_t)&machine_state,
                                   machine_count, &thread);
        if (kr != KERN_SUCCESS) {
            LOG_ERR("thread_create_running failed: %s", mach_error_string(kr));
            goto fail;
        }
        LOG_OK("Thread launched via thread_create_running (macOS %d.%d)",
               os_major, os_minor);
    } else {
        kr = thread_set_state(thread, flavor,
                              (thread_state_t)&machine_state, machine_count);
        if (kr != KERN_SUCCESS) {
            LOG_ERR("thread_set_state failed: %s", mach_error_string(kr));
            thread_terminate(thread);
            goto fail;
        }
        kr = thread_resume(thread);
        if (kr != KERN_SUCCESS) {
            LOG_ERR("thread_resume failed: %s", mach_error_string(kr));
            thread_terminate(thread);
            goto fail;
        }
        LOG_OK("Thread launched via set+resume (macOS %d.%d)",
               os_major, os_minor);
    }

    /* 10. Poll for readiness marker, then wait for hook socket */
    LOG_INFO("Waiting for stage 1 readiness...");
    usleep(10000);  /* 10 ms initial settle */

    arm_thread_state64_t poll_state = {};
    mach_msg_type_number_t poll_count = ARM_THREAD_STATE64_COUNT;
    int stage1_ready = 0;
    for (int i = 0; i < 10; i++) {
        kr = thread_get_state(thread, flavor,
                              (thread_state_t)&poll_state, &poll_count);
        if (kr != KERN_SUCCESS) break;
        if (poll_state.__x[0] == CODE_MARKER_VALUE) {
            stage1_ready = 1;
            LOG_OK("Stage 1 ready (marker 0x%x found).", CODE_MARKER_VALUE);
            break;
        }
        poll_count = ARM_THREAD_STATE64_COUNT;
        usleep(20000);  /* 20 ms between polls */
    }

    if (!stage1_ready) {
        LOG_WARN("Stage 1 marker not detected within 200 ms.");
    }

    LOG_INFO("Waiting for hook socket...");
    int hook_ready = 0;
    for (int w = 0; w < 100; w++) {
        usleep(100000);
        if (access(HYPR_SOCKET_PATH, F_OK) == 0) {
            hook_ready = 1;
            break;
        }
    }

    /* 11. Terminate the spinning stage 1 thread */
    thread_terminate(thread);

    if (hook_ready) {
        LOG_OK("Hook socket found -- library loaded successfully.");
    } else {
        LOG_WARN("Hook socket not found within 10 s.");
        LOG_WARN("Library may have loaded but constructor did not complete.");
    }

    /* Intentionally leak remote pages */
    mach_port_deallocate(mach_task_self(), task);
    return hook_ready ? 0 : -1;

fail:
    mach_port_deallocate(mach_task_self(), task);
    return -1;
}

/* ===========================================================================
 * main
 */
int main(int argc, char *argv[])
{
    int uninstall = 0;
    const char *explicit_lib = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--uninstall") == 0) uninstall = 1;
        else if (argv[i][0] != '-') explicit_lib = argv[i];
    }

    if (uninstall) { handle_uninstall(); return 0; }

    if (geteuid() != 0) {
        LOG_ERR("Must run as root.");
        return 1;
    }

    int sip = check_sip_status();
    if (sip == 0) { LOG_ERR("SIP is ENABLED."); return 1; }
    if (sip == 1) LOG_OK("SIP is disabled -- proceeding.");
    else LOG_WARN("SIP status unknown -- proceeding.");

    int arm64e = check_arm64e_bootargs();
    if (arm64e == 0) {
        LOG_ERR("Missing -arm64e_preview_abi boot argument.");
        return 1;
    }
    if (arm64e == 1) LOG_OK("-arm64e_preview_abi confirmed.");
    else LOG_WARN("Could not verify boot args -- proceeding.");

    if (access(SAFEMODE_PATH, F_OK) == 0) {
        LOG_ERR("Safe-mode active. Remove %s to re-enable.", SAFEMODE_PATH);
        return 1;
    }

    if (check_hook_loaded()) {
        LOG_OK("libhyprserver already loaded -- nothing to do.");
        return 2;
    }

    pid_t ws_pid = find_windowserver_pid();
    if (ws_pid < 0) { LOG_ERR("Cannot locate WindowServer."); return 1; }
    LOG_INFO("WindowServer PID: %d", ws_pid);

    const char *dylib_path = resolve_dylib_path(argv[0], explicit_lib);
    if (!dylib_path) { LOG_ERR("Cannot resolve libhyprserver.dylib."); return 1; }
    LOG_INFO("Loading: %s", dylib_path);

    if (load_library_into_windowserver(ws_pid, dylib_path) != 0) {
        LOG_ERR("Loading failed.");
        return 1;
    }

    /* Post-load crash watchdog */
    usleep(500u * 1000u);
    pid_t ws_after = find_windowserver_pid();
    if (ws_after != ws_pid) {
        LOG_ERR("WindowServer restarted (pid %d -> %d).", ws_pid, ws_after);
        FILE *sf = fopen(SAFEMODE_PATH, "w");
        if (sf) fclose(sf);
        LOG_ERR("Safe-mode engaged.");
        return 1;
    }

    LOG_OK("WindowServer stable (pid %d).", ws_pid);
    LOG_OK("libhyprserver.dylib loaded -- HyprMac is active.");
    return 0;
}

