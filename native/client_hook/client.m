#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <stdio.h>

#pragma mark - Helper Functions

static BOOL is_standard_window(NSWindow *window) {
    if (!window || ![window isKindOfClass:[NSWindow class]]) {
        return NO;
    }

    if (!(window.styleMask & NSWindowStyleMaskTitled)) {
        return NO;
    }

    const char *ignoredClasses[] = {
        "NSStatusBarWindow",
        "NSToolTipPanel",
        "NSMenuPopupWindow",
        "NSCarbonMenuWindow",
        "NSPopoverWindow",
        "_NSPopoverWindow",
        "NSContextMenuWindow",
        "NSCorrectionPanel",
        "NSCandidateListWindow",
        NULL
    };

    for (int i = 0; ignoredClasses[i] != NULL; i++) {
        Class cls = objc_getClass(ignoredClasses[i]);
        if (cls && [window isKindOfClass:cls]) {
            return NO;
        }
    }

    return YES;
}

static void strip_window_decorations(NSWindow *window) {
    if (!window || !is_standard_window(window)) {
        return;
    }

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            strip_window_decorations(window);
        });
        return;
    }

    static __thread BOOL s_in_strip = NO;
    if (s_in_strip) {
        return;
    }
    s_in_strip = YES;

    @try {
        // 1. Strip window shadow completely
        window.hasShadow = NO;
        [window invalidateShadow];

        // 2. Hide titlebar & make content view full size
        window.titleVisibility = NSWindowTitleHidden;
        window.titlebarAppearsTransparent = YES;
        if (!(window.styleMask & NSWindowStyleMaskFullSizeContentView)) {
            window.styleMask |= NSWindowStyleMaskFullSizeContentView;
        }

        // 3. Hide standard traffic light buttons
        NSButton *closeBtn = [window standardWindowButton:NSWindowCloseButton];
        if (closeBtn && !closeBtn.isHidden) {
            [closeBtn setHidden:YES];
        }
        NSButton *minBtn = [window standardWindowButton:NSWindowMiniaturizeButton];
        if (minBtn && !minBtn.isHidden) {
            [minBtn setHidden:YES];
        }
        NSButton *zoomBtn = [window standardWindowButton:NSWindowZoomButton];
        if (zoomBtn && !zoomBtn.isHidden) {
            [zoomBtn setHidden:YES];
        }

        // 4. Remove titlebar separator line (macOS 11+)
        if ([window respondsToSelector:@selector(setTitlebarSeparatorStyle:)]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(window, @selector(setTitlebarSeparatorStyle:), 0);
        }

        // 5. Invoke modern macOS corner radii methods
        Class radiiClass = objc_getClass("NSViewCornerRadii");
        id zeroRadii = nil;
        if (radiiClass) {
            SEL selInitWithRadius = sel_registerName("initWithRadius:");
            if ([radiiClass instancesRespondToSelector:selInitWithRadius]) {
                id alloced = [radiiClass alloc];
                id (*initFn)(id, SEL, double) = (id (*)(id, SEL, double))objc_msgSend;
                zeroRadii = initFn(alloced, selInitWithRadius, 0.0);
            }
        }

        if (zeroRadii) {
            SEL selSetRadii = sel_registerName("_setCornerRadii:");
            if ([window respondsToSelector:selSetRadii]) {
                void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
                fn(window, selSetRadii, zeroRadii);
            }
            SEL selSetEffectiveRadii = sel_registerName("_setEffectiveCornerRadii:");
            if ([window respondsToSelector:selSetEffectiveRadii]) {
                void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
                fn(window, selSetEffectiveRadii, zeroRadii);
            }
        }

        SEL selSetCornerRadius = sel_registerName("_setCornerRadius:");
        if ([window respondsToSelector:selSetCornerRadius]) {
            void (*fn)(id, SEL, double) = (void (*)(id, SEL, double))objc_msgSend;
            fn(window, selSetCornerRadius, 0.0);
        }

        SEL selCornerMaskChanged = sel_registerName("_cornerMaskChanged");
        if ([window respondsToSelector:selCornerMaskChanged]) {
            void (*fn)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
            fn(window, selCornerMaskChanged);
        }

        // 6. Ensure themeFrame and titlebar container views do not induce black bars
        NSView *contentView = window.contentView;
        if (contentView) {
            NSView *themeFrame = contentView.superview;
            if (themeFrame && themeFrame.layer) {
                themeFrame.layer.cornerRadius = 0.0;
                if (themeFrame.layer.mask) {
                    themeFrame.layer.mask = nil;
                }
            }
            if (themeFrame) {
                for (NSView *sub in themeFrame.subviews) {
                    if (sub != contentView) {
                        Class containerClass = objc_getClass("NSTitlebarContainerView");
                        if (containerClass && [sub isKindOfClass:containerClass]) {
                            if (sub.layer) {
                                sub.layer.backgroundColor = nil;
                                sub.layer.opaque = NO;
                            }
                        }
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        // Safe fail-closed
    } @finally {
        s_in_strip = NO;
    }
}

#pragma mark - Swizzling & Replacement Implementations

@interface NSWindow (HyprClientSwizzle)
- (void)hypr_makeKeyAndOrderFront:(id)sender;
- (void)hypr_orderFront:(id)sender;
- (void)hypr_setContentView:(NSView *)view;
- (void)hypr_update;
@end

@implementation NSWindow (HyprClientSwizzle)

- (void)hypr_makeKeyAndOrderFront:(id)sender {
    strip_window_decorations(self);
    [self hypr_makeKeyAndOrderFront:sender];
    strip_window_decorations(self);
}

- (void)hypr_orderFront:(id)sender {
    strip_window_decorations(self);
    [self hypr_orderFront:sender];
    strip_window_decorations(self);
}

- (void)hypr_setContentView:(NSView *)view {
    [self hypr_setContentView:view];
    strip_window_decorations(self);
}

- (void)hypr_update {
    [self hypr_update];
    strip_window_decorations(self);
}

@end

static BOOL hypr_return_NO(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NO;
}

static double hypr_zero_cornerRadius(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return 0.0;
}

static id hypr_nil_cornerMask(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return nil;
}

static id hypr_zero_cornerRadii(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    Class radiiClass = objc_getClass("NSViewCornerRadii");
    if (radiiClass) {
        SEL selInitWithRadius = sel_registerName("initWithRadius:");
        if ([radiiClass instancesRespondToSelector:selInitWithRadius]) {
            id alloced = [radiiClass alloc];
            id (*initFn)(id, SEL, double) = (id (*)(id, SEL, double))objc_msgSend;
            return initFn(alloced, selInitWithRadius, 0.0);
        }
    }
    return nil;
}

static void hypr_swizzle(Class cls, SEL origSEL, SEL swizSEL) {
    Method origMethod = class_getInstanceMethod(cls, origSEL);
    Method swizMethod = class_getInstanceMethod(cls, swizSEL);
    if (!origMethod || !swizMethod) {
        return;
    }

    BOOL didAddMethod = class_addMethod(cls,
                                        origSEL,
                                        method_getImplementation(swizMethod),
                                        method_getTypeEncoding(swizMethod));
    if (didAddMethod) {
        class_replaceMethod(cls,
                            swizSEL,
                            method_getImplementation(origMethod),
                            method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, swizMethod);
    }
}

#pragma mark - Constructor

__attribute__((constructor))
static void hypr_client_init(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fprintf(stderr, "[HyprClient] AppKit window decoration stripper loaded into PID %d\n", getpid());
        fflush(stderr);

        Class windowClass = [NSWindow class];
        if (!windowClass) {
            return;
        }

        hypr_swizzle(windowClass, @selector(makeKeyAndOrderFront:), @selector(hypr_makeKeyAndOrderFront:));
        hypr_swizzle(windowClass, @selector(orderFront:), @selector(hypr_orderFront:));
        hypr_swizzle(windowClass, @selector(setContentView:), @selector(hypr_setContentView:));
        hypr_swizzle(windowClass, @selector(update), @selector(hypr_update));

        // Swizzle NSWindow corner methods
        Method mWinRadius = class_getInstanceMethod(windowClass, sel_registerName("_cornerRadius"));
        if (mWinRadius) method_setImplementation(mWinRadius, (IMP)hypr_zero_cornerRadius);

        Method mWinRadii = class_getInstanceMethod(windowClass, sel_registerName("_cornerRadii"));
        if (mWinRadii) method_setImplementation(mWinRadii, (IMP)hypr_zero_cornerRadii);

        // Swizzle NSThemeFrame surface rounding and corner calculation methods
        Class themeFrameClass = objc_getClass("NSThemeFrame");
        if (themeFrameClass) {
            // Force surface rounding checks to return NO:
            Method mShouldRound = class_getInstanceMethod(themeFrameClass, sel_registerName("_shouldRoundCornersForSurface"));
            if (mShouldRound) method_setImplementation(mShouldRound, (IMP)hypr_return_NO);

            Method mTopRound = class_getInstanceMethod(themeFrameClass, sel_registerName("topCornerRounded"));
            if (mTopRound) method_setImplementation(mTopRound, (IMP)hypr_return_NO);

            Method mBottomRound = class_getInstanceMethod(themeFrameClass, sel_registerName("bottomCornerRounded"));
            if (mBottomRound) method_setImplementation(mBottomRound, (IMP)hypr_return_NO);

            // Force radii and masks to 0 / nil:
            Method mCornerRadius = class_getInstanceMethod(themeFrameClass, sel_registerName("_cornerRadius"));
            if (mCornerRadius) method_setImplementation(mCornerRadius, (IMP)hypr_zero_cornerRadius);

            Method mCornerRadii = class_getInstanceMethod(themeFrameClass, sel_registerName("_cornerRadii"));
            if (mCornerRadii) method_setImplementation(mCornerRadii, (IMP)hypr_zero_cornerRadii);

            Method mCornerMask = class_getInstanceMethod(themeFrameClass, sel_registerName("_cornerMask"));
            if (mCornerMask) method_setImplementation(mCornerMask, (IMP)hypr_nil_cornerMask);
        }

        // Observe window updates to ensure decorations stay stripped across dynamic relayouts
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidUpdateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[NSWindow class]]) {
                strip_window_decorations((NSWindow *)note.object);
            }
        }];
    });
}
