
import Cocoa

/// Layout presentation style for HyprBarWindow
public enum HyprBarStyle: Sendable, Equatable {
    /// Floating pill bar with custom horizontal and top margins from screen edges
    case floatingPill(horizontalMargin: CGFloat, topMargin: CGFloat)
    /// Docked edge-to-edge bar anchored directly to the screen top perimeter
    case docked
}

/// Transparent, non-activating system overlay panel displaying the Waybar 3-island floating status bar
@MainActor
public final class HyprBarWindow: NSPanel {
    nonisolated(unsafe) public static weak var shared: HyprBarWindow?
    public let barView: BarView

    public private(set) var isFullscreenAutoHide: Bool = false
    public private(set) var isRevealedInFullscreen: Bool = false
    public var topEdgeTriggerHeight: CGFloat = 4.0
    public var autoHideHoverPadding: CGFloat = 8.0
    public var autoHideDelay: TimeInterval = 0.25

    nonisolated(unsafe) private var mouseTrackingGlobalMonitor: Any?
    nonisolated(unsafe) private var mouseTrackingLocalMonitor: Any?
    nonisolated(unsafe) private var pendingHideWorkItem: DispatchWorkItem?

    public var barHeight: CGFloat {
        didSet { reposition() }
    }

    public var barStyle: HyprBarStyle {
        didSet { reposition() }
    }

    /// Bar's bottom edge in CoreGraphics coordinates (top = 0)
    public var barBottomY: CGFloat {
        switch barStyle {
        case .floatingPill(_, let topMargin):
            return topMargin + barHeight
        case .docked:
            return barHeight
        }
    }

    public weak var targetScreen: NSScreen? {
        didSet { reposition() }
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public init(
        screen: NSScreen? = NSScreen.main,
        height: CGFloat = 32.0,
        style: HyprBarStyle = .floatingPill(horizontalMargin: 8.0, topMargin: 5.0),
        workspaceCount: Int = 6
    ) {
        self.barHeight = height
        self.barStyle = style
        self.targetScreen = screen ?? NSScreen.main
        self.barView = BarView(frame: .zero, workspaceCount: workspaceCount)

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = barView

        Self.shared = self
        reposition()
        setupScreenNotifications()
    }

    deinit {
        stopFullscreenMouseTracking()
        if Self.shared === self {
            Self.shared = nil
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func setupScreenNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenParametersChanged(_ notification: Notification) {
        reposition()
    }

    /// Computes the normal resting visible frame for the status bar anchored to the top of screenFrame
    public func restingFrame(for screenFrame: NSRect) -> NSRect {
        switch barStyle {
        case .floatingPill(let horizontalMargin, let topMargin):
            let width = Swift.max(400.0, screenFrame.width - (2.0 * horizontalMargin))
            let x = screenFrame.origin.x + horizontalMargin
            let y = screenFrame.origin.y + screenFrame.height - barHeight - topMargin
            barView.cornerRadius = 5.0
            return NSRect(x: x, y: y, width: width, height: barHeight)

        case .docked:
            let width = screenFrame.width
            let x = screenFrame.origin.x
            let y = screenFrame.origin.y + screenFrame.height - barHeight
            barView.cornerRadius = 5.0
            return NSRect(x: x, y: y, width: width, height: barHeight)
        }
    }

    /// Computes the offscreen hidden frame tucked just above the top edge of screenFrame
    public func hiddenFullscreenFrame(for screenFrame: NSRect) -> NSRect {
        let resting = restingFrame(for: screenFrame)
        return NSRect(
            x: resting.origin.x,
            y: screenFrame.origin.y + screenFrame.height + 4.0,
            width: resting.width,
            height: resting.height
        )
    }

    /// Recalculates and repositions the panel anchored to the top of the target monitor
    public func reposition() {
        let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screenFrame = screen?.frame, screenFrame.width > 0, screenFrame.height > 0 else {
            return
        }

        let newFrame: NSRect
        if isFullscreenAutoHide && !isRevealedInFullscreen {
            newFrame = hiddenFullscreenFrame(for: screenFrame)
            alphaValue = 0.0
            ignoresMouseEvents = true
        } else {
            newFrame = restingFrame(for: screenFrame)
            alphaValue = 1.0
            ignoresMouseEvents = false
            orderFrontRegardless()
            if KeybindManager.shared.isMenuBarSuppressed {
                _ = SkyLightBridge.shared.setMenuBarSuppressed(true)
            }
        }

        if frame != newFrame {
            setFrame(newFrame, display: true, animate: false)
        }
    }

    // MARK: - Fullscreen Auto-Hide & Reveal

    /// Configures fullscreen auto-hide behavior and starts/stops mouse tracking
    public func setFullscreenAutoHide(_ enabled: Bool, animated: Bool = true) {
        guard isFullscreenAutoHide != enabled else { return }

        if enabled {
            isFullscreenAutoHide = true
            isRevealedInFullscreen = false
            startFullscreenMouseTracking()
            concealInFullscreen(animated: animated)
        } else {
            isFullscreenAutoHide = false
            isRevealedInFullscreen = false
            stopFullscreenMouseTracking()
            orderFrontRegardless()
            ignoresMouseEvents = false
            if KeybindManager.shared.isMenuBarSuppressed {
                _ = SkyLightBridge.shared.setMenuBarSuppressed(true)
            }
            let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first
            if let screenFrame = screen?.frame, screenFrame.width > 0, screenFrame.height > 0 {
                let targetRect = restingFrame(for: screenFrame)
                if animated {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.18
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        self.animator().setFrame(targetRect, display: true)
                        self.animator().alphaValue = 1.0
                    }
                } else {
                    setFrame(targetRect, display: true, animate: false)
                    alphaValue = 1.0
                }
            }
        }
    }

    /// Reveals the bar when tucked offscreen in fullscreen auto-hide
    public func revealInFullscreen(animated: Bool = true) {
        guard isFullscreenAutoHide else { return }
        cancelPendingHide()
        isRevealedInFullscreen = true
        orderFrontRegardless()
        ignoresMouseEvents = false
        if KeybindManager.shared.isMenuBarSuppressed {
            _ = SkyLightBridge.shared.setMenuBarSuppressed(true)
        }

        let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screenFrame = screen?.frame, screenFrame.width > 0, screenFrame.height > 0 else {
            return
        }
        let targetRect = restingFrame(for: screenFrame)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(targetRect, display: true)
                self.animator().alphaValue = 1.0
            }
        } else {
            setFrame(targetRect, display: true, animate: false)
            alphaValue = 1.0
        }
    }

    /// Conceals the bar back to offscreen position in fullscreen auto-hide
    public func concealInFullscreen(animated: Bool = true) {
        guard isFullscreenAutoHide else { return }
        cancelPendingHide()
        isRevealedInFullscreen = false
        ignoresMouseEvents = true

        let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screenFrame = screen?.frame, screenFrame.width > 0, screenFrame.height > 0 else {
            return
        }
        let targetRect = hiddenFullscreenFrame(for: screenFrame)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().setFrame(targetRect, display: true)
                self.animator().alphaValue = 0.0
            }
        } else {
            setFrame(targetRect, display: true, animate: false)
            alphaValue = 0.0
        }
    }

    /// Evaluates cursor position relative to the top edge and triggers reveal/conceal
    public func handleCursorLocation(
        _ mouseLocation: NSPoint = NSEvent.mouseLocation,
        animated: Bool = true,
        immediateHide: Bool = false
    ) {
        guard isFullscreenAutoHide else { return }
        let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screenFrame = screen?.frame, screenFrame.width > 0, screenFrame.height > 0 else {
            return
        }

        let withinX = (mouseLocation.x >= screenFrame.minX && mouseLocation.x <= screenFrame.maxX)
        guard withinX else {
            if isRevealedInFullscreen {
                if immediateHide || autoHideDelay <= 0 {
                    concealInFullscreen(animated: animated)
                } else {
                    scheduleHide(animated: animated)
                }
            }
            return
        }

        let distanceFromTop = (screenFrame.origin.y + screenFrame.height) - mouseLocation.y
        if distanceFromTop <= topEdgeTriggerHeight {
            cancelPendingHide()
            if !isRevealedInFullscreen {
                revealInFullscreen(animated: animated)
            }
        } else if isRevealedInFullscreen && distanceFromTop <= (barBottomY + autoHideHoverPadding) {
            cancelPendingHide()
        } else if isRevealedInFullscreen && distanceFromTop > (barBottomY + autoHideHoverPadding) {
            if immediateHide || autoHideDelay <= 0 {
                concealInFullscreen(animated: animated)
            } else {
                scheduleHide(animated: animated)
            }
        }
    }

    /// Starts on-demand global and local mouse tracking for top-edge reveal
    public func startFullscreenMouseTracking() {
        stopFullscreenMouseTracking()
        mouseTrackingGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleCursorLocation(NSEvent.mouseLocation, animated: true, immediateHide: false)
            }
        }
        mouseTrackingLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.handleCursorLocation(NSEvent.mouseLocation, animated: true, immediateHide: false)
            return event
        }
    }

    /// Stops mouse tracking and cancels any pending hide work items
    public nonisolated func stopFullscreenMouseTracking() {
        pendingHideWorkItem?.cancel()
        pendingHideWorkItem = nil
        if let global = mouseTrackingGlobalMonitor {
            NSEvent.removeMonitor(global)
            mouseTrackingGlobalMonitor = nil
        }
        if let local = mouseTrackingLocalMonitor {
            NSEvent.removeMonitor(local)
            mouseTrackingLocalMonitor = nil
        }
    }

    private func cancelPendingHide() {
        pendingHideWorkItem?.cancel()
        pendingHideWorkItem = nil
    }

    private func scheduleHide(animated: Bool) {
        guard pendingHideWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingHideWorkItem = nil
            let loc = NSEvent.mouseLocation
            let screen = self.targetScreen ?? NSScreen.main ?? NSScreen.screens.first
            guard let sFrame = screen?.frame else {
                self.concealInFullscreen(animated: animated)
                return
            }
            let inX = (loc.x >= sFrame.minX && loc.x <= sFrame.maxX)
            let distFromTop = (sFrame.origin.y + sFrame.height) - loc.y
            if !inX || distFromTop > (self.barBottomY + self.autoHideHoverPadding) {
                self.concealInFullscreen(animated: animated)
            }
        }
        self.pendingHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideDelay, execute: item)
    }

    // MARK: - Control Methods

    /// Orders the bar frontmost without activating or stealing keyboard focus, starting timers
    public func showBar() {
        reposition()
        orderFrontRegardless()
        ignoresMouseEvents = false
        if KeybindManager.shared.isMenuBarSuppressed {
            _ = SkyLightBridge.shared.setMenuBarSuppressed(true)
        }
        barView.startTimers()
        NotificationCenterManager.shared.start()
    }

    /// Hides the bar and halts background timers
    public func hideBar() {
        stopFullscreenMouseTracking()
        if isVisible {
            orderOut(nil)
        }
        barView.stopTimers()
    }

    /// Updates active workspace indicator
    public func updateActiveWorkspace(_ id: Int) {
        barView.updateActiveWorkspace(id)
    }

    /// Updates focused application name and window title
    public func updateActiveWindow(title: String, app: String) {
        barView.updateActiveWindow(title: title, app: app)
    }
}

