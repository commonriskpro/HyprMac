
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
        level = .mainMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = barView

        Self.shared = self
        reposition()
        setupScreenNotifications()
    }

    deinit {
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

    /// Recalculates and repositions the panel anchored to the top of the target monitor
    public func reposition() {
        let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screenFrame = screen?.frame, screenFrame.width > 0, screenFrame.height > 0 else {
            return
        }

        let newFrame: NSRect
        switch barStyle {
        case .floatingPill(let horizontalMargin, let topMargin):
            let width = Swift.max(400.0, screenFrame.width - (2.0 * horizontalMargin))
            let x = screenFrame.origin.x + horizontalMargin
            let y = screenFrame.origin.y + screenFrame.height - barHeight - topMargin
            newFrame = NSRect(x: x, y: y, width: width, height: barHeight)
            barView.cornerRadius = 5.0

        case .docked:
            let width = screenFrame.width
            let x = screenFrame.origin.x
            let y = screenFrame.origin.y + screenFrame.height - barHeight
            newFrame = NSRect(x: x, y: y, width: width, height: barHeight)
            barView.cornerRadius = 5.0
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
        NotificationCenterManager.shared.start()
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
}

