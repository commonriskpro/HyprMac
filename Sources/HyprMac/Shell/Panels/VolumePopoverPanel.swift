import Cocoa
import QuartzCore

/// Dark floating popover panel anchored below the top bar's volume pill for quick slider control and output device selection.
@MainActor
public final class VolumePopoverPanel: NSPanel {
    public static let panelWidth: CGFloat = 280.0

    public private(set) var isOpen: Bool = false
    public var onClose: (() -> Void)?

    private let capsuleView = FloatingCapsuleView(cornerRadius: 10.0, surfaceAlpha: 0.65)

    // Volume section
    private let volumeIconLabel = NSTextField(labelWithString: "󰕾")
    private let volumeTitleLabel = NSTextField(labelWithString: "Sound")
    private let volumePercentLabel = NSTextField(labelWithString: "80%")
    private let volumeSlider = NSSlider()
    private let divider = NSView()

    // Devices section
    private let devicesHeaderLabel = NSTextField(labelWithString: "OUTPUT DEVICES")
    private let devicesStack = NSStackView()

    private var outsideClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var volumeObserver: Any?

    public struct ResolvedColors: Sendable {
        public let background: NSColor
        public let border: NSColor
        public let surface: NSColor
        public let accent: NSColor
        public let textPrimary: NSColor
        public let textSecondary: NSColor

        public init(theme: HyprTheme = .shared, barColors: HyprBarColors = HyprBarColors(), backgroundAlpha: CGFloat = 0.65) {
            let baseBg = theme.resolveColor(barColors.surface, fallback: theme.surface)
            self.background = baseBg.withAlphaComponent(backgroundAlpha)
            self.border = theme.resolveColor(nil, fallback: theme.outline)
            self.surface = theme.resolveColor(barColors.surface, fallback: theme.surface)
            self.accent = theme.resolveColor(barColors.volume, fallback: theme.primary)
            self.textPrimary = theme.resolveColor(barColors.windowTitle, fallback: theme.onSurface)
            self.textSecondary = theme.resolveColor(barColors.clock, fallback: theme.secondary)
        }
    }

    public init(anchorFrame: NSRect, screen: NSScreen?) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = targetScreen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let initialHeight: CGFloat = 180.0
        let popoverX = min(
            max(screenFrame.origin.x + 10.0, anchorFrame.midX - (Self.panelWidth / 2.0)),
            screenFrame.origin.x + screenFrame.width - Self.panelWidth - 10.0
        )
        let popoverY = anchorFrame.minY - initialHeight - 6.0

        let initialFrame = NSRect(x: popoverX, y: popoverY, width: Self.panelWidth, height: initialHeight)

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        setupUI()
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

        let mainStack = NSStackView()
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10.0
        container.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14.0),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14.0),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14.0),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14.0)
        ])

        // Top Row: Icon + Title + Percent
        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 6.0
        topRow.translatesAutoresizingMaskIntoConstraints = false

        volumeIconLabel.translatesAutoresizingMaskIntoConstraints = false
        volumeIconLabel.isEditable = false
        volumeIconLabel.isSelectable = false
        volumeIconLabel.font = .barFont(ofSize: 13, weight: .bold)
        volumeIconLabel.textColor = theme.tertiary
        topRow.addArrangedSubview(volumeIconLabel)

        volumeTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        volumeTitleLabel.isEditable = false
        volumeTitleLabel.isSelectable = false
        volumeTitleLabel.font = .barFont(ofSize: 12, weight: .bold)
        volumeTitleLabel.textColor = theme.onSurface
        topRow.addArrangedSubview(volumeTitleLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topRow.addArrangedSubview(spacer)

        volumePercentLabel.translatesAutoresizingMaskIntoConstraints = false
        volumePercentLabel.isEditable = false
        volumePercentLabel.isSelectable = false
        volumePercentLabel.font = .barFont(ofSize: 11, weight: .bold, monospacedDigits: true)
        volumePercentLabel.textColor = theme.tertiary
        topRow.addArrangedSubview(volumePercentLabel)

        mainStack.addArrangedSubview(topRow)
        topRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // Volume Slider
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.minValue = 0.0
        volumeSlider.maxValue = 100.0
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(sliderChanged(_:))
        mainStack.addArrangedSubview(volumeSlider)
        volumeSlider.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // Subtle Divider
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        divider.heightAnchor.constraint(equalToConstant: 1.0).isActive = true
        mainStack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // Devices Header
        devicesHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        devicesHeaderLabel.isEditable = false
        devicesHeaderLabel.isSelectable = false
        devicesHeaderLabel.font = .barFont(ofSize: 9.5, weight: .bold)
        devicesHeaderLabel.textColor = theme.onSurface.withAlphaComponent(0.50)
        mainStack.addArrangedSubview(devicesHeaderLabel)

        // Devices Stack
        devicesStack.translatesAutoresizingMaskIntoConstraints = false
        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 4.0
        mainStack.addArrangedSubview(devicesStack)
        devicesStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        applyTheme()
        refreshData()
    }

    public func applyTheme(barColors: HyprBarColors = HyprBarColors()) {
        let theme = HyprTheme.shared
        let capsuleAlpha = HyprBarWindow.shared?.barView.capsuleAlpha ?? 0.65
        capsuleView.theme = theme
        capsuleView.surfaceAlpha = capsuleAlpha
        capsuleView.updateTheme()

        let resolved = ResolvedColors(theme: theme, barColors: barColors, backgroundAlpha: capsuleAlpha)
        volumeIconLabel.textColor = resolved.accent
        volumeTitleLabel.textColor = resolved.textPrimary
        volumePercentLabel.textColor = resolved.accent
        volumeSlider.trackFillColor = resolved.accent
        devicesHeaderLabel.textColor = resolved.textSecondary.withAlphaComponent(0.60)
        divider.layer?.backgroundColor = resolved.border.withAlphaComponent(0.20).cgColor

        refreshDevicesList()
    }

    public func refreshData() {
        let vol = VolumeMonitor.currentVolume()
        if abs(volumeSlider.doubleValue - Double(vol)) >= 1.0 {
            volumeSlider.doubleValue = Double(vol)
        }
        volumePercentLabel.stringValue = "\(vol)%"
        refreshDevicesList()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let vol = Int(sender.doubleValue)
        VolumeMonitor.setVolume(vol)
        volumePercentLabel.stringValue = "\(vol)%"
    }

    private func refreshDevicesList() {
        for sub in devicesStack.arrangedSubviews {
            devicesStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        let devices = VolumeMonitor.outputDevices()
        let theme = HyprTheme.shared

        for dev in devices {
            let row = ClickablePill()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.wantsLayer = true
            row.layer?.cornerRadius = 6.0
            row.heightAnchor.constraint(equalToConstant: 28.0).isActive = true

            if dev.isDefault {
                row.layer?.backgroundColor = theme.primary.withAlphaComponent(0.20).cgColor
                row.layer?.borderWidth = 1.0
                row.layer?.borderColor = theme.primary.withAlphaComponent(0.40).cgColor
            } else {
                row.layer?.backgroundColor = NSColor.clear.cgColor
                row.layer?.borderWidth = 1.0
                row.layer?.borderColor = NSColor(white: 1.0, alpha: 0.05).cgColor
            }

            let iconLabel = NSTextField(labelWithString: dev.icon)
            iconLabel.translatesAutoresizingMaskIntoConstraints = false
            iconLabel.isEditable = false
            iconLabel.isSelectable = false
            iconLabel.font = .barFont(ofSize: 12, weight: .bold)
            iconLabel.textColor = dev.isDefault ? theme.primary : theme.onSurface.withAlphaComponent(0.80)
            row.addSubview(iconLabel)

            let nameLabel = NSTextField(labelWithString: dev.name)
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.isEditable = false
            nameLabel.isSelectable = false
            nameLabel.font = .barFont(ofSize: 11, weight: dev.isDefault ? .bold : .medium)
            nameLabel.textColor = dev.isDefault ? theme.onSurface : theme.onSurface.withAlphaComponent(0.85)
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.maximumNumberOfLines = 1
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addSubview(nameLabel)

            let checkLabel = NSTextField(labelWithString: dev.isDefault ? "✓" : "")
            checkLabel.translatesAutoresizingMaskIntoConstraints = false
            checkLabel.isEditable = false
            checkLabel.isSelectable = false
            checkLabel.font = .barFont(ofSize: 11, weight: .bold)
            checkLabel.textColor = theme.primary
            row.addSubview(checkLabel)

            NSLayoutConstraint.activate([
                iconLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8.0),
                iconLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                iconLabel.widthAnchor.constraint(equalToConstant: 18.0),

                checkLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8.0),
                checkLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),

                nameLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 6.0),
                nameLabel.trailingAnchor.constraint(equalTo: checkLabel.leadingAnchor, constant: -6.0),
                nameLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])

            row.onClick = { [weak self] in
                VolumeMonitor.setOutputDevice(dev.id)
                self?.refreshData()
            }

            devicesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: devicesStack.widthAnchor).isActive = true
        }

        layoutIfNeeded()
        let neededHeight = 119.0 + (CGFloat(devices.count) * 32.0)
        var currentFrame = frame
        let delta = neededHeight - currentFrame.height
        currentFrame.size.height = neededHeight
        currentFrame.origin.y -= delta
        setFrame(currentFrame, display: true)
    }

    public func showPopover(animate: Bool = true) {
        guard !isOpen else { return }
        isOpen = true

        refreshData()

        volumeObserver = NotificationCenter.default.addObserver(
            forName: VolumeMonitor.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshData()
            }
        }

        if animate {
            alphaValue = 0.0
            orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                animator().alphaValue = 1.0
            }
        } else {
            alphaValue = 1.0
            orderFront(nil)
        }

        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isOpen else { return event }
            if let clickWindow = event.window, clickWindow === self {
                return event
            }
            if let clickWindow = event.window, clickWindow is HyprBarWindow {
                let ptInBar = clickWindow.contentView?.convert(event.locationInWindow, from: nil) ?? .zero
                if let bar = clickWindow.contentView as? BarView ?? (clickWindow as? HyprBarWindow)?.barView {
                    let ptInPill = bar.volumeContainer.convert(ptInBar, from: bar)
                    if bar.volumeContainer.bounds.contains(ptInPill) {
                        return event
                    }
                }
                self.dismissPopover()
                return event
            }
            self.dismissPopover()
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissPopover()
            }
        }
    }

    public func dismissPopover(animate: Bool = true) {
        guard isOpen else { return }
        isOpen = false

        if let mon = outsideClickMonitor {
            NSEvent.removeMonitor(mon)
            outsideClickMonitor = nil
        }
        if let gmon = globalClickMonitor {
            NSEvent.removeMonitor(gmon)
            globalClickMonitor = nil
        }
        if let obs = volumeObserver {
            NotificationCenter.default.removeObserver(obs)
            volumeObserver = nil
        }

        onClose?()

        if animate {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                animator().alphaValue = 0.0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.orderOut(nil)
                }
            })
        } else {
            alphaValue = 0.0
            orderOut(nil)
        }
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            dismissPopover()
            return
        }
        super.keyDown(with: event)
    }

    deinit {
        MainActor.assumeIsolated {
            if let obs = self.volumeObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            if let mon = self.outsideClickMonitor {
                NSEvent.removeMonitor(mon)
            }
            if let gmon = self.globalClickMonitor {
                NSEvent.removeMonitor(gmon)
            }
        }
    }
}
