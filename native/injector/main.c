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
#include <mach/arm/thread_state.h>
#include <mach-o/dyld_images.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <bootstrap.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
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
#define STAGED_DYLIB_DIR   "/Library/GPUBundles"
#define STAGED_DYLIB_PATH  "/Library/GPUBundles/libhyprserver.dylib"

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
 *                 saves return code to x20 and pthread_t to x21,
 *                 then spins with a readiness marker in x0.
 *   [0x58..0x5F]  Data slot: pthread_create_from_mach_thread address.
  *   [0x60..0xF7]  Stage 2: writes diagnostic markers, calls dlopen(path, RTLD_LAZY),
  *                 records dlopen result, calls dlerror() if dlopen returned NULL,
  *                 copies dlerror string to diag page + 0x20,
  *                 records post-marker, returns.
  *   [0xF8..0xFF]  Data slot: dlopen address.
  *   [0x100..0x107] Data slot: diagnostic page address.
  *   [0x108..0x10F] Data slot: dlerror address.
  *   [0x110..end]   Dylib path string (NUL-terminated).
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
    0xF4, 0x03, 0x00, 0xAA,  /* mov   x20, x0  (save pcfmt return value)   */
    0xF5, 0x07, 0x40, 0xF9,  /* ldr   x21, [sp, #0x8] (load pthread_t)     */
    0xA0, 0x4C, 0x8C, 0xD2,  /* movz  x0, #0x6265    (marker lo)  */
    0x20, 0x2C, 0xAF, 0xF2,  /* movk  x0, #0x7961, lsl #16        */
    0x09, 0x00, 0x00, 0x10,  /* adr   x9, #0         (spin)       */
    0x20, 0x01, 0x1F, 0xD6,  /* br    x9                          */
    0xC0, 0x03, 0x5F, 0xD6,  /* ret   (dead padding)              */

    /* ---- Data slot at offset 0x58: pcfmt address (8 bytes) ---- */
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

    /* ---- Stage 2 (offset 0x60, 38 instructions = 152 bytes) ---- */
    0x1F, 0x20, 0x03, 0xD5,  /* 0x60: nop (skip pacibsp - cross-process PAC)   */
    0xFF, 0xC3, 0x00, 0xD1,  /* 0x64: sub   sp, sp, #0x30                      */
    0xFD, 0x7B, 0x02, 0xA9,  /* 0x68: stp   x29, x30, [sp, #0x20]              */
    0xFD, 0x83, 0x00, 0x91,  /* 0x6C: add   x29, sp, #0x20                     */
    0x96, 0x04, 0x00, 0x10,  /* 0x70: adr   x22, #0x90      (&diag_slot)       */
    0xD6, 0x02, 0x40, 0xF9,  /* 0x74: ldr   x22, [x22]      (diag page addr)   */
    0x2B, 0x00, 0x80, 0x52,  /* 0x78: mov   w11, #1                            */
    0xAB, 0xD5, 0xBB, 0x72,  /* 0x7C: movk  w11, #0xDEAD, lsl #16 (0xDEAD0001) */
    0xCB, 0x02, 0x00, 0xB9,  /* 0x80: str   w11, [x22]      (entry marker)     */
    0x4B, 0x00, 0x80, 0x52,  /* 0x84: mov   w11, #2                            */
    0xAB, 0xD5, 0xBB, 0x72,  /* 0x88: movk  w11, #0xDEAD, lsl #16 (0xDEAD0002) */
    0xCB, 0x06, 0x00, 0xB9,  /* 0x8C: str   w11, [x22, #4]  (pre-dlopen)       */
    0x21, 0x00, 0x80, 0xD2,  /* 0x90: mov   x1, #1          (RTLD_LAZY)        */
    0xE0, 0x03, 0x00, 0x10,  /* 0x94: adr   x0, #0x7C       (&path)            */
    0x09, 0x03, 0x00, 0x10,  /* 0x98: adr   x9, #0x60       (&dlopen)          */
    0x29, 0x01, 0x40, 0xF9,  /* 0x9C: ldr   x9, [x9]                           */
    0x20, 0x01, 0x3F, 0xD6,  /* 0xA0: blr   x9              (dlopen)           */
    0xC0, 0x06, 0x00, 0xF9,  /* 0xA4: str   x0, [x22, #8]   (dlopen result)    */
    0xC0, 0x01, 0x00, 0xB5,  /* 0xA8: cbnz  x0, #0x38       (skip if non-NULL) */
    0xE9, 0x02, 0x00, 0x10,  /* 0xAC: adr   x9, #0x5C       (&dlerror)         */
    0x29, 0x01, 0x40, 0xF9,  /* 0xB0: ldr   x9, [x9]                           */
    0x20, 0x01, 0x3F, 0xD6,  /* 0xB4: blr   x9              (dlerror)          */
    0xC0, 0x0E, 0x00, 0xF9,  /* 0xB8: str   x0, [x22, #0x18](dlerror result)   */
    0x20, 0x01, 0x00, 0xB4,  /* 0xBC: cbz   x0, #0x24       (skip if NULL)     */
    0xF7, 0x03, 0x00, 0xAA,  /* 0xC0: mov   x23, x0         (source = dlerror string) */
    0xD8, 0x82, 0x00, 0x91,  /* 0xC4: add   x24, x22, #0x20 (dest = diag + 0x20) */
    0x19, 0x19, 0x80, 0x52,  /* 0xC8: mov   w25, #200       (max bytes)        */
    0xEB, 0x16, 0x40, 0x38,  /* 0xCC: ldrb  w11, [x23], #1  (copy_loop: load byte) */
    0x0B, 0x17, 0x00, 0x38,  /* 0xD0: strb  w11, [x24], #1  (store byte)       */
    0x6B, 0x00, 0x00, 0x34,  /* 0xD4: cbz   w11, #0xC       (done if NUL terminator) */
    0x39, 0x07, 0x00, 0x71,  /* 0xD8: subs  w25, w25, #1    (decrement counter) */
    0x81, 0xFF, 0xFF, 0x54,  /* 0xDC: b.ne  #-0x10          (loop if counter > 0) */
    0x6B, 0x00, 0x80, 0x52,  /* 0xE0: mov   w11, #3         (skip_copy: post marker) */
    0xAB, 0xD5, 0xBB, 0x72,  /* 0xE4: movk  w11, #0xDEAD, lsl #16 (0xDEAD0003) */
    0xCB, 0x12, 0x00, 0xB9,  /* 0xE8: str   w11, [x22, #0x10](post-dlopen)     */
    0xFD, 0x7B, 0x42, 0xA9,  /* 0xEC: ldp   x29, x30, [sp, #0x20]              */
    0xFF, 0xC3, 0x00, 0x91,  /* 0xF0: add   sp, sp, #0x30                      */
    0xC0, 0x03, 0x5F, 0xD6,  /* 0xF4: ret (plain return - no PAC auth)         */

    /* ---- Data slot at offset 0xF8: dlopen address (8 bytes) ---- */
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

    /* ---- Data slot at offset 0x100: diagnostic page address (8 bytes) ---- */
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

    /* ---- Data slot at offset 0x108: dlerror address (8 bytes) ---- */
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

    /* ---- Path area at offset 0x110 (filled at runtime) ---- */
};

#define CODE_PCFMT_OFFSET   0x58
#define CODE_DLOPEN_OFFSET  0xF8
#define CODE_DIAG_OFFSET    0x100
#define CODE_DLERROR_OFFSET 0x108
#define CODE_PATH_OFFSET    0x110
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
    if (access(STAGED_DYLIB_PATH, F_OK) == 0) {
        if (remove(STAGED_DYLIB_PATH) == 0)
            LOG_OK("Removed %s", STAGED_DYLIB_PATH);
        else
            LOG_ERR("Failed to remove %s", STAGED_DYLIB_PATH);
    }
    if (access("/tmp/libhyprserver.dylib", F_OK) == 0) {
        remove("/tmp/libhyprserver.dylib");
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
 * stage_dylib_for_windowserver
 *
 * Copies the dylib to /Library/GPUBundles/libhyprserver.dylib with 0644 permissions so
 * WindowServer (running as uid 88, _windowserver) can read and dlopen it even
 * when the source dylib is under a user directory lacking world-traversal rights.
 */
static int stage_dylib_for_windowserver(const char *src_path, const char *dst_path)
{
    if (mkdir("/Library/GPUBundles", 0755) != 0 && errno != EEXIST) {
        LOG_WARN("mkdir('/Library/GPUBundles') failed: %s", strerror(errno));
    }

    struct stat st_src;
    if (stat(src_path, &st_src) != 0) {
        LOG_ERR("Failed to stat source dylib '%s': %s", src_path, strerror(errno));
        return -1;
    }

    struct stat st_dst;
    if (stat(dst_path, &st_dst) == 0 &&
        st_src.st_dev == st_dst.st_dev &&
        st_src.st_ino == st_dst.st_ino) {
        if (chmod(dst_path, 0644) != 0) {
            LOG_WARN("chmod failed on '%s': %s", dst_path, strerror(errno));
        }
        printf("[hypr-inject] Staged dylib to %s for WindowServer access.\n", dst_path);
        return 0;
    }

    int src_fd = open(src_path, O_RDONLY);
    if (src_fd < 0) {
        LOG_ERR("Failed to open source dylib '%s': %s", src_path, strerror(errno));
        return -1;
    }

    unlink(dst_path);

    int dst_fd = open(dst_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (dst_fd < 0) {
        LOG_ERR("Failed to create staged dylib '%s': %s", dst_path, strerror(errno));
        close(src_fd);
        return -1;
    }

    char buf[65536];
    ssize_t bytes_read;
    while ((bytes_read = read(src_fd, buf, sizeof(buf))) > 0) {
        ssize_t total_written = 0;
        while (total_written < bytes_read) {
            ssize_t written = write(dst_fd, buf + total_written, (size_t)(bytes_read - total_written));
            if (written < 0) {
                if (errno == EINTR) continue;
                LOG_ERR("Failed writing to staged dylib: %s", strerror(errno));
                close(src_fd);
                close(dst_fd);
                return -1;
            }
            total_written += written;
        }
    }

    if (bytes_read < 0) {
        LOG_ERR("Failed reading from source dylib: %s", strerror(errno));
        close(src_fd);
        close(dst_fd);
        return -1;
    }

    close(src_fd);

    if (fchmod(dst_fd, 0644) != 0) {
        LOG_WARN("fchmod failed on '%s': %s", dst_path, strerror(errno));
    }
    close(dst_fd);

    printf("[hypr-inject] Staged dylib to %s for WindowServer access.\n", dst_path);
    return 0;
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
    mach_vm_address_t remote_stack = 0;
    mach_vm_address_t remote_code = 0;
    mach_vm_address_t remote_diag = 0;
    vm_size_t stack_size = 16 * 1024;

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
    uint64_t dlerror_addr = (uint64_t)ptrauth_strip(
        dlsym(RTLD_DEFAULT, "dlerror"),
        ptrauth_key_function_pointer);

    if (!pcfmt_addr || !dlopen_addr || !dlerror_addr) {
        LOG_ERR("dlsym failed (pcfmt=0x%llx dlopen=0x%llx dlerror=0x%llx)",
                (unsigned long long)pcfmt_addr,
                (unsigned long long)dlopen_addr,
                (unsigned long long)dlerror_addr);
        goto fail;
    }
    LOG_INFO("Local symbols: pcfmt=0x%llx dlopen=0x%llx dlerror=0x%llx",
             (unsigned long long)pcfmt_addr,
             (unsigned long long)dlopen_addr,
             (unsigned long long)dlerror_addr);

    /* 3. Resolve shared cache slide delta */
    intptr_t slide_delta = 0;
    if (resolve_shared_cache_slide_delta(task, &slide_delta) != 0) {
        LOG_ERR("resolve_shared_cache_slide_delta failed");
        goto fail;
    }
    uint64_t remote_pcfmt   = pcfmt_addr   + slide_delta;
    uint64_t remote_dlopen  = dlopen_addr  + slide_delta;
    uint64_t remote_dlerror = dlerror_addr + slide_delta;
    LOG_INFO("Remote symbols: pcfmt=0x%llx dlopen=0x%llx dlerror=0x%llx",
             (unsigned long long)remote_pcfmt,
             (unsigned long long)remote_dlopen,
             (unsigned long long)remote_dlerror);

    /* 4. Allocate stack (16 KB) */
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

    /* 4b. Allocate diagnostic data page (RW, zero-filled) */
    kr = mach_vm_allocate(task, &remote_diag, 4096, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("mach_vm_allocate(diag) failed: %s", mach_error_string(kr));
        goto fail;
    }
    kr = vm_protect(task, (vm_address_t)remote_diag, 4096,
                    1, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("vm_protect(diag) failed: %s", mach_error_string(kr));
        goto fail;
    }

    /* 5. Build code page: shellcode + data slots + path */
    size_t path_len = strlen(dylib_path) + 1;
    size_t code_size = CODE_PATH_OFFSET + path_len;
    if (code_size > 4096) code_size = 4096;  /* cap at one page */

    /* Patch data slots with slide-corrected addresses and diagnostic page */
    memcpy(g_code_payload + CODE_PCFMT_OFFSET,   &remote_pcfmt,   8);
    memcpy(g_code_payload + CODE_DLOPEN_OFFSET,  &remote_dlopen,  8);
    memcpy(g_code_payload + CODE_DIAG_OFFSET,    &remote_diag,    8);
    memcpy(g_code_payload + CODE_DLERROR_OFFSET, &remote_dlerror, 8);

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

    LOG_INFO("Remote: code=0x%llx stack=0x%llx diag=0x%llx",
             (unsigned long long)remote_code,
             (unsigned long long)remote_stack,
             (unsigned long long)remote_diag);

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
        {
            thread_act_array_t pre_threads;
            mach_msg_type_number_t pre_count = 0;
            kern_return_t kr = task_threads(task, &pre_threads, &pre_count);
            if (kr == KERN_SUCCESS) {
                printf("[hypr-inject] Pre-injection thread count: %u\n", pre_count);
                for (mach_msg_type_number_t i = 0; i < pre_count; i++)
                    mach_port_deallocate(mach_task_self(), pre_threads[i]);
                vm_deallocate(mach_task_self(), (vm_address_t)pre_threads, pre_count * sizeof(thread_act_t));
            }
        }
        unlink(HYPR_READY_PATH);  /* Clear stale readiness marker before launch */
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
            printf("[hypr-inject] POST-MORTEM: pthread_create_from_mach_thread returned: %lld (0x%llx)\n", 
                   (long long)poll_state.__x[20], (unsigned long long)poll_state.__x[20]);
            printf("[hypr-inject] POST-MORTEM: pthread_t value: 0x%llx\n", (unsigned long long)poll_state.__x[21]);
            if (poll_state.__x[20] != 0) {
                printf("[hypr-inject] WARNING: pthread_create_from_mach_thread FAILED (errno=%lld). Stage 2 will never run.\n",
                       (long long)poll_state.__x[20]);
            }
            break;
        }
        poll_count = ARM_THREAD_STATE64_COUNT;
        usleep(20000);  /* 20 ms between polls */
    }

    if (!stage1_ready) {
        LOG_WARN("Stage 1 marker not detected within 200 ms.");
    }

    LOG_INFO("Waiting for hook readiness...");
    int hook_ready = 0;
    for (int w = 0; w < 100; w++) {
        usleep(100000);
        if (access(HYPR_READY_PATH, F_OK) == 0) {
            hook_ready = 1;
            break;
        }
    }

    /* 11. Terminate the spinning stage 1 thread */
    thread_terminate(thread);

    if (hook_ready) {
        LOG_OK("Hook ready -- library loaded successfully.");
    } else {
        LOG_WARN("Hook readiness marker not found within 10 s.");
        LOG_WARN("Library may have loaded but constructor did not complete.");
        // Post-mortem: check if diag log exists
        if (access("/tmp/hyprserver-diag.log", F_OK) == 0) {
            printf("[hypr-inject] Diagnostic log exists at /tmp/hyprserver-diag.log — check it for details.\n");
        } else {
            printf("[hypr-inject] No diagnostic log found. The dylib constructor likely never ran (dlopen may have failed — check path permissions).\n");
        }

        mach_port_t task_port = task;
        mach_vm_address_t code_addr = remote_code;
        mach_vm_address_t stack_addr = remote_stack;

        /* Read diagnostic page to check Stage 2 execution status */
        {
            vm_offset_t data = 0;
            mach_msg_type_number_t cnt = 0;
            kern_return_t kr = mach_vm_read(task_port, remote_diag, 64, &data, &cnt);
            if (kr == KERN_SUCCESS && cnt >= 32) {
                uint32_t *d = (uint32_t *)data;
                uint64_t dlopen_handle = *(uint64_t *)(d + 2); // offset 0x08
                printf("[hypr-inject] DIAG: Stage 2 entry marker:  0x%08x %s\n",
                       d[0], d[0] == 0xDEAD0001 ? "(Stage 2 ENTERED)" : "(Stage 2 NEVER ENTERED)");
                printf("[hypr-inject] DIAG: Pre-dlopen marker:     0x%08x %s\n",
                       d[1], d[1] == 0xDEAD0002 ? "(reached dlopen)" : "(did NOT reach dlopen)");
                printf("[hypr-inject] DIAG: dlopen() returned:     0x%llx %s\n",
                       (unsigned long long)dlopen_handle,
                       dlopen_handle ? "(non-NULL handle = loaded)" : "(NULL or not reached)");

                // If dlopen returned NULL, read the dlerror string
                uint64_t dlerror_ptr = *(uint64_t *)((uint8_t *)data + 0x18);
                if (dlerror_ptr != 0) {
                    printf("[hypr-inject] DIAG: dlerror() pointer:      0x%llx\n", (unsigned long long)dlerror_ptr);
                } else if (dlopen_handle == 0 && d[4] == 0xDEAD0003) {
                    printf("[hypr-inject] DIAG: dlerror() returned NULL (no error message recorded)\n");
                }

                // Read dlerror string copied to diagnostic page
                {
                    vm_offset_t str_data = 0;
                    mach_msg_type_number_t str_cnt = 0;
                    kern_return_t str_kr = mach_vm_read(task_port, remote_diag + 0x20, 256, &str_data, &str_cnt);
                    if (str_kr == KERN_SUCCESS && str_cnt > 0) {
                        char *str = (char *)str_data;
                        str[str_cnt - 1] = '\0';
                        if (str[0] != '\0') {
                            printf("[hypr-inject] DIAG: dlerror() message:      \"%s\"\n", str);
                        }
                        mach_vm_deallocate(mach_task_self(), str_data, str_cnt);
                    }
                }

                printf("[hypr-inject] DIAG: Post-dlopen marker:    0x%08x %s\n",
                       d[4], d[4] == 0xDEAD0003 ? "(dlopen completed)" : "(dlopen did NOT complete)");
                mach_vm_deallocate(mach_task_self(), data, cnt);
            } else {
                printf("[hypr-inject] DIAG: Could not read diagnostic page (kr=%d)\n", kr);
            }
        }

        /* 1. Read back the path string at code_addr + CODE_PATH_OFFSET */
        {
            mach_vm_size_t sz = 256;
            vm_offset_t data = 0;
            mach_msg_type_number_t cnt = 0;
            kern_return_t kr = mach_vm_read(task_port, code_addr + CODE_PATH_OFFSET, sz, &data, &cnt);
            if (kr == KERN_SUCCESS && cnt > 0) {
                printf("[hypr-inject] POST-MORTEM: Remote path string: \"%.200s\"\n", (char *)data);
                mach_vm_deallocate(mach_task_self(), data, cnt);
            } else {
                printf("[hypr-inject] POST-MORTEM: Could not read remote path (kr=%d)\n", kr);
            }
        }

        /* 2. Read back the dlopen function pointer at code_addr + CODE_DLOPEN_OFFSET */
        {
            vm_offset_t data = 0;
            mach_msg_type_number_t cnt = 0;
            kern_return_t kr = mach_vm_read(task_port, code_addr + CODE_DLOPEN_OFFSET, 8, &data, &cnt);
            if (kr == KERN_SUCCESS && cnt >= 8) {
                uint64_t remote_dlopen = *(uint64_t *)data;
                printf("[hypr-inject] POST-MORTEM: Remote dlopen ptr: 0x%llx\n", remote_dlopen);
                mach_vm_deallocate(mach_task_self(), data, cnt);
            }
        }

        /* 2b. Read back the diagnostic page pointer at code_addr + CODE_DIAG_OFFSET */
        {
            vm_offset_t data = 0;
            mach_msg_type_number_t cnt = 0;
            kern_return_t kr = mach_vm_read(task_port, code_addr + CODE_DIAG_OFFSET, 8, &data, &cnt);
            if (kr == KERN_SUCCESS && cnt >= 8) {
                uint64_t remote_diag_slot = *(uint64_t *)data;
                printf("[hypr-inject] POST-MORTEM: Remote diag slot ptr: 0x%llx\n", remote_diag_slot);
                mach_vm_deallocate(mach_task_self(), data, cnt);
            }
        }

        /* 2c. Read back the dlerror function pointer at code_addr + CODE_DLERROR_OFFSET */
        {
            vm_offset_t data = 0;
            mach_msg_type_number_t cnt = 0;
            kern_return_t kr = mach_vm_read(task_port, code_addr + CODE_DLERROR_OFFSET, 8, &data, &cnt);
            if (kr == KERN_SUCCESS && cnt >= 8) {
                uint64_t remote_dlerror_slot = *(uint64_t *)data;
                printf("[hypr-inject] POST-MORTEM: Remote dlerror ptr: 0x%llx\n", remote_dlerror_slot);
                mach_vm_deallocate(mach_task_self(), data, cnt);
            }
        }

        /* 3. Read back the pcfmt function pointer at code_addr + CODE_PCFMT_OFFSET */
        {
            vm_offset_t data = 0;
            mach_msg_type_number_t cnt = 0;
            kern_return_t kr = mach_vm_read(task_port, code_addr + CODE_PCFMT_OFFSET, 8, &data, &cnt);
            if (kr == KERN_SUCCESS && cnt >= 8) {
                uint64_t remote_pcfmt = *(uint64_t *)data;
                printf("[hypr-inject] POST-MORTEM: Remote pcfmt ptr: 0x%llx\n", remote_pcfmt);
                mach_vm_deallocate(mach_task_self(), data, cnt);
            }
        }

        /* 4. Read the first 16 bytes of Stage 2 at code_addr + 0x60 */
        {
            vm_offset_t data = 0;
            mach_msg_type_number_t cnt = 0;
            kern_return_t kr = mach_vm_read(task_port, code_addr + 0x60, 16, &data, &cnt);
            if (kr == KERN_SUCCESS && cnt >= 16) {
                uint8_t *bytes = (uint8_t *)data;
                printf("[hypr-inject] POST-MORTEM: Stage 2 first 16 bytes: ");
                for (int i = 0; i < 16; i++) printf("%02x ", bytes[i]);
                printf("\n");
                // Check if first instruction is NOP (1f 20 03 d5)
                if (bytes[0]==0x1f && bytes[1]==0x20 && bytes[2]==0x03 && bytes[3]==0xd5) {
                    printf("[hypr-inject] POST-MORTEM: Stage 2 entry is NOP (RC4 fix confirmed in remote)\n");
                } else {
                    printf("[hypr-inject] POST-MORTEM: Stage 2 entry is NOT NOP! Bytes: %02x%02x%02x%02x\n", bytes[0],bytes[1],bytes[2],bytes[3]);
                }
                mach_vm_deallocate(mach_task_self(), data, cnt);
            }
        }

        /* 5. Read the Stage 1 marker area (first 64 bytes) */
        {
            // The marker is written at a specific location by Stage 1.
            // Read the first 64 bytes of the code page to see marker + surrounding state
            vm_offset_t data = 0;
            mach_msg_type_number_t cnt = 0;
            kern_return_t kr = mach_vm_read(task_port, code_addr, 64, &data, &cnt);
            if (kr == KERN_SUCCESS && cnt >= 64) {
                uint8_t *bytes = (uint8_t *)data;
                printf("[hypr-inject] POST-MORTEM: Code page first 64 bytes:\n");
                for (int row = 0; row < 4; row++) {
                    printf("  +0x%02x: ", row * 16);
                    for (int i = 0; i < 16; i++) printf("%02x ", bytes[row*16 + i]);
                    printf("\n");
                }
                mach_vm_deallocate(mach_task_self(), data, cnt);
            }
        }


        /* Note: Former Stage 2 result slot at code_addr + 0x4C was broken (read static
         * instructions from Stage 1). Diagnostic info is captured directly from Stage 1
         * registers (x20=pcfmt return value, x21=pthread_t) during thread polling above. */
        /* 6. Check how many threads WindowServer has after the timeout */
        {
            thread_act_array_t threads;
            mach_msg_type_number_t thread_count = 0;
            kern_return_t kr = task_threads(task_port, &threads, &thread_count);
            if (kr == KERN_SUCCESS) {
                printf("[hypr-inject] POST-MORTEM: Thread count now: %u\n", thread_count);

                // Check each thread's PC to find our injected threads
                for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
                    arm_thread_state64_t state;
                    mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
                    kern_return_t tkr = thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&state, &state_count);
                    if (tkr == KERN_SUCCESS) {
                        uint64_t pc = arm_thread_state64_get_pc(state);
                        uint64_t lr = arm_thread_state64_get_lr(state);
                        // Check if this thread's PC is in our code page or related area
                        // code_addr should be accessible here — check the variable name used in the function
                        if (pc >= code_addr && pc < code_addr + 0x1000) {
                            printf("[hypr-inject] POST-MORTEM: Thread %u is in our code page! PC=0x%llx (offset +0x%llx) LR=0x%llx\n", 
                                   i, pc, pc - code_addr, lr);
                        } else if (pc >= stack_addr && pc < stack_addr + 0x4000) {
                            printf("[hypr-inject] POST-MORTEM: Thread %u is in our stack page! PC=0x%llx LR=0x%llx\n", i, pc, lr);
                        }
                        // Also flag any thread near dlopen or pcfmt addresses
                        uint64_t remote_dlopen = 0, remote_pcfmt = 0, remote_dlerror = 0;
                        // Read these from the code page slots
                        vm_offset_t ptr_data = 0;
                        mach_msg_type_number_t ptr_cnt = 0;
                        if (mach_vm_read(task_port, code_addr + CODE_DLOPEN_OFFSET, 8, &ptr_data, &ptr_cnt) == KERN_SUCCESS && ptr_cnt >= 8) {
                            remote_dlopen = *(uint64_t *)ptr_data;
                            mach_vm_deallocate(mach_task_self(), ptr_data, ptr_cnt);
                        }
                        if (mach_vm_read(task_port, code_addr + CODE_PCFMT_OFFSET, 8, &ptr_data, &ptr_cnt) == KERN_SUCCESS && ptr_cnt >= 8) {
                            remote_pcfmt = *(uint64_t *)ptr_data;
                            mach_vm_deallocate(mach_task_self(), ptr_data, ptr_cnt);
                        }
                        if (mach_vm_read(task_port, code_addr + CODE_DLERROR_OFFSET, 8, &ptr_data, &ptr_cnt) == KERN_SUCCESS && ptr_cnt >= 8) {
                            remote_dlerror = *(uint64_t *)ptr_data;
                            mach_vm_deallocate(mach_task_self(), ptr_data, ptr_cnt);
                        }
                        // Check if thread is anywhere near interesting addresses
                        if (remote_dlopen && pc >= (remote_dlopen & ~0xFFFULL) && pc < ((remote_dlopen & ~0xFFFULL) + 0x10000)) {
                            printf("[hypr-inject] POST-MORTEM: Thread %u PC=0x%llx is near dlopen (0x%llx)! Possibly blocked in dlopen.\n",
                                   i, pc, remote_dlopen);
                        }
                        if (remote_dlerror && pc >= (remote_dlerror & ~0xFFFULL) && pc < ((remote_dlerror & ~0xFFFULL) + 0x10000)) {
                            printf("[hypr-inject] POST-MORTEM: Thread %u PC=0x%llx is near dlerror (0x%llx)! Possibly blocked in dlerror.\n",
                                   i, pc, remote_dlerror);
                        }
                        if (remote_pcfmt && pc >= (remote_pcfmt & ~0xFFFULL) && pc < ((remote_pcfmt & ~0xFFFULL) + 0x10000)) {
                            printf("[hypr-inject] POST-MORTEM: Thread %u PC=0x%llx is near pcfmt (0x%llx)! Possibly blocked in pcfmt.\n",
                                   i, pc, remote_pcfmt);
                        }
                    }
                    mach_port_deallocate(mach_task_self(), threads[i]);
                }
                vm_deallocate(mach_task_self(), (vm_address_t)threads, thread_count * sizeof(thread_act_t));
            }
        }
    }

    /* Intentionally leak remote pages */
    mach_port_deallocate(mach_task_self(), task);
    return hook_ready ? 0 : -1;

fail:
    if (remote_code)  mach_vm_deallocate(task, remote_code, 4096);
    if (remote_stack) mach_vm_deallocate(task, remote_stack, stack_size);
    if (remote_diag)  mach_vm_deallocate(task, remote_diag, 4096);
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

    // Pre-flight: check if dylib path is accessible by WindowServer (uid 88)
    {
        struct stat st;
        if (stat(dylib_path, &st) == 0) {
            printf("[hypr-inject] Dylib permissions: mode=%04o uid=%d gid=%d\n", st.st_mode & 07777, st.st_uid, st.st_gid);
        } else {
            printf("[hypr-inject] WARNING: cannot stat dylib: %s\n", strerror(errno));
        }

        // Check each path component for world-traversal
        char path_copy[PATH_MAX];
        strlcpy(path_copy, dylib_path, sizeof(path_copy));
        char *p = path_copy;
        while (*p) {
            char *slash = strchr(p + 1, '/');
            if (!slash) break;
            *slash = '\0';
            struct stat dir_st;
            if (stat(path_copy, &dir_st) == 0) {
                if (!(dir_st.st_mode & S_IXOTH)) {
                    printf("[hypr-inject] WARNING: directory '%s' is NOT world-traversable (mode=%04o). WindowServer (uid 88) cannot access the dylib!\n", path_copy, dir_st.st_mode & 07777);
                }
            }
            *slash = '/';
            p = slash;
        }
    }

    if (access("/tmp/hyprmac.safemode", F_OK) == 0) {
        printf("[hypr-inject] WARNING: /tmp/hyprmac.safemode exists! The hook will abort on load. Remove it first.\n");
    }

    {
        struct stat sock_st;
        if (stat("/tmp/hyprmac-server.sock", &sock_st) == 0) {
            printf("[hypr-inject] NOTE: existing socket /tmp/hyprmac-server.sock (uid=%d). Will be replaced by hook.\n", sock_st.st_uid);
        }
    }

    if (stage_dylib_for_windowserver(dylib_path, STAGED_DYLIB_PATH) != 0) {
        LOG_ERR("Failed to stage dylib to %s", STAGED_DYLIB_PATH);
        return 1;
    }
    dylib_path = STAGED_DYLIB_PATH;

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

