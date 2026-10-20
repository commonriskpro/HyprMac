import Cocoa
import Foundation

/// Slide-in notification center drawer matching SwayNC / mxmrn design:
/// 350.0 pt width, Matugen glassmorphism, 10px rounded corners, 48x48 icons, DND, volume slider, clear-all.
@MainActor
public final class NotificationCenterDrawer: NSPanel {
    public static let drawerWidth: CGFloat = 350.0
    public static let drawerMarginRight: CGFloat = 10.0

    private let capsuleView = FloatingCapsuleView(cornerRadius: 10.0, surfaceAlpha: 0.75)

    // Header
    private let titleLabel = NSTextField(labelWithString: "󰂚  :: Notifications")
    private let clearAllButton = ClickablePill()
    private let clearAllLabel = NSTextField(labelWithString: "󰎟  Clear")

    // Widgets
    private let dndSwitch = NSSwitch()
    private let volumeSlider = NSSlider()
    private let volumeValueLabel = NSTextField(labelWithString: "80%")

    // Notification History List
    private let scrollView = NSScrollView()
    private let cardsStackView = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No Notifications")

    private var outsideClickMonitor: Any?
    public private(set) var isOpen: Bool = false

    public init() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let barBottom = HyprBarWindow.shared?.frame.minY ?? (screenFrame.maxY - 40.0)
        let topY = barBottom - 10.0
        let drawerHeight = min(680.0, max(300.0, topY - (screenFrame.minY + 20.0)))

        let initialFrame = NSRect(
            x: screenFrame.maxX,
            y: topY - drawerHeight,
            width: Self.drawerWidth,
            height: drawerHeight
        )

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .mainMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        setupUI()
    }

    public override var canBecomeKey: Bool { true }

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

        // 1. Header Row: Title + Clear All Button
        let headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.font = .barFont(ofSize: 12.5, weight: .bold, italic: true)
        titleLabel.textColor = theme.primary
        headerView.addSubview(titleLabel)

        clearAllButton.translatesAutoresizingMaskIntoConstraints = false
        clearAllButton.wantsLayer = true
        clearAllButton.layer?.cornerRadius = 10.0
        clearAllButton.layer?.backgroundColor = theme.surface.withAlphaComponent(0.60).cgColor
        clearAllButton.layer?.borderWidth = 1.0
        clearAllButton.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        clearAllButton.onClick = {
            NotificationCenterManager.shared.clearAll()
        }
        headerView.addSubview(clearAllButton)

        clearAllLabel.translatesAutoresizingMaskIntoConstraints = false
        clearAllLabel.isEditable = false
        clearAllLabel.isSelectable = false
        clearAllLabel.font = .barFont(ofSize: 11.0, weight: .bold)
        clearAllLabel.textColor = theme.tertiary
        clearAllButton.addSubview(clearAllLabel)

        NSLayoutConstraint.activate([
            clearAllLabel.centerXAnchor.constraint(equalTo: clearAllButton.centerXAnchor),
            clearAllLabel.centerYAnchor.constraint(equalTo: clearAllButton.centerYAnchor),
            clearAllLabel.leadingAnchor.constraint(equalTo: clearAllButton.leadingAnchor, constant: 8.0),
            clearAllLabel.trailingAnchor.constraint(equalTo: clearAllButton.trailingAnchor, constant: -8.0),
            clearAllButton.heightAnchor.constraint(equalToConstant: 24.0),

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            clearAllButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            clearAllButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 28.0)
        ])

        // 2. DND Toggle Widget
        let dndPill = NSView()
        dndPill.translatesAutoresizingMaskIntoConstraints = false
        dndPill.wantsLayer = true
        dndPill.layer?.cornerRadius = 8.0
        dndPill.layer?.backgroundColor = theme.surface.withAlphaComponent(0.60).cgColor
        dndPill.layer?.borderWidth = 1.0
        dndPill.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        container.addSubview(dndPill)

        let dndLabel = NSTextField(labelWithString: "Do Not Disturb")
        dndLabel.translatesAutoresizingMaskIntoConstraints = false
        dndLabel.isEditable = false
        dndLabel.isSelectable = false
        dndLabel.font = .barFont(ofSize: 11.5, weight: .bold)
        dndLabel.textColor = theme.onSurface
        dndPill.addSubview(dndLabel)

        dndSwitch.translatesAutoresizingMaskIntoConstraints = false
        dndSwitch.target = self
        dndSwitch.action = #selector(dndToggled(_:))
        dndPill.addSubview(dndSwitch)

        NSLayoutConstraint.activate([
            dndPill.heightAnchor.constraint(equalToConstant: 38.0),
            dndLabel.leadingAnchor.constraint(equalTo: dndPill.leadingAnchor, constant: 12.0),
            dndLabel.centerYAnchor.constraint(equalTo: dndPill.centerYAnchor),
            dndSwitch.trailingAnchor.constraint(equalTo: dndPill.trailingAnchor, constant: -12.0),
            dndSwitch.centerYAnchor.constraint(equalTo: dndPill.centerYAnchor)
        ])

        // 3. Volume Slider Widget
        let volPill = NSView()
        volPill.translatesAutoresizingMaskIntoConstraints = false
        volPill.wantsLayer = true
        volPill.layer?.cornerRadius = 8.0
        volPill.layer?.backgroundColor = theme.surface.withAlphaComponent(0.60).cgColor
        volPill.layer?.borderWidth = 1.0
        volPill.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        container.addSubview(volPill)

        let volIconLabel = NSTextField(labelWithString: "󰕾 ")
        volIconLabel.translatesAutoresizingMaskIntoConstraints = false
        volIconLabel.isEditable = false
        volIconLabel.isSelectable = false
        volIconLabel.font = .barFont(ofSize: 13.0, weight: .bold)
        volIconLabel.textColor = theme.tertiary
        volPill.addSubview(volIconLabel)

        let currentVol = VolumeMonitor.currentVolume()
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.minValue = 0.0
        volumeSlider.maxValue = 100.0
        volumeSlider.doubleValue = Double(currentVol)
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volPill.addSubview(volumeSlider)

        volumeValueLabel.translatesAutoresizingMaskIntoConstraints = false
        volumeValueLabel.isEditable = false
        volumeValueLabel.isSelectable = false
        volumeValueLabel.font = .barFont(ofSize: 11.0, weight: .bold)
        volumeValueLabel.textColor = theme.onSurface
        volumeValueLabel.stringValue = "\(currentVol)%"
        volPill.addSubview(volumeValueLabel)

        NSLayoutConstraint.activate([
            volPill.heightAnchor.constraint(equalToConstant: 38.0),
            volIconLabel.leadingAnchor.constraint(equalTo: volPill.leadingAnchor, constant: 12.0),
            volIconLabel.centerYAnchor.constraint(equalTo: volPill.centerYAnchor),
            volIconLabel.widthAnchor.constraint(equalToConstant: 22.0),

            volumeValueLabel.trailingAnchor.constraint(equalTo: volPill.trailingAnchor, constant: -12.0),
            volumeValueLabel.centerYAnchor.constraint(equalTo: volPill.centerYAnchor),
            volumeValueLabel.widthAnchor.constraint(equalToConstant: 36.0),

            volumeSlider.leadingAnchor.constraint(equalTo: volIconLabel.trailingAnchor, constant: 4.0),
            volumeSlider.trailingAnchor.constraint(equalTo: volumeValueLabel.leadingAnchor, constant: -6.0),
            volumeSlider.centerYAnchor.constraint(equalTo: volPill.centerYAnchor)
        ])

        // 4. Scrollable History List
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        container.addSubview(scrollView)

        let flippedDoc = FlippedClipView()
        flippedDoc.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = flippedDoc

        cardsStackView.translatesAutoresizingMaskIntoConstraints = false
        cardsStackView.orientation = .vertical
        cardsStackView.alignment = .leading
        cardsStackView.spacing = 8.0
        flippedDoc.addSubview(cardsStackView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isEditable = false
        emptyLabel.isSelectable = false
        emptyLabel.font = .barFont(ofSize: 13.0, weight: .medium, italic: true)
        emptyLabel.textColor = theme.onSurface.withAlphaComponent(0.50)
        emptyLabel.alignment = .center
        emptyLabel.stringValue = "No Notifications"
        flippedDoc.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: container.topAnchor, constant: 14.0),
            headerView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14.0),
            headerView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14.0),

            dndPill.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 10.0),
            dndPill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14.0),
            dndPill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14.0),

            volPill.topAnchor.constraint(equalTo: dndPill.bottomAnchor, constant: 8.0),
            volPill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14.0),
            volPill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14.0),

            scrollView.topAnchor.constraint(equalTo: volPill.bottomAnchor, constant: 12.0),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12.0),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12.0),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12.0),

            flippedDoc.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            flippedDoc.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            flippedDoc.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            cardsStackView.topAnchor.constraint(equalTo: flippedDoc.topAnchor),
            cardsStackView.leadingAnchor.constraint(equalTo: flippedDoc.leadingAnchor),
            cardsStackView.trailingAnchor.constraint(equalTo: flippedDoc.trailingAnchor),
            cardsStackView.bottomAnchor.constraint(equalTo: flippedDoc.bottomAnchor),
            cardsStackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: flippedDoc.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: flippedDoc.centerYAnchor, constant: 40.0)
        ])

        reloadHistory()
    }

    @objc private func dndToggled(_ sender: NSSwitch) {
        NotificationCenterManager.shared.isDoNotDisturb = (sender.state == .on)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        let vol = Int(sender.doubleValue)
        VolumeMonitor.setVolume(vol)
        volumeValueLabel.stringValue = "\(vol)%"
    }

    /// Re-renders the list of notification cards from NotificationCenterManager history.
    public func reloadHistory() {
        let items = NotificationCenterManager.shared.history

        // Clear existing cards
        for view in cardsStackView.arrangedSubviews {
            cardsStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        emptyLabel.isHidden = !items.isEmpty

        for item in items {
            let card = NotificationCardView(notification: item)
            card.translatesAutoresizingMaskIntoConstraints = false
            cardsStackView.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: cardsStackView.widthAnchor).isActive = true
        }

        dndSwitch.state = NotificationCenterManager.shared.isDoNotDisturb ? .on : .off
        let vol = VolumeMonitor.currentVolume()
        volumeSlider.doubleValue = Double(vol)
        volumeValueLabel.stringValue = "\(vol)%"
    }

    /// Computes drawer open and closed geometry anchored below HyprBar and 10 pt from right screen edge.
    public func calculateFrames() -> (openFrame: NSRect, closedFrame: NSRect) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let barBottom = HyprBarWindow.shared?.frame.minY ?? (screenFrame.maxY - 40.0)
        let topY = barBottom - 10.0
        let drawerHeight = min(680.0, max(300.0, topY - (screenFrame.minY + 20.0)))

        let targetX = screenFrame.maxX - Self.drawerWidth - Self.drawerMarginRight
        let offscreenX = screenFrame.maxX

        let openFrame = NSRect(x: targetX, y: topY - drawerHeight, width: Self.drawerWidth, height: drawerHeight)
        let closedFrame = NSRect(x: offscreenX, y: topY - drawerHeight, width: Self.drawerWidth, height: drawerHeight)
        return (openFrame, closedFrame)
    }

    /// Opens drawer with slide-in animation from the right.
    public func openDrawer(animate: Bool = true) {
        guard !isOpen else { return }
        isOpen = true

        reloadHistory()

        let (targetFrame, startFrame) = calculateFrames()

        if animate {
            setFrame(startFrame, display: true)
            alphaValue = 0.0
            orderFront(nil)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                animator().setFrame(targetFrame, display: true)
                animator().alphaValue = 1.0
            }
        } else {
            setFrame(targetFrame, display: true)
            alphaValue = 1.0
            orderFront(nil)
        }

        // Outside click monitor to auto-dismiss
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isOpen else { return event }
            if let clickWindow = event.window, clickWindow === self || clickWindow is HyprBarWindow {
                return event
            }
            self.closeDrawer()
            return event
        }
    }

    /// Closes drawer with slide-out animation to the right.
    public func closeDrawer(animate: Bool = true) {
        guard isOpen else { return }
        isOpen = false

        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }

        let (_, closedFrame) = calculateFrames()

        if animate {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                animator().setFrame(closedFrame, display: true)
                animator().alphaValue = 0.0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.orderOut(nil)
                }
            })
        } else {
            setFrame(closedFrame, display: true)
            alphaValue = 0.0
            orderOut(nil)
        }
    }

    public func toggleDrawer() {
        if isOpen {
            closeDrawer()
        } else {
            openDrawer()
        }
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            closeDrawer()
            return
        }
        super.keyDown(with: event)
    }
}

/// Flipped coordinate container for top-down scroll layout
private final class FlippedClipView: NSView {
    override var isFlipped: Bool { true }
}

/// Individual notification card in the NotificationCenterDrawer history list.
@MainActor
private final class NotificationCardView: NSView {
    public let notification: HyprNotification
    private let dismissButton = ClickablePill()

    public init(notification: HyprNotification) {
        self.notification = notification
        super.init(frame: .zero)
        setupView()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 10.0
        let theme = HyprTheme.shared
        layer?.backgroundColor = theme.surface.withAlphaComponent(0.60).cgColor
        layer?.borderWidth = 1.0
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor

        // App Icon (48x48)
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 8.0
        iconView.layer?.masksToBounds = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = notification.icon ?? NSWorkspace.shared.icon(for: .application)
        addSubview(iconView)

        // Dismiss Button
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.wantsLayer = true
        dismissButton.layer?.cornerRadius = 11.0
        dismissButton.layer?.backgroundColor = theme.surface.withAlphaComponent(0.80).cgColor
        dismissButton.layer?.borderWidth = 1.0
        dismissButton.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        let notifID = notification.id
        dismissButton.onClick = {
            NotificationCenterManager.shared.removeNotification(id: notifID)
        }
        addSubview(dismissButton)

        let dismissLabel = NSTextField(labelWithString: "✕")
        dismissLabel.translatesAutoresizingMaskIntoConstraints = false
        dismissLabel.isEditable = false
        dismissLabel.isSelectable = false
        dismissLabel.font = .barFont(ofSize: 10.0, weight: .bold)
        dismissLabel.textColor = theme.primary
        dismissButton.addSubview(dismissLabel)

        NSLayoutConstraint.activate([
            dismissLabel.centerXAnchor.constraint(equalTo: dismissButton.centerXAnchor),
            dismissLabel.centerYAnchor.constraint(equalTo: dismissButton.centerYAnchor)
        ])

        // Middle text container
        let textContainer = NSView()
        textContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textContainer)

        let headerStack = NSStackView()
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.distribution = .fill
        headerStack.alignment = .centerY
        headerStack.spacing = 6.0
        textContainer.addSubview(headerStack)

        let summaryLabel = NSTextField(labelWithString: notification.appName.isEmpty ? notification.title : notification.appName)
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.isEditable = false
        summaryLabel.isSelectable = false
        summaryLabel.font = .barFont(ofSize: 11.5, weight: .bold, italic: true)
        summaryLabel.textColor = theme.primary
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerStack.addArrangedSubview(summaryLabel)

        let timeLabel = NSTextField(labelWithString: notification.formattedTimestamp)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.isEditable = false
        timeLabel.isSelectable = false
        timeLabel.font = .barFont(ofSize: 10.5, weight: .bold, italic: true)
        timeLabel.textColor = theme.tertiary
        timeLabel.alignment = .right
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        headerStack.addArrangedSubview(timeLabel)

        let bodyLabel = NSTextField(labelWithString: notification.body.isEmpty ? notification.title : notification.body)
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.isEditable = false
        bodyLabel.isSelectable = false
        bodyLabel.font = .barFont(ofSize: 11.0, weight: .regular)
        bodyLabel.textColor = theme.onSurface
        bodyLabel.maximumNumberOfLines = 3
        bodyLabel.lineBreakMode = .byTruncatingTail
        textContainer.addSubview(bodyLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10.0),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 10.0),
            iconView.widthAnchor.constraint(equalToConstant: 48.0),
            iconView.heightAnchor.constraint(equalToConstant: 48.0),

            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10.0),
            dismissButton.topAnchor.constraint(equalTo: topAnchor, constant: 10.0),
            dismissButton.widthAnchor.constraint(equalToConstant: 22.0),
            dismissButton.heightAnchor.constraint(equalToConstant: 22.0),

            textContainer.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10.0),
            textContainer.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -8.0),
            textContainer.topAnchor.constraint(equalTo: topAnchor, constant: 10.0),
            textContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10.0),

            headerStack.topAnchor.constraint(equalTo: textContainer.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            bodyLabel.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 4.0),
            bodyLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            bodyLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor)
        ])
    }

    public override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if dismissButton.frame.contains(loc) {
            return
        }
        if !notification.appIdentifier.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notification.appIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }
}
