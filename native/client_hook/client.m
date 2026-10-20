//
// client.m - Dynamic Library for AppKit Window Decoration Interposition
// HyprMac macOS Window Manager
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <stdio.h>

#pragma mark - Helper Functions

static BOOL is_browser_or_selftheming_app(void) {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleId) {
        NSString *lower = [bundleId lowercaseString];
        if ([lower containsString:@"zen"] || [lower containsString:@"ghostty"] || [lower containsString:@"kitty"]) {
            return YES;
        }
    }
    NSString *procName = [[NSProcessInfo processInfo] processName];
    if (procName) {
        NSString *lower = [procName lowercaseString];
        if ([lower containsString:@"zen"] || [lower containsString:@"ghostty"] || [lower containsString:@"kitty"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL is_standard_window(NSWindow *window) {
    if (!window || ![window isKindOfClass:[NSWindow class]]) {
        return NO;
    }

    if (!(window.styleMask & NSWindowStyleMaskTitled)) {
        return NO;
    }

    const char *ignored_prefixes[] = {
        "NSStatusBar",
        "NSSavePanel",
        "NSOpenPanel",
        "NSFontPanel",
        "NSColorPanel",
        "NSContextMenuWindow",
        "NSCorrectionPanel",
        "NSCandidateListWindow",
        "TUINSWindow",
        "MOZCellDrawWindow",
        NULL
    };

    const char *cls = object_getClassName(window);
    for (int i = 0; ignored_prefixes[i] != NULL; i++) {
        if (strncmp(cls, ignored_prefixes[i], strlen(ignored_prefixes[i])) == 0) {
            return NO;
        }
    }

    Class panelClass = objc_getClass("NSPanel");
    if (panelClass && [window isKindOfClass:panelClass]) {
        return NO;
    }

    NSRect frame = window.frame;
    if (frame.size.width < 100 || frame.size.height < 100) {
        return NO;
    }

    return YES;
}

static const char *kHyprWindowStrippedKey = "kHyprWindowStrippedKey";
static const char *kHyprZenDrawerKey = "kHyprZenDrawerKey";

@class HyprZenDrawer;
__attribute__((visibility("default")))
HyprZenDrawer *hypr_get_drawer(NSWindow *win) {
    if (!win) return nil;
    return objc_getAssociatedObject(win, kHyprZenDrawerKey);
}

#pragma mark - Zen Sidebar Drawer

@interface HyprDrawerTriggerView : NSView
@property (nonatomic, weak) HyprZenDrawer *drawer;
@property (nonatomic, copy) void (^onMouseEnter)(void);
@end

@implementation HyprDrawerTriggerView {
    NSTrackingArea *_trackingArea;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:(NSTrackingMouseEnteredAndExited |
                                                          NSTrackingMouseMoved |
                                                          NSTrackingActiveAlways |
                                                          NSTrackingInVisibleRect)
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    if (self.onMouseEnter) self.onMouseEnter();
}

- (void)mouseMoved:(NSEvent *)event {
    (void)event;
    if (self.onMouseEnter) self.onMouseEnter();
}

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

@end

__attribute__((visibility("default")))
@interface HyprZenDrawer : NSObject
@property (nonatomic, weak) NSWindow *window;
@property (nonatomic, weak) NSSplitView *splitView;
@property (nonatomic, weak) NSView *sidebarWrapper;
@property (nonatomic, weak) NSView *contentWrapper;
@property (nonatomic, weak) NSView *shadowView;
@property (nonatomic, strong) HyprDrawerTriggerView *triggerView;
@property (nonatomic, assign) BOOL isOpen;
@property (nonatomic, assign) BOOL inLayout;
@property (nonatomic, assign) CGFloat sidebarWidth;
@property (nonatomic, assign) uint64_t closeGeneration;
@property (nonatomic, strong) id mouseMoveMonitor;
@property (nonatomic, strong) id mouseDownMonitor;
- (void)attachToWindow:(NSWindow *)win sidebar:(NSView *)sidebar shadow:(NSView *)shadow;
- (void)layoutSplitView;
- (void)openDrawer;
- (void)closeDrawer;
- (void)scheduleClose;
- (void)cancelCloseTimer;
@end

@implementation HyprZenDrawer

- (void)attachToWindow:(NSWindow *)win sidebar:(NSView *)sidebar shadow:(NSView *)shadow {
    if (!win || !sidebar) return;
    self.window = win;
    self.sidebarWrapper = sidebar;
    self.shadowView = shadow;
    self.sidebarWidth = sidebar.frame.size.width > 50.0 ? sidebar.frame.size.width : 196.0;

    if ([sidebar.superview isKindOfClass:[NSSplitView class]]) {
        self.splitView = (NSSplitView *)sidebar.superview;
        for (NSView *sib in sidebar.superview.subviews) {
            if (sib != sidebar && [sib.className containsString:@"NSSplitViewItemViewWrapper"]) {
                self.contentWrapper = sib;
                break;
            }
        }
    }

    win.acceptsMouseMovedEvents = YES;

    // SplitView setup: layer-backed, zero divider thickness, non-clipping for floating shadow
    if (self.splitView) {
        self.splitView.wantsLayer = YES;
        self.splitView.layer.masksToBounds = NO;
    }

    // Sidebar overlay styling: elevated z-index, deep drop shadow to the right
    sidebar.wantsLayer = YES;
    sidebar.layer.zPosition = 1000.0;
    sidebar.layer.masksToBounds = NO;
    sidebar.layer.shadowColor = [NSColor blackColor].CGColor;
    sidebar.layer.shadowOpacity = 0.55;
    sidebar.layer.shadowRadius = 24.0;
    sidebar.layer.shadowOffset = CGSizeMake(8.0, 0.0);

    // Suppress internal narrow Apple shadow view
    if (shadow) {
        shadow.hidden = YES;
        shadow.alphaValue = 0.0;
    }

    if (!self.isOpen) {
        sidebar.layer.transform = CATransform3DMakeTranslation(-self.sidebarWidth, 0.0, 0.0);
        sidebar.alphaValue = 0.0;
        sidebar.hidden = YES;
    }

    // Force edge-to-edge layout so content view spans the full width immediately
    [self layoutSplitView];

    NSView *contentView = win.contentView;
    if (contentView) {
        if (!self.triggerView || self.triggerView.superview != contentView) {
            [self.triggerView removeFromSuperview];
            self.triggerView = [[HyprDrawerTriggerView alloc] initWithFrame:NSMakeRect(0, 0, 16.0, contentView.bounds.size.height)];
            self.triggerView.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
            self.triggerView.drawer = self;
            __weak typeof(self) weakSelf = self;
            self.triggerView.onMouseEnter = ^{
                [weakSelf openDrawer];
            };
            [contentView addSubview:self.triggerView positioned:NSWindowAbove relativeTo:nil];
        }
    }

    if (!self.mouseMoveMonitor) {
        __weak typeof(self) weakSelf = self;
        self.mouseMoveMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged) handler:^NSEvent *(NSEvent *event) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.window) return event;

            if (event.window != strongSelf.window) {
                if (strongSelf.isOpen) {
                    [strongSelf scheduleClose];
                }
                return event;
            }

            NSPoint pt = event.locationInWindow;
            CGFloat w = strongSelf.sidebarWidth;
            CGFloat h = strongSelf.window.frame.size.height;

            if (!strongSelf.isOpen) {
                if (pt.x <= 16.0 && pt.y >= 0.0 && pt.y <= h) {
                    [strongSelf openDrawer];
                }
            } else {
                if (pt.x > (w + 15.0) || pt.x < 0.0 || pt.y < 0.0 || pt.y > h) {
                    [strongSelf scheduleClose];
                } else {
                    [strongSelf cancelCloseTimer];
                }
            }
            return event;
        }];
    }

    if (!self.mouseDownMonitor) {
        __weak typeof(self) weakSelf = self;
        self.mouseDownMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.window) return event;
            if (event.window != strongSelf.window) return event;

            if (strongSelf.isOpen && event.locationInWindow.x > strongSelf.sidebarWidth) {
                [strongSelf closeDrawer];
            }
            return event;
        }];
    }
}

- (void)layoutSplitView {
    if (self.inLayout) return;
    self.inLayout = YES;
    @try {
        NSSplitView *sv = self.splitView;
        if (!sv) return;

        NSRect bounds = sv.bounds;
        if (bounds.size.width < 50.0 || bounds.size.height < 50.0) return;

        CGFloat h = bounds.size.height;
        CGFloat totalW = bounds.size.width;
        CGFloat sbW = self.sidebarWidth;
        if (sbW < 100.0) sbW = 196.0;

        sv.wantsLayer = YES;
        sv.layer.masksToBounds = NO;

        // 1. Content wrapper occupies 100% full bounds from x = 0 to totalW
        NSView *cw = self.contentWrapper;
        if (cw) {
            cw.wantsLayer = YES;
            cw.layer.zPosition = 0.0;
            NSRect contentFrame = bounds;
            if (!NSEqualRects(cw.frame, contentFrame)) {
                cw.frame = contentFrame;
                [cw setNeedsLayout:YES];
            }
        }

        // 2. Sidebar wrapper floats on top at (0, 0, sbW, h)
        NSView *sw = self.sidebarWrapper;
        if (sw) {
            sw.wantsLayer = YES;
            sw.layer.zPosition = 1000.0;
            sw.layer.masksToBounds = NO;
            NSRect sidebarFrame = NSMakeRect(0, 0, sbW, h);
            if (!NSEqualRects(sw.frame, sidebarFrame)) {
                sw.frame = sidebarFrame;
                [sw setNeedsLayout:YES];
            }
        }

        // 3. Keep internal shadow hidden
        if (self.shadowView) {
            self.shadowView.hidden = YES;
            self.shadowView.alphaValue = 0.0;
        }
    } @finally {
        self.inLayout = NO;
    }
}

- (void)openDrawer {
    if (self.isOpen) return;
    self.isOpen = YES;
    [self cancelCloseTimer];

    NSView *sidebar = self.sidebarWrapper;
    if (!sidebar) return;

    sidebar.hidden = NO;
    sidebar.alphaValue = 1.0;

    [CATransaction begin];
    [CATransaction setAnimationDuration:0.10];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];

    sidebar.layer.transform = CATransform3DIdentity;

    [CATransaction commit];
}

- (void)scheduleClose {
    if (!self.isOpen) return;
    uint64_t gen = ++self.closeGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf.closeGeneration == gen && strongSelf.isOpen) {
            [strongSelf closeDrawer];
        }
    });
}

- (void)cancelCloseTimer {
    self.closeGeneration++;
}

- (void)closeDrawer {
    if (!self.isOpen) return;
    self.isOpen = NO;
    [self cancelCloseTimer];

    NSView *sidebar = self.sidebarWrapper;
    if (!sidebar) return;

    CGFloat w = self.sidebarWidth;
    CATransform3D offscreen = CATransform3DMakeTranslation(-w, 0.0, 0.0);

    [CATransaction begin];
    [CATransaction setAnimationDuration:0.10];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn]];
    [CATransaction setCompletionBlock:^{
        if (!self.isOpen) {
            sidebar.alphaValue = 0.0;
            sidebar.hidden = YES;
        }
    }];

    sidebar.layer.transform = offscreen;

    [CATransaction commit];
}

- (void)dealloc {
    [self cancelCloseTimer];
    if (self.mouseMoveMonitor) {
        [NSEvent removeMonitor:self.mouseMoveMonitor];
        self.mouseMoveMonitor = nil;
    }
    if (self.mouseDownMonitor) {
        [NSEvent removeMonitor:self.mouseDownMonitor];
        self.mouseDownMonitor = nil;
    }
}

@end

#pragma mark - Split View Item Wrapper Hit-Testing Swizzle

static NSView *(*s_orig_wrapper_hitTest)(id, SEL, NSPoint) = NULL;
static NSView *hypr_wrapper_hitTest(id self, SEL _cmd, NSPoint pt) {
    NSWindow *win = [self window];
    if (win) {
        HyprZenDrawer *drawer = hypr_get_drawer(win);
        if (drawer && drawer.sidebarWrapper == self && !drawer.isOpen) {
            return nil; // Completely bypass hit testing when closed! Clicks go straight to icons underneath!
        }
    }
    if (s_orig_wrapper_hitTest) {
        return s_orig_wrapper_hitTest(self, _cmd, pt);
    }
    return nil;
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
        BOOL alreadyStripped = [objc_getAssociatedObject(window, kHyprWindowStrippedKey) boolValue];

        // 1. Strip window shadow completely
        if (window.hasShadow || !alreadyStripped) {
            window.hasShadow = NO;
            [window invalidateShadow];
        }

        // 2. Hide titlebar & make content view full size if titled
        if (window.styleMask & NSWindowStyleMaskTitled) {
            if (window.titleVisibility != NSWindowTitleHidden) {
                window.titleVisibility = NSWindowTitleHidden;
            }
            if (!window.titlebarAppearsTransparent) {
                window.titlebarAppearsTransparent = YES;
            }
            if (!(window.styleMask & NSWindowStyleMaskFullSizeContentView)) {
                window.styleMask |= NSWindowStyleMaskFullSizeContentView;
            }
        }

        // Enable window surface transparency and behind-window vibrancy
        if (window.isOpaque) {
            window.opaque = NO;
        }
        if (![window.backgroundColor isEqual:[NSColor clearColor]]) {
            window.backgroundColor = [NSColor clearColor];
        }
        if ([window.contentView isKindOfClass:[NSVisualEffectView class]]) {
            NSVisualEffectView *vev = (NSVisualEffectView *)window.contentView;
            if (vev.material != NSVisualEffectMaterialFullScreenUI) {
                vev.material = NSVisualEffectMaterialFullScreenUI;
            }
            if (vev.blendingMode != NSVisualEffectBlendingModeBehindWindow) {
                vev.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            }
            if (vev.state != NSVisualEffectStateActive) {
                vev.state = NSVisualEffectStateActive;
            }
        }

        // 3. Permanently hide standard traffic light buttons (do NOT removeFromSuperview)
        NSButton *closeBtn = [window standardWindowButton:NSWindowCloseButton];
        if (closeBtn) {
            closeBtn.hidden = NO;
            closeBtn.alphaValue = 0.0;
            closeBtn.frame = NSMakeRect(0, 0, 14.0, 14.0);
            closeBtn.enabled = YES; // MUST remain enabled so Cmd+W, performClose: and AXPress close actions succeed!
        }
        NSButton *minBtn = [window standardWindowButton:NSWindowMiniaturizeButton];
        if (minBtn) {
            minBtn.hidden = YES;
            minBtn.alphaValue = 0.0;
            minBtn.frame = NSZeroRect;
            minBtn.enabled = NO;
        }
        NSButton *zoomBtn = [window standardWindowButton:NSWindowZoomButton];
        if (zoomBtn) {
            zoomBtn.hidden = YES;
            zoomBtn.alphaValue = 0.0;
            zoomBtn.frame = NSZeroRect;
            zoomBtn.enabled = NO;
        }

        // 4. Remove titlebar separator line (macOS 11+)
        if ([window respondsToSelector:@selector(setTitlebarSeparatorStyle:)]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(window, @selector(setTitlebarSeparatorStyle:), 0);
        }

        // 5. Invoke modern macOS corner radii methods (only on initial decoration stripping)
        if (!alreadyStripped) {
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
        }

        // 6. Ensure themeFrame and titlebar container views do not induce black bars or show buttons
        NSView *contentView = window.contentView;
        if (contentView) {
            NSView *themeFrame = contentView.superview;
            if (themeFrame) {
                if (themeFrame.layer) {
                    themeFrame.layer.backgroundColor = nil;
                    themeFrame.layer.opaque = NO;
                    themeFrame.layer.cornerRadius = 0.0;
                    themeFrame.layer.masksToBounds = NO;
                    if (themeFrame.layer.mask) {
                        themeFrame.layer.mask = nil;
                    }
                    for (CALayer *sub in themeFrame.layer.sublayers) {
                        if ([NSStringFromClass([sub class]) containsString:@"WindowFrameLayer"]) {
                            sub.hidden = YES;
                            sub.opacity = 0.0;
                        }
                    }
                }
                for (NSView *sub in themeFrame.subviews) {
                    if (sub != contentView) {
                        Class containerClass = objc_getClass("NSTitlebarContainerView");
                        if (containerClass && [sub isKindOfClass:containerClass]) {
                            sub.translatesAutoresizingMaskIntoConstraints = NO;
                            sub.hidden = YES;
                            sub.alphaValue = 0.0;
                            if (sub.layer) {
                                sub.layer.backgroundColor = nil;
                                sub.layer.opaque = NO;
                            }
                        }
                    }
                }
            }

            // Adjust scroll view insets for edge-to-edge layout & keep scrollbars visible
            if (!alreadyStripped) {
                void (^configure_scroll_views)(NSView *, void (^)(NSView *, id)) = ^(NSView *view, void (^selfBlock)(NSView *, id)) {
                    if (!view) return;
                    if ([view isKindOfClass:[NSScrollView class]]) {
                        NSScrollView *sv = (NSScrollView *)view;
                        sv.automaticallyAdjustsContentInsets = NO;
                        NSEdgeInsets insets = sv.contentInsets;
                        // 12pt top breathing room prevents top icon row clipping
                        insets.top = 12.0;
                        if (![view.className containsString:@"TSidebar"]) {
                            insets.left = 0.0; // Reclaim 100% full width for icons!
                            sv.hasVerticalScroller = YES;
                            sv.autohidesScrollers = NO;
                        }
                        // insets.bottom is preserved so the bottom ribbon stays clean and unclipped!
                        sv.contentInsets = insets;
                    }
                    for (NSView *sub in view.subviews) {
                        selfBlock(sub, selfBlock);
                    }
                };
                configure_scroll_views(contentView, configure_scroll_views);
                [contentView setNeedsLayout:YES];
            }

            // Configure Zen-style hover drawer for Finder sidebar
            if (!objc_getAssociatedObject(window, kHyprZenDrawerKey)) {
                void (^findSidebarAndSetupDrawer)(NSView *, void (^)(NSView *, id)) = ^(NSView *v, void (^selfBlock)(NSView *, id)) {
                    if ([v.className isEqualToString:@"NSKVONotifying_TSidebarScrollView"] || [v.className containsString:@"TSidebarScrollView"]) {
                        NSView *wrapper = v.superview;
                        while (wrapper && ![wrapper.className containsString:@"NSSplitViewItemViewWrapper"]) {
                            wrapper = wrapper.superview;
                        }
                        if (wrapper) {
                            NSView *shadow = nil;
                            for (NSView *sib in wrapper.superview.subviews) {
                                if ([sib.className containsString:@"ShadowView"]) {
                                    shadow = sib;
                                    break;
                                }
                            }
                            HyprZenDrawer *drawer = [[HyprZenDrawer alloc] init];
                            objc_setAssociatedObject(window, kHyprZenDrawerKey, drawer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            [drawer attachToWindow:window sidebar:wrapper shadow:shadow];
                        }
                        return;
                    }
                    for (NSView *sub in v.subviews) {
                        selfBlock(sub, selfBlock);
                    }
                };
                findSidebarAndSetupDrawer(contentView, findSidebarAndSetupDrawer);
            }
        }

        if (!alreadyStripped) {
            objc_setAssociatedObject(window, kHyprWindowStrippedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } @catch (NSException *exception) {
        // Safe fail-closed
    } @finally {
        s_in_strip = NO;
    }
}

#pragma mark - Method Swizzling

@interface NSWindow (HyprClientSwizzle)
- (void)hypr_makeKeyAndOrderFront:(id)sender;
- (void)hypr_orderFront:(id)sender;
- (void)hypr_setContentView:(NSView *)view;
- (BOOL)hypr_isOpaque;
- (void)hypr_performClose:(id)sender;
- (void)hypr_setOpaque:(BOOL)opaque;
- (void)hypr_setBackgroundColor:(NSColor *)color;
- (BOOL)hypr_performKeyEquivalent:(NSEvent *)event;
- (BOOL)hypr_validateMenuItem:(NSMenuItem *)menuItem;
- (BOOL)hypr_validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item;
- (void)hypr_sendEvent:(NSEvent *)event;
- (BOOL)hypr_canBecomeKeyWindow;
- (BOOL)hypr_canBecomeMainWindow;
@end

@implementation NSWindow (HyprClientSwizzle)

- (void)hypr_makeKeyAndOrderFront:(id)sender {
    [self hypr_makeKeyAndOrderFront:sender];
    strip_window_decorations(self);
}

- (void)hypr_orderFront:(id)sender {
    [self hypr_orderFront:sender];
    strip_window_decorations(self);
}

- (void)hypr_setContentView:(NSView *)view {
    [self hypr_setContentView:view];
    strip_window_decorations(self);
}

- (BOOL)hypr_isOpaque {
    if (is_standard_window(self)) {
        return NO;
    }
    return [self hypr_isOpaque];
}

- (void)hypr_setOpaque:(BOOL)opaque {
    if (is_standard_window(self)) {
        [self hypr_setOpaque:NO];
    } else {
        [self hypr_setOpaque:opaque];
    }
}

- (void)hypr_setBackgroundColor:(NSColor *)color {
    if (is_standard_window(self)) {
        [self hypr_setBackgroundColor:[NSColor clearColor]];
    } else {
        [self hypr_setBackgroundColor:color];
    }
}

- (void)hypr_performClose:(id)sender {
    if (is_standard_window(self)) {
        [self close];
        return;
    }
    [self hypr_performClose:sender];
}

- (BOOL)hypr_performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSString *chars = [event charactersIgnoringModifiers];
    BOOL isCmd = (flags == NSEventModifierFlagCommand);
    BOOL isAlt = (flags == NSEventModifierFlagOption);
    BOOL isCmdOpt = (flags == (NSEventModifierFlagCommand | NSEventModifierFlagOption));

    if ((isCmd || isAlt) && ([chars isEqualToString:@"w"] || [chars isEqualToString:@"W"])) {
        if (is_standard_window(self)) {
            [self close];
            return YES;
        }
    }

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    BOOL isFinder = [bundleId isEqualToString:@"com.apple.finder"];

    if (isFinder) {
        if ((isCmd || isAlt) && ([chars isEqualToString:@"q"] || [chars isEqualToString:@"Q"])) {
            [self close];
            return YES;
        }
        if (isCmdOpt && ([chars isEqualToString:@"w"] || [chars isEqualToString:@"W"])) {
            for (NSWindow *w in [[NSApplication sharedApplication] windows]) {
                if (is_standard_window(w)) {
                    [w close];
                }
            }
            return YES;
        }
    }
    return [self hypr_performKeyEquivalent:event];
}

- (void)hypr_sendEvent:(NSEvent *)event {
    if ([event type] == NSEventTypeKeyDown) {
        NSEventModifierFlags flags = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
        NSString *chars = [event charactersIgnoringModifiers];
        BOOL isCmd = (flags == NSEventModifierFlagCommand);
    BOOL isAlt = (flags == NSEventModifierFlagOption);
        BOOL isCmdOpt = (flags == (NSEventModifierFlagCommand | NSEventModifierFlagOption));

        if ((isCmd || isAlt) && ([chars isEqualToString:@"w"] || [chars isEqualToString:@"W"])) {
            if (is_standard_window(self)) {
                [self close];
                return;
            }
        }

        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleId isEqualToString:@"com.apple.finder"]) {
            if ((isCmd || isAlt) && ([chars isEqualToString:@"q"] || [chars isEqualToString:@"Q"])) {
                [self close];
                return;
            }
        if (isCmdOpt && ([chars isEqualToString:@"w"] || [chars isEqualToString:@"W"])) {
                for (NSWindow *w in [[NSApplication sharedApplication] windows]) {
                    if (is_standard_window(w)) {
                        [w close];
                    }
                }
                return;
            }
        }
    }
    [self hypr_sendEvent:event];
}

- (BOOL)hypr_canBecomeKeyWindow {
    if (is_standard_window(self)) {
        return YES;
    }
    return [self hypr_canBecomeKeyWindow];
}

- (BOOL)hypr_canBecomeMainWindow {
    if (is_standard_window(self)) {
        return YES;
    }
    return [self hypr_canBecomeMainWindow];
}

- (BOOL)hypr_validateMenuItem:(NSMenuItem *)menuItem {
    if ([menuItem action] == @selector(performClose:)) {
        return YES;
    }
    return [self hypr_validateMenuItem:menuItem];
}

- (BOOL)hypr_validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    if ([item action] == @selector(performClose:)) {
        return YES;
    }
    return [self hypr_validateUserInterfaceItem:item];
}

@end

#pragma mark - Split View Edge-to-Edge Layout Swizzles

@interface NSSplitView (HyprDrawerSplitView)
- (void)hypr_layout;
- (void)hypr_adjustSubviews;
- (CGFloat)hypr_dividerThickness;
- (void)hypr_drawDividerInRect:(NSRect)rect;
@end

@implementation NSSplitView (HyprDrawerSplitView)

- (void)hypr_layout {
    [self hypr_layout];
    NSWindow *win = [self window];
    if (win) {
        HyprZenDrawer *drawer = hypr_get_drawer(win);
        if (drawer && drawer.splitView == self) {
            [drawer layoutSplitView];
        }
    }
}

- (void)hypr_adjustSubviews {
    NSWindow *win = [self window];
    HyprZenDrawer *drawer = win ? hypr_get_drawer(win) : nil;
    if (drawer && drawer.splitView == self) {
        NSRect bounds = self.bounds;
        CGFloat sbW = drawer.sidebarWidth > 50.0 ? drawer.sidebarWidth : 196.0;
        if (drawer.contentWrapper) {
            drawer.contentWrapper.frame = bounds;
        }
        if (drawer.sidebarWrapper) {
            drawer.sidebarWrapper.frame = NSMakeRect(0, 0, sbW, bounds.size.height);
        }
        return;
    }
    [self hypr_adjustSubviews];
}

- (CGFloat)hypr_dividerThickness {
    NSWindow *win = [self window];
    if (win) {
        HyprZenDrawer *drawer = hypr_get_drawer(win);
        if (drawer && drawer.splitView == self) {
            return 0.0;
        }
    }
    return [self hypr_dividerThickness];
}

- (void)hypr_drawDividerInRect:(NSRect)rect {
    NSWindow *win = [self window];
    if (win) {
        HyprZenDrawer *drawer = hypr_get_drawer(win);
        if (drawer && drawer.splitView == self) {
            return;
        }
    }
    [self hypr_drawDividerInRect:rect];
}

@end

#pragma mark - Scroll View Edge-to-Edge Swizzles

@interface NSScrollView (HyprEdgeToEdge)
- (void)hypr_setContentInsets:(NSEdgeInsets)insets;
- (NSEdgeInsets)hypr_adjustedContentInsets;
- (BOOL)hypr_automaticallyAdjustsContentInsets;
@end

@implementation NSScrollView (HyprEdgeToEdge)

- (void)hypr_setContentInsets:(NSEdgeInsets)insets {
    if (![NSStringFromClass([self class]) containsString:@"Sidebar"]) {
        insets.left = 0.0;
        insets.top = 12.0;
    }
    [self hypr_setContentInsets:insets];
}

- (NSEdgeInsets)hypr_adjustedContentInsets {
    NSEdgeInsets insets = [self hypr_adjustedContentInsets];
    if (![NSStringFromClass([self class]) containsString:@"Sidebar"]) {
        insets.left = 0.0;
        insets.top = 12.0;
    }
    return insets;
}

- (BOOL)hypr_automaticallyAdjustsContentInsets {
    if (![NSStringFromClass([self class]) containsString:@"Sidebar"]) {
        return NO;
    }
    return [self hypr_automaticallyAdjustsContentInsets];
}

@end


static BOOL hypr_return_NO(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NO;
}

static double hypr_zero_double(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return 0.0;
}

static NSRect hypr_zero_rect(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NSZeroRect;
}

static void hypr_noop(id self, SEL _cmd) {
    (void)self; (void)_cmd;
}

static void hypr_noop_event(id self, SEL _cmd, id event) {
    (void)self; (void)_cmd; (void)event;
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

static void (*s_orig_widget_setHidden)(id, SEL, BOOL) = NULL;
static void hypr_widget_setHidden(id self, SEL _cmd, BOOL hidden) {
    (void)hidden;
    if (s_orig_widget_setHidden) {
        s_orig_widget_setHidden(self, _cmd, YES);
    }
}

static void (*s_orig_widget_setAlphaValue)(id, SEL, double) = NULL;
static void hypr_widget_setAlphaValue(id self, SEL _cmd, double alpha) {
    (void)alpha;
    if (s_orig_widget_setAlphaValue) {
        s_orig_widget_setAlphaValue(self, _cmd, 0.0);
    }
}

static void (*s_orig_widget_setRevealAmount)(id, SEL, double) = NULL;
static void hypr_widget_setRevealAmount(id self, SEL _cmd, double amount) {
    (void)amount;
    if (s_orig_widget_setRevealAmount) {
        s_orig_widget_setRevealAmount(self, _cmd, 0.0);
    }
}

static void hypr_swizzle(Class cls, SEL origSEL, SEL swizSEL) {
    Method origMethod = class_getInstanceMethod(cls, origSEL);
    Method swizMethod = class_getInstanceMethod(cls, swizSEL);
    if (!origMethod || !swizMethod) {
        return;
    }

    if (class_addMethod(cls, origSEL, method_getImplementation(swizMethod), method_getTypeEncoding(swizMethod))) {
        class_replaceMethod(cls, swizSEL, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, swizMethod);
    }
}

#pragma mark - Constructor / Entry Point

__attribute__((constructor))
static void hypr_client_entry(void) {
    // Interpose and strip GUI applications
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (is_browser_or_selftheming_app()) {
            return;
        }

        Class windowClass = [NSWindow class];
        if (!windowClass) {
            return;
        }

        static const char *kHyprSwizzledKey = "kHyprSwizzledKey";
        if (objc_getAssociatedObject(windowClass, kHyprSwizzledKey)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                for (NSWindow *win in [NSApp windows]) {
                    strip_window_decorations(win);
                }
            });
            return;
        }
        objc_setAssociatedObject(windowClass, kHyprSwizzledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        hypr_swizzle(windowClass, @selector(makeKeyAndOrderFront:), @selector(hypr_makeKeyAndOrderFront:));
        hypr_swizzle(windowClass, @selector(orderFront:), @selector(hypr_orderFront:));
        hypr_swizzle(windowClass, @selector(setContentView:), @selector(hypr_setContentView:));
        hypr_swizzle(windowClass, @selector(isOpaque), @selector(hypr_isOpaque));
        hypr_swizzle(windowClass, @selector(setOpaque:), @selector(hypr_setOpaque));
        hypr_swizzle(windowClass, @selector(setBackgroundColor:), @selector(hypr_setBackgroundColor:));
        hypr_swizzle(windowClass, @selector(performClose:), @selector(hypr_performClose:));
        hypr_swizzle(windowClass, @selector(performKeyEquivalent:), @selector(hypr_performKeyEquivalent:));
        hypr_swizzle(windowClass, @selector(validateMenuItem:), @selector(hypr_validateMenuItem:));
        hypr_swizzle(windowClass, @selector(validateUserInterfaceItem:), @selector(hypr_validateUserInterfaceItem:));
        hypr_swizzle(windowClass, @selector(sendEvent:), @selector(hypr_sendEvent:));
        hypr_swizzle(windowClass, @selector(canBecomeKeyWindow), @selector(hypr_canBecomeKeyWindow));
        hypr_swizzle(windowClass, @selector(canBecomeMainWindow), @selector(hypr_canBecomeMainWindow));

        Class splitViewClass = [NSSplitView class];
        if (splitViewClass) {
            hypr_swizzle(splitViewClass, @selector(layout), @selector(hypr_layout));
            hypr_swizzle(splitViewClass, @selector(adjustSubviews), @selector(hypr_adjustSubviews));
            hypr_swizzle(splitViewClass, @selector(dividerThickness), @selector(hypr_dividerThickness));
            hypr_swizzle(splitViewClass, @selector(drawDividerInRect:), @selector(hypr_drawDividerInRect:));
        }

        Class scrollViewClass = [NSScrollView class];
        if (scrollViewClass) {
            hypr_swizzle(scrollViewClass, @selector(setContentInsets:), @selector(hypr_setContentInsets:));
            hypr_swizzle(scrollViewClass, @selector(adjustedContentInsets), @selector(hypr_adjustedContentInsets));
            hypr_swizzle(scrollViewClass, @selector(automaticallyAdjustsContentInsets), @selector(hypr_automaticallyAdjustsContentInsets));
        }

        // Swizzle NSWindow corner methods
        Method mWinRadius = class_getInstanceMethod(windowClass, sel_registerName("_cornerRadius"));
        if (mWinRadius) method_setImplementation(mWinRadius, (IMP)hypr_zero_double);

        Method mWinRadii = class_getInstanceMethod(windowClass, sel_registerName("_cornerRadii"));
        if (mWinRadii) method_setImplementation(mWinRadii, (IMP)hypr_zero_cornerRadii);

        // Swizzle NSThemeFrame surface rounding and corner calculation methods
        Class themeFrameClass = objc_getClass("NSThemeFrame");
        if (themeFrameClass) {
            Method mShouldRound = class_getInstanceMethod(themeFrameClass, sel_registerName("_shouldRoundCornersForSurface"));
            if (mShouldRound) method_setImplementation(mShouldRound, (IMP)hypr_return_NO);

            Method mTopRound = class_getInstanceMethod(themeFrameClass, sel_registerName("topCornerRounded"));
            if (mTopRound) method_setImplementation(mTopRound, (IMP)hypr_return_NO);

            Method mBottomRound = class_getInstanceMethod(themeFrameClass, sel_registerName("bottomCornerRounded"));
            if (mBottomRound) method_setImplementation(mBottomRound, (IMP)hypr_return_NO);

            Method mCornerRadius = class_getInstanceMethod(themeFrameClass, sel_registerName("_cornerRadius"));
            if (mCornerRadius) method_setImplementation(mCornerRadius, (IMP)hypr_zero_double);

            Method mCornerRadii = class_getInstanceMethod(themeFrameClass, sel_registerName("_cornerRadii"));
            if (mCornerRadii) method_setImplementation(mCornerRadii, (IMP)hypr_zero_cornerRadii);

            Method mCornerMask = class_getInstanceMethod(themeFrameClass, sel_registerName("_cornerMask"));
            if (mCornerMask) method_setImplementation(mCornerMask, (IMP)hypr_nil_cornerMask);

            Method mTitlebarHeight = class_getInstanceMethod(themeFrameClass, sel_registerName("_titlebarHeight"));
            if (mTitlebarHeight) method_setImplementation(mTitlebarHeight, (IMP)hypr_zero_double);

            Method mTitlebarHeightInline = class_getInstanceMethod(themeFrameClass, sel_registerName("_titlebarHeightIncludingInlineToolbar"));
            if (mTitlebarHeightInline) method_setImplementation(mTitlebarHeightInline, (IMP)hypr_zero_double);

            Method mToolbarReserved = class_getInstanceMethod(themeFrameClass, sel_registerName("_hasToolbarReservedSpace"));
            if (mToolbarReserved) method_setImplementation(mToolbarReserved, (IMP)hypr_return_NO);

            Method mCustomTitlebarHeight = class_getInstanceMethod(themeFrameClass, sel_registerName("customTitlebarHeight"));
            if (mCustomTitlebarHeight) method_setImplementation(mCustomTitlebarHeight, (IMP)hypr_zero_double);

            Method mApplySafeArea = class_getInstanceMethod(themeFrameClass, sel_registerName("applySafeAreaInsetsForTransparentTitlebar"));
            if (mApplySafeArea) method_setImplementation(mApplySafeArea, (IMP)hypr_return_NO);
        }

        // Swizzle _NSSplitViewItemViewWrapper hitTest: to pass clicks through when closed
        Class wrapperClass = objc_getClass("_NSSplitViewItemViewWrapper");
        if (wrapperClass) {
            Method mHit = class_getInstanceMethod(wrapperClass, @selector(hitTest:));
            if (mHit) {
                s_orig_wrapper_hitTest = (NSView *(*)(id, SEL, NSPoint))method_getImplementation(mHit);
                if (class_addMethod(wrapperClass, @selector(hitTest:), (IMP)hypr_wrapper_hitTest, method_getTypeEncoding(mHit))) {
                    // Added cleanly
                } else {
                    method_setImplementation(mHit, (IMP)hypr_wrapper_hitTest);
                }
            }
        }

        // Swizzle _NSThemeWidget to permanently intercept mouse hover unhiding (e.g. Electron / Codex sidebar hover)
        Class widgetClass = objc_getClass("_NSThemeWidget");
        if (widgetClass) {
            Method mHidden = class_getInstanceMethod(widgetClass, @selector(setHidden:));
            if (mHidden) {
                s_orig_widget_setHidden = (void (*)(id, SEL, BOOL))method_getImplementation(mHidden);
                method_setImplementation(mHidden, (IMP)hypr_widget_setHidden);
            }

            Method mAlpha = class_getInstanceMethod(widgetClass, @selector(setAlphaValue:));
            if (mAlpha) {
                s_orig_widget_setAlphaValue = (void (*)(id, SEL, double))method_getImplementation(mAlpha);
                method_setImplementation(mAlpha, (IMP)hypr_widget_setAlphaValue);
            }

            SEL selSetReveal = sel_registerName("setRevealAmount:");
            Method mSetReveal = class_getInstanceMethod(widgetClass, selSetReveal);
            if (mSetReveal) {
                s_orig_widget_setRevealAmount = (void (*)(id, SEL, double))method_getImplementation(mSetReveal);
                method_setImplementation(mSetReveal, (IMP)hypr_widget_setRevealAmount);
            }

            SEL selReveal = sel_registerName("revealAmount");
            Method mReveal = class_getInstanceMethod(widgetClass, selReveal);
            if (mReveal) {
                method_setImplementation(mReveal, (IMP)hypr_zero_double);
            }

            SEL selMouse = sel_registerName("mouseEnteredOrExited");
            Method mMouse = class_getInstanceMethod(widgetClass, selMouse);
            if (mMouse) {
                method_setImplementation(mMouse, (IMP)hypr_noop);
            }
        }

        // Swizzle NSTitlebarView mouseEntered: so hovering over titlebar / sidebar does not trigger button reveal
        Class titlebarViewClass = objc_getClass("NSTitlebarView");
        if (titlebarViewClass) {
            Method mTitlebarMouseEntered = class_getInstanceMethod(titlebarViewClass, @selector(mouseEntered:));
            if (mTitlebarMouseEntered) {
                method_setImplementation(mTitlebarMouseEntered, (IMP)hypr_noop_event);
            }
        }

        // Strip all currently open windows immediately upon injection
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSWindow *win in [NSApp windows]) {
                strip_window_decorations(win);
            }
        });

        // Observe window updates to ensure decorations stay stripped across dynamic relayouts
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidUpdateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            id obj = note.object;
            if ([obj isKindOfClass:[NSWindow class]]) {
                NSWindow *win = (NSWindow *)obj;
                if (![objc_getAssociatedObject(win, kHyprWindowStrippedKey) boolValue] || win.hasShadow) {
                    strip_window_decorations(win);
                }
            }
        }];
    });
}


