
import Cocoa
import QuartzCore
import IOKit.ps
import AudioToolbox
import CoreAudio
import Darwin
import CoreWLAN
import CoreLocation
import Network

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

    nonisolated(unsafe) private static var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private static var batteryCallback: (@Sendable (BatteryStatus) -> Void)?

    private static let batteryCallbackFn: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
        let status = BatteryMonitor.currentStatus()
        BatteryMonitor.batteryCallback?(status)
    }

    public static func startMonitoring(onChange: @escaping @Sendable (BatteryStatus) -> Void) {
        stopMonitoring()
        batteryCallback = onChange
        if let source = IOPSNotificationCreateRunLoopSource(batteryCallbackFn, nil)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        onChange(currentStatus())
    }

    public static func stopMonitoring() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        batteryCallback = nil
    }
}

/// Reader for hardware CPU & Memory utilization using Mach host statistics
public enum HardwareMonitor {
    nonisolated(unsafe) private static var lastTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    private static let hostPort: mach_port_t = mach_host_self()

    public static func currentCPULoad() -> Int {
        let count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var actualCount = count
        var cpuLoad = host_cpu_load_info()
        let kerr = withUnsafeMutablePointer(to: &cpuLoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &actualCount)
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
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
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
    public static var shared: VolumeMonitor.Type { VolumeMonitor.self }

    nonisolated(unsafe) private static var trackedSystemBlock: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private static var trackedDeviceBlock: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private static var trackedDeviceID: AudioDeviceID?

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

    public static func setVolume(_ volume: Int) {
        let clamped = max(0, min(100, volume))
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
        guard status == noErr else {
            let script = "set volume output volume \(clamped)"
            NSAppleScript(source: script)?.executeAndReturnError(nil)
            return
        }

        var volFloat = Float32(clamped) / 100.0
        propertyAddress.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        propertyAddress.mScope = kAudioObjectPropertyScopeOutput
        let setStatus = AudioObjectSetPropertyData(
            defaultOutputDeviceID,
            &propertyAddress,
            0,
            nil,
            propertySize,
            &volFloat
        )
        if setStatus != noErr {
            let script = "set volume output volume \(clamped)"
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    public static func stopMonitoring() {
        if let block = trackedSystemBlock {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                DispatchQueue.main,
                block
            )
            trackedSystemBlock = nil
        }
        if let block = trackedDeviceBlock, let deviceID = trackedDeviceID, deviceID != 0 {
            var volAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                deviceID,
                &volAddress,
                DispatchQueue.main,
                block
            )
            trackedDeviceBlock = nil
            trackedDeviceID = nil
        }
    }

    public static func startMonitoring(onChange: @escaping @Sendable (Int) -> Void) {
        stopMonitoring()

        func attachDeviceListener() {
            if let block = trackedDeviceBlock, let deviceID = trackedDeviceID, deviceID != 0 {
                var volAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(deviceID, &volAddress, DispatchQueue.main, block)
                trackedDeviceBlock = nil
                trackedDeviceID = nil
            }

            var defaultOutputDeviceID = AudioDeviceID(0)
            var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &propertySize,
                &defaultOutputDeviceID
            ) == noErr && defaultOutputDeviceID != 0 {
                var volAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
                let devBlock: AudioObjectPropertyListenerBlock = { _, _ in
                    let vol = currentVolume()
                    onChange(vol)
                }
                trackedDeviceBlock = devBlock
                trackedDeviceID = defaultOutputDeviceID
                AudioObjectAddPropertyListenerBlock(
                    defaultOutputDeviceID,
                    &volAddress,
                    DispatchQueue.main,
                    devBlock
                )
            }
        }

        var systemAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let sysBlock: AudioObjectPropertyListenerBlock = { _, _ in
            attachDeviceListener()
            let vol = currentVolume()
            onChange(vol)
        }
        trackedSystemBlock = sysBlock

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &systemAddress,
            DispatchQueue.main,
            sysBlock
        )

        attachDeviceListener()
        onChange(currentVolume())
    }
}

/// Reader for active Wi-Fi network SSID
final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        NetworkMonitor.resetCache()
    }
}

final class WiFiEventObserver: NSObject, CWEventDelegate, @unchecked Sendable {
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        NetworkMonitor.refreshAsync()
    }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        NetworkMonitor.refreshAsync()
    }
    func modeDidChangeForWiFiInterface(withName interfaceName: String) {
        NetworkMonitor.refreshAsync()
    }
    func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        NetworkMonitor.refreshAsync()
    }
}

public enum NetworkMonitor {
    nonisolated(unsafe) private static var cachedSSID: String = "Wi-Fi"
    nonisolated(unsafe) private static var isInitialized: Bool = false
    nonisolated(unsafe) private static var wifiObserver: WiFiEventObserver?
    nonisolated(unsafe) private static var locationManager: CLLocationManager?
    nonisolated(unsafe) private static var locationDelegate: LocationDelegate?
    nonisolated(unsafe) private static var pathMonitor: NWPathMonitor?
    private static let monitorQueue = DispatchQueue(label: "org.hyprmac.network-monitor", qos: .utility)

    public static func resetCache() {
        refreshAsync()
    }

    @MainActor
    public static func requestAuthorizationIfNeeded() {
        if locationManager == nil {
            let lm = CLLocationManager()
            let del = LocationDelegate()
            lm.delegate = del
            locationDelegate = del
            locationManager = lm
        }
        if let lm = locationManager, lm.authorizationStatus == .notDetermined {
            lm.requestWhenInUseAuthorization()
        }
    }

    public static func initializeEventMonitoringIfNeeded() {
        guard !isInitialized else { return }
        isInitialized = true

        let observer = WiFiEventObserver()
        wifiObserver = observer

        let client = CWWiFiClient.shared()
        client.delegate = observer
        _ = try? client.startMonitoringEvent(with: .ssidDidChange)
        _ = try? client.startMonitoringEvent(with: .linkDidChange)
        _ = try? client.startMonitoringEvent(with: .powerDidChange)
        _ = try? client.startMonitoringEvent(with: .bssidDidChange)

        // Reactive kernel-level network path monitoring via NWPathMonitor (zero subprocesses, zero ipconfig polling)
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                if path.status != .satisfied {
                    cachedSSID = "Disconnected"
                } else {
                    refreshAsync()
                }
            }
        }
        monitor.start(queue: monitorQueue)

        refreshAsync()
    }

    public static func refreshAsync() {
        // Request location permission so macOS allows SSID reading
        Task { @MainActor in
            requestAuthorizationIfNeeded()
        }

        // 1. Direct CoreWLAN interface reading
        if let wifiIface = CWWiFiClient.shared().interface() {
            if !wifiIface.powerOn() {
                cachedSSID = "Off"
                return
            }
            if let ssid = wifiIface.ssid(), !ssid.isEmpty, ssid != "<redacted>" {
                cachedSSID = ssid
                return
            }
        }

        // 2. Reactive Network.framework state fallback (zero fork/exec subprocesses)
        if let currentPath = pathMonitor?.currentPath {
            if currentPath.status != .satisfied {
                cachedSSID = "Disconnected"
            } else if currentPath.usesInterfaceType(.wiredEthernet) {
                cachedSSID = "Ethernet"
            } else if currentPath.usesInterfaceType(.wifi) {
                cachedSSID = "Wi-Fi"
            } else {
                cachedSSID = "Connected"
            }
        } else {
            cachedSSID = "Wi-Fi"
        }
    }

    public static func currentSSID() -> String {
        initializeEventMonitoringIfNeeded()
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
    public var activeBgColor: NSColor? {
        didSet { updateAppearance() }
    }
    public var activeFgColor: NSColor? {
        didSet { updateAppearance() }
    }
    public var inactiveTextColor: NSColor? {
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
            layer?.backgroundColor = (activeBgColor ?? theme.primary).cgColor
            label.textColor = activeFgColor ?? theme.onPrimary
            label.font = .barFont(ofSize: 11, weight: .bold)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = inactiveTextColor ?? theme.onSurface
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

    public var surfaceAlpha: CGFloat = 0.65 {
        didSet {
            updateTheme()
        }
    }

    public var isFrameless: Bool = false {
        didSet {
            updateAppearance()
        }
    }

    private let clipView = NSView()
    private let visualEffectView = NSVisualEffectView()
    private let darkOverlay = NSView()
    public let stackView = NSStackView()
    public var contentView: NSView { clipView }
    private var stackLeadingConstraint: NSLayoutConstraint?
    private var stackTrailingConstraint: NSLayoutConstraint?

    public init(cornerRadius: CGFloat = 5.0, theme: HyprTheme = .shared, surfaceAlpha: CGFloat = 0.65) {
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
        visualEffectView.material = .fullScreenUI
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

        let leading = stackView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 8.0)
        let trailing = stackView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -8.0)
        self.stackLeadingConstraint = leading
        self.stackTrailingConstraint = trailing

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
            leading,
            trailing
        ])

        updateCornerRadius()
        updateTheme()
        updateAppearance()
    }

    private func updateCornerRadius() {
        clipView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.cornerRadius = cornerRadius
        darkOverlay.layer?.cornerRadius = cornerRadius
        needsLayout = true
    }

    public func updateTheme() {
        if isFrameless {
            darkOverlay.layer?.backgroundColor = NSColor.clear.cgColor
            darkOverlay.layer?.borderWidth = 0.0
            darkOverlay.layer?.borderColor = NSColor.clear.cgColor
        } else {
            darkOverlay.layer?.backgroundColor = theme.surface.withAlphaComponent(surfaceAlpha).cgColor
            darkOverlay.layer?.borderWidth = 1.0
            darkOverlay.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        }
    }

    private func updateAppearance() {
        if isFrameless {
            layer?.shadowOpacity = 0.0
            layer?.shadowPath = nil
            visualEffectView.isHidden = true
            darkOverlay.layer?.backgroundColor = NSColor.clear.cgColor
            darkOverlay.layer?.borderWidth = 0.0
            darkOverlay.layer?.borderColor = NSColor.clear.cgColor
            stackLeadingConstraint?.constant = 0.0
            stackTrailingConstraint?.constant = 0.0
        } else {
            layer?.shadowOpacity = 0.25
            visualEffectView.isHidden = false
            darkOverlay.layer?.borderWidth = 1.0
            stackLeadingConstraint?.constant = 8.0
            stackTrailingConstraint?.constant = -8.0
            updateTheme()
        }
        needsLayout = true
    }

    private var previousRenderedFrame: NSRect = .zero

    public override func layout() {
        super.layout()
        let currentFrame = frame
        if isFrameless {
            layer?.shadowOpacity = 0.0
            layer?.shadowPath = nil
        } else if bounds.width > 0 && bounds.height > 0 {
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        }

        // Invalidate vacated dirty rects in the transparent window backing store when shrinking
        if previousRenderedFrame != .zero && previousRenderedFrame != currentFrame {
            if currentFrame.width < previousRenderedFrame.width || currentFrame.height < previousRenderedFrame.height || currentFrame.origin != previousRenderedFrame.origin {
                let shadowPadding: CGFloat = 16.0
                let dirtyRect = previousRenderedFrame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
                superview?.setNeedsDisplay(dirtyRect)
                window?.viewsNeedDisplay = true
            }
        }
        previousRenderedFrame = currentFrame
    }
}

/// Native Waybar-style status bar with 3 independent floating capsules (mxmrn rice)
@MainActor
public final class BarView: NSView {
    public override var isOpaque: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
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
    private var currentWlogoutWindow: WlogoutWindow?

    // Periodic update timer
    nonisolated(unsafe) private var updateTimer: Timer?
    public var clockFormat: String = "h:mm a  EEE" {
        didSet {
            dateFormatter.dateFormat = clockFormat
            updateClock()
        }
    }
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "h:mm a  EEE"
        return df
    }()

    public init(frame frameRect: NSRect = .zero, workspaceCount: Int = 6, theme: HyprTheme = .shared, clockFormat: String = "h:mm a  EEE") {
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
            musicTrackLabel.topAnchor.constraint(equalTo: musicTrackContainer.topAnchor),
            musicTrackLabel.bottomAnchor.constraint(equalTo: musicTrackContainer.bottomAnchor),
            musicTrackLabel.leadingAnchor.constraint(equalTo: musicTrackContainer.leadingAnchor),
            musicTrackLabel.trailingAnchor.constraint(equalTo: musicTrackContainer.trailingAnchor)
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
            musicPrevLabel.leadingAnchor.constraint(equalTo: musicPrevButton.leadingAnchor, constant: 1.0),
            musicPrevLabel.trailingAnchor.constraint(equalTo: musicPrevButton.trailingAnchor, constant: -1.0)
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
            musicPlayPauseLabel.leadingAnchor.constraint(equalTo: musicPlayPauseButton.leadingAnchor, constant: 1.0),
            musicPlayPauseLabel.trailingAnchor.constraint(equalTo: musicPlayPauseButton.trailingAnchor, constant: -1.0)
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
            musicNextLabel.leadingAnchor.constraint(equalTo: musicNextButton.leadingAnchor, constant: 1.0),
            musicNextLabel.trailingAnchor.constraint(equalTo: musicNextButton.trailingAnchor, constant: -1.0)
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
                self.updateHardware()
            }
        }
    }

    @objc private func handleNotificationStateDidChange() {
        updateNotificationIndicator()
    }

    public func stopTimers() {
        updateTimer?.invalidate()
        updateTimer = nil
        BatteryMonitor.stopMonitoring()
        VolumeMonitor.stopMonitoring()
        MusicMonitor.shared.stop()
        NotificationCenter.default.removeObserver(self, name: NotificationCenterManager.stateDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.screensDidSleepNotification, object: nil)
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

