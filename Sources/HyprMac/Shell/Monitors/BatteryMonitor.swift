import Cocoa
import IOKit.ps

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
