#include "../shared/protocol.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/event.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include <errno.h>
#include <os/lock.h>
#include <signal.h>
#include <setjmp.h>
#include <stdbool.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <bootstrap.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

#define HYPR_MAX_CLIENTS 32
#define CLIENT_READ_BUF_SIZE 4096
#define CLIENT_WRITE_BUF_SIZE 4096
#define HYPR_MANAGED_WINDOWS_CAPACITY 4096
#define HYPR_MAX_DISPLAYS 8
#define HYPR_TIMER_SPACE_DEBOUNCE 1001
#define HYPR_TIMER_DISPLAY_DEBOUNCE 1002
#define HYPR_TIMER_AUTH_BASE 2000

#ifndef kCGDisplayBeginConfigurationFlag
#define kCGDisplayBeginConfigurationFlag (1 << 0)
#endif
#ifndef kCGDisplayMovedFlag
#define kCGDisplayMovedFlag (1 << 1)
#endif
#ifndef kCGDisplaySetMainFlag
#define kCGDisplaySetMainFlag (1 << 2)
#endif
#ifndef kCGDisplaySetModeFlag
#define kCGDisplaySetModeFlag (1 << 3)
#endif
#ifndef kCGDisplayAddFlag
#define kCGDisplayAddFlag (1 << 4)
#endif
#ifndef kCGDisplayRemoveFlag
#define kCGDisplayRemoveFlag (1 << 5)
#endif
#ifndef kCGDisplayEnabledFlag
#define kCGDisplayEnabledFlag (1 << 8)
#endif
#ifndef kCGDisplayDisabledFlag
#define kCGDisplayDisabledFlag (1 << 9)
#endif

#pragma pack(push, 1)
typedef struct {
    uint32_t window_id;
} HyprPayloadFocus;
#pragma pack(pop)

/* ---- Logging & Rotation (Task 1.8) --------------------------------------- */

static os_unfair_lock g_log_lock = OS_UNFAIR_LOCK_INIT;

static void hypr_log(const char *fmt, ...) {
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    os_unfair_lock_lock(&g_log_lock);
    FILE *f = fopen(HYPR_LOG_PATH, "a");
    if (f) {
        int fd = fileno(f);
        struct stat st;
        if (fstat(fd, &st) == 0 && st.st_size > HYPR_LOG_MAX_SIZE) {
            fclose(f);
            rename(HYPR_LOG_PATH, HYPR_LOG_PATH_ROTATED);
            f = fopen(HYPR_LOG_PATH, "a");
        }
        if (f) {
            fprintf(f, "%s\n", buf);
            fflush(f);
            fclose(f);
        }
    }
    os_unfair_lock_unlock(&g_log_lock);
}

/* ---- Private Types & Symbol Function Signatures (Task 3.1) --------------- */

typedef int32_t CGSConnectionID;
typedef int32_t CGError;

typedef CGSConnectionID (*fn_SLSMainConnectionID)(void);
typedef CGError (*fn_SLSGetWindowCount)(CGSConnectionID cid, CGSConnectionID targetCID, int32_t *count);
typedef CGError (*fn_SLSGetWindowList)(CGSConnectionID cid, CGSConnectionID targetCID, int32_t capacity, uint32_t *list, int32_t *actualCount);
typedef CGError (*fn_SLSSetWindowProperty)(CGSConnectionID cid, uint32_t wid, CFStringRef key, CFTypeRef value);
typedef CGError (*fn_SLSSetWindowTags)(CGSConnectionID cid, uint32_t wid, const uint32_t *tags, int tagSize);
typedef CGError (*fn_SLSClearWindowTags)(CGSConnectionID cid, uint32_t wid, const uint32_t *tags, int tagSize);
typedef CGError (*fn_SLSGetWindowTags)(CGSConnectionID cid, uint32_t wid, uint32_t *tags, int tagSize);
typedef CGError (*fn_SLSMoveWindow)(CGSConnectionID cid, uint32_t wid, const CGPoint *point);
typedef CGError (*fn_SLSFlushSurface)(CGSConnectionID cid, uint32_t wid, uint32_t flags);
typedef CGError (*fn_SLSGetWindowBounds)(CGSConnectionID cid, uint32_t wid, CGRect *outRect);
typedef CGError (*fn_SLSSetWindowCornerMask)(CGSConnectionID cid, CFTypeRef mask, uint32_t wid, float d0, float d1, float d2, float d3);
typedef CGError (*fn_SLSWindowSetCornerRadius)(CGSConnectionID cid, uint32_t wid, float radius);
typedef CGError (*fn_SLSSetWindowShadowParameters)(CGSConnectionID cid, uint32_t wid, float standard_deviation, float density, int offset_x, int offset_y);
typedef CGError (*fn_SLSNewWindow)(CGSConnectionID cid, int type, float x, float y, void *shape, uint32_t *outWid);
typedef void *fn_generic;

typedef uint32_t CGDisplayChangeSummaryFlags;
typedef void (*CGDisplayReconfigurationCallBack)(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo);
typedef CGError (*fn_CGDisplayRegisterReconfigurationCallback)(CGDisplayReconfigurationCallBack proc, void *userInfo);
typedef CGError (*fn_CGDisplayRemoveReconfigurationCallback)(CGDisplayReconfigurationCallBack proc, void *userInfo);
typedef CGError (*fn_CGGetActiveDisplayList)(uint32_t maxDisplays, CGDirectDisplayID *activeDisplays, uint32_t *displayCount);
typedef CGRect (*fn_CGDisplayBounds)(CGDirectDisplayID display);
typedef CGDisplayModeRef (*fn_CGDisplayCopyDisplayMode)(CGDirectDisplayID display);
typedef double (*fn_CGDisplayModeGetRefreshRate)(CGDisplayModeRef mode);
typedef void (*fn_CGDisplayModeRelease)(CGDisplayModeRef mode);
typedef CGDirectDisplayID (*fn_CGMainDisplayID)(void);

typedef uint64_t (*fn_SLSGetActiveSpace)(CGSConnectionID cid);
typedef int32_t (*fn_SLSSpaceGetType)(CGSConnectionID cid, uint64_t space_id);
typedef CFArrayRef (*fn_SLSCopyManagedDisplaySpaces)(CGSConnectionID cid);
typedef void (*CGSConnectionNotifyProc)(int data1, int data2, int data3, void *userParameter);
typedef CGError (*fn_CGSRegisterConnectionNotifyProc)(CGSConnectionID cid, CGSConnectionNotifyProc proc, int event, void *userParameter);
typedef void (*CGSNotifyProcPtr)(int type, void *data, size_t dataLength, void *userData);
typedef CGError (*fn_CGSRegisterNotifyProc)(CGSNotifyProcPtr proc, int type, void *userData);

struct hypr_symbols {
    bool resolved;
    fn_SLSMainConnectionID   MainConnectionID;
    fn_SLSGetWindowCount     GetWindowCount;
    fn_SLSGetWindowList      GetWindowList;
    fn_SLSSetWindowProperty  SetWindowProperty;
    fn_generic               SetWindowCornerRadius;
    const char              *CornerRadiusSymbolName;
    fn_generic               SetWindowShadowProperties;
    const char              *ShadowPropertiesSymbolName;
    fn_SLSMoveWindow         MoveWindow;
    fn_SLSFlushSurface       FlushSurface;
    fn_SLSGetWindowBounds    GetWindowBounds;
    fn_SLSSetWindowTags      SetWindowTags;
    fn_SLSClearWindowTags    ClearWindowTags;
    fn_SLSGetWindowTags      GetWindowTags;
    fn_SLSNewWindow          NewWindow;
    // Display APIs (Task 4.9)
    fn_CGDisplayRegisterReconfigurationCallback DisplayRegisterReconfigurationCallback;
    fn_CGDisplayRemoveReconfigurationCallback   DisplayRemoveReconfigurationCallback;
    fn_CGGetActiveDisplayList                   GetActiveDisplayList;
    fn_CGDisplayBounds                          DisplayBounds;
    fn_CGDisplayCopyDisplayMode                 DisplayCopyDisplayMode;
    fn_CGDisplayModeGetRefreshRate              DisplayModeGetRefreshRate;
    fn_CGDisplayModeRelease                     DisplayModeRelease;
    fn_CGMainDisplayID                          MainDisplayID;
    // Space & Notification APIs (Task 4.10)
    fn_SLSGetActiveSpace                        GetActiveSpace;
    fn_SLSSpaceGetType                          SpaceGetType;
    fn_SLSCopyManagedDisplaySpaces              CopyManagedDisplaySpaces;
    fn_CGSRegisterConnectionNotifyProc          RegisterConnectionNotifyProc;
    fn_CGSRegisterNotifyProc                    RegisterNotifyProc;
};

static struct hypr_symbols g_symbols = {0};

/* Static function pointer globals */
static fn_SLSMainConnectionID   g_SLSMainConnectionID = NULL;
static fn_SLSGetWindowCount     g_SLSGetWindowCount = NULL;
static fn_SLSGetWindowList      g_SLSGetWindowList = NULL;
static fn_SLSSetWindowProperty  g_SLSSetWindowProperty = NULL;
static fn_generic               g_SLSSetWindowCornerRadius = NULL;
static const char              *g_corner_sym_name = NULL;
static fn_generic               g_SLSSetWindowShadowProperties = NULL;
static const char              *g_shadow_sym_name = NULL;
static fn_SLSMoveWindow         g_SLSMoveWindow = NULL;
static fn_SLSFlushSurface       g_SLSFlushSurface = NULL;
static fn_SLSGetWindowBounds    g_SLSGetWindowBounds = NULL;
static fn_SLSSetWindowTags      g_SLSSetWindowTags = NULL;
static fn_SLSClearWindowTags    g_SLSClearWindowTags = NULL;
static fn_SLSGetWindowTags      g_SLSGetWindowTags = NULL;
static fn_SLSNewWindow          g_orig_SLSNewWindow = NULL;

static void *safe_resolve_symbol(const char *name);

/* ---- Managed Window Registry & Global Policy State (Tasks 4.6, 4.7) ------ */

typedef struct {
    uint32_t wid;
    bool     active;
    float    corner_radius;
    uint8_t  shadow_enabled;
    uint8_t  titlebar_stripped;
    float    border_width;
    uint32_t color_active;
    uint32_t color_inactive;
    bool     is_focused;
} HyprManagedWindow;

typedef struct {
    uint8_t  auto_square_corners;
    uint8_t  auto_strip_shadow;
    uint8_t  auto_strip_titlebar;
    uint8_t  auto_set_border;
    float    border_width;
    uint32_t border_color_active;
    uint32_t border_color_inactive;
} HyprGlobalPolicyState;

static HyprManagedWindow g_managed_windows[HYPR_MANAGED_WINDOWS_CAPACITY];
static size_t g_managed_window_count = 0;
static os_unfair_lock g_state_lock = OS_UNFAIR_LOCK_INIT;
static mach_port_t g_bootstrap_service_port = MACH_PORT_NULL;
static uint8_t g_auth_token[16] = {0};

/* ---- Multi-Monitor & State Tracking (Tasks 4.9, 4.10) ------------------- */

typedef struct {
    CGDirectDisplayID display_id;
    CGRect            bounds;
    double            refresh_rate;
    bool              active;
    bool              is_promotion;
} HyprDisplayInfo;

static HyprDisplayInfo g_displays[HYPR_MAX_DISPLAYS];
static size_t g_display_count = 0;

static volatile bool g_safe_mode = false;
static bool g_display_callback_registered = false;
static bool g_space_callback_registered = false;
static int g_kq = -1;

static inline bool is_safe_mode_active(void) {
    if (g_safe_mode) return true;
    if (access(HYPR_SAFEMODE_PATH, F_OK) == 0) {
        g_safe_mode = true;
        return true;
    }
    return false;
}

static inline bool rect_intersects(CGRect r1, CGRect r2, CGFloat *out_area) {
    CGFloat x1 = r1.origin.x > r2.origin.x ? r1.origin.x : r2.origin.x;
    CGFloat y1 = r1.origin.y > r2.origin.y ? r1.origin.y : r2.origin.y;
    CGFloat x2 = (r1.origin.x + r1.size.width) < (r2.origin.x + r2.size.width) ?
                 (r1.origin.x + r1.size.width) : (r2.origin.x + r2.size.width);
    CGFloat y2 = (r1.origin.y + r1.size.height) < (r2.origin.y + r2.size.height) ?
                 (r1.origin.y + r1.size.height) : (r2.origin.y + r2.size.height);

    if (x2 > x1 && y2 > y1) {
        if (out_area) *out_area = (x2 - x1) * (y2 - y1);
        return true;
    }
    if (out_area) *out_area = 0.0;
    return false;
}

static HyprGlobalPolicyState g_global_policy = {
    .auto_square_corners = 1,
    .auto_strip_shadow = 1,
    .auto_strip_titlebar = 1,
    .auto_set_border = 1,
    .border_width = 1.0f,
    .border_color_active = 0xFF00AAFF,
    .border_color_inactive = 0xFF444444
};

static inline uint32_t hash_wid(uint32_t wid) {
    return (wid * 2654435761u) & (HYPR_MANAGED_WINDOWS_CAPACITY - 1);
}

static HyprManagedWindow *managed_window_find(uint32_t wid) {
    if (wid == 0) return NULL;
    uint32_t idx = hash_wid(wid);
    for (size_t i = 0; i < HYPR_MANAGED_WINDOWS_CAPACITY; i++) {
        uint32_t slot = (idx + i) & (HYPR_MANAGED_WINDOWS_CAPACITY - 1);
        if (g_managed_windows[slot].active && g_managed_windows[slot].wid == wid) {
            return &g_managed_windows[slot];
        }
        if (!g_managed_windows[slot].active && g_managed_windows[slot].wid == 0) {
            return NULL;
        }
    }
    return NULL;
}

static HyprManagedWindow *managed_window_get_or_create(uint32_t wid) {
    if (wid == 0) return NULL;
    HyprManagedWindow *existing = managed_window_find(wid);
    if (existing) return existing;

    uint32_t idx = hash_wid(wid);
    for (size_t i = 0; i < HYPR_MANAGED_WINDOWS_CAPACITY; i++) {
        uint32_t slot = (idx + i) & (HYPR_MANAGED_WINDOWS_CAPACITY - 1);
        if (!g_managed_windows[slot].active) {
            memset(&g_managed_windows[slot], 0, sizeof(HyprManagedWindow));
            g_managed_windows[slot].wid = wid;
            g_managed_windows[slot].active = true;
            g_managed_window_count++;
            return &g_managed_windows[slot];
        }
    }
    return NULL;
}

static void managed_window_evict(uint32_t wid) {
    HyprManagedWindow *win = managed_window_find(wid);
    if (win && win->active) {
        win->active = false;
        if (g_managed_window_count > 0) {
            g_managed_window_count--;
        }
    }
}

static bool is_window_alive(CGSConnectionID cid, uint32_t wid) {
    if (wid == 0) return false;
    if (g_symbols.GetWindowBounds) {
        CGRect rect;
        memset(&rect, 0, sizeof(rect));
        CGError err = g_symbols.GetWindowBounds(cid, wid, &rect);
        if (err == 0) return true;
    }
    if (g_symbols.GetWindowList) {
        uint32_t wids[256];
        int32_t actual = 0;
        CGError err = g_symbols.GetWindowList(cid, 0, 256, wids, &actual);
        if (err == 0 && actual > 0) {
            for (int32_t i = 0; i < actual; i++) {
                if (wids[i] == wid) return true;
            }
            return false;
        }
    }
    if (!g_symbols.GetWindowBounds && !g_symbols.GetWindowList) {
        return true;
    }
    return false;
}

/* ---- Compositor Surface Invalidation (Task 4.8) -------------------------- */

static void invalidate_window(CGSConnectionID cid, uint32_t wid) {
    if (wid == 0) return;
    if (g_symbols.FlushSurface) {
        g_symbols.FlushSurface(cid, wid, 0);
    }
    if (g_symbols.GetWindowBounds && g_symbols.MoveWindow) {
        CGRect rect;
        memset(&rect, 0, sizeof(rect));
        if (g_symbols.GetWindowBounds(cid, wid, &rect) == 0) {
            g_symbols.MoveWindow(cid, wid, &rect.origin);
        }
    }
}

/* ---- Auto-Decoration of New Windows (Task 4.6) --------------------------- */

static void apply_global_policy_to_window(CGSConnectionID cid, uint32_t wid) {
    if (wid == 0) return;
    if (is_safe_mode_active()) return;

    // When entering or in native fullscreen, skip decoration (REQ-WSP-002)
    if (g_symbols.GetWindowTags) {
        uint32_t tags[2] = {0, 0};
        if (g_symbols.GetWindowTags(cid, wid, tags, 64) == 0) {
            if (tags[0] & (1 << 14)) {
                hypr_log("Window wid=%u is native fullscreen; skipping global policy decoration", wid);
                return;
            }
        }
    }

    os_unfair_lock_lock(&g_state_lock);
    HyprManagedWindow *win = managed_window_get_or_create(wid);
    if (win) {
        win->corner_radius = g_global_policy.auto_square_corners ? 0.0f : 10.0f;
        win->shadow_enabled = g_global_policy.auto_strip_shadow ? 0 : 1;
        win->titlebar_stripped = g_global_policy.auto_strip_titlebar ? 1 : 0;
        if (g_global_policy.auto_set_border) {
            win->border_width = g_global_policy.border_width;
            win->color_active = g_global_policy.border_color_active;
            win->color_inactive = g_global_policy.border_color_inactive;
        } else {
            win->border_width = 0.0f;
            win->color_active = 0;
            win->color_inactive = 0;
        }
        win->is_focused = false;
    }
    uint8_t square = g_global_policy.auto_square_corners;
    uint8_t shadow = g_global_policy.auto_strip_shadow;
    uint8_t titlebar = g_global_policy.auto_strip_titlebar;
    float bwidth = g_global_policy.auto_set_border ? g_global_policy.border_width : 0.0f;
    os_unfair_lock_unlock(&g_state_lock);

    if (square != 0 && g_symbols.SetWindowCornerRadius) {
        if (g_symbols.CornerRadiusSymbolName && strstr(g_symbols.CornerRadiusSymbolName, "Mask")) {
            fn_SLSSetWindowCornerMask fn = (fn_SLSSetWindowCornerMask)g_symbols.SetWindowCornerRadius;
            fn(cid, NULL, wid, 0.0f, 0.0f, 0.0f, 0.0f);
        } else {
            fn_SLSWindowSetCornerRadius fn = (fn_SLSWindowSetCornerRadius)g_symbols.SetWindowCornerRadius;
            fn(cid, wid, 0.0f);
        }
    }

    if (shadow != 0) {
        uint32_t tags[2] = { 1 << 3, 0 };
        if (g_symbols.SetWindowTags) {
            g_symbols.SetWindowTags(cid, wid, tags, 64);
        }
        if (g_symbols.SetWindowShadowProperties) {
            fn_SLSSetWindowShadowParameters fn = (fn_SLSSetWindowShadowParameters)g_symbols.SetWindowShadowProperties;
            fn(cid, wid, 0.0f, 0.0f, 0, 0);
        }
    }

    if (titlebar != 0) {
        uint32_t tags[2] = { (1 << 9) | (1 << 18), 0 };
        if (g_symbols.SetWindowTags) {
            g_symbols.SetWindowTags(cid, wid, tags, 64);
        }
    }

    invalidate_window(cid, wid);
    hypr_log("Auto-decorated newly created window wid=%u (square=%u, strip_shadow=%u, strip_titlebar=%u, border_width=%.1f)",
             wid, square, shadow, titlebar, bwidth);
}

/* ---- Window Decoration Re-application & Helpers -------------------------- */

static void reapply_decorations_to_window(CGSConnectionID cid, uint32_t wid) {
    if (wid == 0) return;
    if (is_safe_mode_active()) return;

    // Detect fullscreen enter/exit (window tag bit for fullscreen: 1 << 14)
    bool is_fullscreen = false;
    bool is_sticky = false;
    if (g_symbols.GetWindowTags) {
        uint32_t tags[2] = {0, 0};
        if (g_symbols.GetWindowTags(cid, wid, tags, 64) == 0) {
            if (tags[0] & (1 << 14)) {
                is_fullscreen = true;
            }
            if (tags[0] & (1 << 11)) {
                is_sticky = true;
            }
        }
    }

    if (is_fullscreen) {
        hypr_log("Window wid=%u is native fullscreen; skipping decoration", wid);
        return;
    }

    os_unfair_lock_lock(&g_state_lock);
    HyprManagedWindow *win = managed_window_find(wid);
    if (!win || !win->active) {
        os_unfair_lock_unlock(&g_state_lock);
        return;
    }

    float radius = win->corner_radius;
    uint8_t shadow = win->shadow_enabled;
    uint8_t titlebar = win->titlebar_stripped;
    os_unfair_lock_unlock(&g_state_lock);

    if (radius == 0.0f && g_symbols.SetWindowCornerRadius) {
        if (g_symbols.CornerRadiusSymbolName && strstr(g_symbols.CornerRadiusSymbolName, "Mask")) {
            fn_SLSSetWindowCornerMask fn = (fn_SLSSetWindowCornerMask)g_symbols.SetWindowCornerRadius;
            fn(cid, NULL, wid, 0.0f, 0.0f, 0.0f, 0.0f);
        } else {
            fn_SLSWindowSetCornerRadius fn = (fn_SLSWindowSetCornerRadius)g_symbols.SetWindowCornerRadius;
            fn(cid, wid, 0.0f);
        }
    }

    if (shadow == 0) {
        uint32_t tags[2] = { 1 << 3, 0 };
        if (g_symbols.SetWindowTags) {
            g_symbols.SetWindowTags(cid, wid, tags, 64);
        }
        if (g_symbols.SetWindowShadowProperties) {
            fn_SLSSetWindowShadowParameters fn = (fn_SLSSetWindowShadowParameters)g_symbols.SetWindowShadowProperties;
            fn(cid, wid, 0.0f, 0.0f, 0, 0);
        }
    }

    if (titlebar != 0) {
        uint32_t tags[2] = { (1 << 9) | (1 << 18), 0 };
        if (g_symbols.SetWindowTags) {
            g_symbols.SetWindowTags(cid, wid, tags, 64);
        }
    }

    invalidate_window(cid, wid);
    if (is_sticky) {
        hypr_log("Re-applied decorations to sticky window wid=%u (spans multiple spaces)", wid);
    }
}

/* ---- Multi-Monitor & Display Reconfiguration (Task 4.9) ------------------ */

static CGDirectDisplayID find_display_for_bounds(CGRect bounds) {
    os_unfair_lock_lock(&g_state_lock);
    CGDirectDisplayID best_id = 0;
    CGFloat max_area = 0.0;

    for (size_t i = 0; i < g_display_count; i++) {
        if (!g_displays[i].active) continue;
        CGFloat area = 0.0;
        if (rect_intersects(bounds, g_displays[i].bounds, &area)) {
            if (area > max_area) {
                max_area = area;
                best_id = g_displays[i].display_id;
            }
        }
    }
    if (best_id == 0 && g_display_count > 0) {
        best_id = g_displays[0].display_id;
    }
    os_unfair_lock_unlock(&g_state_lock);
    return best_id;
}

static void update_display_topology(void) {
    if (is_safe_mode_active()) return;
    if (!g_symbols.resolved) return;

    CGDirectDisplayID active_displays[HYPR_MAX_DISPLAYS];
    uint32_t count = 0;
    CGError err = -1;

    if (g_symbols.GetActiveDisplayList) {
        err = g_symbols.GetActiveDisplayList(HYPR_MAX_DISPLAYS, active_displays, &count);
    }

    if (err != 0 || count == 0) {
        if (g_symbols.MainDisplayID) {
            active_displays[0] = g_symbols.MainDisplayID();
            count = 1;
        } else {
            active_displays[0] = 1;
            count = 1;
        }
    }

    if (count > HYPR_MAX_DISPLAYS) count = HYPR_MAX_DISPLAYS;

    os_unfair_lock_lock(&g_state_lock);
    memset(g_displays, 0, sizeof(g_displays));
    g_display_count = count;

    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID did = active_displays[i];
        g_displays[i].display_id = did;
        g_displays[i].active = true;

        if (g_symbols.DisplayBounds) {
            g_displays[i].bounds = g_symbols.DisplayBounds(did);
        }

        double rate = 0.0;
        if (g_symbols.DisplayCopyDisplayMode && g_symbols.DisplayModeGetRefreshRate) {
            CGDisplayModeRef mode = g_symbols.DisplayCopyDisplayMode(did);
            if (mode) {
                rate = g_symbols.DisplayModeGetRefreshRate(mode);
                if (g_symbols.DisplayModeRelease) {
                    g_symbols.DisplayModeRelease(mode);
                }
            }
        }
        g_displays[i].refresh_rate = rate;
        g_displays[i].is_promotion = (rate >= 119.0);

        if (rate > 0.0) {
            hypr_log("Display [%u/%u] ID 0x%x: bounds=(%.0f, %.0f, %.0f, %.0f), refresh=%.1f Hz%s",
                     i + 1, count, did,
                     g_displays[i].bounds.origin.x, g_displays[i].bounds.origin.y,
                     g_displays[i].bounds.size.width, g_displays[i].bounds.size.height,
                     rate,
                     g_displays[i].is_promotion ? " [ProMotion]" : "");
        } else {
            hypr_log("Display [%u/%u] ID 0x%x: bounds=(%.0f, %.0f, %.0f, %.0f), refresh=auto/variable",
                     i + 1, count, did,
                     g_displays[i].bounds.origin.x, g_displays[i].bounds.origin.y,
                     g_displays[i].bounds.size.width, g_displays[i].bounds.size.height);
        }
    }
    os_unfair_lock_unlock(&g_state_lock);
}

static void handle_display_reconfiguration_settled(void) {
    if (is_safe_mode_active()) return;
    if (!g_symbols.resolved || !g_symbols.MainConnectionID) return;

    hypr_log("Display reconfiguration settled, updating topology and managed windows");

    update_display_topology();

    CGSConnectionID cid = g_symbols.MainConnectionID();

    os_unfair_lock_lock(&g_state_lock);
    uint32_t active_wids[HYPR_MANAGED_WINDOWS_CAPACITY];
    size_t count = 0;
    for (size_t i = 0; i < HYPR_MANAGED_WINDOWS_CAPACITY; i++) {
        if (g_managed_windows[i].active && g_managed_windows[i].wid != 0) {
            active_wids[count++] = g_managed_windows[i].wid;
        }
    }
    os_unfair_lock_unlock(&g_state_lock);

    for (size_t i = 0; i < count; i++) {
        uint32_t wid = active_wids[i];

        // Display disconnect safety: probe with is_window_alive (uses SLSGetWindowBounds)
        if (!is_window_alive(cid, wid)) {
            os_unfair_lock_lock(&g_state_lock);
            managed_window_evict(wid);
            os_unfair_lock_unlock(&g_state_lock);
            hypr_log("Display disconnect safety: window wid=%u no longer valid, evicted", wid);
            continue;
        }

        CGRect bounds = {0};
        if (g_symbols.GetWindowBounds) {
            g_symbols.GetWindowBounds(cid, wid, &bounds);
        }
        CGDirectDisplayID win_display = find_display_for_bounds(bounds);
        hypr_log("Display reconfiguration: window wid=%u on display 0x%x (bounds: %.0f, %.0f, %.0f, %.0f)",
                 wid, win_display, bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);

        reapply_decorations_to_window(cid, wid);
    }
}

static void on_display_reconfiguration(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo) {
    (void)userInfo;
    if (is_safe_mode_active()) return;

    bool is_begin = (flags & kCGDisplayBeginConfigurationFlag) != 0;
    bool is_add = (flags & kCGDisplayAddFlag) != 0;
    bool is_remove = (flags & kCGDisplayRemoveFlag) != 0;
    bool is_moved = (flags & kCGDisplayMovedFlag) != 0;
    bool is_mode = (flags & kCGDisplaySetModeFlag) != 0;

    hypr_log("Display reconfiguration event: id=0x%x flags=0x%08x (begin=%d, add=%d, remove=%d, moved=%d, mode=%d)",
             display, flags, is_begin, is_add, is_remove, is_moved, is_mode);

    if (is_begin) {
        return;
    }

    if (g_kq >= 0) {
        struct kevent ev;
        EV_SET(&ev, HYPR_TIMER_DISPLAY_DEBOUNCE, EVFILT_TIMER, EV_ADD | EV_ENABLE | EV_ONESHOT, 0, 150, NULL);
        kevent(g_kq, &ev, 1, NULL, 0, NULL);
    } else {
        handle_display_reconfiguration_settled();
    }
}

/* ---- Spaces, Mission Control & Fullscreen Transitions (Task 4.10) -------- */

static void handle_space_transition_settled(void) {
    if (is_safe_mode_active()) return;
    if (!g_symbols.resolved || !g_symbols.MainConnectionID) return;

    CGSConnectionID cid = g_symbols.MainConnectionID();

    uint64_t active_space = 0;
    int32_t space_type = 0;
    if (g_symbols.GetActiveSpace) {
        active_space = g_symbols.GetActiveSpace(cid);
        if (g_symbols.SpaceGetType) {
            space_type = g_symbols.SpaceGetType(cid, active_space);
        }
    }
    hypr_log("Space transition settled: active space=%llu (type=%d)", (unsigned long long)active_space, space_type);

    // Mission Control / Stage Manager awareness (REQ-WSP-001):
    // Type 4 is system space / Mission Control. During Mission Control animation or active view,
    // avoid applying decorations to prevent clipping distortion on scaled windows.
    if (space_type == 4) {
        hypr_log("Mission Control is active (space type=4); deferring window decoration");
        return;
    }

    // 1. Re-apply decorations to all existing managed windows
    os_unfair_lock_lock(&g_state_lock);
    uint32_t active_wids[HYPR_MANAGED_WINDOWS_CAPACITY];
    size_t count = 0;
    for (size_t i = 0; i < HYPR_MANAGED_WINDOWS_CAPACITY; i++) {
        if (g_managed_windows[i].active && g_managed_windows[i].wid != 0) {
            active_wids[count++] = g_managed_windows[i].wid;
        }
    }
    os_unfair_lock_unlock(&g_state_lock);

    for (size_t i = 0; i < count; i++) {
        uint32_t wid = active_wids[i];
        if (!is_window_alive(cid, wid)) {
            os_unfair_lock_lock(&g_state_lock);
            managed_window_evict(wid);
            os_unfair_lock_unlock(&g_state_lock);
            continue;
        }
        reapply_decorations_to_window(cid, wid);
    }

    // 2. Re-query visible windows on current space and auto-decorate newly visible windows
    if (g_symbols.GetWindowList) {
        uint32_t wids[256];
        int32_t actual = 0;
        CGError err = g_symbols.GetWindowList(cid, 0, 256, wids, &actual);
        if (err == 0 && actual > 0) {
            for (int32_t i = 0; i < actual; i++) {
                uint32_t wid = wids[i];
                if (wid == 0) continue;

                os_unfair_lock_lock(&g_state_lock);
                HyprManagedWindow *existing = managed_window_find(wid);
                bool already_managed = (existing && existing->active);
                os_unfair_lock_unlock(&g_state_lock);

                if (already_managed) continue;

                if (g_symbols.GetWindowTags) {
                    uint32_t tags[2] = {0, 0};
                    if (g_symbols.GetWindowTags(cid, wid, tags, 64) == 0) {
                        if (tags[0] & (1 << 14)) continue; // skip fullscreen windows
                    }
                }

                if (g_symbols.GetWindowBounds) {
                    CGRect r = {0};
                    if (g_symbols.GetWindowBounds(cid, wid, &r) == 0) {
                        if (r.size.width <= 50.0f || r.size.height <= 50.0f) {
                            continue; // skip tiny or invisible utility windows
                        }
                    }
                }

                apply_global_policy_to_window(cid, wid);
                hypr_log("Auto-decorated newly visible window wid=%u on space %llu",
                         wid, (unsigned long long)active_space);
            }
        }
    }
}

static void trigger_space_transition(const char *source, int event_type) {
    if (is_safe_mode_active()) return;

    hypr_log("Space transition event from %s (type=%d)", source, event_type);

    // Debounce rapid transitions using kqueue timer (e.g. swipe gestures)
    if (g_kq >= 0) {
        struct kevent ev;
        EV_SET(&ev, HYPR_TIMER_SPACE_DEBOUNCE, EVFILT_TIMER, EV_ADD | EV_ENABLE | EV_ONESHOT, 0, 300, NULL);
        kevent(g_kq, &ev, 1, NULL, 0, NULL);
    } else {
        handle_space_transition_settled();
    }
}

static void on_connection_notify(int data1, int data2, int data3, void *userParameter) {
    (void)data3;
    (void)userParameter;
    if (is_safe_mode_active()) return;

    if (data1 == 106) {
        hypr_log("Event CGSClientEnterFullscreen: wid=%d", data2);
        trigger_space_transition("CGSClientEnterFullscreen", 106);
    } else if (data1 == 107) {
        hypr_log("Event CGSClientExitFullscreen: wid=%d", data2);
        trigger_space_transition("CGSClientExitFullscreen", 107);
    } else if (data1 == 1401) {
        hypr_log("Event CGSWorkspaceChanged: data2=%d", data2);
        trigger_space_transition("CGSWorkspaceChanged", 1401);
    } else if (data1 == 100) {
        hypr_log("Event CGSScreenResolutionChanged: data2=%d", data2);
        if (g_kq >= 0) {
            struct kevent ev;
            EV_SET(&ev, HYPR_TIMER_DISPLAY_DEBOUNCE, EVFILT_TIMER, EV_ADD | EV_ENABLE | EV_ONESHOT, 0, 150, NULL);
            kevent(g_kq, &ev, 1, NULL, 0, NULL);
        } else {
            handle_display_reconfiguration_settled();
        }
    } else {
        hypr_log("Event CGSConnectionNotify: data1=%d data2=%d", data1, data2);
        trigger_space_transition("CGSConnectionNotify", data1);
    }
}

static void on_cgs_notify(int type, void *data, size_t dataLength, void *userData) {
    (void)data;
    (void)dataLength;
    (void)userData;
    if (is_safe_mode_active()) return;
    hypr_log("Event CGSNotifyProc: type=%d", type);
    trigger_space_transition("CGSNotifyProc", type);
}

static void on_darwin_space_notification(CFNotificationCenterRef center,
                                         void *observer,
                                         CFStringRef name,
                                         const void *object,
                                         CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    if (is_safe_mode_active()) return;
    hypr_log("Darwin notification received: com.apple.spaces.activeSpaceDidChange");
    trigger_space_transition("DarwinNotifyCenter", 0);
}

static void on_distributed_space_notification(CFNotificationCenterRef center,
                                              void *observer,
                                              CFStringRef name,
                                              const void *object,
                                              CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    if (is_safe_mode_active()) return;
    hypr_log("Distributed notification received: com.apple.spaces.activeSpaceDidChange");
    trigger_space_transition("DistributedNotifyCenter", 0);
}

static void register_display_callbacks(void) {
    if (g_display_callback_registered) return;
    if (is_safe_mode_active()) return;

    if (g_symbols.DisplayRegisterReconfigurationCallback) {
        CGError err = g_symbols.DisplayRegisterReconfigurationCallback(on_display_reconfiguration, NULL);
        if (err == 0) {
            g_display_callback_registered = true;
            hypr_log("Display reconfiguration callback registered successfully");
        } else {
            hypr_log("Warning: DisplayRegisterReconfigurationCallback returned err=%d", err);
        }
    } else if (g_symbols.RegisterConnectionNotifyProc && g_symbols.MainConnectionID) {
        CGSConnectionID cid = g_symbols.MainConnectionID();
        CGError err = g_symbols.RegisterConnectionNotifyProc(cid, on_connection_notify, 100, NULL);
        if (err == 0) {
            g_display_callback_registered = true;
            hypr_log("Registered SkyLight connection notify proc for screen resolution change (100)");
        }
    }
}

static void register_space_callbacks(void) {
    if (g_space_callback_registered) return;
    if (is_safe_mode_active()) return;

    bool registered = false;

    // 1. SkyLight Connection Notifications
    if (g_symbols.RegisterConnectionNotifyProc && g_symbols.MainConnectionID) {
        CGSConnectionID cid = g_symbols.MainConnectionID();

        // 1401: CGSWorkspaceChangedEvent
        CGError e1 = g_symbols.RegisterConnectionNotifyProc(cid, on_connection_notify, 1401, NULL);
        // 106: CGSClientEnterFullscreen
        CGError e2 = g_symbols.RegisterConnectionNotifyProc(cid, on_connection_notify, 106, NULL);
        // 107: CGSClientExitFullscreen
        CGError e3 = g_symbols.RegisterConnectionNotifyProc(cid, on_connection_notify, 107, NULL);

        if (e1 == 0 || e2 == 0 || e3 == 0) {
            registered = true;
            hypr_log("Registered SkyLight connection notify procs (1401=%d, 106=%d, 107=%d)", e1, e2, e3);
        }
    }

    if (g_symbols.RegisterNotifyProc) {
        CGError e = g_symbols.RegisterNotifyProc(on_cgs_notify, 1401, NULL);
        if (e == 0) {
            registered = true;
            hypr_log("Registered SkyLight notify proc for 1401");
        }
    }

    // 2. Darwin Notification Center for space changes
    CFNotificationCenterRef darwin_center = CFNotificationCenterGetDarwinNotifyCenter();
    if (darwin_center) {
        CFNotificationCenterAddObserver(
            darwin_center,
            NULL,
            on_darwin_space_notification,
            CFSTR("com.apple.spaces.activeSpaceDidChange"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        registered = true;
        hypr_log("Registered Darwin notification observer for com.apple.spaces.activeSpaceDidChange");
    }

    // 3. Distributed Notification Center for space changes
    CFNotificationCenterRef dist_center = CFNotificationCenterGetDistributedCenter();
    if (dist_center) {
        CFNotificationCenterAddObserver(
            dist_center,
            NULL,
            on_distributed_space_notification,
            CFSTR("com.apple.spaces.activeSpaceDidChange"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        registered = true;
        hypr_log("Registered Distributed notification observer for com.apple.spaces.activeSpaceDidChange");
    }

    g_space_callback_registered = registered;
}

/* ---- SkyLight SLSNewWindow Interposition (Task 3.4) ----------------------- */

static CGError my_SLSNewWindow(CGSConnectionID cid, int type, float x, float y, void *shape, uint32_t *outWid) {
    CGError err = g_orig_SLSNewWindow ? g_orig_SLSNewWindow(cid, type, x, y, shape, outWid) : -1;
    if (err == 0 && outWid && *outWid != 0) {
        uint32_t wid = *outWid;
        apply_global_policy_to_window(cid, wid);
    }
    return err;
}

static void rebind_section(intptr_t slide, const struct section_64 *sect,
                           const uint32_t *indirect_symtab, const struct nlist_64 *symtab,
                           const char *strtab, uint32_t strsize, uint32_t nsyms) {
    const uint32_t *indirect_symbol_indices = indirect_symtab + sect->reserved1;
    void **indirect_symbol_bindings = (void **)(slide + sect->addr);
    size_t count = sect->size / sizeof(void *);

    for (size_t i = 0; i < count; i++) {
        uint32_t symtab_index = indirect_symbol_indices[i];
        if (symtab_index == INDIRECT_SYMBOL_ABS || symtab_index == INDIRECT_SYMBOL_LOCAL) continue;
        if (symtab_index >= nsyms) continue;

        uint32_t strx = symtab[symtab_index].n_un.n_strx;
        if (!strx || strx >= strsize) continue;

        const char *name = strtab + strx;
        if (strcmp(name, "_SLSNewWindow") == 0 || strcmp(name, "_CGSNewWindow") == 0) {
            kern_return_t kr = vm_protect(mach_task_self(),
                                          (vm_address_t)&indirect_symbol_bindings[i],
                                          sizeof(void *),
                                          FALSE,
                                          VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            if (kr != KERN_SUCCESS) {
                hypr_log("vm_protect failed on binding %p for %s: kr=%d", &indirect_symbol_bindings[i], name, kr);
                continue;
            }
#if __has_feature(ptrauth_calls)
            void *raw_target = ptrauth_strip((void *)my_SLSNewWindow, ptrauth_key_function_pointer);
            void *target = ptrauth_sign_unauthenticated(raw_target, ptrauth_key_asia, (uintptr_t)&indirect_symbol_bindings[i]);
            indirect_symbol_bindings[i] = target;
#else
            indirect_symbol_bindings[i] = (void *)my_SLSNewWindow;
#endif
            hypr_log("Runtime rebind succeeded for %s at %p", name, &indirect_symbol_bindings[i]);
        }
    }
}

static void rebind_image_symbols(const struct mach_header *mh, intptr_t slide) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)mh;
    if (!header || header->magic != MH_MAGIC_64) return;
    if (header->flags & 0x80000000) return;

    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab_cmd = NULL;
    const struct dysymtab_command *dysymtab_cmd = NULL;

    uintptr_t cur = (uintptr_t)header + sizeof(struct mach_header_64);
    for (uint32_t j = 0; j < header->ncmds; j++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, "__LINKEDIT") == 0) linkedit = seg;
        } else if (lc->cmd == LC_SYMTAB) {
            symtab_cmd = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (const struct dysymtab_command *)lc;
        }
        cur += lc->cmdsize;
    }

    if (!linkedit || !symtab_cmd || !dysymtab_cmd) return;

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symtab = (const struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    const char *strtab = (const char *)(linkedit_base + symtab_cmd->stroff);
    const uint32_t *indirect_symtab = (const uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    cur = (uintptr_t)header + sizeof(struct mach_header_64);
    for (uint32_t j = 0; j < header->ncmds; j++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, "__DATA") == 0 ||
                strcmp(seg->segname, "__DATA_CONST") == 0 ||
                strcmp(seg->segname, "__AUTH_CONST") == 0) {
                const struct section_64 *sect = (const struct section_64 *)(cur + sizeof(struct segment_command_64));
                for (uint32_t k = 0; k < seg->nsects; k++) {
                    uint8_t type = sect[k].flags & SECTION_TYPE;
                    if (type == S_LAZY_SYMBOL_POINTERS ||
                        type == S_NON_LAZY_SYMBOL_POINTERS ||
                        strcmp(sect[k].sectname, "__auth_got") == 0 ||
                        strcmp(sect[k].sectname, "__got") == 0) {
                        rebind_section(slide, &sect[k], indirect_symtab, symtab, strtab, symtab_cmd->strsize, symtab_cmd->nsyms);
                    }
                }
            }
        }
        cur += lc->cmdsize;
    }
}

static void on_dyld_image_added(const struct mach_header *mh, intptr_t vmaddr_slide) {
    rebind_image_symbols(mh, vmaddr_slide);
}

static void install_interposition(void) {
    if (!g_orig_SLSNewWindow) {
        void *sym = safe_resolve_symbol("SLSNewWindow");
        if (!sym) sym = safe_resolve_symbol("CGSNewWindow");
        g_orig_SLSNewWindow = (fn_SLSNewWindow)sym;
    }

    struct dyld_interpose_tuple {
        const void *replacement;
        const void *replacee;
    };
    typedef void (*fn_dyld_dynamic_interpose)(const struct mach_header *mh, const struct dyld_interpose_tuple tuples[], size_t count);
    fn_dyld_dynamic_interpose dyld_interpose = (fn_dyld_dynamic_interpose)safe_resolve_symbol("dyld_dynamic_interpose");
    if (dyld_interpose && g_orig_SLSNewWindow) {
        extern struct mach_header __dso_handle;
        struct dyld_interpose_tuple t[] = {
            { (const void *)my_SLSNewWindow, (const void *)g_orig_SLSNewWindow }
        };
        dyld_interpose(&__dso_handle, t, 1);
        hypr_log("Interposition: dyld_dynamic_interpose invoked for SLSNewWindow");
    }

    uint32_t image_count = _dyld_image_count();
    for (uint32_t i = 0; i < image_count; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        rebind_image_symbols(mh, slide);
    }

    _dyld_register_func_for_add_image(on_dyld_image_added);
    hypr_log("Interposition: window creation hooks registered (orig=%p)", (void *)g_orig_SLSNewWindow);
}

/* ---- Signal-Safe Symbol Sandbox (Task 3.1) -------------------------------- */

static sigjmp_buf g_probe_jmp;
static volatile sig_atomic_t g_probe_active = 0;

static void probe_signal_handler(int sig) {
    if (g_probe_active) {
        siglongjmp(g_probe_jmp, sig);
    }
}

static void *safe_resolve_symbol(const char *name) {
    void *sym = NULL;
    g_probe_active = 1;
    if (sigsetjmp(g_probe_jmp, 1) == 0) {
        sym = dlsym(RTLD_DEFAULT, name);
    } else {
        hypr_log("Signal caught while resolving '%s'", name);
        sym = NULL;
    }
    g_probe_active = 0;
    return sym;
}

static void *safe_resolve_variants(const char *category, const char * const *variants, size_t count, const char **out_name) {
    if (out_name) *out_name = NULL;
    for (size_t i = 0; i < count; i++) {
        void *sym = safe_resolve_symbol(variants[i]);
        if (sym) {
            hypr_log("Symbol resolved: [%s] -> %s (%p)", category, variants[i], sym);
            if (out_name) *out_name = variants[i];
            return sym;
        } else {
            hypr_log("Symbol variant not found: %s for [%s]", variants[i], category);
        }
    }
    hypr_log("Symbol failed: [%s] (none of %zu variants resolved)", category, count);
    return NULL;
}

/* ---- Internal State Probing & Server Authority (Tasks 3.2, 3.3) ----------- */

static void probe_internal_state(void) {
    if (!g_symbols.MainConnectionID) {
        hypr_log("Probe: MainConnectionID unresolved, skipping state probe");
        return;
    }
    g_probe_active = 1;
    if (sigsetjmp(g_probe_jmp, 1) == 0) {
        CGSConnectionID cid = g_symbols.MainConnectionID();
        hypr_log("Probe: Server CGSConnectionID = %d (0x%x)", cid, (uint32_t)cid);
        if (g_symbols.GetWindowCount) {
            int32_t count = 0;
            CGError err = g_symbols.GetWindowCount(cid, 0, &count);
            hypr_log("Probe: SLSGetWindowCount(cid=%d, 0, &count) -> err=%d, count=%d", cid, err, count);
        } else {
            hypr_log("Probe: SLSGetWindowCount unresolved");
        }
    } else {
        hypr_log("Signal caught during internal state probe");
    }
    g_probe_active = 0;
}

static void validate_server_authority(void) {
    if (!g_symbols.MainConnectionID) {
        hypr_log("Validate authority: MainConnectionID unresolved");
        return;
    }
    g_probe_active = 1;
    if (sigsetjmp(g_probe_jmp, 1) == 0) {
        CGSConnectionID cid = g_symbols.MainConnectionID();
        if (g_symbols.GetWindowList && g_symbols.GetWindowTags) {
            uint32_t wids[16];
            int32_t actual = 0;
            CGError list_err = g_symbols.GetWindowList(cid, 0, 16, wids, &actual);
            if (list_err == 0 && actual > 0) {
                uint32_t tags[2] = {0, 0};
                CGError tag_err = g_symbols.GetWindowTags(cid, wids[0], tags, 64);
                hypr_log("Validate authority: wid=%u current tags=[0x%08x, 0x%08x] (err=%d)",
                         wids[0], tags[0], tags[1], tag_err);
            } else {
                hypr_log("Validate authority: SLSGetWindowList returned err=%d, actual=%d",
                         list_err, actual);
            }
        } else {
            hypr_log("Validate authority: GetWindowList or GetWindowTags unresolved");
        }
        if (g_symbols.SetWindowProperty) {
            hypr_log("Validate authority: SLSSetWindowProperty is available for server properties");
        }
    } else {
        hypr_log("Signal caught during server authority validation");
    }
    g_probe_active = 0;
}

static void resolve_symbols_and_probe(void) {
    struct sigaction sa, old_segv, old_bus;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = probe_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;

    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGBUS, &sa, &old_bus);

    g_probe_active = 1;
    if (sigsetjmp(g_probe_jmp, 1) == 0) {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL);
        dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_GLOBAL);
    }
    g_probe_active = 0;

    static const char * const v_main_conn[] = { "SLSMainConnectionID", "CGSMainConnectionID" };
    g_SLSMainConnectionID = (fn_SLSMainConnectionID)safe_resolve_variants("SLSMainConnectionID", v_main_conn, 2, NULL);
    g_symbols.MainConnectionID = g_SLSMainConnectionID;

    static const char * const v_win_count[] = { "SLSGetWindowCount", "CGSGetWindowCount" };
    g_SLSGetWindowCount = (fn_SLSGetWindowCount)safe_resolve_variants("SLSGetWindowCount", v_win_count, 2, NULL);
    g_symbols.GetWindowCount = g_SLSGetWindowCount;

    static const char * const v_win_list[] = { "SLSGetWindowList", "CGSGetWindowList" };
    g_SLSGetWindowList = (fn_SLSGetWindowList)safe_resolve_variants("SLSGetWindowList", v_win_list, 2, NULL);
    g_symbols.GetWindowList = g_SLSGetWindowList;

    static const char * const v_set_prop[] = { "SLSSetWindowProperty", "CGSSetWindowProperty" };
    g_SLSSetWindowProperty = (fn_SLSSetWindowProperty)safe_resolve_variants("SLSSetWindowProperty", v_set_prop, 2, NULL);
    g_symbols.SetWindowProperty = g_SLSSetWindowProperty;

    static const char * const v_corner[] = {
        "SLSSetWindowCornerMask", "CGSSetWindowCornerMask",
        "SLSWindowSetCornerRadius", "CGSSetWindowCornerRadius", "CGSWindowSetCornerRadius",
        "SLSSetWindowCornerRadius"
    };
    g_SLSSetWindowCornerRadius = safe_resolve_variants("WindowCornerRadius", v_corner, sizeof(v_corner)/sizeof(v_corner[0]), &g_corner_sym_name);
    g_symbols.SetWindowCornerRadius = g_SLSSetWindowCornerRadius;
    g_symbols.CornerRadiusSymbolName = g_corner_sym_name;

    static const char * const v_shadow[] = {
        "SLSSetWindowShadowParameters", "CGSSetWindowShadowParameters",
        "SLSWindowSetShadowProperties", "CGSWindowSetShadowProperties", "SLSSetWindowShadowProperties", "SLSWindowSetShadowParameters"
    };
    g_SLSSetWindowShadowProperties = safe_resolve_variants("WindowShadowProperties", v_shadow, sizeof(v_shadow)/sizeof(v_shadow[0]), &g_shadow_sym_name);
    g_symbols.SetWindowShadowProperties = g_SLSSetWindowShadowProperties;
    g_symbols.ShadowPropertiesSymbolName = g_shadow_sym_name;

    static const char * const v_move[] = { "SLSMoveWindow", "CGSMoveWindow" };
    g_SLSMoveWindow = (fn_SLSMoveWindow)safe_resolve_variants("MoveWindow", v_move, 2, NULL);
    g_symbols.MoveWindow = g_SLSMoveWindow;

    static const char * const v_flush[] = { "SLSFlushSurface", "CGSFlushSurface" };
    g_SLSFlushSurface = (fn_SLSFlushSurface)safe_resolve_variants("FlushSurface", v_flush, 2, NULL);
    g_symbols.FlushSurface = g_SLSFlushSurface;

    static const char * const v_bounds[] = { "SLSGetWindowBounds", "CGSGetWindowBounds" };
    g_SLSGetWindowBounds = (fn_SLSGetWindowBounds)safe_resolve_variants("GetWindowBounds", v_bounds, 2, NULL);
    g_symbols.GetWindowBounds = g_SLSGetWindowBounds;

    static const char * const v_new_win[] = { "SLSNewWindow", "CGSNewWindow" };
    g_orig_SLSNewWindow = (fn_SLSNewWindow)safe_resolve_variants("NewWindow", v_new_win, 2, NULL);
    g_symbols.NewWindow = g_orig_SLSNewWindow;

    static const char * const v_set_tags[] = { "SLSSetWindowTags", "CGSSetWindowTags" };
    g_SLSSetWindowTags = (fn_SLSSetWindowTags)safe_resolve_variants("SetWindowTags", v_set_tags, 2, NULL);
    g_symbols.SetWindowTags = g_SLSSetWindowTags;

    static const char * const v_clear_tags[] = { "SLSClearWindowTags", "CGSClearWindowTags" };
    g_SLSClearWindowTags = (fn_SLSClearWindowTags)safe_resolve_variants("ClearWindowTags", v_clear_tags, 2, NULL);
    g_symbols.ClearWindowTags = g_SLSClearWindowTags;

    static const char * const v_get_tags[] = { "SLSGetWindowTags", "CGSGetWindowTags" };
    g_SLSGetWindowTags = (fn_SLSGetWindowTags)safe_resolve_variants("GetWindowTags", v_get_tags, 2, NULL);
    g_symbols.GetWindowTags = g_SLSGetWindowTags;

    // Display APIs (Task 4.9)
    static const char * const v_reg_disp[] = {
        "CGDisplayRegisterReconfigurationCallback", "SLSDisplayRegisterReconfigurationCallback"
    };
    g_symbols.DisplayRegisterReconfigurationCallback =
        (fn_CGDisplayRegisterReconfigurationCallback)safe_resolve_variants("DisplayRegisterReconfigurationCallback", v_reg_disp, 2, NULL);

    static const char * const v_rem_disp[] = {
        "CGDisplayRemoveReconfigurationCallback", "SLSDisplayRemoveReconfigurationCallback"
    };
    g_symbols.DisplayRemoveReconfigurationCallback =
        (fn_CGDisplayRemoveReconfigurationCallback)safe_resolve_variants("DisplayRemoveReconfigurationCallback", v_rem_disp, 2, NULL);

    static const char * const v_act_disp[] = {
        "CGGetActiveDisplayList", "SLSGetActiveDisplayList", "SLSGetDisplayList"
    };
    g_symbols.GetActiveDisplayList =
        (fn_CGGetActiveDisplayList)safe_resolve_variants("GetActiveDisplayList", v_act_disp, 3, NULL);

    static const char * const v_disp_bounds[] = {
        "CGDisplayBounds", "SLSGetDisplayBounds"
    };
    g_symbols.DisplayBounds =
        (fn_CGDisplayBounds)safe_resolve_variants("DisplayBounds", v_disp_bounds, 2, NULL);

    static const char * const v_copy_mode[] = {
        "CGDisplayCopyDisplayMode"
    };
    g_symbols.DisplayCopyDisplayMode =
        (fn_CGDisplayCopyDisplayMode)safe_resolve_variants("DisplayCopyDisplayMode", v_copy_mode, 1, NULL);

    static const char * const v_get_refresh[] = {
        "CGDisplayModeGetRefreshRate", "SLSDisplayGetRefreshRate", "SLSGetDisplayModeMinRefreshRate"
    };
    g_symbols.DisplayModeGetRefreshRate =
        (fn_CGDisplayModeGetRefreshRate)safe_resolve_variants("DisplayModeGetRefreshRate", v_get_refresh, 3, NULL);

    static const char * const v_rel_mode[] = {
        "CGDisplayModeRelease"
    };
    g_symbols.DisplayModeRelease =
        (fn_CGDisplayModeRelease)safe_resolve_variants("DisplayModeRelease", v_rel_mode, 1, NULL);

    static const char * const v_main_disp[] = {
        "CGMainDisplayID", "SLSMainDisplayID"
    };
    g_symbols.MainDisplayID =
        (fn_CGMainDisplayID)safe_resolve_variants("MainDisplayID", v_main_disp, 2, NULL);

    // Space & Notification APIs (Task 4.10)
    static const char * const v_act_space[] = {
        "SLSGetActiveSpace", "CGSGetActiveSpace"
    };
    g_symbols.GetActiveSpace =
        (fn_SLSGetActiveSpace)safe_resolve_variants("GetActiveSpace", v_act_space, 2, NULL);

    static const char * const v_space_type[] = {
        "SLSSpaceGetType", "CGSSpaceGetType"
    };
    g_symbols.SpaceGetType =
        (fn_SLSSpaceGetType)safe_resolve_variants("SpaceGetType", v_space_type, 2, NULL);

    static const char * const v_disp_spaces[] = {
        "SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"
    };
    g_symbols.CopyManagedDisplaySpaces =
        (fn_SLSCopyManagedDisplaySpaces)safe_resolve_variants("CopyManagedDisplaySpaces", v_disp_spaces, 2, NULL);

    static const char * const v_reg_conn_notify[] = {
        "SLSRegisterConnectionNotifyProc", "CGSRegisterConnectionNotifyProc"
    };
    g_symbols.RegisterConnectionNotifyProc =
        (fn_CGSRegisterConnectionNotifyProc)safe_resolve_variants("RegisterConnectionNotifyProc", v_reg_conn_notify, 2, NULL);

    static const char * const v_reg_notify[] = {
        "SLSRegisterNotifyProc", "CGSRegisterNotifyProc"
    };
    g_symbols.RegisterNotifyProc =
        (fn_CGSRegisterNotifyProc)safe_resolve_variants("RegisterNotifyProc", v_reg_notify, 2, NULL);

    g_symbols.resolved = (g_symbols.MainConnectionID != NULL);
    if (!g_symbols.resolved) {
        hypr_log("Warning: Core symbols unresolved; compositor mutations unavailable");
    } else {
        hypr_log("Core symbols resolved successfully");
        probe_internal_state();
        validate_server_authority();
    }

    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(SIGBUS, &old_bus, NULL);
}

/* ---- Client Connection State & kqueue Server (Task 1.4) ------------------ */

typedef struct {
    int     fd;
    bool    active;
    bool    authenticated;
    uint8_t read_buf[CLIENT_READ_BUF_SIZE];
    size_t  read_len;
    uint8_t write_buf[CLIENT_WRITE_BUF_SIZE];
    size_t  write_len;
    size_t  write_pos;
} ClientConn;

static ClientConn g_clients[HYPR_MAX_CLIENTS];
static int g_server_fd = -1;

static ClientConn *find_client(int fd) {
    for (int i = 0; i < HYPR_MAX_CLIENTS; i++) {
        if (g_clients[i].active && g_clients[i].fd == fd) return &g_clients[i];
    }
    return NULL;
}

static ClientConn *alloc_client(int fd) {
    for (int i = 0; i < HYPR_MAX_CLIENTS; i++) {
        if (!g_clients[i].active) {
            memset(&g_clients[i], 0, sizeof(ClientConn));
            g_clients[i].fd = fd;
            g_clients[i].active = true;
            return &g_clients[i];
        }
    }
    return NULL;
}

static void close_client(int kq, ClientConn *c) {
    if (!c || !c->active) return;
    int idx = (int)(c - g_clients);
    if (kq >= 0) {
        struct kevent tev;
        EV_SET(&tev, HYPR_TIMER_AUTH_BASE + idx, EVFILT_TIMER, EV_DELETE, 0, 0, NULL);
        kevent(kq, &tev, 1, NULL, 0, NULL);
    }
    close(c->fd);
    c->active = false;
    c->authenticated = false;
    c->fd = -1;
    c->read_len = 0;
    c->write_len = 0;
    c->write_pos = 0;
}

static void client_send_response(int kq, ClientConn *c, const void *hdr, size_t hdr_len, const void *payload, size_t payload_len) {
    if (!c || !c->active) return;

    if (c->write_len > c->write_pos) {
        size_t needed = hdr_len + payload_len;
        size_t available = sizeof(c->write_buf) - c->write_len;
        if (needed <= available) {
            memcpy(c->write_buf + c->write_len, hdr, hdr_len);
            c->write_len += hdr_len;
            if (payload && payload_len > 0) {
                memcpy(c->write_buf + c->write_len, payload, payload_len);
                c->write_len += payload_len;
            }
        } else {
            hypr_log("Write buffer overflow for fd=%d, dropping connection", c->fd);
            close_client(kq, c);
        }
        return;
    }

    c->write_pos = 0;
    c->write_len = 0;

    struct iovec iov[2];
    int iovcnt = 0;
    iov[iovcnt].iov_base = (void *)hdr;
    iov[iovcnt].iov_len = hdr_len;
    iovcnt++;
    if (payload && payload_len > 0) {
        iov[iovcnt].iov_base = (void *)payload;
        iov[iovcnt].iov_len = payload_len;
        iovcnt++;
    }

    size_t total = hdr_len + payload_len;
    ssize_t n = writev(c->fd, iov, iovcnt);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            n = 0;
        } else {
            hypr_log("writev error fd=%d: %s", c->fd, strerror(errno));
            close_client(kq, c);
            return;
        }
    }

    if ((size_t)n < total) {
        size_t rem = total - (size_t)n;
        if ((size_t)n < hdr_len) {
            size_t hdr_rem = hdr_len - (size_t)n;
            memcpy(c->write_buf, (const char *)hdr + n, hdr_rem);
            if (payload && payload_len > 0) {
                memcpy(c->write_buf + hdr_rem, payload, payload_len);
            }
        } else {
            size_t payload_written = (size_t)n - hdr_len;
            size_t payload_rem = payload_len - payload_written;
            memcpy(c->write_buf, (const char *)payload + payload_written, payload_rem);
        }
        c->write_pos = 0;
        c->write_len = rem;

        struct kevent ev;
        EV_SET(&ev, c->fd, EVFILT_WRITE, EV_ADD | EV_ENABLE, 0, 0, NULL);
        kevent(kq, &ev, 1, NULL, 0, NULL);
    }
}

static void handle_client_write(int kq, ClientConn *c) {
    if (!c || !c->active) return;
    if (c->write_pos >= c->write_len) {
        struct kevent ev;
        EV_SET(&ev, c->fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
        kevent(kq, &ev, 1, NULL, 0, NULL);
        c->write_pos = 0;
        c->write_len = 0;
        return;
    }

    size_t remaining = c->write_len - c->write_pos;
    ssize_t n = write(c->fd, c->write_buf + c->write_pos, remaining);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return;
        hypr_log("client write error fd=%d: %s", c->fd, strerror(errno));
        close_client(kq, c);
        return;
    }
    c->write_pos += (size_t)n;
    if (c->write_pos >= c->write_len) {
        c->write_pos = 0;
        c->write_len = 0;
        struct kevent ev;
        EV_SET(&ev, c->fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
        kevent(kq, &ev, 1, NULL, 0, NULL);
    }
}

static void send_ack(int kq, ClientConn *c, uint32_t seq, uint32_t status, const char *msg) {
    HyprMessageHeader header;
    memset(&header, 0, sizeof(header));
    header.magic = HYPR_MAGIC;
    header.version = HYPR_PROTO_VERSION;
    header.command_id = (status == HYPR_ERR_SUCCESS) ? HYPR_CMD_ACK : HYPR_CMD_ERROR;
    header.sequence = seq;
    header.payload_size = sizeof(HyprPayloadAck);

    HyprPayloadAck ack;
    memset(&ack, 0, sizeof(ack));
    ack.status = status;
    if (msg) snprintf(ack.message, sizeof(ack.message), "%s", msg);

    client_send_response(kq, c, &header, sizeof(header), &ack, sizeof(ack));
}

static void send_pong(int kq, ClientConn *c, uint32_t seq) {
    HyprMessageHeader header;
    memset(&header, 0, sizeof(header));
    header.magic = HYPR_MAGIC;
    header.version = HYPR_PROTO_VERSION;
    header.command_id = HYPR_CMD_PONG;
    header.sequence = seq;
    header.payload_size = sizeof(HyprPayloadPong);

    HyprPayloadPong pong;
    memset(&pong, 0, sizeof(pong));
    pong.server_version = (1 << 16);
    os_unfair_lock_lock(&g_state_lock);
    pong.active_windows = (uint32_t)g_managed_window_count;
    os_unfair_lock_unlock(&g_state_lock);

    if (pong.active_windows == 0 && g_symbols.resolved && g_symbols.MainConnectionID && g_symbols.GetWindowCount) {
        int32_t cid = g_symbols.MainConnectionID();
        int32_t count = 0;
        if (g_symbols.GetWindowCount(cid, 0, &count) == 0 && count >= 0) {
            pong.active_windows = (uint32_t)count;
        }
    }

    client_send_response(kq, c, &header, sizeof(header), &pong, sizeof(pong));
}

static void dispatch_command(int kq, ClientConn *c, const HyprMessageHeader *hdr, const uint8_t *payload) {
    if (!c->authenticated && hdr->command_id != HYPR_CMD_AUTH) {
        hypr_log("Unauthorized command 0x%04x from fd=%d rejected", hdr->command_id, c->fd);
        send_ack(kq, c, hdr->sequence, HYPR_ERR_UNAUTHORIZED, "Unauthorized");
        return;
    }

    switch (hdr->command_id) {
        case HYPR_CMD_AUTH: {
            if (hdr->payload_size != sizeof(HyprPayloadAuth)) {
                hypr_log("HYPR_CMD_AUTH fd=%d bad payload size %u", c->fd, hdr->payload_size);
                send_ack(kq, c, hdr->sequence, HYPR_ERR_UNAUTHORIZED, "Unauthorized");
                close_client(kq, c);
                return;
            }
            const HyprPayloadAuth *auth = (const HyprPayloadAuth *)payload;
            if (memcmp(auth->token, g_auth_token, sizeof(g_auth_token)) == 0) {
                c->authenticated = true;
                int idx = (int)(c - g_clients);
                struct kevent tev;
                EV_SET(&tev, HYPR_TIMER_AUTH_BASE + idx, EVFILT_TIMER, EV_DELETE, 0, 0, NULL);
                kevent(kq, &tev, 1, NULL, 0, NULL);

                hypr_log("Client fd=%d successfully authenticated", c->fd);
                send_ack(kq, c, hdr->sequence, HYPR_ERR_SUCCESS, "Authenticated");
            } else {
                hypr_log("Client fd=%d authentication failed (token mismatch)", c->fd);
                send_ack(kq, c, hdr->sequence, HYPR_ERR_UNAUTHORIZED, "Unauthorized");
                close_client(kq, c);
            }
            break;
        }
        case HYPR_CMD_PING:
            send_pong(kq, c, hdr->sequence);
            break;
        case HYPR_CMD_SET_CORNER_RADIUS: {
            if (hdr->payload_size != sizeof(HyprPayloadCornerRadius)) {
                send_ack(kq, c, hdr->sequence, HYPR_ERR_INTERNAL, "Bad payload size");
                return;
            }
            HyprPayloadCornerRadius p;
            memcpy(&p, payload, sizeof(p));
            if (!g_symbols.resolved || !g_symbols.MainConnectionID) {
                hypr_log("SET_CORNER_RADIUS wid=%u: compositor mutations unavailable", hdr->window_id);
                send_ack(kq, c, hdr->sequence, HYPR_ERR_HOOK_UNAVAIL, "Compositor unavailable");
                return;
            }
            CGSConnectionID cid = g_symbols.MainConnectionID();
            if (!is_window_alive(cid, hdr->window_id)) {
                os_unfair_lock_lock(&g_state_lock);
                managed_window_evict(hdr->window_id);
                os_unfair_lock_unlock(&g_state_lock);
                hypr_log("SET_CORNER_RADIUS wid=%u: invalid or destroyed window", hdr->window_id);
                send_ack(kq, c, hdr->sequence, HYPR_ERR_INVALID_WID, "Invalid window ID");
                return;
            }
            os_unfair_lock_lock(&g_state_lock);
            HyprManagedWindow *win = managed_window_get_or_create(hdr->window_id);
            if (win) {
                win->corner_radius = p.corner_radius;
            }
            if (p.corner_radius == 0.0f && g_symbols.SetWindowCornerRadius) {
                if (g_symbols.CornerRadiusSymbolName && strstr(g_symbols.CornerRadiusSymbolName, "Mask")) {
                    fn_SLSSetWindowCornerMask fn = (fn_SLSSetWindowCornerMask)g_symbols.SetWindowCornerRadius;
                    fn(cid, NULL, hdr->window_id, 0.0f, 0.0f, 0.0f, 0.0f);
                } else {
                    fn_SLSWindowSetCornerRadius fn = (fn_SLSWindowSetCornerRadius)g_symbols.SetWindowCornerRadius;
                    fn(cid, hdr->window_id, 0.0f);
                }
            }
            os_unfair_lock_unlock(&g_state_lock);

            invalidate_window(cid, hdr->window_id);
            hypr_log("SET_CORNER_RADIUS wid=%u r=%.2f: OK", hdr->window_id, p.corner_radius);
            send_ack(kq, c, hdr->sequence, HYPR_ERR_SUCCESS, "OK");
            break;
        }
        case HYPR_CMD_SET_SHADOW_STATE: {
            if (hdr->payload_size != sizeof(HyprPayloadShadow)) {
                send_ack(kq, c, hdr->sequence, HYPR_ERR_INTERNAL, "Bad payload size");
                return;
            }
            HyprPayloadShadow p;
            memcpy(&p, payload, sizeof(p));
            if (!g_symbols.resolved || !g_symbols.MainConnectionID) {
                hypr_log("SET_SHADOW wid=%u: compositor mutations unavailable", hdr->window_id);
                send_ack(kq, c, hdr->sequence, HYPR_ERR_HOOK_UNAVAIL, "Compositor unavailable");
                return;
            }
            CGSConnectionID cid = g_symbols.MainConnectionID();
            if (!is_window_alive(cid, hdr->window_id)) {
                os_unfair_lock_lock(&g_state_lock);
                managed_window_evict(hdr->window_id);
                os_unfair_lock_unlock(&g_state_lock);
                hypr_log("SET_SHADOW wid=%u: invalid or destroyed window", hdr->window_id);
                send_ack(kq, c, hdr->sequence, HYPR_ERR_INVALID_WID, "Invalid window ID");
                return;
            }
            os_unfair_lock_lock(&g_state_lock);
            HyprManagedWindow *win = managed_window_get_or_create(hdr->window_id);
            if (win) {
                win->shadow_enabled = p.shadow_enabled;
            }
            uint32_t tags[2] = { 1 << 3, 0 };
            if (p.shadow_enabled == 0) {
                if (g_symbols.SetWindowTags) {
                    g_symbols.SetWindowTags(cid, hdr->window_id, tags, 64);
                }
                if (g_symbols.SetWindowShadowProperties) {
                    fn_SLSSetWindowShadowParameters fn = (fn_SLSSetWindowShadowParameters)g_symbols.SetWindowShadowProperties;
                    fn(cid, hdr->window_id, 0.0f, 0.0f, 0, 0);
                }
            } else {
                if (g_symbols.ClearWindowTags) {
                    g_symbols.ClearWindowTags(cid, hdr->window_id, tags, 64);
                }
            }
            os_unfair_lock_unlock(&g_state_lock);

            invalidate_window(cid, hdr->window_id);
            hypr_log("SET_SHADOW wid=%u en=%u: OK", hdr->window_id, p.shadow_enabled);
            send_ack(kq, c, hdr->sequence, HYPR_ERR_SUCCESS, "OK");
            break;
        }
        case HYPR_CMD_SET_WINDOW_BORDER: {
            if (hdr->payload_size != sizeof(HyprPayloadBorder)) {
                send_ack(kq, c, hdr->sequence, HYPR_ERR_INTERNAL, "Bad payload size");
                return;
            }
            HyprPayloadBorder p;
            memcpy(&p, payload, sizeof(p));
            if (!g_symbols.resolved || !g_symbols.MainConnectionID) {
                hypr_log("SET_BORDER wid=%u: compositor mutations unavailable", hdr->window_id);
                send_ack(kq, c, hdr->sequence, HYPR_ERR_HOOK_UNAVAIL, "Compositor unavailable");
                return;
            }
            CGSConnectionID cid = g_symbols.MainConnectionID();
            if (!is_window_alive(cid, hdr->window_id)) {
                os_unfair_lock_lock(&g_state_lock);
                managed_window_evict(hdr->window_id);
                os_unfair_lock_unlock(&g_state_lock);
                hypr_log("SET_BORDER wid=%u: invalid or destroyed window", hdr->window_id);
                send_ack(kq, c, hdr->sequence, HYPR_ERR_INVALID_WID, "Invalid window ID");
                return;
            }
            os_unfair_lock_lock(&g_state_lock);
            HyprManagedWindow *win = managed_window_get_or_create(hdr->window_id);
            if (win) {
                win->border_width = p.border_width;
                win->color_active = p.color_active;
                win->color_inactive = p.color_inactive;
            }
            os_unfair_lock_unlock(&g_state_lock);

            invalidate_window(cid, hdr->window_id);
            hypr_log("SET_BORDER wid=%u w=%.2f a=0x%08x i=0x%08x",
                     hdr->window_id, p.border_width, p.color_active, p.color_inactive);
            send_ack(kq, c, hdr->sequence, HYPR_ERR_SUCCESS, "OK");
            break;
        }
        case HYPR_CMD_STRIP_TITLEBAR: {
            if (hdr->payload_size != sizeof(HyprPayloadStripTitlebar)) {
                send_ack(kq, c, hdr->sequence, HYPR_ERR_INTERNAL, "Bad payload size");
                return;
            }
            HyprPayloadStripTitlebar p;
            memcpy(&p, payload, sizeof(p));
            if (!g_symbols.resolved || !g_symbols.MainConnectionID) {
                hypr_log("STRIP_TITLEBAR wid=%u: compositor mutations unavailable", hdr->window_id);
                send_ack(kq, c, hdr->sequence, HYPR_ERR_HOOK_UNAVAIL, "Compositor unavailable");
                return;
            }
            CGSConnectionID cid = g_symbols.MainConnectionID();
            if (!is_window_alive(cid, hdr->window_id)) {
                os_unfair_lock_lock(&g_state_lock);
                managed_window_evict(hdr->window_id);
                os_unfair_lock_unlock(&g_state_lock);
                hypr_log("STRIP_TITLEBAR wid=%u: invalid or destroyed window", hdr->window_id);
                send_ack(kq, c, hdr->sequence, HYPR_ERR_INVALID_WID, "Invalid window ID");
                return;
            }
            os_unfair_lock_lock(&g_state_lock);
            HyprManagedWindow *win = managed_window_get_or_create(hdr->window_id);
            if (win) {
                win->titlebar_stripped = p.strip;
            }
            uint32_t tags[2] = { (1 << 9) | (1 << 18), 0 };
            if (p.strip != 0) {
                if (g_symbols.SetWindowTags) {
                    g_symbols.SetWindowTags(cid, hdr->window_id, tags, 64);
                }
            } else {
                if (g_symbols.ClearWindowTags) {
                    g_symbols.ClearWindowTags(cid, hdr->window_id, tags, 64);
                }
            }
            os_unfair_lock_unlock(&g_state_lock);

            invalidate_window(cid, hdr->window_id);
            hypr_log("STRIP_TITLEBAR wid=%u s=%u: OK", hdr->window_id, p.strip);
            send_ack(kq, c, hdr->sequence, HYPR_ERR_SUCCESS, "OK");
            break;
        }
        case HYPR_CMD_QUERY_WINDOW: {
            if (!g_symbols.resolved || !g_symbols.MainConnectionID) {
                send_ack(kq, c, hdr->sequence, HYPR_ERR_HOOK_UNAVAIL, "Compositor unavailable");
                return;
            }
            CGSConnectionID cid = g_symbols.MainConnectionID();
            if (!is_window_alive(cid, hdr->window_id)) {
                os_unfair_lock_lock(&g_state_lock);
                managed_window_evict(hdr->window_id);
                os_unfair_lock_unlock(&g_state_lock);
                send_ack(kq, c, hdr->sequence, HYPR_ERR_INVALID_WID, "Window not found");
                return;
            }
            os_unfair_lock_lock(&g_state_lock);
            HyprManagedWindow *win = managed_window_find(hdr->window_id);
            if (!win || !win->active) {
                os_unfair_lock_unlock(&g_state_lock);
                send_ack(kq, c, hdr->sequence, HYPR_ERR_INVALID_WID, "Window not managed");
                return;
            }
            HyprPayloadQueryResponse resp;
            memset(&resp, 0, sizeof(resp));
            resp.corner_radius = win->corner_radius;
            resp.shadow_enabled = win->shadow_enabled;
            resp.titlebar_stripped = win->titlebar_stripped;
            resp.border_color = win->is_focused ? win->color_active : win->color_inactive;
            resp.border_width = win->border_width;
            os_unfair_lock_unlock(&g_state_lock);

            HyprMessageHeader header;
            memset(&header, 0, sizeof(header));
            header.magic = HYPR_MAGIC;
            header.version = HYPR_PROTO_VERSION;
            header.command_id = HYPR_CMD_ACK;
            header.sequence = hdr->sequence;
            header.window_id = hdr->window_id;
            header.payload_size = sizeof(HyprPayloadQueryResponse);
            client_send_response(kq, c, &header, sizeof(header), &resp, sizeof(resp));
            break;
        }
        case HYPR_CMD_SET_WINDOW_FOCUS: {
            uint32_t target_wid = hdr->window_id;
            if (hdr->payload_size >= sizeof(uint32_t) && payload) {
                target_wid = *(const uint32_t *)payload;
            }
            if (!g_symbols.resolved || !g_symbols.MainConnectionID) {
                send_ack(kq, c, hdr->sequence, HYPR_ERR_HOOK_UNAVAIL, "Compositor unavailable");
                return;
            }
            CGSConnectionID cid = g_symbols.MainConnectionID();
            os_unfair_lock_lock(&g_state_lock);
            for (size_t i = 0; i < HYPR_MANAGED_WINDOWS_CAPACITY; i++) {
                if (g_managed_windows[i].active) {
                    g_managed_windows[i].is_focused = (g_managed_windows[i].wid == target_wid);
                }
            }
            os_unfair_lock_unlock(&g_state_lock);

            if (target_wid != 0) {
                invalidate_window(cid, target_wid);
            }
            hypr_log("SET_WINDOW_FOCUS focused wid=%u: OK", target_wid);
            send_ack(kq, c, hdr->sequence, HYPR_ERR_SUCCESS, "OK");
            break;
        }
        case HYPR_CMD_SET_GLOBAL_POLICY: {
            if (hdr->payload_size != sizeof(HyprPayloadGlobalPolicy)) {
                send_ack(kq, c, hdr->sequence, HYPR_ERR_INTERNAL, "Bad payload size");
                return;
            }
            HyprPayloadGlobalPolicy p;
            memcpy(&p, payload, sizeof(p));
            os_unfair_lock_lock(&g_state_lock);
            g_global_policy.auto_square_corners = p.auto_square_corners;
            g_global_policy.auto_strip_shadow = p.auto_strip_shadow;
            g_global_policy.auto_strip_titlebar = p.auto_strip_titlebar;
            g_global_policy.auto_set_border = p.auto_set_border;
            g_global_policy.border_width = p.border_width;
            g_global_policy.border_color_active = p.border_color_active;
            g_global_policy.border_color_inactive = p.border_color_inactive;
            os_unfair_lock_unlock(&g_state_lock);

            hypr_log("SET_GLOBAL_POLICY square=%u shadow=%u titlebar=%u border=%u (w=%.1f act=0x%08x inact=0x%08x): OK",
                     p.auto_square_corners, p.auto_strip_shadow, p.auto_strip_titlebar, p.auto_set_border,
                     p.border_width, p.border_color_active, p.border_color_inactive);
            send_ack(kq, c, hdr->sequence, HYPR_ERR_SUCCESS, "OK");
            break;
        }
        default:
            send_ack(kq, c, hdr->sequence, HYPR_ERR_INVALID_CMD, "Unknown");
            break;
    }
}

static void handle_client_read(int kq, ClientConn *c) {
    if (!c || !c->active) return;

    size_t space = sizeof(c->read_buf) - c->read_len;
    if (space == 0) {
        hypr_log("Client read buffer full for fd=%d without complete frame, dropping", c->fd);
        close_client(kq, c);
        return;
    }

    ssize_t n = read(c->fd, c->read_buf + c->read_len, space);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return;
        hypr_log("read error fd=%d: %s", c->fd, strerror(errno));
        close_client(kq, c);
        return;
    }
    if (n == 0) {
        close_client(kq, c);
        return;
    }

    c->read_len += (size_t)n;

    while (c->active && c->read_len >= sizeof(HyprMessageHeader)) {
        HyprMessageHeader header;
        memcpy(&header, c->read_buf, sizeof(header));

        if (header.magic != HYPR_MAGIC) {
            hypr_log("Bad magic 0x%08x from fd=%d", header.magic, c->fd);
            send_ack(kq, c, header.sequence, HYPR_ERR_INTERNAL, "Bad magic");
            close_client(kq, c);
            return;
        }
        if (header.version != HYPR_PROTO_VERSION) {
            hypr_log("Bad version %u from fd=%d", header.version, c->fd);
            send_ack(kq, c, header.sequence, HYPR_ERR_INTERNAL, "Bad version");
            close_client(kq, c);
            return;
        }
        if (header.payload_size > HYPR_MAX_PAYLOAD_SIZE) {
            hypr_log("Payload too large (%u bytes) from fd=%d", header.payload_size, c->fd);
            send_ack(kq, c, header.sequence, HYPR_ERR_INTERNAL, "Payload too large");
            close_client(kq, c);
            return;
        }

        size_t total_msg_len = sizeof(HyprMessageHeader) + header.payload_size;
        if (c->read_len < total_msg_len) {
            break;
        }

        const uint8_t *payload = c->read_buf + sizeof(HyprMessageHeader);
        dispatch_command(kq, c, &header, payload);
        if (!c->active) return;

        size_t rem = c->read_len - total_msg_len;
        if (rem > 0) {
            memmove(c->read_buf, c->read_buf + total_msg_len, rem);
        }
        c->read_len = rem;
    }
}

static void server_kqueue_loop(int server_fd) {
    int kq = kqueue();
    if (kq < 0) {
        hypr_log("kqueue() failed: %s", strerror(errno));
        close(server_fd);
        return;
    }
    g_kq = kq;

    struct kevent ev;
    EV_SET(&ev, server_fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
    if (kevent(kq, &ev, 1, NULL, 0, NULL) < 0) {
        hypr_log("kevent() failed to register server_fd: %s", strerror(errno));
        close(kq);
        close(server_fd);
        return;
    }

    struct kevent events[32];
    while (1) {
        int nev = kevent(kq, NULL, 0, events, 32, NULL);
        if (nev < 0) {
            if (errno == EINTR) continue;
            hypr_log("kevent wait error: %s", strerror(errno));
            break;
        }

        for (int i = 0; i < nev; i++) {
            int fd = (int)events[i].ident;
            int filter = events[i].filter;
            uint16_t flags = events[i].flags;

            if (filter == EVFILT_TIMER) {
                if (events[i].ident == HYPR_TIMER_SPACE_DEBOUNCE) {
                    handle_space_transition_settled();
                } else if (events[i].ident == HYPR_TIMER_DISPLAY_DEBOUNCE) {
                    handle_display_reconfiguration_settled();
                } else if (events[i].ident >= HYPR_TIMER_AUTH_BASE &&
                           events[i].ident < (uintptr_t)(HYPR_TIMER_AUTH_BASE + HYPR_MAX_CLIENTS)) {
                    int idx = (int)(events[i].ident - HYPR_TIMER_AUTH_BASE);
                    if (idx >= 0 && idx < HYPR_MAX_CLIENTS) {
                        ClientConn *c = &g_clients[idx];
                        if (c->active && !c->authenticated) {
                            hypr_log("Client fd=%d auth timeout (1s) expired; closing", c->fd);
                            close_client(kq, c);
                        }
                    }
                }
                continue;
            }

            if (fd == server_fd) {
                while (1) {
                    int client_fd = accept(server_fd, NULL, NULL);
                    if (client_fd < 0) {
                        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                        if (errno == EINTR) continue;
                        hypr_log("accept error: %s", strerror(errno));
                        break;
                    }

                    int fl = fcntl(client_fd, F_GETFL, 0);
                    if (fl >= 0) fcntl(client_fd, F_SETFL, fl | O_NONBLOCK);

                    int nosigpipe = 1;
                    setsockopt(client_fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));

                    ClientConn *c = alloc_client(client_fd);
                    if (!c) {
                        hypr_log("Max clients reached, dropping fd=%d", client_fd);
                        close(client_fd);
                        continue;
                    }

                    struct kevent cev;
                    EV_SET(&cev, client_fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
                    if (kevent(kq, &cev, 1, NULL, 0, NULL) < 0) {
                        hypr_log("Failed to add client_fd to kqueue: %s", strerror(errno));
                        close_client(kq, c);
                        continue;
                    }

                    int idx = (int)(c - g_clients);
                    struct kevent tev;
                    EV_SET(&tev, HYPR_TIMER_AUTH_BASE + idx, EVFILT_TIMER, EV_ADD | EV_ONESHOT, 0, 1000, NULL);
                    if (kevent(kq, &tev, 1, NULL, 0, NULL) < 0) {
                        hypr_log("Failed to add auth timer for client_fd=%d: %s", client_fd, strerror(errno));
                        close_client(kq, c);
                    }
                }
            } else {
                ClientConn *c = find_client(fd);
                if (!c) continue;

                if (filter == EVFILT_READ) {
                    handle_client_read(kq, c);
                } else if (filter == EVFILT_WRITE) {
                    handle_client_write(kq, c);
                }

                if ((flags & EV_EOF) && c->active && c->write_pos >= c->write_len) {
                    close_client(kq, c);
                }
            }
        }
    }

    close(kq);
    g_kq = -1;
    close(server_fd);
}

static void init_auth_token(void) {
    arc4random_buf(g_auth_token, sizeof(g_auth_token));
    unlink(HYPR_AUTH_TOKEN_PATH);
    int fd = open(HYPR_AUTH_TOKEN_PATH, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) {
        fchmod(fd, 0600);
        ssize_t written = write(fd, g_auth_token, sizeof(g_auth_token));
        if (written != (ssize_t)sizeof(g_auth_token)) {
            hypr_log("Failed to write complete auth token (%zd/%zu bytes)", written, sizeof(g_auth_token));
        }
        close(fd);
        hypr_log("Generated auth token and wrote to %s (permissions 0600)", HYPR_AUTH_TOKEN_PATH);
    } else {
        hypr_log("Failed to create auth token file %s: %s", HYPR_AUTH_TOKEN_PATH, strerror(errno));
    }
}

static void *deferred_init(void *arg) {
    (void)arg;
    usleep(500000);
    if (is_safe_mode_active()) return NULL;

    resolve_symbols_and_probe();
    install_interposition();

    // Task 4.9: Multi-monitor display topology and reconfiguration observer
    update_display_topology();
    register_display_callbacks();

    // Task 4.10: Mission Control, Spaces, and fullscreen transition observers
    register_space_callbacks();

    // Ensure bootstrap port is registered before socket server starts (REQ-INJ-001)
    if (g_bootstrap_service_port == MACH_PORT_NULL) {
        mach_port_t port = MACH_PORT_NULL;
        kern_return_t kr = bootstrap_check_in(bootstrap_port, HYPR_BOOTSTRAP_NAME, &port);
        if (kr == BOOTSTRAP_SERVICE_ACTIVE) {
            hypr_log("HyprServer detected BOOTSTRAP_SERVICE_ACTIVE in deferred_init, aborting");
            return NULL;
        } else if (kr == KERN_SUCCESS) {
            g_bootstrap_service_port = port;
            hypr_log("HyprServer registered Mach bootstrap service in deferred_init (port=%u)", port);
        } else {
            hypr_log("bootstrap_check_in(%s) returned %d (%s)", HYPR_BOOTSTRAP_NAME, kr, bootstrap_strerror(kr));
        }
    }

    // Initialize 16-byte random auth token (REQ-WS-012)
    init_auth_token();

    unlink(HYPR_SOCKET_PATH);
    g_server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_server_fd < 0) { hypr_log("socket: %s", strerror(errno)); return NULL; }

    int fl = fcntl(g_server_fd, F_GETFL, 0);
    if (fl >= 0) fcntl(g_server_fd, F_SETFL, fl | O_NONBLOCK);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, HYPR_SOCKET_PATH, sizeof(addr.sun_path) - 1);
    if (bind(g_server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        hypr_log("bind: %s", strerror(errno));
        close(g_server_fd); g_server_fd = -1; return NULL;
    }
    chmod(HYPR_SOCKET_PATH, 0666);
    if (listen(g_server_fd, 16) < 0) {
        hypr_log("listen: %s", strerror(errno));
        close(g_server_fd); g_server_fd = -1; return NULL;
    }

    hypr_log("HyprServer initialized on %s (symbols %s)",
             HYPR_SOCKET_PATH, g_symbols.resolved ? "resolved" : "unresolved");

    server_kqueue_loop(g_server_fd);
    return NULL;
}

/* Constructor: register Mach bootstrap port for idempotency check and spawn deferred init.
 * The calling thread (raw Mach thread from the injector) will return
 * to a spin-loop stub after dlopen, so no unwinding issues. */
__attribute__((constructor))
static void hypr_server_init(void) {
    /* Keep the constructor minimal: just spawn deferred_init.
     * bootstrap_check_in is done inside deferred_init after the 500ms delay,
     * when the process environment is fully stable. */
    pthread_t t;
    if (pthread_create(&t, NULL, deferred_init, NULL) == 0)
        pthread_detach(t);
}

/* Destructor: release Mach bootstrap port and clean up ephemeral artifacts. */
__attribute__((destructor))
static void hypr_server_fini(void) {
    if (g_bootstrap_service_port != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), g_bootstrap_service_port);
        g_bootstrap_service_port = MACH_PORT_NULL;
    }
    unlink(HYPR_AUTH_TOKEN_PATH);
}
