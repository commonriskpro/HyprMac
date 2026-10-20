import Cocoa
import Foundation

/// Floating transient notification toast panel matching SwayNC / mxmrn aesthetic.
@MainActor
public final class NotificationToastWindow: NSPanel {
    public static let panelWidth: CGFloat = 350.0
    public static let defaultHeight: CGFloat = 78.0

    public let notification: HyprNotification
    public var onDismiss: (@MainActor () -> Void)?
    public var onAction: (@MainActor (HyprNotification) -> Void)?

    private let capsuleView = FloatingCapsuleView(cornerRadius: 10.0, surfaceAlpha: 0.70)
    private let iconImageView = NSImageView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let dismissButton = ClickablePill()
    private let dismissLabel = NSTextField(labelWithString: "✕")

    private var dismissTimer: Timer?
    private var trackingArea: NSTrackingArea?

    public init(notification: HyprNotification) {
        self.notification = notification
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.defaultHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        setupUI()
        setupTimer()
    }

    private func setupUI() {
        guard let content = contentView else { return }

        capsuleView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(capsuleView)

        NSLayoutConstraint.activate([
            capsuleView.topAnchor.constraint(equalTo: content.topAnchor),
            capsuleView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            capsuleView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            capsuleView.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])

        let container = capsuleView.contentView
        let theme = HyprTheme.shared

        // 1. App Icon (48x48)
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.wantsLayer = true
        iconImageView.layer?.cornerRadius = 8.0
        iconImageView.layer?.masksToBounds = true
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.image = notification.icon ?? NSWorkspace.shared.icon(for: .application)
        container.addSubview(iconImageView)

        // 2. Dismiss Button (24x24 circular button)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.wantsLayer = true
        dismissButton.layer?.cornerRadius = 12.0
        dismissButton.layer?.backgroundColor = theme.surface.withAlphaComponent(0.60).cgColor
        dismissButton.layer?.borderWidth = 1.0
        dismissButton.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        dismissButton.onClick = { [weak self] in
            self?.dismissToast()
        }
        container.addSubview(dismissButton)

        dismissLabel.translatesAutoresizingMaskIntoConstraints = false
        dismissLabel.isEditable = false
        dismissLabel.isSelectable = false
        dismissLabel.font = .barFont(ofSize: 10.0, weight: .bold)
        dismissLabel.alignment = .center
        dismissLabel.textColor = theme.primary
        dismissButton.addSubview(dismissLabel)

        NSLayoutConstraint.activate([
            dismissLabel.centerXAnchor.constraint(equalTo: dismissButton.centerXAnchor),
            dismissLabel.centerYAnchor.constraint(equalTo: dismissButton.centerYAnchor)
        ])

        // 3. Text Header Container: Summary + Timestamp
        let textContainer = NSView()
        textContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textContainer)

        let headerStack = NSStackView()
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.distribution = .fill
        headerStack.alignment = .centerY
        headerStack.spacing = 6.0
        textContainer.addSubview(headerStack)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.isEditable = false
        summaryLabel.isSelectable = false
        summaryLabel.font = .barFont(ofSize: 11.5, weight: .bold, italic: true)
        summaryLabel.textColor = theme.primary
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.stringValue = notification.appName.isEmpty ? notification.title : notification.appName
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerStack.addArrangedSubview(summaryLabel)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.isEditable = false
        timeLabel.isSelectable = false
        timeLabel.font = .barFont(ofSize: 10.5, weight: .bold, italic: true)
        timeLabel.textColor = theme.tertiary
        timeLabel.alignment = .right
        timeLabel.stringValue = notification.formattedTimestamp
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        headerStack.addArrangedSubview(timeLabel)

        // 4. Body Label
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.isEditable = false
        bodyLabel.isSelectable = false
        bodyLabel.font = .barFont(ofSize: 11.0, weight: .regular)
        bodyLabel.textColor = theme.onSurface
        bodyLabel.maximumNumberOfLines = 2
        bodyLabel.lineBreakMode = .byTruncatingTail
        let effectiveBody = notification.body.isEmpty ? notification.title : notification.body
        bodyLabel.stringValue = effectiveBody
        textContainer.addSubview(bodyLabel)

        NSLayoutConstraint.activate([
            // Icon
            iconImageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12.0),
            iconImageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 48.0),
            iconImageView.heightAnchor.constraint(equalToConstant: 48.0),

            // Dismiss Button
            dismissButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12.0),
            dismissButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 24.0),
            dismissButton.heightAnchor.constraint(equalToConstant: 24.0),

            // Text container
            textContainer.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 10.0),
            textContainer.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -8.0),
            textContainer.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            headerStack.topAnchor.constraint(equalTo: textContainer.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            bodyLabel.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 4.0),
            bodyLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            bodyLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor)
        ])

        // Mouse tracking for hover detection
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        content.addTrackingArea(tracking)
        self.trackingArea = tracking
    }

    private func setupTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismissToast()
            }
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setupTimer()
    }

    public override func mouseUp(with event: NSEvent) {
        let loc = contentView?.convert(event.locationInWindow, from: nil) ?? .zero
        if dismissButton.frame.contains(loc) {
            return
        }

        // Focus application when clicking toast body
        if !notification.appIdentifier.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notification.appIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
        onAction?(notification)
        dismissToast()
    }

    /// Closes and animates out the toast panel.
    public func dismissToast() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.20
            animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.orderOut(nil)
                self?.onDismiss?()
            }
        })
    }
}

/// Manages stacking and presentation of up to 5 concurrent toasts vertically with 8.0 pt spacing.
@MainActor
public final class NotificationToastManager {
    public static let shared = NotificationToastManager()

    public static let maxToasts: Int = 5
    public static let toastWidth: CGFloat = 350.0
    public static let toastMarginRight: CGFloat = 10.0
    public static let toastSpacing: CGFloat = 8.0

    public private(set) var activeToasts: [NotificationToastWindow] = []

    public init() {}

    /// Presents a new notification toast, stacking or dismissing oldest if needed.
    public func present(notification: HyprNotification, animate: Bool = true) {
        if activeToasts.count >= Self.maxToasts {
            let oldest = activeToasts.removeFirst()
            oldest.dismissToast()
        }

        let toast = NotificationToastWindow(notification: notification)
        toast.onDismiss = { [weak self, weak toast] in
            guard let self = self, let toast = toast else { return }
            self.removeToast(toast)
        }

        activeToasts.append(toast)
        repositionToasts(animate: animate)
    }

    public func removeToast(_ toast: NotificationToastWindow) {
        if let idx = activeToasts.firstIndex(where: { $0 === toast }) {
            activeToasts.remove(at: idx)
            repositionToasts(animate: true)
        }
    }

    /// Recalculates vertical stacked layout below HyprBar anchored 10.0 pt from right screen edge.
    public func repositionToasts(animate: Bool = false) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let barBottom = HyprBarWindow.shared?.frame.minY ?? (screenFrame.maxY - 40.0)
        var currentTopY = barBottom - 10.0
        let x = screenFrame.maxX - Self.toastWidth - Self.toastMarginRight

        for toast in activeToasts {
            let h = toast.frame.height > 0 ? toast.frame.height : NotificationToastWindow.defaultHeight
            let targetFrame = NSRect(x: x, y: currentTopY - h, width: Self.toastWidth, height: h)
            if animate {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    toast.animator().setFrame(targetFrame, display: true)
                }
            } else {
                toast.setFrame(targetFrame, display: true)
            }
            toast.orderFront(nil)
            currentTopY = targetFrame.minY - Self.toastSpacing
        }
    }

    /// Dismisses all active toasts immediately.
    public func dismissAll() {
        let copy = activeToasts
        activeToasts.removeAll()
        for t in copy {
            t.dismissToast()
        }
    }
}
