import Cocoa
import QuartzCore
import IOKit.ps
import AudioToolbox
import CoreAudio
import Darwin

/// Battery status representation read from hardware power sources
public struct BatteryStatus: Sendable, Equatable {
    public let isPresent: Bool
    public let isCharging: Bool
    public let percentage: Int
    public let powerSource: String

    public init(
        isPresent: Bool,
        isCharging: Bool,
        percentage: Int,
        powerSource: String
    ) {
        self.isPresent = isPresent
        self.isCharging = isCharging
        self.percentage = percentage
        self.powerSource = powerSource
    }

    public var formattedText: String {
        let pct = isPresent ? percentage : 100
        return "\(pct)% "
    }
}

/// Reader for system power sources using IOPowerSources APIs
public enum BatteryMonitor {
    public static func currentStatus() -> BatteryStatus {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return BatteryStatus(isPresent: false, isCharging: true, percentage: 100, powerSource: "AC Power")
        }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty else {
            return BatteryStatus(isPresent: false, isCharging: true, percentage: 100, powerSource: "AC Power")
        }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let isPresent = (desc[kIOPSIsPresentKey as String] as? Bool) ?? true
            let isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
            let currentCap = desc[kIOPSCurrentCapacityKey as String] as? Int
            let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int
            let state = (desc[kIOPSPowerSourceStateKey as String] as? String) ?? "Battery"

            if let currentCap = currentCap, let maxCap = maxCap, maxCap > 0 {
                let pct = Swift.min(100, Swift.max(0, Int((Double(currentCap) / Double(maxCap)) * 100)))
                return BatteryStatus(isPresent: isPresent, isCharging: isCharging, percentage: pct, powerSource: state)
            }
        }

        return BatteryStatus(isPresent: false, isCharging: true, percentage: 100, powerSource: "AC Power")
    }
}

/// Reader for hardware CPU & Memory utilization using Mach host statistics
public enum HardwareMonitor {
    nonisolated(unsafe) private static var lastTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?

    public static func currentCPULoad() -> Int {
        let count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var actualCount = count
        var cpuLoad = host_cpu_load_info()
        let kerr = withUnsafeMutablePointer(to: &cpuLoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &actualCount)
            }
        }
        guard kerr == KERN_SUCCESS else { return 24 }

        let user = cpuLoad.cpu_ticks.0
        let sys = cpuLoad.cpu_ticks.1
        let idle = cpuLoad.cpu_ticks.2
        let nice = cpuLoad.cpu_ticks.3

        guard let previous = lastTicks else {
            lastTicks = (user, sys, idle, nice)
            return 24
        }

        let deltaUser = Double(user >= previous.user ? user - previous.user : 0)
        let deltaSys = Double(sys >= previous.sys ? sys - previous.sys : 0)
        let deltaIdle = Double(idle >= previous.idle ? idle - previous.idle : 0)
        let deltaNice = Double(nice >= previous.nice ? nice - previous.nice : 0)
        lastTicks = (user, sys, idle, nice)

        let total = deltaUser + deltaSys + deltaIdle + deltaNice
        guard total > 0 else { return 24 }

        let active = deltaUser + deltaSys + deltaNice
        let pct = Int((active / total) * 100.0)
        return Swift.max(1, Swift.min(100, pct))
    }

    public static func currentMemoryLoad() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 35 }
        let pageSize = UInt64(getpagesize())
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let usedBytes = active + wired + compressed
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        guard totalBytes > 0 else { return 35 }
        let pct = Int((Double(usedBytes) / Double(totalBytes)) * 100.0)
        return Swift.max(1, Swift.min(100, pct))
    }
}

/// Reader for system output volume via CoreAudio / AudioToolbox
public enum VolumeMonitor {
    public static func currentVolume() -> Int {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID
        )
        guard status == noErr else { return 80 }

        var volume = Float32(0.0)
        propertySize = UInt32(MemoryLayout<Float32>.size)
        propertyAddress.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        propertyAddress.mScope = kAudioObjectPropertyScopeOutput

        let volStatus = AudioObjectGetPropertyData(
            defaultOutputDeviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &volume
        )
        guard volStatus == noErr else { return 80 }

        return Int((volume * 100.0).rounded())
    }
}

/// Reader for active Wi-Fi network SSID
public enum NetworkMonitor {
    nonisolated(unsafe) private static var cachedSSID: String = "Wi-Fi"
    nonisolated(unsafe) private static var lastCheckTime: TimeInterval = 0

    public static func currentSSID() -> String {
        let now = Date().timeIntervalSince1970
        if now - lastCheckTime < 5.0 {
            return cachedSSID
        }
        lastCheckTime = now

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = ["-getairportnetwork", "en1"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if str.contains("Current Wi-Fi Network:") {
                    let parts = str.components(separatedBy: "Current Wi-Fi Network:")
                    if parts.count > 1 {
                        let ssid = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !ssid.isEmpty {
                            cachedSSID = ssid
                            return ssid
                        }
                    }
                }
            }
        } catch {}

        return cachedSSID
    }
}

/// Interactive clickable pill container with hand cursor
@MainActor
public class ClickablePill: NSView {
    public var onClick: (() -> Void)?

    public override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            onClick?()
        }
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Individual interactive workspace pill styled with mxmrn Japanese Kanji workspaces
@MainActor
public final class WorkspacePill: NSView {
    public static let kanjiList = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]

    public let workspaceID: Int
    public var theme: HyprTheme {
        didSet { updateAppearance() }
    }
    public var isActive: Bool = false {
        didSet { updateAppearance() }
    }
    public var onSelect: ((Int) -> Void)?

    public let label = NSTextField(labelWithString: "")

    public init(workspaceID: Int, theme: HyprTheme = .shared) {
        self.workspaceID = workspaceID
        self.theme = theme
        super.init(frame: .zero)
        setupView()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 5.0
        layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)

        let kanjiIndex = workspaceID - 1
        let symbol = (kanjiIndex >= 0 && kanjiIndex < Self.kanjiList.count) ? Self.kanjiList[kanjiIndex] : "\(workspaceID)"
        label.stringValue = symbol

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22.0),
            heightAnchor.constraint(equalToConstant: 20.0),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 1.0),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -1.0)
        ])

        updateAppearance()
    }

    public func updateAppearance() {
        layer?.cornerRadius = 5.0
        let kanjiIndex = workspaceID - 1
        let symbol = (kanjiIndex >= 0 && kanjiIndex < Self.kanjiList.count) ? Self.kanjiList[kanjiIndex] : "\(workspaceID)"
        label.stringValue = symbol

        if isActive {
            layer?.backgroundColor = theme.primary.cgColor
            label.textColor = theme.onPrimary
            label.font = .barFont(ofSize: 11, weight: .bold)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = theme.onSurface
            label.font = .barFont(ofSize: 11, weight: .medium)
        }
        needsLayout = true
    }

    public override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            onSelect?(workspaceID)
        }
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Floating glass capsule container styled after Waybar 5px border-radius floating capsules
@MainActor
public final class FloatingCapsuleView: NSView {
    public var cornerRadius: CGFloat = 5.0 {
        didSet {
            updateCornerRadius()
        }
    }

    public var theme: HyprTheme = .shared {
        didSet {
            updateTheme()
        }
    }

    public var surfaceAlpha: CGFloat = 0.60 {
        didSet {
            updateTheme()
        }
    }

    private let clipView = NSView()
    private let visualEffectView = NSVisualEffectView()
    private let darkOverlay = NSView()
    public let stackView = NSStackView()

    public init(cornerRadius: CGFloat = 5.0, theme: HyprTheme = .shared, surfaceAlpha: CGFloat = 0.60) {
        self.cornerRadius = cornerRadius
        self.theme = theme
        self.surfaceAlpha = surfaceAlpha
        super.init(frame: .zero)
        setupViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowRadius = 5.0

        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        addSubview(clipView)

        // Frosted glass background
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.appearance = NSAppearance(named: .darkAqua)
        visualEffectView.wantsLayer = true
        clipView.addSubview(visualEffectView)

        // Dark surface layer matching Material You theme with subtle 1px border
        darkOverlay.translatesAutoresizingMaskIntoConstraints = false
        darkOverlay.wantsLayer = true
        darkOverlay.layer?.backgroundColor = theme.surface.withAlphaComponent(surfaceAlpha).cgColor
        darkOverlay.layer?.borderWidth = 1.0
        darkOverlay.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        clipView.addSubview(darkOverlay)

        // Content stack inside capsule
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.spacing = 8.0
        stackView.alignment = .centerY
        clipView.addSubview(stackView)

        NSLayoutConstraint.activate([
            clipView.topAnchor.constraint(equalTo: topAnchor),
            clipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            clipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: trailingAnchor),

            visualEffectView.topAnchor.constraint(equalTo: clipView.topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            visualEffectView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),

            darkOverlay.topAnchor.constraint(equalTo: clipView.topAnchor),
            darkOverlay.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            darkOverlay.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            darkOverlay.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),

            stackView.topAnchor.constraint(equalTo: clipView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 8.0),
            stackView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -8.0)
        ])

        updateCornerRadius()
        updateTheme()
    }

    private func updateCornerRadius() {
        clipView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.cornerRadius = cornerRadius
        darkOverlay.layer?.cornerRadius = cornerRadius
        needsLayout = true
    }

    public func updateTheme() {
        darkOverlay.layer?.backgroundColor = theme.surface.withAlphaComponent(surfaceAlpha).cgColor
        darkOverlay.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
    }

    public override func layout() {
        super.layout()
        if bounds.width > 0 && bounds.height > 0 {
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        }
    }
}

/// Native Waybar-style status bar with 3 independent floating capsules (mxmrn rice)
@MainActor
public final class BarView: NSView {
    public var cornerRadius: CGFloat = 5.0 {
        didSet {
            leftCapsule.cornerRadius = cornerRadius
            centerCapsule.cornerRadius = cornerRadius
            rightCapsule.cornerRadius = cornerRadius
        }
    }

    public var theme: HyprTheme = .shared {
        didSet {
            applyTheme()
        }
    }

    public var capsuleAlpha: CGFloat = 0.60 {
        didSet {
            leftCapsule.surfaceAlpha = capsuleAlpha
            centerCapsule.surfaceAlpha = capsuleAlpha
            rightCapsule.surfaceAlpha = capsuleAlpha
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

    // Left Island Elements: Japanese Kanji Workspaces + Compact Window Title
    private let workspacesStack = NSStackView()
    private var workspacePills: [WorkspacePill] = []
    public let windowTitleLabel = NSTextField(labelWithString: "")

    // Center Island Elements: Battery telemetry, Clock & Day, Volume
    public let batteryLabel = NSTextField(labelWithString: "100% ")
    public let clockLabel = NSTextField(labelWithString: "")
    public let volumeLabel = NSTextField(labelWithString: "  80%")

    // Right Island Elements: Notification, Network, Hardware (CPU/MEM), Power
    public let notificationContainer = ClickablePill()
    public let notificationLabel = NSTextField(labelWithString: "󱅫")

    public let networkLabel = NSTextField(labelWithString: "  Wi-Fi")
    public let cpuLabel = NSTextField(labelWithString: "󰍛  24%")
    public let memLabel = NSTextField(labelWithString: "  45%")

    public let powerContainer = ClickablePill()
    public let powerLabel = NSTextField(labelWithString: "󰐥")

    // Periodic update timer
    nonisolated(unsafe) private var updateTimer: Timer?
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm  EEE"
        return df
    }()

    public init(frame frameRect: NSRect = .zero, workspaceCount: Int = 6, theme: HyprTheme = .shared) {
        self.theme = theme
        super.init(frame: frameRect)
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

        // 2. Clock & Day: {HH:mm  EEE}
        clockLabel.translatesAutoresizingMaskIntoConstraints = false
        clockLabel.isEditable = false
        clockLabel.isSelectable = false
        clockLabel.alignment = .center
        clockLabel.font = .barFont(ofSize: 11, weight: .medium, monospacedDigits: true)
        centerCapsule.stackView.addArrangedSubview(clockLabel)

        // 3. Volume / Audio:  {vol}%
        volumeLabel.translatesAutoresizingMaskIntoConstraints = false
        volumeLabel.isEditable = false
        volumeLabel.isSelectable = false
        volumeLabel.alignment = .center
        volumeLabel.font = .barFont(ofSize: 11, weight: .medium)
        centerCapsule.stackView.addArrangedSubview(volumeLabel)
    }

    // MARK: - Right Island Setup

    private func setupRightIsland() {
        rightCapsule.stackView.spacing = 11.0

        // 1. Notification: 󱅫
        notificationContainer.translatesAutoresizingMaskIntoConstraints = false
        notificationContainer.wantsLayer = true
        notificationContainer.onClick = { [weak self] in
            self?.onNotificationClicked?()
        }

        notificationLabel.translatesAutoresizingMaskIntoConstraints = false
        notificationLabel.isEditable = false
        notificationLabel.isSelectable = false
        notificationLabel.font = .barFont(ofSize: 12, weight: .medium)
        notificationLabel.alignment = .center
        notificationLabel.stringValue = "󱅫"
        notificationContainer.addSubview(notificationLabel)

        NSLayoutConstraint.activate([
            notificationLabel.centerXAnchor.constraint(equalTo: notificationContainer.centerXAnchor),
            notificationLabel.centerYAnchor.constraint(equalTo: notificationContainer.centerYAnchor),
            notificationLabel.leadingAnchor.constraint(equalTo: notificationContainer.leadingAnchor, constant: 2.0),
            notificationLabel.trailingAnchor.constraint(equalTo: notificationContainer.trailingAnchor, constant: -2.0)
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
            self?.onPowerClicked?()
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
            powerLabel.leadingAnchor.constraint(equalTo: powerContainer.leadingAnchor, constant: 2.0),
            powerLabel.trailingAnchor.constraint(equalTo: powerContainer.trailingAnchor, constant: -2.0)
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

        for pill in workspacePills {
            pill.theme = theme
            pill.updateAppearance()
        }

        windowTitleLabel.textColor = theme.onSurface
        batteryLabel.textColor = theme.secondary
        clockLabel.textColor = theme.secondary
        volumeLabel.textColor = theme.tertiary
        notificationLabel.textColor = theme.primary
        networkLabel.textColor = theme.primary
        cpuLabel.textColor = theme.secondary
        memLabel.textColor = theme.secondary
        powerLabel.textColor = theme.error

        leftCapsule.needsDisplay = true
        centerCapsule.needsDisplay = true
        rightCapsule.needsDisplay = true
        needsDisplay = true
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
        currentAppName = app.trimmingCharacters(in: .whitespacesAndNewlines)
        currentWindowTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if currentAppName.isEmpty && currentWindowTitle.isEmpty {
            windowTitleLabel.stringValue = "~"
        } else if !currentAppName.isEmpty && currentWindowTitle.isEmpty {
            windowTitleLabel.stringValue = currentAppName
        } else if currentAppName.isEmpty && !currentWindowTitle.isEmpty {
            windowTitleLabel.stringValue = currentWindowTitle
        } else {
            windowTitleLabel.stringValue = "\(currentAppName): \(currentWindowTitle)"
        }
    }

    // MARK: - Periodic Updates

    public func updateClock() {
        clockLabel.stringValue = dateFormatter.string(from: Date())
    }

    public func updateBattery() {
        let status = BatteryMonitor.currentStatus()
        batteryLabel.stringValue = status.formattedText
        batteryLabel.textColor = theme.secondary
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

    public func updateNetwork() {
        let ssid = NetworkMonitor.currentSSID()
        networkLabel.stringValue = "  \(ssid)"
    }

    public func startTimers() {
        guard updateTimer == nil else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.updateClock()
                self.updateBattery()
                self.updateHardware()
                self.updateVolume()
                self.updateNetwork()
            }
        }
    }

    public func stopTimers() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
}
