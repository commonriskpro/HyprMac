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
        "Completion",
        "RoundedWindow",
        "NSPopover",
        "Popover",
        NULL
    };

    const char *cls = object_getClassName(window);
    for (int i = 0; ignored_prefixes[i] != NULL; i++) {
        if (strncmp(cls, ignored_prefixes[i], strlen(ignored_prefixes[i])) == 0) {
            return NO;
        }
    }

    if (strstr(cls, "Completion") != NULL || strstr(cls, "Popover") != NULL) {
        return NO;
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

static BOOL is_finder(void) {
    static int s_is_finder = -1;
    if (s_is_finder < 0) {
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        s_is_finder = (bundleId && [bundleId isEqualToString:@"com.apple.finder"]) ? 1 : 0;
    }
    return s_is_finder == 1;
}

static BOOL is_safari(void) {
    static int s_is_safari = -1;
    if (s_is_safari < 0) {
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        s_is_safari = (bundleId && [bundleId isEqualToString:@"com.apple.Safari"]) ? 1 : 0;
    }
    return s_is_safari == 1;
}

static BOOL is_descendant_of_view(NSView *child, NSView *ancestor) {
    if (!child || !ancestor) return NO;
    NSView *v = child;
    while (v) {
        if (v == ancestor) return YES;
        v = v.superview;
    }
    return NO;
}

static void hide_traffic_lights_in_view(NSView *view) {
    if (!view) return;
    if ([view isKindOfClass:[NSButton class]]) {
        NSButton *b = (NSButton *)view;
        SEL act = [b action];
        if (act == @selector(performClose:) || act == @selector(closeWindow:) ||
            act == @selector(performMiniaturize:) || act == @selector(miniaturize:) ||
            act == @selector(performZoom:) || act == @selector(zoom:)) {
            b.hidden = YES;
            b.alphaValue = 0.0;
        }
    }
    if ([NSStringFromClass([view class]) containsString:@"ThemeWidget"]) {
        view.hidden = YES;
        view.alphaValue = 0.0;
    }
    for (NSView *sub in view.subviews) {
        hide_traffic_lights_in_view(sub);
    }
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
@property (nonatomic, weak) NSView *titlebarContainer;
@property (nonatomic, strong) HyprDrawerTriggerView *triggerView;
@property (nonatomic, assign) BOOL isOpen;
@property (nonatomic, assign) BOOL inLayout;
@property (nonatomic, assign) CGFloat sidebarWidth;
@property (nonatomic, assign) uint64_t closeGeneration;
@property (nonatomic, strong) id mouseMoveMonitor;
@property (nonatomic, strong) id mouseDownMonitor;
@property (nonatomic, assign) NSRect lastSafariWinFrame;
@property (nonatomic, assign) CGFloat lastSafariSidebarWidth;
@property (nonatomic, assign) CGFloat lastStyledSafariWidth;
@property (nonatomic, assign) NSUInteger lastToolbarSubviewCount;
@property (nonatomic, assign) BOOL hasStyledSafariSearchBar;
- (void)attachToWindow:(NSWindow *)win sidebar:(NSView *)sidebar shadow:(NSView *)shadow titlebarContainer:(NSView *)titlebarContainer;
- (BOOL)isFocusInDrawer;
- (void)layoutSplitView;
- (void)layoutSafariTopSearchBar;
- (void)openDrawer;
- (void)closeDrawer;
- (void)scheduleClose;
- (void)cancelCloseTimer;
 - (void)setupMonitors;
 - (void)teardownMonitors;
@end

@implementation HyprZenDrawer

- (void)attachToWindow:(NSWindow *)win sidebar:(NSView *)sidebar shadow:(NSView *)shadow titlebarContainer:(NSView *)titlebarContainer {
    if (!win || !sidebar) return;
    self.window = win;
    self.sidebarWrapper = sidebar;
    self.shadowView = shadow;
    self.titlebarContainer = titlebarContainer;
    if (is_safari()) {
        self.sidebarWidth = 280.0;
    } else {
        self.sidebarWidth = sidebar.frame.size.width > 50.0 ? sidebar.frame.size.width : 196.0;
    }

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

    if (titlebarContainer) {
        titlebarContainer.wantsLayer = YES;
        titlebarContainer.layer.zPosition = 1001.0;
        titlebarContainer.layer.masksToBounds = NO;
        CALayer *mask = [CALayer layer];
        mask.frame = CGRectMake(0.0, 0.0, self.sidebarWidth, 52.0);
        mask.backgroundColor = [NSColor blackColor].CGColor;
        titlebarContainer.layer.mask = mask;
        if (!self.isOpen) {
            titlebarContainer.layer.transform = CATransform3DMakeTranslation(-self.sidebarWidth, 0.0, 0.0);
            titlebarContainer.alphaValue = 0.0;
            titlebarContainer.hidden = YES;
        }
    }

    // Force edge-to-edge layout so content view spans the full width immediately
    [self layoutSplitView];
    [self layoutSafariTopSearchBar];

    if (is_safari() && [self isFocusInDrawer]) {
        [self openDrawer];
    }

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

    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowWillCloseNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowWillClose:)
                                                 name:NSWindowWillCloseNotification
                                               object:win];

    [self setupMonitors];
}

- (void)windowWillClose:(NSNotification *)note {
    (void)note;
    [self teardownMonitors];
}

- (void)teardownMonitors {
    if (self.mouseMoveMonitor) {
        [NSEvent removeMonitor:self.mouseMoveMonitor];
        self.mouseMoveMonitor = nil;
    }
    if (self.mouseDownMonitor) {
        [NSEvent removeMonitor:self.mouseDownMonitor];
        self.mouseDownMonitor = nil;
    }
    [self cancelCloseTimer];
}

- (void)setupMonitors {
    if (!self.window) return;
    if (!self.mouseMoveMonitor) {
        __weak typeof(self) weakSelf = self;
        self.mouseMoveMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged) handler:^NSEvent *(NSEvent *event) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.window) return event;

            if (event.window != strongSelf.window) {
                BOOL isChild = NO;
                for (NSWindow *child in strongSelf.window.childWindows) {
                    if (event.window == child) {
                        isChild = YES;
                        break;
                    }
                }
                if (isChild) {
                    [strongSelf cancelCloseTimer];
                } else if (strongSelf.isOpen && ![strongSelf isFocusInDrawer]) {
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
                    if (![strongSelf isFocusInDrawer]) {
                        [strongSelf scheduleClose];
                    }
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
                if ([strongSelf isFocusInDrawer]) {
                    if (![strongSelf.window makeFirstResponder:strongSelf.window.contentView] || [strongSelf isFocusInDrawer]) {
                        [strongSelf.window makeFirstResponder:nil];
                    }
                }
                [strongSelf closeDrawer];
            }
            return event;
        }];
    }
}

- (BOOL)isFocusInDrawer {
    NSWindow *win = self.window;
    if (!win) return NO;
    NSResponder *resp = [win firstResponder];
    if ([resp isKindOfClass:[NSView class]]) {
        NSView *rv = (NSView *)resp;
        if (self.sidebarWrapper && is_descendant_of_view(rv, self.sidebarWrapper)) return YES;
        if (self.titlebarContainer && is_descendant_of_view(rv, self.titlebarContainer)) return YES;
    }
    return NO;
}

- (void)layoutSafariTopSearchBar {
    if (!is_safari() || !self.window || !self.titlebarContainer) return;
    NSView *container = self.titlebarContainer;
    NSRect winFrame = self.window.frame;
    CGFloat sbW = self.sidebarWidth > 100.0 ? self.sidebarWidth : 280.0;
    CGFloat fullW = winFrame.size.width > sbW ? winFrame.size.width : sbW;
    CGFloat bh = 52.0;

    NSRect desiredContainer = NSMakeRect(0.0, winFrame.size.height - bh, fullW, bh);
    if (!NSEqualRects(container.frame, desiredContainer)) {
        container.frame = desiredContainer;
    }
    if (container.layer) {
        if (!container.layer.mask) {
            CALayer *mask = [CALayer layer];
            mask.backgroundColor = [NSColor blackColor].CGColor;
            container.layer.mask = mask;
        }
        CGRect desiredMask = CGRectMake(0.0, 0.0, sbW, bh);
        if (!CGRectEqualToRect(container.layer.mask.frame, desiredMask)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            container.layer.mask.frame = desiredMask;
            [CATransaction commit];
        }
    }

    void (^contains_search)(NSView *, BOOL *, void (^)(NSView *, BOOL *, id)) = ^(NSView *v, BOOL *found, void (^selfBlock)(NSView *, BOOL *, id)) {
        if (*found || !v) return;
        NSString *cls = NSStringFromClass([v class]);
        if ([cls containsString:@"UnifiedTabBar"] || [cls containsString:@"UnifiedField"]) {
            *found = YES;
            return;
        }
        for (NSView *sub in v.subviews) {
            selfBlock(sub, found, selfBlock);
            if (*found) return;
        }
    };

    void (^style_titlebar_tree)(NSView *, void (^)(NSView *, id)) = ^(NSView *v, void (^selfBlock)(NSView *, id)) {
        if (!v) return;
        NSString *cls = NSStringFromClass([v class]);
        if ([cls containsString:@"TitlebarDecorationView"]) {
            v.hidden = YES;
            v.alphaValue = 0.0;
            return;
        }
        if ([cls isEqualToString:@"NSTitlebarView"] || [cls isEqualToString:@"NSToolbarView"] || [cls isEqualToString:@"NSGlassContainerView"]) {
            NSRect r = NSMakeRect(0.0, 0.0, fullW, bh);
            if (!NSEqualRects(v.frame, r)) {
                v.frame = r;
            }
        }
        if ([cls isEqualToString:@"NSToolbarItemViewer"] || [cls containsString:@"ToolbarPlatterView"]) {
            BOOL hasSearch = NO;
            contains_search(v, &hasSearch, contains_search);
            if (hasSearch) {
                if (v.isHidden) v.hidden = NO;
                if (v.alphaValue != 1.0) v.alphaValue = 1.0;
                NSRect itemRect = NSMakeRect(8.0, 0.0, sbW - 16.0, bh);
                if (!NSEqualRects(v.frame, itemRect)) {
                    v.frame = itemRect;
                }
                for (NSView *sub in v.subviews) {
                    if ([NSStringFromClass([sub class]) containsString:@"UnifiedTabBar"]) {
                        NSRect barRect = NSMakeRect(0.0, 8.0, sbW - 16.0, 36.0);
                        SEL selSetCenter = sel_registerName("setUnpinnedTabCenteringFrame:");
                        if ([sub respondsToSelector:selSetCenter]) {
                            void (*setCenterFn)(id, SEL, NSRect) = (void (*)(id, SEL, NSRect))objc_msgSend;
                            setCenterFn(sub, selSetCenter, NSMakeRect(0.0, 0.0, sbW - 16.0, 36.0));
                        }
                        if (!NSEqualRects(sub.frame, barRect)) {
                            sub.frame = barRect;
                            [sub setNeedsLayout:YES];
                            [sub layoutSubtreeIfNeeded];
                        } else {
                            for (NSView *tabSub in sub.subviews) {
                                for (NSView *clipSub in tabSub.subviews) {
                                    for (NSView *contSub in clipSub.subviews) {
                                        if (contSub.frame.origin.x > 4.0 || contSub.frame.origin.x < -4.0) {
                                            [sub setNeedsLayout:YES];
                                            [sub layoutSubtreeIfNeeded];
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                if (!v.isHidden) v.hidden = YES;
                if (v.alphaValue != 0.0) v.alphaValue = 0.0;
            }
            return;
        }
        for (NSView *sub in v.subviews) {
            selfBlock(sub, selfBlock);
        }
    };
    style_titlebar_tree(container, style_titlebar_tree);

    self.lastSafariWinFrame = winFrame;
    self.lastSafariSidebarWidth = sbW;
    self.lastStyledSafariWidth = winFrame.size.width;
    self.hasStyledSafariSearchBar = YES;
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
        CGFloat sbW = self.sidebarWidth;
        if (sbW < 100.0) sbW = 196.0;

        sv.wantsLayer = YES;
        sv.layer.masksToBounds = NO;

        // 1. Content wrapper occupies 100% full bounds from x = 0 to totalW
        NSView *cw = self.contentWrapper;
        if (cw) {
            cw.wantsLayer = YES;
            cw.layer.zPosition = 0.0;
            if ([cw respondsToSelector:@selector(setAdditionalSafeAreaInsets:)]) {
                NSEdgeInsets cur = cw.additionalSafeAreaInsets;
                if (cur.top != 0.0 || cur.left != 0.0 || cur.bottom != 0.0 || cur.right != 0.0) {
                    cw.additionalSafeAreaInsets = NSEdgeInsetsZero;
                }
            }
            NSRect contentFrame = bounds;
            if (!NSEqualRects(cw.frame, contentFrame)) {
                cw.frame = contentFrame;
                [cw setNeedsLayout:YES];
            }
        }

        for (NSLayoutConstraint *c in sv.constraints) {
            if ([c.identifier isEqualToString:@"NSSplitViewItem.safeArea.sidebarTracking"] && c.isActive) {
                c.active = NO;
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

        for (NSView *sub in sv.subviews) {
            if ([NSStringFromClass([sub class]) containsString:@"TitlebarBackgroundView"]) {
                if (!sub.isHidden) sub.hidden = YES;
                if (sub.alphaValue != 0.0) sub.alphaValue = 0.0;
            }
        }

        if (is_safari()) {
            if (cw) {
                void (^hide_content_pockets)(NSView *, void (^)(NSView *, id)) = ^(NSView *v, void (^selfBlock)(NSView *, id)) {
                    NSString *vCls = NSStringFromClass([v class]);
                    if ([vCls containsString:@"ScrollPocket"] || [vCls containsString:@"Pocket"] || [vCls containsString:@"TitlebarBackgroundView"]) {
                        if (!v.isHidden) v.hidden = YES;
                        if (v.alphaValue != 0.0) v.alphaValue = 0.0;
                    }
                    for (NSView *sub in v.subviews) {
                        selfBlock(sub, selfBlock);
                    }
                };
                hide_content_pockets(cw, hide_content_pockets);
            }
            [self layoutSafariTopSearchBar];
        }
    } @finally {
        self.inLayout = NO;
    }
}

- (void)openDrawer {
    [self setupMonitors];
    if (self.isOpen) {
        [self cancelCloseTimer];
        return;
    }
    self.isOpen = YES;
    [self cancelCloseTimer];

    NSView *sidebar = self.sidebarWrapper;
    if (!sidebar) return;

    sidebar.hidden = NO;

    NSView *tb = self.titlebarContainer;
    if (tb) {
        tb.hidden = NO;
    }

    CAMediaTimingFunction *springCurve = [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.3 :1.0];

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.24;
        context.timingFunction = springCurve;
        context.allowsImplicitAnimation = YES;

        [CATransaction begin];
        [CATransaction setAnimationDuration:0.24];
        [CATransaction setAnimationTimingFunction:springCurve];

        CALayer *sbPres = sidebar.layer.presentationLayer;
        if (sbPres) {
            sidebar.layer.transform = sbPres.transform;
        }
        sidebar.layer.transform = CATransform3DIdentity;
        sidebar.alphaValue = 1.0;

        if (tb) {
            CALayer *tbPres = tb.layer.presentationLayer;
            if (tbPres) {
                tb.layer.transform = tbPres.transform;
            }
            tb.layer.transform = CATransform3DIdentity;
            tb.alphaValue = 1.0;
        }

        [CATransaction commit];
    } completionHandler:nil];
}

- (void)scheduleClose {
    if (!self.isOpen) return;
    if ([self isFocusInDrawer]) return;
    if (self.window.attachedSheet != nil) return;
    if (self.window.childWindows.count > 0) {
        for (NSWindow *child in self.window.childWindows) {
            if ([child isVisible]) return;
        }
    }
    NSPoint mouseNow = [self.window mouseLocationOutsideOfEventStream];
    if (mouseNow.x >= 0.0 && mouseNow.x <= self.sidebarWidth && mouseNow.y >= 0.0 && mouseNow.y <= self.window.frame.size.height) {
        return;
    }
    uint64_t gen = ++self.closeGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf.closeGeneration == gen && strongSelf.isOpen) {
            if (![strongSelf isFocusInDrawer] && strongSelf.window.attachedSheet == nil) {
                BOOL hasVisibleChild = NO;
                for (NSWindow *child in strongSelf.window.childWindows) {
                    if (child.isVisible) {
                        hasVisibleChild = YES;
                        break;
                    }
                }
                if (!hasVisibleChild) {
                    NSPoint mouseInWin = [strongSelf.window mouseLocationOutsideOfEventStream];
                    if (mouseInWin.x >= 0.0 && mouseInWin.x <= strongSelf.sidebarWidth && mouseInWin.y >= 0.0 && mouseInWin.y <= strongSelf.window.frame.size.height) {
                        return;
                    }
                    [strongSelf closeDrawer];
                }
            }
        }
    });
}

- (void)cancelCloseTimer {
    self.closeGeneration++;
}

- (void)closeDrawer {
    if (!self.isOpen) return;
    if ([self isFocusInDrawer]) return;
    if (self.window.attachedSheet != nil) return;
    if (self.window.childWindows.count > 0) {
        for (NSWindow *child in self.window.childWindows) {
            if (child.isVisible) return;
        }
    }
    self.isOpen = NO;
    [self cancelCloseTimer];

    NSView *sidebar = self.sidebarWrapper;
    if (!sidebar) return;

    NSView *tb = self.titlebarContainer;
    CGFloat w = self.sidebarWidth;
    CATransform3D offscreen = CATransform3DMakeTranslation(-w, 0.0, 0.0);
    CAMediaTimingFunction *closeCurve = [CAMediaTimingFunction functionWithControlPoints:0.22 :1.0 :0.36 :1.0];

    __weak typeof(self) weakSelf = self;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.22;
        context.timingFunction = closeCurve;
        context.allowsImplicitAnimation = YES;

        [CATransaction begin];
        [CATransaction setAnimationDuration:0.22];
        [CATransaction setAnimationTimingFunction:closeCurve];

        CALayer *sbPres = sidebar.layer.presentationLayer;
        if (sbPres) {
            sidebar.layer.transform = sbPres.transform;
        }
        sidebar.layer.transform = offscreen;
        sidebar.alphaValue = 0.0;

        if (tb) {
            CALayer *tbPres = tb.layer.presentationLayer;
            if (tbPres) {
                tb.layer.transform = tbPres.transform;
            }
            tb.layer.transform = offscreen;
            tb.alphaValue = 0.0;
        }

        [CATransaction commit];
    } completionHandler:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && !strongSelf.isOpen) {
            sidebar.hidden = YES;
            if (tb) {
                tb.hidden = YES;
            }
        }
    }];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self teardownMonitors];
    if (self.triggerView) {
        [self.triggerView removeFromSuperview];
        self.triggerView = nil;
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

static void (*s_orig_wrapper_setAdditionalSafeAreaInsets)(id, SEL, NSEdgeInsets) = NULL;
static void hypr_wrapper_setAdditionalSafeAreaInsets(id self, SEL _cmd, NSEdgeInsets insets) {
    NSWindow *win = [(NSView *)self window];
    if (win) {
        HyprZenDrawer *drawer = hypr_get_drawer(win);
        if (drawer && drawer.contentWrapper == self) {
            insets = NSEdgeInsetsZero;
        }
    }
    if (s_orig_wrapper_setAdditionalSafeAreaInsets) {
        s_orig_wrapper_setAdditionalSafeAreaInsets(self, _cmd, insets);
    }
}

static NSView *(*s_orig_titlebarContainer_hitTest)(id, SEL, NSPoint) = NULL;
static NSView *hypr_titlebarContainer_hitTest(id self, SEL _cmd, NSPoint pt) {
    NSWindow *win = [self window];
    if (win) {
        HyprZenDrawer *drawer = hypr_get_drawer(win);
        if (drawer && drawer.titlebarContainer == self) {
            NSPoint localPt = [(NSView *)self convertPoint:pt fromView:[(NSView *)self superview]];
            if (!drawer.isOpen || localPt.x > drawer.sidebarWidth) {
                return nil; // Pass straight through to WKWebView / StartPage underneath!
            }
        }
    }
    if (s_orig_titlebarContainer_hitTest) {
        return s_orig_titlebarContainer_hitTest(self, _cmd, pt);
    }
    return nil;
}

static Class s_accWrapperClass = nil;
static Class s_sidebarScrollViewClass = nil;
static void init_finder_classes_once(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_accWrapperClass = objc_getClass("_NSSplitViewItemAccessoryViewWrapper");
        s_sidebarScrollViewClass = objc_getClass("TSidebarScrollView");
    });
}

static const char *kHyprCachedAccessoryViewKey = "kHyprCachedAccessoryViewKey";
static CGFloat hypr_find_accessory_height(NSView *view) {
    if (!view) return 0.0;
    init_finder_classes_once();

    __weak NSView *cached = objc_getAssociatedObject(view, kHyprCachedAccessoryViewKey);
    if (cached && cached.window == view.window) {
        if (!cached.isHidden && cached.frame.size.height > 0.0) {
            return cached.frame.size.height;
        }
        if (cached.isHidden) return 0.0;
    }

    NSView *v = view;
    while (v) {
        for (NSView *sub in v.subviews) {
            BOOL matches = NO;
            if (s_accWrapperClass && [sub isKindOfClass:s_accWrapperClass]) {
                matches = YES;
            } else if ([sub.className containsString:@"AccessoryViewWrapper"]) {
                matches = YES;
            }
            if (matches) {
                objc_setAssociatedObject(view, kHyprCachedAccessoryViewKey, sub, OBJC_ASSOCIATION_ASSIGN);
                if (!sub.isHidden && sub.frame.size.height > 0.0) {
                    return sub.frame.size.height;
                }
                return 0.0;
            }
        }
        v = v.superview;
    }
    return 0.0;
}

static void configure_accessory_wrappers(NSView *view) {
    if (!view) return;
    if ([NSStringFromClass([view class]) containsString:@"AccessoryViewWrapper"]) {
        view.wantsLayer = YES;
        if (view.layer) {
            view.layer.backgroundColor = [NSColor colorWithCalibratedRed:37.0/255.0 green:37.0/255.0 blue:37.0/255.0 alpha:1.0].CGColor;
            view.layer.masksToBounds = YES;
            view.layer.opaque = YES;
        }
    }
    for (NSView *sub in view.subviews) {
        configure_accessory_wrappers(sub);
    }
}

static void (*s_orig_accessory_layout)(id, SEL) = NULL;
static void hypr_accessory_layout(id self, SEL _cmd) {
    if (s_orig_accessory_layout) {
        s_orig_accessory_layout(self, _cmd);
    }
    NSView *v = (NSView *)self;
    v.wantsLayer = YES;
    if (v.layer) {
        v.layer.backgroundColor = [NSColor colorWithCalibratedRed:37.0/255.0 green:37.0/255.0 blue:37.0/255.0 alpha:1.0].CGColor;
        v.layer.masksToBounds = YES;
        v.layer.opaque = YES;
    }

    CGFloat h = v.isHidden ? 0.0 : v.frame.size.height;
    NSView *parent = v.superview;
    if (parent) {
        void (^update_scroll)(NSView *, void (^)(NSView *, id)) = ^(NSView *child, void (^selfBlock)(NSView *, id)) {
            if ([child isKindOfClass:[NSScrollView class]]) {
                NSScrollView *sv = (NSScrollView *)child;
                NSEdgeInsets insets = sv.contentInsets;
                if (insets.bottom != h) {
                    insets.bottom = h;
                    sv.contentInsets = insets;
                }
                return;
            }
            for (NSView *sub in child.subviews) {
                selfBlock(sub, selfBlock);
            }
        };
        for (NSView *sib in parent.subviews) {
            if (sib != v) {
                update_scroll(sib, update_scroll);
            }
        }
    }
}

static BOOL ensure_zen_drawer_attached(NSWindow *window) {
    if (!is_finder() && !is_safari()) return NO;
    if (!window || !is_standard_window(window)) return NO;
    HyprZenDrawer *existingDrawer = objc_getAssociatedObject(window, kHyprZenDrawerKey);
    if (existingDrawer) {
        return YES;
    }

    // Cooldown per window for negative sidebar scans to prevent 120Hz view-tree walking
    static const char *kHyprDrawerScanTimeKey = "kHyprDrawerScanTimeKey";
    NSNumber *lastScanNum = objc_getAssociatedObject(window, kHyprDrawerScanTimeKey);
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (lastScanNum && (now - [lastScanNum doubleValue] < 0.5)) {
        return NO;
    }
    objc_setAssociatedObject(window, kHyprDrawerScanTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSView *contentView = window.contentView;
    if (!contentView) return NO;

    NSView *titlebarContainer = nil;
    if (is_safari()) {
        id wc = [window windowController];
        SEL selSetTabBar = sel_registerName("setTabBarVisible:");
        if (wc && [wc respondsToSelector:selSetTabBar]) {
            void (*fn)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
            fn(wc, selSetTabBar, NO);
        }

        // Ensure Safari's native vertical tab sidebar is uncollapsed so LibraryOutlineView is mounted
        void (^uncollapse_safari_sidebar)(NSView *, void (^)(NSView *, id)) = ^(NSView *v, void (^selfBlock)(NSView *, id)) {
            if ([v isKindOfClass:[NSSplitView class]]) {
                NSSplitView *sv = (NSSplitView *)v;
                id del = [sv delegate];
                SEL selItems = sel_registerName("splitViewItems");
                if (del && [del respondsToSelector:selItems]) {
                    id (*itemsFn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                    NSArray *items = itemsFn(del, selItems);
                    if ([items isKindOfClass:[NSArray class]] && items.count > 0) {
                        id firstItem = items[0];
                        SEL selIsCollapsed = sel_registerName("isCollapsed");
                        SEL selSetCollapsed = sel_registerName("setCollapsed:");
                        if ([firstItem respondsToSelector:selIsCollapsed] && [firstItem respondsToSelector:selSetCollapsed]) {
                            BOOL (*getCol)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
                            if (getCol(firstItem, selIsCollapsed)) {
                                void (*setCol)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
                                setCol(firstItem, selSetCollapsed, NO);
                                [sv layoutSubtreeIfNeeded];
                            }
                        }
                    }
                }
                return;
            }
            for (NSView *sub in v.subviews) {
                selfBlock(sub, selfBlock);
            }
        };
        uncollapse_safari_sidebar(contentView, uncollapse_safari_sidebar);

        NSView *themeFrame = contentView.superview;
        if (themeFrame) {
            Class containerClass = objc_getClass("NSTitlebarContainerView");
            for (NSView *sub in themeFrame.subviews) {
                if (containerClass && [sub isKindOfClass:containerClass]) {
                    titlebarContainer = sub;
                    hide_traffic_lights_in_view(titlebarContainer);
                    break;
                }
            }
        }
    }

    __block BOOL attached = NO;
    void (^findSidebarAndSetupDrawer)(NSView *, void (^)(NSView *, id)) = ^(NSView *v, void (^selfBlock)(NSView *, id)) {
        if ([v.className isEqualToString:@"NSKVONotifying_TSidebarScrollView"] ||
            [v.className containsString:@"TSidebarScrollView"] ||
            [v.className containsString:@"LibraryOutlineView"]) {
            NSView *wrapper = v.superview;
            while (wrapper && ![wrapper.className containsString:@"NSSplitViewItemViewWrapper"]) {
                wrapper = wrapper.superview;
            }
            if (wrapper) {
                NSView *shadow = nil;
                if (wrapper.superview) {
                    for (NSView *sib in wrapper.superview.subviews) {
                        if ([sib.className containsString:@"ShadowView"]) {
                            shadow = sib;
                            break;
                        }
                    }
                }
                HyprZenDrawer *drawer = [[HyprZenDrawer alloc] init];
                objc_setAssociatedObject(window, kHyprZenDrawerKey, drawer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [drawer attachToWindow:window sidebar:wrapper shadow:shadow titlebarContainer:titlebarContainer];
                attached = YES;
            }
            return;
        }
        for (NSView *sub in v.subviews) {
            selfBlock(sub, selfBlock);
        }
    };
    findSidebarAndSetupDrawer(contentView, findSidebarAndSetupDrawer);

    if (attached) {
        if (is_finder()) {
            void (^configure_scroll_views)(NSView *, void (^)(NSView *, id)) = ^(NSView *view, void (^selfBlock)(NSView *, id)) {
                if (!view) return;
                if ([view isKindOfClass:[NSScrollView class]]) {
                    NSScrollView *sv = (NSScrollView *)view;
                    sv.automaticallyAdjustsContentInsets = NO;
                    NSEdgeInsets insets = sv.contentInsets;
                    insets.top = 12.0;
                    if (![view.className containsString:@"TSidebar"]) {
                        insets.left = 0.0;
                        sv.hasVerticalScroller = YES;
                        sv.autohidesScrollers = NO;
                    }
                    CGFloat accH = hypr_find_accessory_height(view);
                    if (accH > 0.0) {
                        insets.bottom = accH;
                    }
                    sv.contentInsets = insets;
                }
                for (NSView *sub in view.subviews) {
                    selfBlock(sub, selfBlock);
                }
            };
            configure_scroll_views(contentView, configure_scroll_views);
            [contentView setNeedsLayout:YES];
        }

        HyprZenDrawer *drawer = objc_getAssociatedObject(window, kHyprZenDrawerKey);
        if (drawer) {
            if (drawer.splitView) {
                [drawer.splitView setNeedsLayout:YES];
                [drawer.splitView layoutSubtreeIfNeeded];
            }
            [drawer layoutSplitView];
        }
    }
    return attached;
}

static id hypr_get_zero_corner_radii(void) {
    static id s_zeroRadii = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class radiiClass = objc_getClass("NSViewCornerRadii");
        if (radiiClass) {
            SEL selInitWithRadius = sel_registerName("initWithRadius:");
            if ([radiiClass instancesRespondToSelector:selInitWithRadius]) {
                id alloced = [radiiClass alloc];
                typedef id (*InitFn)(id __attribute__((ns_consumed)), SEL, double) __attribute__((ns_returns_retained));
                InitFn initFn = (InitFn)objc_msgSend;
                s_zeroRadii = initFn(alloced, selInitWithRadius, 0.0);
            }
        }
    });
    return s_zeroRadii;
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
        if (alreadyStripped) {
            ensure_zen_drawer_attached(window);
            return;
        }

        // 1. Strip window shadow completely
        window.hasShadow = NO;
        [window invalidateShadow];

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
            if (is_standard_window(window) && !(window.styleMask & NSWindowStyleMaskMiniaturizable)) {
                window.styleMask |= NSWindowStyleMaskMiniaturizable;
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

        // 3. Permanently hide standard traffic light buttons (do NOT zero out frames or disable in Electron)
        NSButton *closeBtn = [window standardWindowButton:NSWindowCloseButton];
        if (closeBtn) {
            closeBtn.hidden = YES;
            closeBtn.alphaValue = 0.0;
            closeBtn.enabled = YES; // MUST remain enabled so Cmd+W, performClose: and AXPress close actions succeed!
        }
        NSButton *minBtn = [window standardWindowButton:NSWindowMiniaturizeButton];
        if (minBtn) {
            minBtn.hidden = YES;
            minBtn.alphaValue = 1.0;
            minBtn.enabled = YES;
        }
        NSButton *zoomBtn = [window standardWindowButton:NSWindowZoomButton];
        if (zoomBtn) {
            zoomBtn.hidden = YES;
            zoomBtn.alphaValue = 0.0;
            zoomBtn.enabled = YES;
        }

        // 4. Remove titlebar separator line (macOS 11+)
        if ([window respondsToSelector:@selector(setTitlebarSeparatorStyle:)]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(window, @selector(setTitlebarSeparatorStyle:), 0);
        }

        // 5. Invoke modern macOS corner radii methods (only on initial decoration stripping)
        if (!alreadyStripped) {
            id zeroRadii = hypr_get_zero_corner_radii();

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
                            if (!is_safari()) {
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
            }

            // Style accessory wrappers (Path Bar and Status Bar) with solid opaque backing
            configure_accessory_wrappers(contentView);

            // Adjust scroll view insets for edge-to-edge layout & keep scrollbars visible (Finder only)
            if (!alreadyStripped && !is_safari() && is_finder()) {
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
                            CGFloat accH = hypr_find_accessory_height(view);
                            if (accH > 0.0) {
                                insets.bottom = accH;
                            }
                        sv.contentInsets = insets;
                    }
                    for (NSView *sub in view.subviews) {
                        selfBlock(sub, selfBlock);
                    }
                };
                configure_scroll_views(contentView, configure_scroll_views);
                [contentView setNeedsLayout:YES];
            }

            // Hide any WebKit scroll pockets in Safari
            if (is_safari()) {
                void (^hide_pockets)(NSView *, void (^)(NSView *, id)) = ^(NSView *v, void (^selfBlock)(NSView *, id)) {
                    if ([v.className containsString:@"ScrollPocket"] || [v.className containsString:@"Pocket"]) {
                        v.alphaValue = 0.0;
                    }
                    for (NSView *sub in v.subviews) {
                        selfBlock(sub, selfBlock);
                    }
                };
                hide_pockets(contentView, hide_pockets);
            }

            // Configure unified Zen-style hover drawer (Finder sidebar & Safari sidebar + top search bar)
            ensure_zen_drawer_attached(window);
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
- (void)hypr_performMiniaturize:(id)sender;
- (void)hypr_setOpaque:(BOOL)opaque;
- (void)hypr_setBackgroundColor:(NSColor *)color;
- (BOOL)hypr_performKeyEquivalent:(NSEvent *)event;
- (BOOL)hypr_validateMenuItem:(NSMenuItem *)menuItem;
- (BOOL)hypr_validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item;
- (void)hypr_sendEvent:(NSEvent *)event;
- (BOOL)hypr_canBecomeKeyWindow;
- (BOOL)hypr_canBecomeMainWindow;
- (NSRect)hypr_contentLayoutRect;
- (BOOL)hypr_makeFirstResponder:(NSResponder *)responder;
- (BOOL)hypr_accessibilityIsMinimizedAttributeSettable;
- (void)hypr_accessibilitySetMinimizedAttribute:(id)value;
- (BOOL)hypr_accessibilityIsAttributeSettable:(NSString *)attribute;
- (void)hypr_accessibilitySetValue:(id)value forAttribute:(NSString *)attribute;
- (void)hypr_setAccessibilityMinimized:(BOOL)minimized;
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

- (void)hypr_performMiniaturize:(id)sender {
    if (([self styleMask] & NSWindowStyleMaskMiniaturizable) != 0 || is_standard_window(self)) {
        NSButton *minBtn = [self standardWindowButton:NSWindowMiniaturizeButton];
        if (minBtn && minBtn.alphaValue <= 0.0) {
            minBtn.alphaValue = 1.0;
        }
        [self miniaturize:sender];
        return;
    }
    [self hypr_performMiniaturize:sender];
}

- (NSRect)hypr_contentLayoutRect {
    if (is_standard_window(self)) {
        NSRect frame = [self frame];
        return NSMakeRect(0.0, 0.0, frame.size.width, frame.size.height);
    }
    return [self hypr_contentLayoutRect];
}

- (BOOL)hypr_makeFirstResponder:(NSResponder *)responder {
    BOOL ret = [self hypr_makeFirstResponder:responder];
    if (is_safari() && is_standard_window(self)) {
        HyprZenDrawer *drawer = hypr_get_drawer(self);
        if (drawer) {
            if ([responder isKindOfClass:[NSView class]]) {
                NSView *rv = (NSView *)responder;
                if ((drawer.titlebarContainer && is_descendant_of_view(rv, drawer.titlebarContainer)) ||
                    (drawer.sidebarWrapper && is_descendant_of_view(rv, drawer.sidebarWrapper))) {
                    [drawer openDrawer];
                } else if (drawer.isOpen) {
                    [drawer scheduleClose];
                }
            }
        }
    }
    return ret;
}

- (BOOL)hypr_performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSString *chars = [event charactersIgnoringModifiers];
    BOOL isCmd = (flags == NSEventModifierFlagCommand);
    BOOL isCmdOpt = (flags == (NSEventModifierFlagCommand | NSEventModifierFlagOption));

    if (isCmd && ([chars isEqualToString:@"w"] || [chars isEqualToString:@"W"])) {
        if (is_standard_window(self)) {
            [self close];
            return YES;
        }
    }
    if (isCmd && ([chars isEqualToString:@"m"] || [chars isEqualToString:@"M"])) {
        if (is_standard_window(self) || (([self styleMask] & NSWindowStyleMaskMiniaturizable) != 0)) {
            if (![self isMiniaturized]) {
                [self performMiniaturize:nil];
                return YES;
            }
        }
    }

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    BOOL isFinder = [bundleId isEqualToString:@"com.apple.finder"];

    if (is_safari()) {
        if (isCmd && ([chars isEqualToString:@"l"] || [chars isEqualToString:@"L"] ||
                      [chars isEqualToString:@"t"] || [chars isEqualToString:@"T"])) {
            HyprZenDrawer *drawer = hypr_get_drawer(self);
            if (drawer) {
                [drawer openDrawer];
            }
        }
    }

    if (isFinder) {
        if (isCmd && ([chars isEqualToString:@"q"] || [chars isEqualToString:@"Q"])) {
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
        BOOL isCmdOpt = (flags == (NSEventModifierFlagCommand | NSEventModifierFlagOption));

        if (isCmd && ([chars isEqualToString:@"w"] || [chars isEqualToString:@"W"])) {
            if (is_standard_window(self)) {
                [self close];
                return;
            }
        }
        if (isCmd && ([chars isEqualToString:@"m"] || [chars isEqualToString:@"M"])) {
            if (is_standard_window(self) || (([self styleMask] & NSWindowStyleMaskMiniaturizable) != 0)) {
                if (![self isMiniaturized]) {
                    [self performMiniaturize:nil];
                    return;
                }
            }
        }

        if (is_safari()) {
            if (isCmd && ([chars isEqualToString:@"l"] || [chars isEqualToString:@"L"] ||
                          [chars isEqualToString:@"t"] || [chars isEqualToString:@"T"])) {
                HyprZenDrawer *drawer = hypr_get_drawer(self);
                if (drawer) {
                    [drawer openDrawer];
                }
            }
        }

        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleId isEqualToString:@"com.apple.finder"]) {
            if (isCmd && ([chars isEqualToString:@"q"] || [chars isEqualToString:@"Q"])) {
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
    if ([menuItem action] == @selector(performMiniaturize:) || [menuItem action] == @selector(miniaturize:)) {
        if (([self styleMask] & NSWindowStyleMaskMiniaturizable) != 0 || is_standard_window(self)) {
            return ![self isMiniaturized];
        }
    }
    return [self hypr_validateMenuItem:menuItem];
}

- (BOOL)hypr_validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    if ([item action] == @selector(performClose:)) {
        return YES;
    }
    if ([item action] == @selector(performMiniaturize:) || [item action] == @selector(miniaturize:)) {
        if (([self styleMask] & NSWindowStyleMaskMiniaturizable) != 0 || is_standard_window(self)) {
            return ![self isMiniaturized];
        }
    }
    return [self hypr_validateUserInterfaceItem:item];
}

- (BOOL)hypr_accessibilityIsMinimizedAttributeSettable {
    if (([self styleMask] & NSWindowStyleMaskMiniaturizable) != 0 || is_standard_window(self)) {
        return YES;
    }
    return [self hypr_accessibilityIsMinimizedAttributeSettable];
}

- (void)hypr_accessibilitySetMinimizedAttribute:(id)value {
    if (([self styleMask] & NSWindowStyleMaskMiniaturizable) != 0 || is_standard_window(self)) {
        BOOL shouldMin = YES;
        if ([value respondsToSelector:@selector(boolValue)]) {
            shouldMin = [value boolValue];
        }
        if (shouldMin) {
            NSButton *minBtn = [self standardWindowButton:NSWindowMiniaturizeButton];
            if (minBtn && minBtn.alphaValue <= 0.0) {
                minBtn.alphaValue = 1.0;
            }
            [self miniaturize:nil];
        } else {
            [self deminiaturize:nil];
        }
        return;
    }
    [self hypr_accessibilitySetMinimizedAttribute:value];
}

- (BOOL)hypr_accessibilityIsAttributeSettable:(NSString *)attribute {
    if ([attribute isEqualToString:NSAccessibilityMinimizedAttribute]) {
        if (([self styleMask] & NSWindowStyleMaskMiniaturizable) != 0 || is_standard_window(self)) {
            return YES;
        }
    }
    return [self hypr_accessibilityIsAttributeSettable:attribute];
}

- (void)hypr_accessibilitySetValue:(id)value forAttribute:(NSString *)attribute {
    if ([attribute isEqualToString:NSAccessibilityMinimizedAttribute]) {
        if (([self styleMask] & NSWindowStyleMaskMiniaturizable) != 0 || is_standard_window(self)) {
            BOOL shouldMin = YES;
            if ([value respondsToSelector:@selector(boolValue)]) {
                shouldMin = [value boolValue];
            }
            if (shouldMin) {
                NSButton *minBtn = [self standardWindowButton:NSWindowMiniaturizeButton];
                if (minBtn && minBtn.alphaValue <= 0.0) {
                    minBtn.alphaValue = 1.0;
                }
                [self miniaturize:nil];
            } else {
                [self deminiaturize:nil];
            }
            return;
        }
    }
    [self hypr_accessibilitySetValue:value forAttribute:attribute];
}

- (void)hypr_setAccessibilityMinimized:(BOOL)minimized {
    if (([self styleMask] & NSWindowStyleMaskMiniaturizable) != 0 || is_standard_window(self)) {
        if (minimized) {
            NSButton *minBtn = [self standardWindowButton:NSWindowMiniaturizeButton];
            if (minBtn && minBtn.alphaValue <= 0.0) {
                minBtn.alphaValue = 1.0;
            }
            [self miniaturize:nil];
        } else {
            [self deminiaturize:nil];
        }
        return;
    }
    [self hypr_setAccessibilityMinimized:minimized];
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
    init_finder_classes_once();
    BOOL isSidebar = s_sidebarScrollViewClass ? [self isKindOfClass:s_sidebarScrollViewClass] : [self.className containsString:@"Sidebar"];
    if (!is_safari() && is_finder() && !isSidebar) {
        insets.left = 0.0;
        insets.top = 12.0;
        CGFloat accH = hypr_find_accessory_height(self);
        if (accH > 0.0) {
            insets.bottom = accH;
        }
    }
    [self hypr_setContentInsets:insets];
}

- (NSEdgeInsets)hypr_adjustedContentInsets {
    NSEdgeInsets insets = [self hypr_adjustedContentInsets];
    init_finder_classes_once();
    BOOL isSidebar = s_sidebarScrollViewClass ? [self isKindOfClass:s_sidebarScrollViewClass] : [self.className containsString:@"Sidebar"];
    if (!is_safari() && is_finder() && !isSidebar) {
        insets.left = 0.0;
        insets.top = 12.0;
        CGFloat accH = hypr_find_accessory_height(self);
        if (accH > 0.0) {
            insets.bottom = accH;
        }
    }
    return insets;
}

- (BOOL)hypr_automaticallyAdjustsContentInsets {
    init_finder_classes_once();
    BOOL isSidebar = s_sidebarScrollViewClass ? [self isKindOfClass:s_sidebarScrollViewClass] : [self.className containsString:@"Sidebar"];
    if (!is_safari() && is_finder() && !isSidebar) {
        return NO;
    }
    return [self hypr_automaticallyAdjustsContentInsets];
}

@end


#pragma mark - View Safe Area Insets Swizzle (Safari)

@interface NSView (HyprSafariSafeArea)
- (NSEdgeInsets)hypr_safeAreaInsets;
@end

@implementation NSView (HyprSafariSafeArea)

- (NSEdgeInsets)hypr_safeAreaInsets {
    if (is_safari()) {
        NSWindow *win = [self window];
        if (win && is_standard_window(win)) {
            HyprZenDrawer *drawer = hypr_get_drawer(win);
            if (drawer && drawer.sidebarWrapper && is_descendant_of_view(self, drawer.sidebarWrapper)) {
                return [self hypr_safeAreaInsets];
            }
            if (drawer && drawer.contentWrapper && is_descendant_of_view(self, drawer.contentWrapper)) {
                return NSEdgeInsetsZero;
            }
            NSString *cls = NSStringFromClass([self class]);
            if ([cls containsString:@"WK"] || [cls containsString:@"Browser"] || [cls containsString:@"Pocket"] || [cls containsString:@"TabContent"]) {
                return NSEdgeInsetsZero;
            }
        }
    }
    return [self hypr_safeAreaInsets];
}

@end

static BOOL hypr_unifiedTabBarShouldOnlyShowActiveTab(id self, SEL _cmd, id tabBar) {
    (void)self; (void)_cmd; (void)tabBar;
    return YES;
}

static NSRect hypr_unifiedTabBar_computeTitlebarMainContentLayoutFrameForCentering(id self, SEL _cmd) {
    (void)_cmd;
    CGFloat w = 264.0;
    NSWindow *win = [(NSView *)self window];
    if (win) {
        HyprZenDrawer *drawer = hypr_get_drawer(win);
        if (drawer && drawer.sidebarWidth > 50.0) {
            w = drawer.sidebarWidth - 16.0;
        }
    }
    return NSMakeRect(0.0, 0.0, w, 36.0);
}

static void (*s_orig_toolbarView_layout)(id, SEL) = NULL;
static void hypr_toolbarView_layout(id self, SEL _cmd) {
    if (s_orig_toolbarView_layout) {
        s_orig_toolbarView_layout(self, _cmd);
    }
    if (is_safari()) {
        static __thread BOOL s_in_tb_layout = NO;
        if (s_in_tb_layout) return;
        s_in_tb_layout = YES;
        NSWindow *win = [(NSView *)self window];
        if (win) {
            HyprZenDrawer *drawer = hypr_get_drawer(win);
            if (drawer) {
                NSUInteger subCount = [((NSView *)self).subviews count];
                if (drawer.lastToolbarSubviewCount != subCount || drawer.lastStyledSafariWidth != win.frame.size.width) {
                    drawer.hasStyledSafariSearchBar = NO;
                    drawer.lastToolbarSubviewCount = subCount;
                }
                [drawer layoutSafariTopSearchBar];
            }
        }
        s_in_tb_layout = NO;
    }
}

static BOOL hypr_view_contains_unified_tab_bar(NSView *v) {
    if (!v) return NO;
    NSString *cls = NSStringFromClass([v class]);
    if ([cls containsString:@"UnifiedTabBar"] || [cls containsString:@"UnifiedField"]) {
        return YES;
    }
    for (NSView *sub in v.subviews) {
        if (hypr_view_contains_unified_tab_bar(sub)) {
            return YES;
        }
    }
    return NO;
}

static void (*s_orig_toolbarItemViewer_setFrame)(id, SEL, NSRect) = NULL;
static void hypr_toolbarItemViewer_setFrame(id self, SEL _cmd, NSRect frame) {
    if (is_safari()) {
        NSView *v = (NSView *)self;
        NSWindow *win = [v window];
        HyprZenDrawer *drawer = win ? hypr_get_drawer(win) : nil;
        CGFloat sbW = (drawer && drawer.sidebarWidth > 100.0) ? drawer.sidebarWidth : 280.0;
        if (hypr_view_contains_unified_tab_bar(v)) {
            frame = NSMakeRect(8.0, 0.0, sbW - 16.0, 52.0);
        }
    }
    if (s_orig_toolbarItemViewer_setFrame) {
        s_orig_toolbarItemViewer_setFrame(self, _cmd, frame);
    }
}

static void (*s_orig_unifiedTabBar_setFrame)(id, SEL, NSRect) = NULL;
static void hypr_unifiedTabBar_setFrame(id self, SEL _cmd, NSRect frame) {
    if (is_safari()) {
        NSView *v = (NSView *)self;
        NSWindow *win = [v window];
        HyprZenDrawer *drawer = win ? hypr_get_drawer(win) : nil;
        CGFloat sbW = (drawer && drawer.sidebarWidth > 100.0) ? drawer.sidebarWidth : 280.0;
        frame = NSMakeRect(0.0, 8.0, sbW - 16.0, 36.0);
    }
    if (s_orig_unifiedTabBar_setFrame) {
        s_orig_unifiedTabBar_setFrame(self, _cmd, frame);
    }
}

static void (*s_orig_unifiedTabBar_layout)(id, SEL) = NULL;
static void hypr_unifiedTabBar_layout(id self, SEL _cmd) {
    if (is_safari()) {
        NSView *v = (NSView *)self;
        NSWindow *win = [v window];
        HyprZenDrawer *drawer = win ? hypr_get_drawer(win) : nil;
        CGFloat sbW = (drawer && drawer.sidebarWidth > 100.0) ? drawer.sidebarWidth : 280.0;
        SEL selSetCenter = sel_registerName("setUnpinnedTabCenteringFrame:");
        if ([self respondsToSelector:selSetCenter]) {
            void (*setCenterFn)(id, SEL, NSRect) = (void (*)(id, SEL, NSRect))objc_msgSend;
            setCenterFn(self, selSetCenter, NSMakeRect(0.0, 0.0, sbW - 16.0, 36.0));
        }
    }
    if (s_orig_unifiedTabBar_layout) {
        s_orig_unifiedTabBar_layout(self, _cmd);
    }
}

static double hypr_zero_double(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return 0.0;
}

static id hypr_zero_cornerRadii(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return hypr_get_zero_corner_radii();
}

static double (*s_orig_window_cornerRadius)(id, SEL) = NULL;
static double hypr_window_cornerRadius(id self, SEL _cmd) {
    if (is_standard_window(self)) {
        return 0.0;
    }
    if (s_orig_window_cornerRadius) {
        return s_orig_window_cornerRadius(self, _cmd);
    }
    return 0.0;
}

static id (*s_orig_window_cornerRadii)(id, SEL) = NULL;
static id hypr_window_cornerRadii(id self, SEL _cmd) {
    if (is_standard_window(self)) {
        return hypr_zero_cornerRadii(self, _cmd);
    }
    if (s_orig_window_cornerRadii) {
        return s_orig_window_cornerRadii(self, _cmd);
    }
    return nil;
}

static BOOL (*s_orig_themeFrame_shouldRoundCornersForSurface)(id, SEL) = NULL;
static BOOL hypr_themeFrame_shouldRoundCornersForSurface(id self, SEL _cmd) {
    NSWindow *win = [(NSView *)self window];
    if (win && !is_standard_window(win)) {
        return s_orig_themeFrame_shouldRoundCornersForSurface ? s_orig_themeFrame_shouldRoundCornersForSurface(self, _cmd) : YES;
    }
    return NO;
}

static BOOL (*s_orig_themeFrame_topCornerRounded)(id, SEL) = NULL;
static BOOL hypr_themeFrame_topCornerRounded(id self, SEL _cmd) {
    NSWindow *win = [(NSView *)self window];
    if (win && !is_standard_window(win)) {
        return s_orig_themeFrame_topCornerRounded ? s_orig_themeFrame_topCornerRounded(self, _cmd) : YES;
    }
    return NO;
}

static BOOL (*s_orig_themeFrame_bottomCornerRounded)(id, SEL) = NULL;
static BOOL hypr_themeFrame_bottomCornerRounded(id self, SEL _cmd) {
    NSWindow *win = [(NSView *)self window];
    if (win && !is_standard_window(win)) {
        return s_orig_themeFrame_bottomCornerRounded ? s_orig_themeFrame_bottomCornerRounded(self, _cmd) : YES;
    }
    return NO;
}

static double (*s_orig_themeFrame_cornerRadius)(id, SEL) = NULL;
static double hypr_themeFrame_cornerRadius(id self, SEL _cmd) {
    NSWindow *win = [(NSView *)self window];
    if (win && !is_standard_window(win)) {
        return s_orig_themeFrame_cornerRadius ? s_orig_themeFrame_cornerRadius(self, _cmd) : 0.0;
    }
    return 0.0;
}

static id (*s_orig_themeFrame_cornerRadii)(id, SEL) = NULL;
static id hypr_themeFrame_cornerRadii(id self, SEL _cmd) {
    NSWindow *win = [(NSView *)self window];
    if (win && !is_standard_window(win)) {
        return s_orig_themeFrame_cornerRadii ? s_orig_themeFrame_cornerRadii(self, _cmd) : nil;
    }
    return hypr_get_zero_corner_radii();
}

static id (*s_orig_themeFrame_cornerMask)(id, SEL) = NULL;
static id hypr_themeFrame_cornerMask(id self, SEL _cmd) {
    NSWindow *win = [(NSView *)self window];
    if (win && !is_standard_window(win)) {
        return s_orig_themeFrame_cornerMask ? s_orig_themeFrame_cornerMask(self, _cmd) : nil;
    }
    return nil;
}

static BOOL (*s_orig_themeFrame_applySafeAreaInsetsForTransparentTitlebar)(id, SEL) = NULL;
static BOOL hypr_themeFrame_applySafeAreaInsetsForTransparentTitlebar(id self, SEL _cmd) {
    NSWindow *win = [(NSView *)self window];
    if (win && !is_standard_window(win)) {
        return s_orig_themeFrame_applySafeAreaInsetsForTransparentTitlebar ? s_orig_themeFrame_applySafeAreaInsetsForTransparentTitlebar(self, _cmd) : YES;
    }
    return NO;
}

static double (*s_orig_titlebarHeight)(id, SEL) = NULL;
static double hypr_themeFrame_titlebarHeight(id self, SEL _cmd) {
    NSWindow *win = [(NSView *)self window];
    if (win && !is_standard_window(win)) {
        return s_orig_titlebarHeight ? s_orig_titlebarHeight(self, _cmd) : 0.0;
    }
    if (is_safari()) {
        return s_orig_titlebarHeight ? s_orig_titlebarHeight(self, _cmd) : 0.0;
    }
    return 0.0;
}

static double (*s_orig_titlebarHeightInline)(id, SEL) = NULL;
static double hypr_themeFrame_titlebarHeightInline(id self, SEL _cmd) {
    NSWindow *win = [(NSView *)self window];
    if (win && !is_standard_window(win)) {
        return s_orig_titlebarHeightInline ? s_orig_titlebarHeightInline(self, _cmd) : 0.0;
    }
    if (is_safari()) {
        return s_orig_titlebarHeightInline ? s_orig_titlebarHeightInline(self, _cmd) : 0.0;
    }
    return 0.0;
}

static BOOL (*s_orig_hasToolbarReservedSpace)(id, SEL) = NULL;
static BOOL hypr_themeFrame_hasToolbarReservedSpace(id self, SEL _cmd) {
    NSWindow *win = [(NSView *)self window];
    if (win && !is_standard_window(win)) {
        return s_orig_hasToolbarReservedSpace ? s_orig_hasToolbarReservedSpace(self, _cmd) : NO;
    }
    if (is_safari()) {
        return s_orig_hasToolbarReservedSpace ? s_orig_hasToolbarReservedSpace(self, _cmd) : NO;
    }
    return NO;
}

static double (*s_orig_customTitlebarHeight)(id, SEL) = NULL;
static double hypr_themeFrame_customTitlebarHeight(id self, SEL _cmd) {
    NSWindow *win = [(NSView *)self window];
    if (win && !is_standard_window(win)) {
        return s_orig_customTitlebarHeight ? s_orig_customTitlebarHeight(self, _cmd) : 0.0;
    }
    if (is_safari()) {
        return s_orig_customTitlebarHeight ? s_orig_customTitlebarHeight(self, _cmd) : 0.0;
    }
    return 0.0;
}

static void hypr_noop(id self, SEL _cmd) {
    (void)self; (void)_cmd;
}

static void hypr_noop_event(id self, SEL _cmd, id event) {
    (void)self; (void)_cmd; (void)event;
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
        // NSWindowMiniaturizeButton MUST maintain alpha > 0.0 so AppKit dock minimize animation succeeds
        if ([self isKindOfClass:[NSButton class]]) {
            NSButton *btn = (NSButton *)self;
            SEL act = [btn action];
            if (act == @selector(miniaturize:) || act == @selector(performMiniaturize:) || [btn tag] == 1) {
                s_orig_widget_setAlphaValue(self, _cmd, 1.0);
                return;
            }
            NSWindow *win = [btn window];
            if (win && [win standardWindowButton:NSWindowMiniaturizeButton] == btn) {
                s_orig_widget_setAlphaValue(self, _cmd, 1.0);
                return;
            }
        }
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

static void hypr_install_hooks_on_main(void) {
    if (is_browser_or_selftheming_app()) {
        return;
    }

    Class windowClass = [NSWindow class];
    if (!windowClass) {
        return;
    }

    static const char *kHyprSwizzledKey = "kHyprSwizzledKey";
    if (objc_getAssociatedObject(windowClass, kHyprSwizzledKey)) {
        for (NSWindow *win in [NSApp windows]) {
            strip_window_decorations(win);
        }
        return;
    }
        objc_setAssociatedObject(windowClass, kHyprSwizzledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        hypr_swizzle(windowClass, @selector(makeKeyAndOrderFront:), @selector(hypr_makeKeyAndOrderFront:));
        hypr_swizzle(windowClass, @selector(orderFront:), @selector(hypr_orderFront:));
        hypr_swizzle(windowClass, @selector(setContentView:), @selector(hypr_setContentView:));
        hypr_swizzle(windowClass, @selector(isOpaque), @selector(hypr_isOpaque));
        hypr_swizzle(windowClass, @selector(setOpaque:), @selector(hypr_setOpaque:));
        hypr_swizzle(windowClass, @selector(setBackgroundColor:), @selector(hypr_setBackgroundColor:));
        hypr_swizzle(windowClass, @selector(performClose:), @selector(hypr_performClose:));
        hypr_swizzle(windowClass, @selector(performMiniaturize:), @selector(hypr_performMiniaturize:));
        hypr_swizzle(windowClass, @selector(performKeyEquivalent:), @selector(hypr_performKeyEquivalent:));
        hypr_swizzle(windowClass, @selector(validateMenuItem:), @selector(hypr_validateMenuItem:));
        hypr_swizzle(windowClass, @selector(validateUserInterfaceItem:), @selector(hypr_validateUserInterfaceItem:));
        hypr_swizzle(windowClass, @selector(sendEvent:), @selector(hypr_sendEvent:));
        hypr_swizzle(windowClass, @selector(canBecomeKeyWindow), @selector(hypr_canBecomeKeyWindow));
        hypr_swizzle(windowClass, @selector(canBecomeMainWindow), @selector(hypr_canBecomeMainWindow));
        hypr_swizzle(windowClass, @selector(contentLayoutRect), @selector(hypr_contentLayoutRect));
        hypr_swizzle(windowClass, @selector(makeFirstResponder:), @selector(hypr_makeFirstResponder:));
        hypr_swizzle(windowClass, sel_registerName("accessibilityIsMinimizedAttributeSettable"), @selector(hypr_accessibilityIsMinimizedAttributeSettable));
        hypr_swizzle(windowClass, sel_registerName("accessibilitySetMinimizedAttribute:"), @selector(hypr_accessibilitySetMinimizedAttribute:));
        hypr_swizzle(windowClass, sel_registerName("accessibilityIsAttributeSettable:"), @selector(hypr_accessibilityIsAttributeSettable:));
        hypr_swizzle(windowClass, sel_registerName("accessibilitySetValue:forAttribute:"), @selector(hypr_accessibilitySetValue:forAttribute:));
        hypr_swizzle(windowClass, sel_registerName("setAccessibilityMinimized:"), @selector(hypr_setAccessibilityMinimized:));

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

        Class viewClass = [NSView class];
        if (viewClass) {
            hypr_swizzle(viewClass, @selector(safeAreaInsets), @selector(hypr_safeAreaInsets));
        }

        // Swizzle NSWindow corner methods
        Method mWinRadius = class_getInstanceMethod(windowClass, sel_registerName("_cornerRadius"));
        if (mWinRadius) {
            s_orig_window_cornerRadius = (double (*)(id, SEL))method_getImplementation(mWinRadius);
            method_setImplementation(mWinRadius, (IMP)hypr_window_cornerRadius);
        }

        Method mWinRadii = class_getInstanceMethod(windowClass, sel_registerName("_cornerRadii"));
        if (mWinRadii) {
            s_orig_window_cornerRadii = (id (*)(id, SEL))method_getImplementation(mWinRadii);
            method_setImplementation(mWinRadii, (IMP)hypr_window_cornerRadii);
        }

        // Swizzle NSThemeFrame surface rounding and corner calculation methods
        Class themeFrameClass = objc_getClass("NSThemeFrame");
        if (themeFrameClass) {
            Method mShouldRound = class_getInstanceMethod(themeFrameClass, sel_registerName("_shouldRoundCornersForSurface"));
            if (mShouldRound) {
                s_orig_themeFrame_shouldRoundCornersForSurface = (BOOL (*)(id, SEL))method_getImplementation(mShouldRound);
                method_setImplementation(mShouldRound, (IMP)hypr_themeFrame_shouldRoundCornersForSurface);
            }

            Method mTopRound = class_getInstanceMethod(themeFrameClass, sel_registerName("topCornerRounded"));
            if (mTopRound) {
                s_orig_themeFrame_topCornerRounded = (BOOL (*)(id, SEL))method_getImplementation(mTopRound);
                method_setImplementation(mTopRound, (IMP)hypr_themeFrame_topCornerRounded);
            }

            Method mBottomRound = class_getInstanceMethod(themeFrameClass, sel_registerName("bottomCornerRounded"));
            if (mBottomRound) {
                s_orig_themeFrame_bottomCornerRounded = (BOOL (*)(id, SEL))method_getImplementation(mBottomRound);
                method_setImplementation(mBottomRound, (IMP)hypr_themeFrame_bottomCornerRounded);
            }

            Method mCornerRadius = class_getInstanceMethod(themeFrameClass, sel_registerName("_cornerRadius"));
            if (mCornerRadius) {
                s_orig_themeFrame_cornerRadius = (double (*)(id, SEL))method_getImplementation(mCornerRadius);
                method_setImplementation(mCornerRadius, (IMP)hypr_themeFrame_cornerRadius);
            }

            Method mCornerRadii = class_getInstanceMethod(themeFrameClass, sel_registerName("_cornerRadii"));
            if (mCornerRadii) {
                s_orig_themeFrame_cornerRadii = (id (*)(id, SEL))method_getImplementation(mCornerRadii);
                method_setImplementation(mCornerRadii, (IMP)hypr_themeFrame_cornerRadii);
            }

            Method mCornerMask = class_getInstanceMethod(themeFrameClass, sel_registerName("_cornerMask"));
            if (mCornerMask) {
                s_orig_themeFrame_cornerMask = (id (*)(id, SEL))method_getImplementation(mCornerMask);
                method_setImplementation(mCornerMask, (IMP)hypr_themeFrame_cornerMask);
            }

            Method mTitlebarHeight = class_getInstanceMethod(themeFrameClass, sel_registerName("_titlebarHeight"));
            if (mTitlebarHeight) {
                s_orig_titlebarHeight = (double (*)(id, SEL))method_getImplementation(mTitlebarHeight);
                method_setImplementation(mTitlebarHeight, (IMP)hypr_themeFrame_titlebarHeight);
            }

            Method mTitlebarHeightInline = class_getInstanceMethod(themeFrameClass, sel_registerName("_titlebarHeightIncludingInlineToolbar"));
            if (mTitlebarHeightInline) {
                s_orig_titlebarHeightInline = (double (*)(id, SEL))method_getImplementation(mTitlebarHeightInline);
                method_setImplementation(mTitlebarHeightInline, (IMP)hypr_themeFrame_titlebarHeightInline);
            }

            Method mToolbarReserved = class_getInstanceMethod(themeFrameClass, sel_registerName("_hasToolbarReservedSpace"));
            if (mToolbarReserved) {
                s_orig_hasToolbarReservedSpace = (BOOL (*)(id, SEL))method_getImplementation(mToolbarReserved);
                method_setImplementation(mToolbarReserved, (IMP)hypr_themeFrame_hasToolbarReservedSpace);
            }

            Method mCustomTitlebarHeight = class_getInstanceMethod(themeFrameClass, sel_registerName("customTitlebarHeight"));
            if (mCustomTitlebarHeight) {
                s_orig_customTitlebarHeight = (double (*)(id, SEL))method_getImplementation(mCustomTitlebarHeight);
                method_setImplementation(mCustomTitlebarHeight, (IMP)hypr_themeFrame_customTitlebarHeight);
            }

            Method mApplySafeArea = class_getInstanceMethod(themeFrameClass, sel_registerName("applySafeAreaInsetsForTransparentTitlebar"));
            if (mApplySafeArea) {
                s_orig_themeFrame_applySafeAreaInsetsForTransparentTitlebar = (BOOL (*)(id, SEL))method_getImplementation(mApplySafeArea);
                method_setImplementation(mApplySafeArea, (IMP)hypr_themeFrame_applySafeAreaInsetsForTransparentTitlebar);
            }
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

            Method mAddSafe = class_getInstanceMethod(wrapperClass, @selector(setAdditionalSafeAreaInsets:));
            if (mAddSafe) {
                s_orig_wrapper_setAdditionalSafeAreaInsets = (void (*)(id, SEL, NSEdgeInsets))method_getImplementation(mAddSafe);
                if (class_addMethod(wrapperClass, @selector(setAdditionalSafeAreaInsets:), (IMP)hypr_wrapper_setAdditionalSafeAreaInsets, method_getTypeEncoding(mAddSafe))) {
                    // Added cleanly
                } else {
                    method_setImplementation(mAddSafe, (IMP)hypr_wrapper_setAdditionalSafeAreaInsets);
                }
            }
        }

        // Swizzle NSTitlebarContainerView hitTest: to pass clicks through when top bar is closed
        Class containerClass = objc_getClass("NSTitlebarContainerView");
        if (containerClass) {
            Method mHit = class_getInstanceMethod(containerClass, @selector(hitTest:));
            if (mHit) {
                s_orig_titlebarContainer_hitTest = (NSView *(*)(id, SEL, NSPoint))method_getImplementation(mHit);
                if (class_addMethod(containerClass, @selector(hitTest:), (IMP)hypr_titlebarContainer_hitTest, method_getTypeEncoding(mHit))) {
                    // Added cleanly
                } else {
                    method_setImplementation(mHit, (IMP)hypr_titlebarContainer_hitTest);
                }
            }
        }

        // Swizzle _NSSplitViewItemAccessoryViewWrapper layout to maintain opaque background & inset sync
        Class accWrapperClass = objc_getClass("_NSSplitViewItemAccessoryViewWrapper");
        if (accWrapperClass) {
            Method mLayout = class_getInstanceMethod(accWrapperClass, @selector(layout));
            if (mLayout) {
                s_orig_accessory_layout = (void (*)(id, SEL))method_getImplementation(mLayout);
                if (class_addMethod(accWrapperClass, @selector(layout), (IMP)hypr_accessory_layout, method_getTypeEncoding(mLayout))) {
                    // Added cleanly
                } else {
                    method_setImplementation(mLayout, (IMP)hypr_accessory_layout);
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

        // Swizzle NSToolbarView layout and Safari ToolbarController to dock single search bar in left sidebar header
        if (is_safari()) {
            Class toolbarViewClass = objc_getClass("NSToolbarView");
            if (toolbarViewClass) {
                Method mToolbarLayout = class_getInstanceMethod(toolbarViewClass, @selector(layout));
                if (mToolbarLayout) {
                    s_orig_toolbarView_layout = (void (*)(id, SEL))method_getImplementation(mToolbarLayout);
                    method_setImplementation(mToolbarLayout, (IMP)hypr_toolbarView_layout);
                }
            }

            Class toolbarControllerClass = objc_getClass("ToolbarController");
            if (toolbarControllerClass) {
                SEL selOnlyActive = sel_registerName("unifiedTabBarShouldOnlyShowActiveTab:");
                Method mOnlyActive = class_getInstanceMethod(toolbarControllerClass, selOnlyActive);
                if (mOnlyActive) {
                    method_setImplementation(mOnlyActive, (IMP)hypr_unifiedTabBarShouldOnlyShowActiveTab);
                }
            }

            Class browserWCClass = objc_getClass("BrowserWindowController");
            if (browserWCClass) {
                SEL selOnlyActive = sel_registerName("unifiedTabBarShouldOnlyShowActiveTab:");
                Method mOnlyActive = class_getInstanceMethod(browserWCClass, selOnlyActive);
                if (mOnlyActive) {
                    method_setImplementation(mOnlyActive, (IMP)hypr_unifiedTabBarShouldOnlyShowActiveTab);
                }
            }

            Class unifiedTabBarClass = objc_getClass("UnifiedTabBar");
            if (unifiedTabBarClass) {
                SEL selCenterFrame = sel_registerName("_computeTitlebarMainContentLayoutFrameForCentering");
                Method mCenterFrame = class_getInstanceMethod(unifiedTabBarClass, selCenterFrame);
                if (mCenterFrame) {
                    method_setImplementation(mCenterFrame, (IMP)hypr_unifiedTabBar_computeTitlebarMainContentLayoutFrameForCentering);
                }

                Method mTabBarSetFrame = class_getInstanceMethod(unifiedTabBarClass, @selector(setFrame:));
                if (mTabBarSetFrame) {
                    s_orig_unifiedTabBar_setFrame = (void (*)(id, SEL, NSRect))method_getImplementation(mTabBarSetFrame);
                    if (!class_addMethod(unifiedTabBarClass, @selector(setFrame:), (IMP)hypr_unifiedTabBar_setFrame, method_getTypeEncoding(mTabBarSetFrame))) {
                        method_setImplementation(mTabBarSetFrame, (IMP)hypr_unifiedTabBar_setFrame);
                    }
                }

                Method mTabBarLayout = class_getInstanceMethod(unifiedTabBarClass, @selector(layout));
                if (mTabBarLayout) {
                    s_orig_unifiedTabBar_layout = (void (*)(id, SEL))method_getImplementation(mTabBarLayout);
                    if (!class_addMethod(unifiedTabBarClass, @selector(layout), (IMP)hypr_unifiedTabBar_layout, method_getTypeEncoding(mTabBarLayout))) {
                        method_setImplementation(mTabBarLayout, (IMP)hypr_unifiedTabBar_layout);
                    }
                }
            }

            Class itemViewerClass = objc_getClass("NSToolbarItemViewer");
            if (itemViewerClass) {
                Method mViewerSetFrame = class_getInstanceMethod(itemViewerClass, @selector(setFrame:));
                if (mViewerSetFrame) {
                    s_orig_toolbarItemViewer_setFrame = (void (*)(id, SEL, NSRect))method_getImplementation(mViewerSetFrame);
                    if (!class_addMethod(itemViewerClass, @selector(setFrame:), (IMP)hypr_toolbarItemViewer_setFrame, method_getTypeEncoding(mViewerSetFrame))) {
                        method_setImplementation(mViewerSetFrame, (IMP)hypr_toolbarItemViewer_setFrame);
                    }
                }
            }
        }

        // Strip all currently open windows immediately upon injection
        for (NSWindow *win in [NSApp windows]) {
            strip_window_decorations(win);
        }

        // Observe window updates to ensure new windows get stripped without re-processing stripped ones
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidUpdateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            id obj = note.object;
            if ([obj isKindOfClass:[NSWindow class]]) {
                NSWindow *win = (NSWindow *)obj;
                if (![objc_getAssociatedObject(win, kHyprWindowStrippedKey) boolValue]) {
                    strip_window_decorations(win);
                } else if ((is_finder() || is_safari()) && !hypr_get_drawer(win)) {
                    ensure_zen_drawer_attached(win);
                }
            }
        }];
}

#pragma mark - Constructor / Entry Point

__attribute__((constructor))
static void hypr_client_entry(void) {
    if (is_browser_or_selftheming_app()) {
        return;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if ([NSThread isMainThread]) {
            hypr_install_hooks_on_main();
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                hypr_install_hooks_on_main();
            });
        }
    });
}


