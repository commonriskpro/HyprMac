import Cocoa
import CoreWLAN
import CoreLocation
import Network

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
