import Cocoa
import QuartzCore

/// Native Waybar-style status bar with 3 independent floating capsules (mxmrn rice)
public final class BarView: NSView {
    public override var isOpaque: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
    }

    public override var isHidden: Bool {
        didSet {
            if !isHidden && self.window?.isVisible != false {
                updateHardware()
            }
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let win = window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowVisibilityChange),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: win
            )
        }
        if !isHidden && self.window?.isVisible != false {
            updateHardware()
        }
    }

    @objc private func handleWindowVisibilityChange() {
        if !isHidden && self.window?.isVisible != false {
            updateHardware()
        }
    }

    public var cornerRadius: CGFloat = 5.0 {
        didSet {
            leftCapsule.cornerRadius = cornerRadius
            centerCapsule.cornerRadius = cornerRadius
            rightCapsule.cornerRadius = cornerRadius
            musicCapsule.cornerRadius = cornerRadius
        }
    }

    public var theme: HyprTheme = .shared {
        didSet {
            applyTheme()
        }
    }

    public var barColors: HyprBarColors = HyprBarColors() {
        didSet {
            applyTheme()
        }
    }

    public var capsuleAlpha: CGFloat = 0.65 {
        didSet {
            leftCapsule.surfaceAlpha = capsuleAlpha
            centerCapsule.surfaceAlpha = capsuleAlpha
            rightCapsule.surfaceAlpha = capsuleAlpha
            musicCapsule.surfaceAlpha = capsuleAlpha
            volumePopover?.applyTheme(barColors: barColors)
            calendarPopover?.applyTheme(barColors: barColors)
            NotificationCenterDrawer.shared.applyTheme()
        }
    }

    public private(set) var activeWorkspaceID: Int = 1
    public private(set) var currentAppName: String = ""
    public private(set) var currentWindowTitle: String = ""

    public var onWorkspaceSelected: ((Int) -> Void)?
    public var onNotificationClicked: (() -> Void)?
    public var onPowerClicked: (() -> Void)?

    // The Three Floating Glass Capsules (Islands)
    public let leftCapsule = FloatingCapsuleView(cornerRadius: 5.0)
    public let centerCapsule = FloatingCapsuleView(cornerRadius: 5.0)
    public let rightCapsule = FloatingCapsuleView(cornerRadius: 5.0)
    public let musicCapsule = FloatingCapsuleView(cornerRadius: 5.0)

    // Music Module Elements: Status Icon, Track Title, Controls (Prev, Play/Pause, Next)
    public let musicStatusLabel = NSTextField(labelWithString: "󰝚")
    public let musicTrackContainer = ClickablePill()
    public let musicTrackLabel = NSTextField(labelWithString: "")
    public let musicPrevButton = ClickablePill()
    public let musicPrevLabel = NSTextField(labelWithString: "󰒮")
    public let musicPlayPauseButton = ClickablePill()
    public let musicPlayPauseLabel = NSTextField(labelWithString: "󰏤")
    public let musicNextButton = ClickablePill()
    public let musicNextLabel = NSTextField(labelWithString: "󰒭")

    // Left Island Elements: Japanese Kanji Workspaces + Compact Window Title
    private let workspacesStack = NSStackView()
    private var workspacePills: [WorkspacePill] = []
    public let windowTitleLabel = NSTextField(labelWithString: "")

    // Center Island Elements: Battery telemetry, Clock & Day, Volume
    public let batteryLabel = NSTextField(labelWithString: "100% ")
    public let clockContainer = ClickablePill()
    public let clockLabel = NSTextField(labelWithString: "")
    public private(set) var calendarPopover: CalendarPopoverPanel?
    public let volumeContainer = ClickablePill()
    public let volumeLabel = NSTextField(labelWithString: "  80%")
    public private(set) var volumePopover: VolumePopoverPanel?

    // Right Island Elements: Notification, Network, Hardware (CPU/MEM), Power
    public let notificationContainer = ClickablePill()
    public let notificationLabel = NSTextField(labelWithString: "󱅫")

    public let networkLabel = NSTextField(labelWithString: "  Wi-Fi")
    public let cpuLabel = NSTextField(labelWithString: "󰍛  24%")
    public let memLabel = NSTextField(labelWithString: "  45%")

    public let powerContainer = ClickablePill()
    public let powerLabel = NSTextField(labelWithString: "󰐥")
    private var currentWlogoutWindow: WlogoutWindow?

    // Periodic update timer
    nonisolated(unsafe) private var updateTimer: Timer?
    public var clockFormat: String = "h:mm a  EEE, MMM d" {
        didSet {
            dateFormatter.dateFormat = clockFormat
            updateClock()
        }
    }
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "h:mm a  EEE, MMM d"
        return df
    }()

    public init(frame frameRect: NSRect = .zero, workspaceCount: Int = 6, theme: HyprTheme = .shared, clockFormat: String = "h:mm a  EEE, MMM d") {
        self.theme = theme
        self.clockFormat = clockFormat
        super.init(frame: frameRect)
        dateFormatter.dateFormat = clockFormat
        setupViews(workspaceCount: workspaceCount)
        startTimers()
    }

    public required init?(coder: NSCoder) {
        self.theme = .shared
        super.init(coder: coder)
        setupViews(workspaceCount: 6)
        startTimers()
    }

    deinit {
        updateTimer?.invalidate()
    }

    private func setupViews(workspaceCount: Int) {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor.clear.cgColor

        leftCapsule.translatesAutoresizingMaskIntoConstraints = false
        centerCapsule.translatesAutoresizingMaskIntoConstraints = false
        rightCapsule.translatesAutoresizingMaskIntoConstraints = false

        addSubview(leftCapsule)
        addSubview(centerCapsule)
        addSubview(rightCapsule)

        let capsuleHeight: CGFloat = 24.0

        NSLayoutConstraint.activate([
            // Left Capsule anchored to leading
            leftCapsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8.0),
            leftCapsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftCapsule.heightAnchor.constraint(equalToConstant: capsuleHeight),

            // Center Capsule centered horizontally
            centerCapsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerCapsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            centerCapsule.heightAnchor.constraint(equalToConstant: capsuleHeight),
            centerCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: leftCapsule.trailingAnchor, constant: 8.0),
            rightCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: centerCapsule.trailingAnchor, constant: 8.0),

            // Right Capsule anchored to trailing
            rightCapsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8.0),
            rightCapsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightCapsule.heightAnchor.constraint(equalToConstant: capsuleHeight)
        ])

        // 1. Build Left Island
        setupLeftIsland(workspaceCount: workspaceCount)

        // 2. Build Center Island
        setupCenterIsland()

        // 2b. Build Music Module inside Center Island
        setupMusicModule()

        // 3. Build Right Island
        setupRightIsland()

        // Apply theme styling
        applyTheme()

        // Initial updates
        updateClock()
        updateBattery()
        updateHardware()
        updateVolume()
        updateNetwork()
        updateActiveWindow(title: "", app: "")
    }

    // MARK: - Left Island Setup

    private func setupLeftIsland(workspaceCount: Int) {
        workspacesStack.translatesAutoresizingMaskIntoConstraints = false
        workspacesStack.orientation = .horizontal
        workspacesStack.spacing = 3.0
        workspacesStack.alignment = .centerY
        leftCapsule.stackView.addArrangedSubview(workspacesStack)

        setWorkspaceCount(workspaceCount)

        windowTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        windowTitleLabel.isEditable = false
        windowTitleLabel.isSelectable = false
        windowTitleLabel.font = .barFont(ofSize: 11, weight: .medium)
        windowTitleLabel.lineBreakMode = .byTruncatingTail
        windowTitleLabel.maximumNumberOfLines = 1

        let maxWidth = windowTitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240.0)
        maxWidth.priority = .defaultHigh
        maxWidth.isActive = true

        leftCapsule.stackView.addArrangedSubview(windowTitleLabel)
    }

    // MARK: - Center Island Setup

    private func setupCenterIsland() {
        // 1. Battery telemetry: {capacity}% 
        batteryLabel.translatesAutoresizingMaskIntoConstraints = false
        batteryLabel.isEditable = false
        batteryLabel.isSelectable = false
        batteryLabel.font = .barFont(ofSize: 11, weight: .medium)
        batteryLabel.alignment = .center
        centerCapsule.stackView.addArrangedSubview(batteryLabel)

        // 2. Clock & Day: {h:mm a  EEE, MMM d} (Clickable calendar popover)
        clockContainer.translatesAutoresizingMaskIntoConstraints = false
        clockContainer.wantsLayer = true
        clockContainer.onClick = { [weak self] in
            self?.toggleCalendarPopover()
        }

        clockLabel.translatesAutoresizingMaskIntoConstraints = false
        clockLabel.isEditable = false
        clockLabel.isSelectable = false
        clockLabel.alignment = .center
        clockLabel.font = .barFont(ofSize: 11, weight: .medium, monospacedDigits: true)
        clockContainer.addSubview(clockLabel)

        NSLayoutConstraint.activate([
            clockLabel.centerXAnchor.constraint(equalTo: clockContainer.centerXAnchor),
            clockLabel.centerYAnchor.constraint(equalTo: clockContainer.centerYAnchor),
            clockLabel.topAnchor.constraint(equalTo: clockContainer.topAnchor, constant: 2.0),
            clockLabel.bottomAnchor.constraint(equalTo: clockContainer.bottomAnchor, constant: -2.0),
            clockLabel.leadingAnchor.constraint(equalTo: clockContainer.leadingAnchor, constant: 4.0),
            clockLabel.trailingAnchor.constraint(equalTo: clockContainer.trailingAnchor, constant: -4.0),
            clockContainer.heightAnchor.constraint(equalToConstant: 20.0),
            clockContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 18.0)
        ])
        centerCapsule.stackView.addArrangedSubview(clockContainer)

        // 3. Volume / Audio:  {vol}% (Clickable quick selector)
        volumeContainer.translatesAutoresizingMaskIntoConstraints = false
        volumeContainer.wantsLayer = true
        volumeContainer.onClick = { [weak self] in
            self?.toggleVolumePopover()
        }

        volumeLabel.translatesAutoresizingMaskIntoConstraints = false
        volumeLabel.isEditable = false
        volumeLabel.isSelectable = false
        volumeLabel.alignment = .center
        volumeLabel.font = .barFont(ofSize: 11, weight: .medium)
        volumeContainer.addSubview(volumeLabel)

        NSLayoutConstraint.activate([
            volumeLabel.centerXAnchor.constraint(equalTo: volumeContainer.centerXAnchor),
            volumeLabel.centerYAnchor.constraint(equalTo: volumeContainer.centerYAnchor),
            volumeLabel.topAnchor.constraint(equalTo: volumeContainer.topAnchor, constant: 2.0),
            volumeLabel.bottomAnchor.constraint(equalTo: volumeContainer.bottomAnchor, constant: -2.0),
            volumeLabel.leadingAnchor.constraint(equalTo: volumeContainer.leadingAnchor, constant: 2.0),
            volumeLabel.trailingAnchor.constraint(equalTo: volumeContainer.trailingAnchor, constant: -2.0),
            volumeContainer.heightAnchor.constraint(equalToConstant: 20.0),
            volumeContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 18.0)
        ])
        centerCapsule.stackView.addArrangedSubview(volumeContainer)
    }

    // MARK: - Music Module Setup

    private func setupMusicModule() {
        musicCapsule.translatesAutoresizingMaskIntoConstraints = false
        musicCapsule.isFrameless = true
        musicCapsule.isHidden = true // Auto-hidden until active music is detected
        musicCapsule.stackView.spacing = 6.0

        // 1. Status Icon ("󰝚" or "󰏤")
        musicStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        musicStatusLabel.isEditable = false
        musicStatusLabel.isSelectable = false
        musicStatusLabel.font = .barFont(ofSize: 11, weight: .bold)
        musicStatusLabel.stringValue = "󰝚"
        musicCapsule.stackView.addArrangedSubview(musicStatusLabel)

        // 2. Track Title Clickable Container (activates music player)
        musicTrackContainer.translatesAutoresizingMaskIntoConstraints = false
        musicTrackContainer.onClick = {
            MusicMonitor.shared.activatePlayerApp()
        }

        musicTrackLabel.translatesAutoresizingMaskIntoConstraints = false
        musicTrackLabel.isEditable = false
        musicTrackLabel.isSelectable = false
        musicTrackLabel.font = .barFont(ofSize: 11, weight: .medium)
        musicTrackLabel.textColor = theme.resolveColor(barColors.music, fallback: theme.secondary)
        musicTrackLabel.lineBreakMode = .byTruncatingTail
        musicTrackLabel.maximumNumberOfLines = 1

        let maxTrackWidth = musicTrackLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180.0)
        maxTrackWidth.priority = .defaultHigh
        maxTrackWidth.isActive = true

        musicTrackContainer.addSubview(musicTrackLabel)
        NSLayoutConstraint.activate([
            musicTrackLabel.topAnchor.constraint(equalTo: musicTrackContainer.topAnchor, constant: 2.0),
            musicTrackLabel.bottomAnchor.constraint(equalTo: musicTrackContainer.bottomAnchor, constant: -2.0),
            musicTrackLabel.leadingAnchor.constraint(equalTo: musicTrackContainer.leadingAnchor),
            musicTrackLabel.trailingAnchor.constraint(equalTo: musicTrackContainer.trailingAnchor),
            musicTrackContainer.heightAnchor.constraint(equalToConstant: 20.0)
        ])
        musicCapsule.stackView.addArrangedSubview(musicTrackContainer)

        // 3. Previous Button (󰒮)
        musicPrevButton.translatesAutoresizingMaskIntoConstraints = false
        musicPrevButton.onClick = {
            MusicMonitor.shared.previousTrack()
        }
        musicPrevLabel.translatesAutoresizingMaskIntoConstraints = false
        musicPrevLabel.isEditable = false
        musicPrevLabel.isSelectable = false
        musicPrevLabel.font = .barFont(ofSize: 10, weight: .bold)
        musicPrevLabel.stringValue = "󰒮"
        musicPrevButton.addSubview(musicPrevLabel)
        NSLayoutConstraint.activate([
            musicPrevLabel.centerXAnchor.constraint(equalTo: musicPrevButton.centerXAnchor),
            musicPrevLabel.centerYAnchor.constraint(equalTo: musicPrevButton.centerYAnchor),
            musicPrevLabel.topAnchor.constraint(equalTo: musicPrevButton.topAnchor, constant: 2.0),
            musicPrevLabel.bottomAnchor.constraint(equalTo: musicPrevButton.bottomAnchor, constant: -2.0),
            musicPrevLabel.leadingAnchor.constraint(equalTo: musicPrevButton.leadingAnchor, constant: 1.0),
            musicPrevLabel.trailingAnchor.constraint(equalTo: musicPrevButton.trailingAnchor, constant: -1.0),
            musicPrevButton.heightAnchor.constraint(equalToConstant: 20.0),
            musicPrevButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 18.0)
        ])
        musicCapsule.stackView.addArrangedSubview(musicPrevButton)

        // 4. Play/Pause Button (󰏤 / 󰐊)
        musicPlayPauseButton.translatesAutoresizingMaskIntoConstraints = false
        musicPlayPauseButton.onClick = {
            MusicMonitor.shared.togglePlayPause()
        }
        musicPlayPauseLabel.translatesAutoresizingMaskIntoConstraints = false
        musicPlayPauseLabel.isEditable = false
        musicPlayPauseLabel.isSelectable = false
        musicPlayPauseLabel.font = .barFont(ofSize: 10, weight: .bold)
        musicPlayPauseLabel.stringValue = "󰏤"
        musicPlayPauseButton.addSubview(musicPlayPauseLabel)
        NSLayoutConstraint.activate([
            musicPlayPauseLabel.centerXAnchor.constraint(equalTo: musicPlayPauseButton.centerXAnchor),
            musicPlayPauseLabel.centerYAnchor.constraint(equalTo: musicPlayPauseButton.centerYAnchor),
            musicPlayPauseLabel.topAnchor.constraint(equalTo: musicPlayPauseButton.topAnchor, constant: 2.0),
            musicPlayPauseLabel.bottomAnchor.constraint(equalTo: musicPlayPauseButton.bottomAnchor, constant: -2.0),
            musicPlayPauseLabel.leadingAnchor.constraint(equalTo: musicPlayPauseButton.leadingAnchor, constant: 1.0),
            musicPlayPauseLabel.trailingAnchor.constraint(equalTo: musicPlayPauseButton.trailingAnchor, constant: -1.0),
            musicPlayPauseButton.heightAnchor.constraint(equalToConstant: 20.0),
            musicPlayPauseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 18.0)
        ])
        musicCapsule.stackView.addArrangedSubview(musicPlayPauseButton)

        // 5. Next Button (󰒭)
        musicNextButton.translatesAutoresizingMaskIntoConstraints = false
        musicNextButton.onClick = {
            MusicMonitor.shared.nextTrack()
        }
        musicNextLabel.translatesAutoresizingMaskIntoConstraints = false
        musicNextLabel.isEditable = false
        musicNextLabel.isSelectable = false
        musicNextLabel.font = .barFont(ofSize: 10, weight: .bold)
        musicNextLabel.stringValue = "󰒭"
        musicNextButton.addSubview(musicNextLabel)
        NSLayoutConstraint.activate([
            musicNextLabel.centerXAnchor.constraint(equalTo: musicNextButton.centerXAnchor),
            musicNextLabel.centerYAnchor.constraint(equalTo: musicNextButton.centerYAnchor),
            musicNextLabel.topAnchor.constraint(equalTo: musicNextButton.topAnchor, constant: 2.0),
            musicNextLabel.bottomAnchor.constraint(equalTo: musicNextButton.bottomAnchor, constant: -2.0),
            musicNextLabel.leadingAnchor.constraint(equalTo: musicNextButton.leadingAnchor, constant: 1.0),
            musicNextLabel.trailingAnchor.constraint(equalTo: musicNextButton.trailingAnchor, constant: -1.0),
            musicNextButton.heightAnchor.constraint(equalToConstant: 20.0),
            musicNextButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 18.0)
        ])
        musicCapsule.stackView.addArrangedSubview(musicNextButton)

        // Insert at the beginning of center island
        centerCapsule.stackView.insertArrangedSubview(musicCapsule, at: 0)
    }

    // MARK: - Right Island Setup

    private func setupRightIsland() {
        rightCapsule.stackView.spacing = 11.0

        // 1. Notification: 󱅫
        notificationContainer.translatesAutoresizingMaskIntoConstraints = false
        notificationContainer.wantsLayer = true
        notificationContainer.onClick = { [weak self] in
            self?.closeVolumePopover(animate: false)
            self?.closeCalendarPopover(animate: false)
            NotificationCenterManager.shared.toggleDrawer()
            self?.onNotificationClicked?()
        }

        notificationLabel.translatesAutoresizingMaskIntoConstraints = false
        notificationLabel.isEditable = false
        notificationLabel.isSelectable = false
        notificationLabel.font = .barFont(ofSize: 12, weight: .medium)
        notificationLabel.alignment = .center
        notificationLabel.stringValue = "󰂚"
        notificationContainer.addSubview(notificationLabel)

        NotificationCenterManager.shared.onStateChange = { [weak self] in
            self?.updateNotificationIndicator()
        }
        updateNotificationIndicator()

        NSLayoutConstraint.activate([
            notificationLabel.centerXAnchor.constraint(equalTo: notificationContainer.centerXAnchor),
            notificationLabel.centerYAnchor.constraint(equalTo: notificationContainer.centerYAnchor),
            notificationLabel.topAnchor.constraint(equalTo: notificationContainer.topAnchor, constant: 2.0),
            notificationLabel.bottomAnchor.constraint(equalTo: notificationContainer.bottomAnchor, constant: -2.0),
            notificationLabel.leadingAnchor.constraint(equalTo: notificationContainer.leadingAnchor, constant: 2.0),
            notificationLabel.trailingAnchor.constraint(equalTo: notificationContainer.trailingAnchor, constant: -2.0),
            notificationContainer.heightAnchor.constraint(equalToConstant: 20.0),
            notificationContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 18.0)
        ])
        rightCapsule.stackView.addArrangedSubview(notificationContainer)

        // 2. Network:  {ssid}
        networkLabel.translatesAutoresizingMaskIntoConstraints = false
        networkLabel.isEditable = false
        networkLabel.isSelectable = false
        networkLabel.font = .barFont(ofSize: 11, weight: .medium)
        networkLabel.alignment = .center
        networkLabel.stringValue = "  Wi-Fi"
        rightCapsule.stackView.addArrangedSubview(networkLabel)

        // 3. Hardware Telemetry: Separated CPU & RAM metrics
        cpuLabel.translatesAutoresizingMaskIntoConstraints = false
        cpuLabel.isEditable = false
        cpuLabel.isSelectable = false
        cpuLabel.font = .barFont(ofSize: 11, weight: .medium)
        cpuLabel.alignment = .center
        cpuLabel.stringValue = "󰍛  24%"

        memLabel.translatesAutoresizingMaskIntoConstraints = false
        memLabel.isEditable = false
        memLabel.isSelectable = false
        memLabel.font = .barFont(ofSize: 11, weight: .medium)
        memLabel.alignment = .center
        memLabel.stringValue = "  45%"

        let hardwareStack = NSStackView(views: [cpuLabel, memLabel])
        hardwareStack.translatesAutoresizingMaskIntoConstraints = false
        hardwareStack.orientation = .horizontal
        hardwareStack.spacing = 8.0
        hardwareStack.alignment = .centerY
        rightCapsule.stackView.addArrangedSubview(hardwareStack)

        // 4. Power: 󰐥
        powerContainer.translatesAutoresizingMaskIntoConstraints = false
        powerContainer.wantsLayer = true
        powerContainer.onClick = { [weak self] in
            guard let self = self else { return }
            if let custom = self.onPowerClicked {
                custom()
            } else {
                self.presentWlogout()
            }
        }

        powerLabel.translatesAutoresizingMaskIntoConstraints = false
        powerLabel.isEditable = false
        powerLabel.isSelectable = false
        powerLabel.font = .barFont(ofSize: 12, weight: .bold)
        powerLabel.alignment = .center
        powerLabel.stringValue = "󰐥"
        powerContainer.addSubview(powerLabel)

        NSLayoutConstraint.activate([
            powerLabel.centerXAnchor.constraint(equalTo: powerContainer.centerXAnchor),
            powerLabel.centerYAnchor.constraint(equalTo: powerContainer.centerYAnchor),
            powerLabel.topAnchor.constraint(equalTo: powerContainer.topAnchor, constant: 2.0),
            powerLabel.bottomAnchor.constraint(equalTo: powerContainer.bottomAnchor, constant: -2.0),
            powerLabel.leadingAnchor.constraint(equalTo: powerContainer.leadingAnchor, constant: 2.0),
            powerLabel.trailingAnchor.constraint(equalTo: powerContainer.trailingAnchor, constant: -2.0),
            powerContainer.heightAnchor.constraint(equalToConstant: 20.0),
            powerContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 18.0)
        ])
        rightCapsule.stackView.addArrangedSubview(powerContainer)
    }

    // MARK: - Theming

    public func applyTheme() {
        leftCapsule.theme = theme
        leftCapsule.updateTheme()
        centerCapsule.theme = theme
        centerCapsule.updateTheme()
        rightCapsule.theme = theme
        rightCapsule.updateTheme()
        musicCapsule.theme = theme
        musicCapsule.updateTheme()

        let actBg = theme.resolveColor(barColors.workspacesActiveBg, fallback: theme.primary)
        let actFg = theme.resolveColor(barColors.workspacesActiveFg, fallback: theme.onPrimary)
        let inactFg = theme.resolveColor(barColors.workspacesInactive, fallback: theme.onSurface)

        for pill in workspacePills {
            pill.theme = theme
            pill.activeBgColor = actBg
            pill.activeFgColor = actFg
            pill.inactiveTextColor = inactFg
            pill.updateAppearance()
        }

        windowTitleLabel.textColor = theme.resolveColor(barColors.windowTitle, fallback: theme.onSurface)
        batteryLabel.textColor = theme.resolveColor(barColors.battery, fallback: theme.secondary)
        clockLabel.textColor = theme.resolveColor(barColors.clock, fallback: theme.secondary)
        volumeLabel.textColor = theme.resolveColor(barColors.volume, fallback: theme.tertiary)
        notificationLabel.textColor = theme.resolveColor(barColors.notification, fallback: theme.primary)
        networkLabel.textColor = theme.resolveColor(barColors.network, fallback: theme.primary)
        cpuLabel.textColor = theme.resolveColor(barColors.cpu, fallback: theme.secondary)
        memLabel.textColor = theme.resolveColor(barColors.memory, fallback: theme.secondary)
        powerLabel.textColor = theme.resolveColor(barColors.power, fallback: theme.error)
        musicStatusLabel.textColor = theme.primary
        musicTrackLabel.textColor = theme.resolveColor(barColors.music, fallback: theme.secondary)
        musicPrevLabel.textColor = theme.secondary
        musicPlayPauseLabel.textColor = theme.primary
        musicNextLabel.textColor = theme.secondary

        leftCapsule.needsDisplay = true
        centerCapsule.needsDisplay = true
        rightCapsule.needsDisplay = true
        musicCapsule.needsDisplay = true
        needsDisplay = true

        volumePopover?.applyTheme(barColors: barColors)
        calendarPopover?.applyTheme(barColors: barColors)
        NotificationCenterDrawer.shared.applyTheme()
    }

    // MARK: - Workspace Module

    public func setWorkspaceCount(_ count: Int) {
        workspacePills.forEach { $0.removeFromSuperview() }
        workspacePills.removeAll()

        for id in 1...count {
            let pill = WorkspacePill(workspaceID: id, theme: theme)
            pill.isActive = (id == activeWorkspaceID)
            pill.onSelect = { [weak self] selectedID in
                self?.updateActiveWorkspace(selectedID)
                self?.onWorkspaceSelected?(selectedID)
            }
            workspacePills.append(pill)
            workspacesStack.addArrangedSubview(pill)
        }
    }

    public func updateActiveWorkspace(_ id: Int) {
        activeWorkspaceID = id
        for pill in workspacePills {
            pill.isActive = (pill.workspaceID == id)
        }
    }

    // MARK: - Active Window Module

    public func updateActiveWindow(title: String, app: String) {
        let oldLeftFrame = leftCapsule.frame
        currentAppName = app.trimmingCharacters(in: .whitespacesAndNewlines)
        currentWindowTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let newString: String
        if currentAppName.isEmpty && currentWindowTitle.isEmpty {
            newString = "~"
        } else if !currentAppName.isEmpty && currentWindowTitle.isEmpty {
            newString = currentAppName
        } else if currentAppName.isEmpty && !currentWindowTitle.isEmpty {
            newString = currentWindowTitle
        } else {
            newString = "\(currentAppName): \(currentWindowTitle)"
        }

        if windowTitleLabel.stringValue != newString {
            windowTitleLabel.stringValue = newString
            leftCapsule.needsLayout = true
            layoutSubtreeIfNeeded()
            let newLeftFrame = leftCapsule.frame
            if newLeftFrame.width < oldLeftFrame.width || newLeftFrame.origin != oldLeftFrame.origin {
                let shadowPadding: CGFloat = 16.0
                let dirtyRect = oldLeftFrame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
                setNeedsDisplay(dirtyRect)
                window?.viewsNeedDisplay = true
            }
        }
    }

    // MARK: - Periodic Updates

    public func updateClock() {
        clockLabel.stringValue = dateFormatter.string(from: Date())
    }

    public func updateBattery() {
        let status = BatteryMonitor.currentStatus()
        batteryLabel.stringValue = status.formattedText
        batteryLabel.textColor = theme.resolveColor(barColors.battery, fallback: theme.secondary)
    }

    public func updateHardware() {
        let cpu = HardwareMonitor.currentCPULoad()
        let mem = HardwareMonitor.currentMemoryLoad()
        cpuLabel.stringValue = "󰍛  \(cpu)%"
        memLabel.stringValue = "  \(mem)%"
    }

    public func updateVolume() {
        let vol = VolumeMonitor.currentVolume()
        volumeLabel.stringValue = "  \(vol)%"
    }

    public func updateNotificationIndicator() {
        let manager = NotificationCenterManager.shared
        if manager.isDoNotDisturb {
            notificationLabel.stringValue = "󰂛"
        } else if !manager.history.isEmpty {
            notificationLabel.stringValue = "󰂚 \(manager.history.count)"
        } else {
            notificationLabel.stringValue = "󰂚"
        }
    }

    public func updateNetwork() {
        let ssid = NetworkMonitor.currentSSID()
        if ssid == "Off" {
            networkLabel.stringValue = "󰤭  Off"
        } else if ssid == "Disconnected" {
            networkLabel.stringValue = "󰤩  Disconnected"
        } else {
            networkLabel.stringValue = "  \(ssid)"
        }
    }

    // MARK: - Music Module Updates

    /// Updates the music player capsule state and visibility.
    public func updateMusicTrack(_ track: MusicTrackInfo?) {
        guard let track = track else {
            musicCapsule.isHidden = true
            musicTrackLabel.stringValue = ""
            centerCapsule.needsLayout = true
            needsLayout = true
            return
        }

        musicCapsule.isHidden = false
        musicTrackLabel.stringValue = track.formattedText
        musicStatusLabel.stringValue = track.isPlaying ? "󰝚" : "󰏤"
        musicPlayPauseLabel.stringValue = track.isPlaying ? "󰏤" : "󰐊"
        centerCapsule.needsLayout = true
        needsLayout = true
    }

    public func startTimers() {
        // Initial setup
        updateClock()
        updateBattery()
        updateHardware()
        updateVolume()
        updateNetwork()
        updateNotificationIndicator()

        // Wire and start MusicMonitor
        MusicMonitor.shared.onTrackChange = { [weak self] track in
            self?.updateMusicTrack(track)
        }
        MusicMonitor.shared.start()
        updateMusicTrack(MusicMonitor.shared.currentTrack)

        // Event-driven listeners for Battery, Volume and Notifications
        BatteryMonitor.startMonitoring { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateBattery()
            }
        }

        VolumeMonitor.startMonitoring { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateVolume()
            }
        }

        NotificationCenter.default.removeObserver(self, name: NotificationCenterManager.stateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNotificationStateDidChange),
            name: NotificationCenterManager.stateDidChangeNotification,
            object: nil
        )

        // Event-driven power saving: pause periodic hardware timer when screens sleep, resume on wake
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateTimer?.invalidate()
            self?.updateTimer = nil
        }

        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.screensDidWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startTimers()
            }
        }

        // Periodic 1.0s timer only for Clock & Hardware CPU/RAM
        guard updateTimer == nil else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.updateClock()
                if !self.isHidden && self.window?.isVisible != false {
                    self.updateHardware()
                }
            }
        }
    }

    @objc private func handleNotificationStateDidChange() {
        updateNotificationIndicator()
    }

    // MARK: - Volume / Audio Popover

    public func toggleVolumePopover() {
        if let popover = volumePopover, popover.isOpen {
            closeVolumePopover()
        } else {
            openVolumePopover()
        }
    }

    public func openVolumePopover() {
        closeCalendarPopover(animate: false)
        closeVolumePopover(animate: false)

        let pillScreenRect: NSRect
        let targetScreen: NSScreen?
        if let win = self.window {
            let pillFrameInWindow = volumeContainer.convert(volumeContainer.bounds, to: nil)
            pillScreenRect = win.convertToScreen(pillFrameInWindow)
            targetScreen = win.screen
        } else {
            pillScreenRect = NSRect(x: 500, y: 1000, width: 60, height: 20)
            targetScreen = NSScreen.main ?? NSScreen.screens.first
        }

        let popover = VolumePopoverPanel(anchorFrame: pillScreenRect, screen: targetScreen)
        popover.onClose = { [weak self] in
            self?.volumePopover = nil
        }
        self.volumePopover = popover
        popover.applyTheme(barColors: barColors)
        popover.showPopover()
    }

    public func closeVolumePopover(animate: Bool = true) {
        volumePopover?.dismissPopover(animate: animate)
        volumePopover = nil
    }

    // MARK: - Calendar Popover

    public func toggleCalendarPopover() {
        if let popover = calendarPopover, popover.isOpen {
            closeCalendarPopover()
        } else {
            openCalendarPopover()
        }
    }

    public func openCalendarPopover() {
        closeVolumePopover(animate: false)
        closeCalendarPopover(animate: false)

        let pillScreenRect: NSRect
        let targetScreen: NSScreen?
        if let win = self.window {
            let pillFrameInWindow = clockContainer.convert(clockContainer.bounds, to: nil)
            pillScreenRect = win.convertToScreen(pillFrameInWindow)
            targetScreen = win.screen
        } else {
            pillScreenRect = NSRect(x: 500, y: 1000, width: 60, height: 20)
            targetScreen = NSScreen.main ?? NSScreen.screens.first
        }

        let popover = CalendarPopoverPanel(anchorFrame: pillScreenRect, screen: targetScreen)
        popover.onClose = { [weak self] in
            self?.calendarPopover = nil
        }
        self.calendarPopover = popover
        popover.applyTheme(barColors: barColors)
        popover.showPopover()
    }

    public func closeCalendarPopover(animate: Bool = true) {
        calendarPopover?.dismissPopover(animate: animate)
        calendarPopover = nil
    }

    public func stopTimers() {
        closeVolumePopover(animate: false)
        closeCalendarPopover(animate: false)
        updateTimer?.invalidate()
        updateTimer = nil
        BatteryMonitor.stopMonitoring()
        VolumeMonitor.stopMonitoring()
        MusicMonitor.shared.stop()
        NotificationCenter.default.removeObserver(self, name: NotificationCenterManager.stateDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.screensDidSleepNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    // MARK: - Power Menu / Wlogout

    @MainActor
    public func presentWlogout() {
        if let existing = currentWlogoutWindow {
            existing.dismiss()
            currentWlogoutWindow = nil
            return
        }
        let wlogout = WlogoutWindow(screen: window?.screen ?? NSScreen.main)
        wlogout.onDismiss = { [weak self] in
            self?.currentWlogoutWindow = nil
        }
        wlogout.onActionExecuted = { [weak self] _ in
            self?.currentWlogoutWindow = nil
        }
        currentWlogoutWindow = wlogout
        wlogout.present()
    }
}

