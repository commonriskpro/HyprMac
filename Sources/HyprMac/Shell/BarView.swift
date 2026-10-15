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
        if !isPresent {
            return "⚡ 100%"
        }
        if isCharging {
            return "⚡ \(percentage)%"
        }
        let icon = percentage <= 20 ? "🪫" : "🔋"
        return "\(percentage)% \(icon)"
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

/// Reader for hardware CPU utilization using Mach host statistics
public enum HardwareMonitor {
    private static var lastTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?

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

/// Individual interactive workspace pill styled with Waybar/Hyprland aesthetics
@MainActor
public final class WorkspacePill: NSView {
    public let workspaceID: Int
    public var isActive: Bool = false {
        didSet { updateAppearance() }
    }
    public var onSelect: ((Int) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint?

    public init(workspaceID: Int) {
        self.workspaceID = workspaceID
        super.init(frame: .zero)
        setupView()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 12.0
        layer?.masksToBounds = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)

        let wc = widthAnchor.constraint(equalToConstant: 24.0)
        self.widthConstraint = wc

        NSLayoutConstraint.activate([
            wc,
            heightAnchor.constraint(equalToConstant: 24.0),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2.0),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2.0)
        ])

        updateAppearance()
    }

    public func updateAppearance() {
        if isActive {
            // Expanded active capsule with glowing Hyprland cyan
            widthConstraint?.constant = 44.0
            layer?.backgroundColor = NSColor(hex: 0x33CCFF).cgColor
            layer?.shadowColor = NSColor(hex: 0x33CCFF).cgColor
            layer?.shadowOpacity = 0.65
            layer?.shadowRadius = 8.0
            layer?.shadowOffset = .zero

            label.stringValue = "[ \(workspaceID) ]"
            label.textColor = NSColor(hex: 0x11111B)
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .heavy)
        } else {
            // Compact subtle inactive dot
            widthConstraint?.constant = 24.0
            layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
            layer?.shadowOpacity = 0.0

            label.stringValue = "•"
            label.textColor = NSColor(white: 0.70, alpha: 0.8)
            label.font = .systemFont(ofSize: 13, weight: .bold)
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

/// Floating glass capsule container styled after Waybar floating-glass-pills
@MainActor
public final class FloatingCapsuleView: NSView {
    public var cornerRadius: CGFloat = 17.0 {
        didSet {
            updateCornerRadius()
        }
    }

    private let clipView = NSView()
    private let visualEffectView = NSVisualEffectView()
    private let darkOverlay = NSView()
    public let stackView = NSStackView()

    public init(cornerRadius: CGFloat = 17.0) {
        self.cornerRadius = cornerRadius
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
        layer?.shadowOpacity = 0.30
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.shadowRadius = 8.0

        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        addSubview(clipView)

        // Frosted glass background
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        clipView.addSubview(visualEffectView)

        // Translucent dark layer rgba(22, 23, 30, 0.75) with 1px border rgba(255, 255, 255, 0.15)
        darkOverlay.translatesAutoresizingMaskIntoConstraints = false
        darkOverlay.wantsLayer = true
        darkOverlay.layer?.backgroundColor = NSColor(hex: 0x16171E, alpha: 0.75).cgColor
        darkOverlay.layer?.borderWidth = 1.0
        darkOverlay.layer?.borderColor = NSColor(white: 1.0, alpha: 0.15).cgColor
        clipView.addSubview(darkOverlay)

        // Content stack inside capsule
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.spacing = 6.0
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

            stackView.topAnchor.constraint(equalTo: clipView.topAnchor, constant: 5.0),
            stackView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor, constant: -5.0),
            stackView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 10.0),
            stackView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -10.0)
        ])

        updateCornerRadius()
    }

    private func updateCornerRadius() {
        clipView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.cornerRadius = cornerRadius
        darkOverlay.layer?.cornerRadius = cornerRadius
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        if bounds.width > 0 && bounds.height > 0 {
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        }
    }
}

/// Native Waybar floating-glass-pills status bar with 3 independent floating capsules
@MainActor
public final class BarView: NSView {
    public var cornerRadius: CGFloat = 17.0 {
        didSet {
            leftCapsule.cornerRadius = cornerRadius
            centerCapsule.cornerRadius = cornerRadius
            rightCapsule.cornerRadius = cornerRadius
        }
    }

    public private(set) var activeWorkspaceID: Int = 1
    public private(set) var currentAppName: String = ""
    public private(set) var currentWindowTitle: String = ""

    public var onWorkspaceSelected: ((Int) -> Void)?
    public var onNotificationClicked: (() -> Void)?
    public var onPowerClicked: (() -> Void)?

    // The Three Floating Glass Capsules (Islands)
    public let leftCapsule = FloatingCapsuleView(cornerRadius: 17.0)
    public let centerCapsule = FloatingCapsuleView(cornerRadius: 17.0)
    public let rightCapsule = FloatingCapsuleView(cornerRadius: 17.0)

    // Left Island Elements
    private let logoContainer = NSView()
    private let logoLabel = NSTextField(labelWithString: "")

    private let clockContainer = NSView()
    private let clockLabel = NSTextField(labelWithString: "")

    private let networkContainer = NSView()
    private let networkLabel = NSTextField(labelWithString: "Wi-Fi 📶")

    private let windowTitleContainer = NSView()
    private let windowTitleLabel = NSTextField(labelWithString: "")

    // Center Island Elements
    private let workspacesStack = NSStackView()
    private var workspacePills: [WorkspacePill] = []

    private let volumeContainer = NSView()
    private let volumeLabel = NSTextField(labelWithString: "80% 🔈")

    // Right Island Elements
    private let batteryContainer = NSView()
    private let batteryLabel = NSTextField(labelWithString: "")

    private let cpuContainer = NSView()
    private let cpuLabel = NSTextField(labelWithString: "⚙️ 24%")

    private let notificationContainer = ClickablePill()
    private let notificationLabel = NSTextField(labelWithString: "🔔")

    private let powerContainer = ClickablePill()
    private let powerLabel = NSTextField(labelWithString: "⏻")

    // Periodic update timer
    private var updateTimer: Timer?
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm 🕒"
        return df
    }()

    public init(frame frameRect: NSRect = .zero, workspaceCount: Int = 5) {
        super.init(frame: frameRect)
        setupViews(workspaceCount: workspaceCount)
        startTimers()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews(workspaceCount: 5)
        startTimers()
    }

    deinit {
        updateTimer?.invalidate()
    }

    private func setupViews(workspaceCount: Int) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Setup the 3 floating islands
        leftCapsule.translatesAutoresizingMaskIntoConstraints = false
        centerCapsule.translatesAutoresizingMaskIntoConstraints = false
        rightCapsule.translatesAutoresizingMaskIntoConstraints = false

        addSubview(leftCapsule)
        addSubview(centerCapsule)
        addSubview(rightCapsule)

        let capsuleHeight: CGFloat = 34.0

        NSLayoutConstraint.activate([
            // Left Capsule anchored to leading
            leftCapsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12.0),
            leftCapsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftCapsule.heightAnchor.constraint(equalToConstant: capsuleHeight),

            // Center Capsule centered horizontally
            centerCapsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerCapsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            centerCapsule.heightAnchor.constraint(equalToConstant: capsuleHeight),
            centerCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: leftCapsule.trailingAnchor, constant: 12.0),
            rightCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: centerCapsule.trailingAnchor, constant: 12.0),

            // Right Capsule anchored to trailing
            rightCapsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12.0),
            rightCapsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightCapsule.heightAnchor.constraint(equalToConstant: capsuleHeight)
        ])

        // 1. Build Left Island
        setupLeftIsland()

        // 2. Build Center Island
        setupCenterIsland(workspaceCount: workspaceCount)

        // 3. Build Right Island
        setupRightIsland()

        // Initial updates
        updateClock()
        updateBattery()
        updateHardware()
        updateVolume()
        updateActiveWindow(title: "", app: "")
    }

    // MARK: - Left Island Setup

    private func setupLeftIsland() {
        // 1. Logo Pill (Apple / Nix / Arch symbol)
        logoContainer.translatesAutoresizingMaskIntoConstraints = false
        logoContainer.wantsLayer = true
        logoContainer.layer?.cornerRadius = 12.0
        logoContainer.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        logoContainer.layer?.borderWidth = 1.0
        logoContainer.layer?.borderColor = NSColor(hex: 0x33CCFF, alpha: 0.35).cgColor

        logoLabel.translatesAutoresizingMaskIntoConstraints = false
        logoLabel.isEditable = false
        logoLabel.isSelectable = false
        logoLabel.alignment = .center
        logoLabel.font = .systemFont(ofSize: 13, weight: .bold)
        logoLabel.textColor = NSColor(hex: 0x33CCFF)
        logoContainer.addSubview(logoLabel)

        NSLayoutConstraint.activate([
            logoContainer.heightAnchor.constraint(equalToConstant: 24.0),
            logoLabel.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),
            logoLabel.leadingAnchor.constraint(equalTo: logoContainer.leadingAnchor, constant: 8.0),
            logoLabel.trailingAnchor.constraint(equalTo: logoContainer.trailingAnchor, constant: -8.0)
        ])
        leftCapsule.stackView.addArrangedSubview(logoContainer)

        // 2. Clock Pill with soft primary accent
        clockContainer.translatesAutoresizingMaskIntoConstraints = false
        clockContainer.wantsLayer = true
        clockContainer.layer?.cornerRadius = 12.0
        clockContainer.layer?.backgroundColor = NSColor(hex: 0x33CCFF, alpha: 0.12).cgColor
        clockContainer.layer?.borderWidth = 1.0
        clockContainer.layer?.borderColor = NSColor(hex: 0x33CCFF, alpha: 0.28).cgColor

        clockLabel.translatesAutoresizingMaskIntoConstraints = false
        clockLabel.isEditable = false
        clockLabel.isSelectable = false
        clockLabel.alignment = .center
        clockLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        clockLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        clockContainer.addSubview(clockLabel)

        NSLayoutConstraint.activate([
            clockContainer.heightAnchor.constraint(equalToConstant: 24.0),
            clockLabel.centerYAnchor.constraint(equalTo: clockContainer.centerYAnchor),
            clockLabel.leadingAnchor.constraint(equalTo: clockContainer.leadingAnchor, constant: 9.0),
            clockLabel.trailingAnchor.constraint(equalTo: clockContainer.trailingAnchor, constant: -9.0)
        ])
        leftCapsule.stackView.addArrangedSubview(clockContainer)

        // 3. Network Pill
        networkContainer.translatesAutoresizingMaskIntoConstraints = false
        networkContainer.wantsLayer = true
        networkContainer.layer?.cornerRadius = 12.0
        networkContainer.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        networkContainer.layer?.borderWidth = 1.0
        networkContainer.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor

        networkLabel.translatesAutoresizingMaskIntoConstraints = false
        networkLabel.isEditable = false
        networkLabel.isSelectable = false
        networkLabel.alignment = .center
        networkLabel.font = .systemFont(ofSize: 11, weight: .medium)
        networkLabel.textColor = NSColor(hex: 0xA6E3A1)
        networkContainer.addSubview(networkLabel)

        NSLayoutConstraint.activate([
            networkContainer.heightAnchor.constraint(equalToConstant: 24.0),
            networkLabel.centerYAnchor.constraint(equalTo: networkContainer.centerYAnchor),
            networkLabel.leadingAnchor.constraint(equalTo: networkContainer.leadingAnchor, constant: 8.0),
            networkLabel.trailingAnchor.constraint(equalTo: networkContainer.trailingAnchor, constant: -8.0)
        ])
        leftCapsule.stackView.addArrangedSubview(networkContainer)

        // 4. Active Window Title / Route Pill
        windowTitleContainer.translatesAutoresizingMaskIntoConstraints = false
        windowTitleContainer.wantsLayer = true
        windowTitleContainer.layer?.cornerRadius = 12.0
        windowTitleContainer.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        windowTitleContainer.layer?.borderWidth = 1.0
        windowTitleContainer.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor

        windowTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        windowTitleLabel.isEditable = false
        windowTitleLabel.isSelectable = false
        windowTitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        windowTitleLabel.textColor = NSColor(white: 0.90, alpha: 1.0)
        windowTitleLabel.lineBreakMode = .byTruncatingTail
        windowTitleLabel.maximumNumberOfLines = 1

        let maxWidthConstraint = windowTitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220.0)
        maxWidthConstraint.priority = .defaultHigh
        maxWidthConstraint.isActive = true

        windowTitleContainer.addSubview(windowTitleLabel)

        NSLayoutConstraint.activate([
            windowTitleContainer.heightAnchor.constraint(equalToConstant: 24.0),
            windowTitleLabel.centerYAnchor.constraint(equalTo: windowTitleContainer.centerYAnchor),
            windowTitleLabel.leadingAnchor.constraint(equalTo: windowTitleContainer.leadingAnchor, constant: 8.0),
            windowTitleLabel.trailingAnchor.constraint(equalTo: windowTitleContainer.trailingAnchor, constant: -8.0)
        ])
        leftCapsule.stackView.addArrangedSubview(windowTitleContainer)
    }

    // MARK: - Center Island Setup

    private func setupCenterIsland(workspaceCount: Int) {
        // Workspaces sub-stack
        workspacesStack.translatesAutoresizingMaskIntoConstraints = false
        workspacesStack.orientation = .horizontal
        workspacesStack.spacing = 4.0
        workspacesStack.alignment = .centerY
        centerCapsule.stackView.addArrangedSubview(workspacesStack)

        setWorkspaceCount(workspaceCount)

        // Volume Module
        volumeContainer.translatesAutoresizingMaskIntoConstraints = false
        volumeContainer.wantsLayer = true
        volumeContainer.layer?.cornerRadius = 12.0
        volumeContainer.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        volumeContainer.layer?.borderWidth = 1.0
        volumeContainer.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor

        volumeLabel.translatesAutoresizingMaskIntoConstraints = false
        volumeLabel.isEditable = false
        volumeLabel.isSelectable = false
        volumeLabel.alignment = .center
        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        volumeLabel.textColor = NSColor(hex: 0x89DCEB)
        volumeContainer.addSubview(volumeLabel)

        NSLayoutConstraint.activate([
            volumeContainer.heightAnchor.constraint(equalToConstant: 24.0),
            volumeLabel.centerYAnchor.constraint(equalTo: volumeContainer.centerYAnchor),
            volumeLabel.leadingAnchor.constraint(equalTo: volumeContainer.leadingAnchor, constant: 8.0),
            volumeLabel.trailingAnchor.constraint(equalTo: volumeContainer.trailingAnchor, constant: -8.0)
        ])
        centerCapsule.stackView.addArrangedSubview(volumeContainer)
    }

    // MARK: - Right Island Setup

    private func setupRightIsland() {
        // 1. Battery Pill
        batteryContainer.translatesAutoresizingMaskIntoConstraints = false
        batteryContainer.wantsLayer = true
        batteryContainer.layer?.cornerRadius = 12.0
        batteryContainer.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        batteryContainer.layer?.borderWidth = 1.0
        batteryContainer.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor

        batteryLabel.translatesAutoresizingMaskIntoConstraints = false
        batteryLabel.isEditable = false
        batteryLabel.isSelectable = false
        batteryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        batteryLabel.textColor = NSColor(white: 0.90, alpha: 1.0)
        batteryLabel.alignment = .center
        batteryContainer.addSubview(batteryLabel)

        NSLayoutConstraint.activate([
            batteryContainer.heightAnchor.constraint(equalToConstant: 24.0),
            batteryLabel.centerYAnchor.constraint(equalTo: batteryContainer.centerYAnchor),
            batteryLabel.leadingAnchor.constraint(equalTo: batteryContainer.leadingAnchor, constant: 8.0),
            batteryLabel.trailingAnchor.constraint(equalTo: batteryContainer.trailingAnchor, constant: -8.0)
        ])
        rightCapsule.stackView.addArrangedSubview(batteryContainer)

        // 2. Hardware / CPU Pill
        cpuContainer.translatesAutoresizingMaskIntoConstraints = false
        cpuContainer.wantsLayer = true
        cpuContainer.layer?.cornerRadius = 12.0
        cpuContainer.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        cpuContainer.layer?.borderWidth = 1.0
        cpuContainer.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor

        cpuLabel.translatesAutoresizingMaskIntoConstraints = false
        cpuLabel.isEditable = false
        cpuLabel.isSelectable = false
        cpuLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        cpuLabel.textColor = NSColor(hex: 0x7DCFFF)
        cpuLabel.alignment = .center
        cpuContainer.addSubview(cpuLabel)

        NSLayoutConstraint.activate([
            cpuContainer.heightAnchor.constraint(equalToConstant: 24.0),
            cpuLabel.centerYAnchor.constraint(equalTo: cpuContainer.centerYAnchor),
            cpuLabel.leadingAnchor.constraint(equalTo: cpuContainer.leadingAnchor, constant: 8.0),
            cpuLabel.trailingAnchor.constraint(equalTo: cpuContainer.trailingAnchor, constant: -8.0)
        ])
        rightCapsule.stackView.addArrangedSubview(cpuContainer)

        // 3. Notification Bell Pill
        notificationContainer.translatesAutoresizingMaskIntoConstraints = false
        notificationContainer.wantsLayer = true
        notificationContainer.layer?.cornerRadius = 12.0
        notificationContainer.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        notificationContainer.layer?.borderWidth = 1.0
        notificationContainer.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        notificationContainer.onClick = { [weak self] in
            self?.onNotificationClicked?()
        }

        notificationLabel.translatesAutoresizingMaskIntoConstraints = false
        notificationLabel.isEditable = false
        notificationLabel.isSelectable = false
        notificationLabel.font = .systemFont(ofSize: 12, weight: .medium)
        notificationLabel.textColor = NSColor(hex: 0xBB9AF7)
        notificationLabel.alignment = .center
        notificationContainer.addSubview(notificationLabel)

        NSLayoutConstraint.activate([
            notificationContainer.heightAnchor.constraint(equalToConstant: 24.0),
            notificationLabel.centerYAnchor.constraint(equalTo: notificationContainer.centerYAnchor),
            notificationLabel.leadingAnchor.constraint(equalTo: notificationContainer.leadingAnchor, constant: 8.0),
            notificationLabel.trailingAnchor.constraint(equalTo: notificationContainer.trailingAnchor, constant: -8.0)
        ])
        rightCapsule.stackView.addArrangedSubview(notificationContainer)

        // 4. Power / Session Pill
        powerContainer.translatesAutoresizingMaskIntoConstraints = false
        powerContainer.wantsLayer = true
        powerContainer.layer?.cornerRadius = 12.0
        powerContainer.layer?.backgroundColor = NSColor(hex: 0xED4245, alpha: 0.18).cgColor
        powerContainer.layer?.borderWidth = 1.0
        powerContainer.layer?.borderColor = NSColor(hex: 0xED4245, alpha: 0.35).cgColor
        powerContainer.onClick = { [weak self] in
            self?.onPowerClicked?()
        }

        powerLabel.translatesAutoresizingMaskIntoConstraints = false
        powerLabel.isEditable = false
        powerLabel.isSelectable = false
        powerLabel.font = .systemFont(ofSize: 12, weight: .bold)
        powerLabel.textColor = NSColor(hex: 0xED4245)
        powerLabel.alignment = .center
        powerContainer.addSubview(powerLabel)

        NSLayoutConstraint.activate([
            powerContainer.heightAnchor.constraint(equalToConstant: 24.0),
            powerLabel.centerYAnchor.constraint(equalTo: powerContainer.centerYAnchor),
            powerLabel.leadingAnchor.constraint(equalTo: powerContainer.leadingAnchor, constant: 8.0),
            powerLabel.trailingAnchor.constraint(equalTo: powerContainer.trailingAnchor, constant: -8.0)
        ])
        rightCapsule.stackView.addArrangedSubview(powerContainer)
    }

    // MARK: - Workspace Module

    public func setWorkspaceCount(_ count: Int) {
        workspacePills.forEach { $0.removeFromSuperview() }
        workspacePills.removeAll()

        for id in 1...count {
            let pill = WorkspacePill(workspaceID: id)
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
            windowTitleLabel.stringValue = "📁 on ~/REA"
        } else if !currentAppName.isEmpty && currentWindowTitle.isEmpty {
            windowTitleLabel.stringValue = "📁 \(currentAppName)"
        } else if currentAppName.isEmpty && !currentWindowTitle.isEmpty {
            windowTitleLabel.stringValue = "📁 \(currentWindowTitle)"
        } else {
            windowTitleLabel.stringValue = "📁 \(currentAppName): \(currentWindowTitle)"
        }
    }

    // MARK: - Periodic Updates

    public func updateClock() {
        clockLabel.stringValue = dateFormatter.string(from: Date())
    }

    public func updateBattery() {
        let status = BatteryMonitor.currentStatus()
        batteryLabel.stringValue = status.formattedText

        if status.isPresent && !status.isCharging && status.percentage <= 20 {
            batteryLabel.textColor = NSColor(hex: 0xED4245)
        } else if status.isPresent && status.isCharging {
            batteryLabel.textColor = NSColor(hex: 0x00FF99)
        } else {
            batteryLabel.textColor = NSColor(white: 0.90, alpha: 1.0)
        }
    }

    public func updateHardware() {
        let load = HardwareMonitor.currentCPULoad()
        cpuLabel.stringValue = "⚙️ \(load)%"
    }

    public func updateVolume() {
        let vol = VolumeMonitor.currentVolume()
        let icon = vol == 0 ? "🔇" : (vol < 50 ? "🔈" : "🔊")
        volumeLabel.stringValue = "\(vol)% \(icon)"
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
            }
        }
    }

    public func stopTimers() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
}
