import Cocoa
@preconcurrency import ApplicationServices

/// Native macOS Accessibility Event Observer.
/// Bridges application-level Accessibility events (window moved, resized, focused, title changed, minimized)
/// into reactive callbacks on MainActor, replacing recurring polling timers with true 0% CPU event listeners.
public final class AXEventObserver: @unchecked Sendable {
    private var observer: AXObserver?
    private var source: CFRunLoopSource?
    public private(set) var observedPID: pid_t = 0
    private var appElement: AXUIElement?

    public var onWindowMoved: (@MainActor () -> Void)?
    public var onWindowResized: (@MainActor () -> Void)?
    public var onFocusedWindowChanged: (@MainActor () -> Void)?
    public var onTitleChanged: (@MainActor () -> Void)?
    public var onWindowMiniaturized: (@MainActor () -> Void)?
    public var onWindowDeminiaturized: (@MainActor () -> Void)?
    public var onWindowMiniaturizedWithWindow: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onWindowDeminiaturizedWithWindow: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onWindowCreated: (@MainActor (pid_t) -> Void)?
    public var onWindowDestroyed: (@MainActor (pid_t) -> Void)?
    public var onAnyEvent: (@MainActor (pid_t, String) -> Void)?

    public var isObserving: Bool {
        return observer != nil && observedPID > 0
    }

    private var monitoredNotifications: [CFString] {
        return [
            kAXWindowCreatedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowMovedNotification as CFString,
            kAXWindowResizedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXTitleChangedNotification as CFString,
            kAXWindowMiniaturizedNotification as CFString,
            kAXWindowDeminiaturizedNotification as CFString
        ]
    }

    public init() {}

    deinit {
        stop()
    }

    /// Attaches the observer to the given process identifier.
    /// Safely invalidates any existing observer before attaching to the new target.
    public func observe(pid: pid_t) {
        guard pid > 0, pid != observedPID else { return }
        stop()

        var axObs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let watcher = Unmanaged<AXEventObserver>.fromOpaque(refcon).takeUnretainedValue()
            let notifName = notification as String

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let pid = watcher.observedPID
                    watcher.onAnyEvent?(pid, notifName)
                    if notifName == (kAXWindowCreatedNotification as String) {
                        watcher.onWindowCreated?(pid)
                    } else if notifName == (kAXUIElementDestroyedNotification as String) {
                        watcher.onWindowDestroyed?(pid)
                    } else if notifName == (kAXWindowMovedNotification as String) {
                        watcher.onWindowMoved?()
                    } else if notifName == (kAXWindowResizedNotification as String) {
                        watcher.onWindowResized?()
                    } else if notifName == (kAXFocusedWindowChangedNotification as String) {
                        watcher.onFocusedWindowChanged?()
                    } else if notifName == (kAXTitleChangedNotification as String) {
                        watcher.onTitleChanged?()
                    } else if notifName == (kAXWindowMiniaturizedNotification as String) {
                        let wid = WindowDetector.shared.getWindowID(for: element)
                        watcher.onWindowMiniaturizedWithWindow?(pid, wid)
                        watcher.onWindowMiniaturized?()
                    } else if notifName == (kAXWindowDeminiaturizedNotification as String) {
                        let wid = WindowDetector.shared.getWindowID(for: element)
                        watcher.onWindowDeminiaturizedWithWindow?(pid, wid)
                        watcher.onWindowDeminiaturized?()
                    }
                }
            }
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, callback, &axObs) == .success, let obs = axObs else {
            return
        }

        let appElem = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElem, 0.150)
        self.appElement = appElem

        for notif in monitoredNotifications {
            AXObserverAddNotification(obs, appElem, notif, refcon)
        }

        let src = AXObserverGetRunLoopSource(obs)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)

        self.observer = obs
        self.source = src
        self.observedPID = pid
    }

    /// Detaches the observer from the runloop and releases accessibility notifications.
    public func stop() {
        if let obs = observer, let src = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            if let app = appElement {
                for notif in monitoredNotifications {
                    AXObserverRemoveNotification(obs, app, notif)
                }
            }
        }
        self.observer = nil
        self.source = nil
        self.appElement = nil
        self.observedPID = 0
    }
}
