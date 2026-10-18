#include <stdio.h>
#include <stdbool.h>
#include <unistd.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <CoreGraphics/CoreGraphics.h>

#define SUPPRESSION_FLAG_PATH "/tmp/hyprmac-menubar-suppressed"

static bool was_suppressed = false;

static inline bool is_suppression_active(void) {
    return access(SUPPRESSION_FLAG_PATH, F_OK) == 0;
}

// SkyLight private API declarations
typedef int32_t (*SLSMainConnectionIDFunc)(void);
typedef int32_t (*SLSSetMenuBarVisibilityOverrideFunc)(int32_t cid, uint32_t displayID, bool visible);
typedef int32_t (*SLSSetMenuBarAutohideEnabledFunc)(int32_t cid, bool enabled);
typedef int32_t (*SLSSetMenuBarSystemOverrideAlphaFunc)(int32_t cid, float alpha);

static SLSMainConnectionIDFunc orig_SLSMainConnectionID = NULL;
static SLSSetMenuBarVisibilityOverrideFunc orig_SLSSetMenuBarVisibilityOverrideOnDisplay = NULL;
static SLSSetMenuBarAutohideEnabledFunc orig_SLSSetMenuBarAutohideEnabled = NULL;
static SLSSetMenuBarSystemOverrideAlphaFunc orig_SLSSetMenuBarSystemOverrideAlpha = NULL;

static void load_skylight_symbols(void) {
    void *skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!skylight) return;

    orig_SLSMainConnectionID = (SLSMainConnectionIDFunc)dlsym(skylight, "SLSMainConnectionID");
    orig_SLSSetMenuBarVisibilityOverrideOnDisplay = (SLSSetMenuBarVisibilityOverrideFunc)dlsym(skylight, "SLSSetMenuBarVisibilityOverrideOnDisplay");
    orig_SLSSetMenuBarAutohideEnabled = (SLSSetMenuBarAutohideEnabledFunc)dlsym(skylight, "SLSSetMenuBarAutohideEnabled");
    orig_SLSSetMenuBarSystemOverrideAlpha = (SLSSetMenuBarSystemOverrideAlphaFunc)dlsym(skylight, "SLSSetMenuBarSystemOverrideAlpha");
}

static void force_hide_menu_bar(void) {
    if (!orig_SLSMainConnectionID || !orig_SLSSetMenuBarVisibilityOverrideOnDisplay) return;

    int32_t cid = orig_SLSMainConnectionID();
    uint32_t display = CGMainDisplayID();

    if (is_suppression_active()) {
        orig_SLSSetMenuBarVisibilityOverrideOnDisplay(cid, display, false);
        if (orig_SLSSetMenuBarAutohideEnabled)
            orig_SLSSetMenuBarAutohideEnabled(cid, true);
        if (orig_SLSSetMenuBarSystemOverrideAlpha)
            orig_SLSSetMenuBarSystemOverrideAlpha(cid, 0.0f);
        was_suppressed = true;
    } else {
        if (was_suppressed) {
            orig_SLSSetMenuBarVisibilityOverrideOnDisplay(cid, display, true);
            if (orig_SLSSetMenuBarAutohideEnabled)
                orig_SLSSetMenuBarAutohideEnabled(cid, false);
            if (orig_SLSSetMenuBarSystemOverrideAlpha)
                orig_SLSSetMenuBarSystemOverrideAlpha(cid, 1.0f);
            was_suppressed = false;
        }
    }
}

// DYLD_INTERPOSE macro
#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    }

int32_t hooked_SLSSetMenuBarVisibilityOverrideOnDisplay(int32_t cid, uint32_t displayID, bool visible) {
    if (orig_SLSSetMenuBarVisibilityOverrideOnDisplay) {
        if (is_suppression_active()) {
            return orig_SLSSetMenuBarVisibilityOverrideOnDisplay(cid, displayID, false);
        } else {
            return orig_SLSSetMenuBarVisibilityOverrideOnDisplay(cid, displayID, visible);
        }
    }
    return -1;
}

// We need the original symbol to interpose
extern int32_t SLSSetMenuBarVisibilityOverrideOnDisplay(int32_t cid, uint32_t displayID, bool visible);
DYLD_INTERPOSE(hooked_SLSSetMenuBarVisibilityOverrideOnDisplay, SLSSetMenuBarVisibilityOverrideOnDisplay);

// Also interpose SLSSetMenuBarSystemOverrideAlpha to prevent anything from setting it to visible
extern int32_t SLSSetMenuBarSystemOverrideAlpha(int32_t cid, float alpha);

int32_t hooked_SLSSetMenuBarSystemOverrideAlpha(int32_t cid, float alpha) {
    if (orig_SLSSetMenuBarSystemOverrideAlpha) {
        if (is_suppression_active()) {
            return orig_SLSSetMenuBarSystemOverrideAlpha(cid, 0.0f);
        } else {
            return orig_SLSSetMenuBarSystemOverrideAlpha(cid, alpha);
        }
    }
    return -1;
}
DYLD_INTERPOSE(hooked_SLSSetMenuBarSystemOverrideAlpha, SLSSetMenuBarSystemOverrideAlpha);

__attribute__((constructor))
static void interposer_init(void) {
    fprintf(stderr, "[MenuBarInterposer] Loading into pid %d\n", getpid());

    load_skylight_symbols();

    // Initial check
    force_hide_menu_bar();

    // Periodic check every 500ms from within the process
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                              500 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        force_hide_menu_bar();
    });
    dispatch_resume(timer);

    fprintf(stderr, "[MenuBarInterposer] Dynamic menu bar interposer active\n");
}
