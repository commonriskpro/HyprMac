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
    public let barView: BarView

    public var barHeight: CGFloat {
        didSet { reposition() }
    }

    public var barStyle: HyprBarStyle {
        didSet { reposition() }
    }

    public weak var targetScreen: NSScreen? {
        didSet { reposition() }
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public init(
        screen: NSScreen? = NSScreen.main,
        height: CGFloat = 46.0,
        style: HyprBarStyle = .floatingPill(horizontalMargin: 10.0, topMargin: 8.0),
        workspaceCount: Int = 5
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
        level = .mainMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = barView

        reposition()
        setupScreenNotifications()
    }

    deinit {
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

    /// Recalculates and repositions the panel anchored to the top of the target monitor
    public func reposition() {
        let screen = targetScreen ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let newFrame: NSRect
        switch barStyle {
        case .floatingPill(let horizontalMargin, let topMargin):
            let width = Swift.max(400.0, screenFrame.width - (2.0 * horizontalMargin))
            let x = screenFrame.origin.x + horizontalMargin
            let y = screenFrame.origin.y + screenFrame.height - barHeight - topMargin
            newFrame = NSRect(x: x, y: y, width: width, height: barHeight)
            barView.cornerRadius = 17.0

        case .docked:
            let width = screenFrame.width
            let x = screenFrame.origin.x
            let y = screenFrame.origin.y + screenFrame.height - barHeight
            newFrame = NSRect(x: x, y: y, width: width, height: barHeight)
            barView.cornerRadius = 17.0
        }

        if frame != newFrame {
            setFrame(newFrame, display: true, animate: false)
        }
    }

    // MARK: - Control Methods

    /// Orders the bar frontmost without activating or stealing keyboard focus, starting timers
    public func showBar() {
        reposition()
        if !isVisible {
            orderFrontRegardless()
        }
        barView.startTimers()
    }

    /// Hides the bar and halts background timers
    public func hideBar() {
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

    // MARK: - Self-Test Suite

    /// Executes self-diagnostics verifying view hierarchy, layout, and system status reading
    @discardableResult
    public static func runSelfTest() -> Bool {
        print("[HyprBarWindow] Starting self-test diagnostics...")

        let testScreen = NSScreen.main
        let window = HyprBarWindow(
            screen: testScreen,
            height: 46.0,
            style: .floatingPill(horizontalMargin: 10.0, topMargin: 8.0),
            workspaceCount: 5
        )

        guard window.contentView === window.barView else {
            print("[-] SelfTest failed: contentView mismatch")
            return false
        }

        // Verify window masks and levels
        guard window.level == .mainMenu else {
            print("[-] SelfTest failed: level != .mainMenu (actual: \(window.level.rawValue))")
            return false
        }

        let expectedBehaviors: [NSWindow.CollectionBehavior] = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        for behavior in expectedBehaviors {
            guard window.collectionBehavior.contains(behavior) else {
                print("[-] SelfTest failed: missing collectionBehavior \(behavior)")
                return false
            }
        }

        guard window.styleMask.contains(.borderless) && window.styleMask.contains(.nonactivatingPanel) else {
            print("[-] SelfTest failed: styleMask mismatch")
            return false
        }

        // Verify window transparency and shadow ownership
        guard !window.hasShadow else {
            print("[-] SelfTest failed: window hasShadow must be false (shadows are projected by individual capsules)")
            return false
        }

        guard window.backgroundColor == .clear else {
            print("[-] SelfTest failed: window backgroundColor must be clear")
            return false
        }

        // Verify workspace update logic
        window.updateActiveWorkspace(1)
        guard window.barView.activeWorkspaceID == 1 else {
            print("[-] SelfTest failed: activeWorkspaceID != 1")
            return false
        }

        window.updateActiveWorkspace(4)
        guard window.barView.activeWorkspaceID == 4 else {
            print("[-] SelfTest failed: activeWorkspaceID != 4")
            return false
        }

        // Verify active window updates
        window.updateActiveWindow(title: "HyprMac — Waybar", app: "Ghostty")
        guard window.barView.currentAppName == "Ghostty" else {
            print("[-] SelfTest failed: currentAppName mismatch")
            return false
        }
        guard window.barView.currentWindowTitle == "HyprMac — Waybar" else {
            print("[-] SelfTest failed: currentWindowTitle mismatch")
            return false
        }

        // Verify battery querying without crashing
        let battery = BatteryMonitor.currentStatus()
        print("[HyprBarWindow] Battery status verified: \(battery.formattedText) (\(battery.powerSource))")

        // Verify hardware CPU monitor
        let cpu = HardwareMonitor.currentCPULoad()
        print("[HyprBarWindow] Hardware CPU load verified: \(cpu)%")

        // Verify volume monitor
        let vol = VolumeMonitor.currentVolume()
        print("[HyprBarWindow] Volume level verified: \(vol)%")

        // Verify clock update
        window.barView.updateClock()

        // Force a layout pass
        window.reposition()
        window.barView.layoutSubtreeIfNeeded()
        guard window.frame.width > 0 && window.frame.height > 0 else {
            print("[-] SelfTest failed: window frame has non-positive dimensions")
            return false
        }

        // Verify show/hide operations
        window.showBar()
        guard window.isVisible else {
            print("[-] SelfTest failed: window is not visible after showBar()")
            return false
        }

        window.hideBar()
        guard !window.isVisible else {
            print("[-] SelfTest failed: window is still visible after hideBar()")
            return false
        }

        print("[+] HyprBarWindow self-test completed with 100% success!")
        return true
    }
}
