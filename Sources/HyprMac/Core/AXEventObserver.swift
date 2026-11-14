import Cocoa
@preconcurrency import ApplicationServices

private let kAXWindowZoomedNotification: String = "AXWindowZoomed"

private final class AXCallbackBox: @unchecked Sendable {
    weak var observer: AXEventObserver?

    init(observer: AXEventObserver) {
        self.observer = observer
    }
}

/// Native macOS Accessibility Event Observer.
/// Bridges application-level Accessibility events (window moved, resized, focused, title changed, minimized)
/// into reactive callbacks on MainActor, replacing recurring polling timers with true 0% CPU event listeners.
public final class AXEventObserver: @unchecked Sendable {
    private var observer: AXObserver?
    private var source: CFRunLoopSource?
    private var callbackBox: AXCallbackBox?
    public private(set) var observedPID: pid_t = 0
    private var appElement: AXUIElement?

    public var onWindowMoved: (@MainActor () -> Void)?
    public var onWindowResized: (@MainActor () -> Void)?
    public var onFocusedWindowChanged: (@MainActor () -> Void)?
    public var onFocusedWindowChangedWithWindow: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onTitleChanged: (@MainActor () -> Void)?
    public var onTitleChangedWithWindow: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onMainWindowChanged: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onFocusedUIElementChanged: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onWindowMiniaturized: (@MainActor () -> Void)?
    public var onWindowDeminiaturized: (@MainActor () -> Void)?
    public var onWindowMiniaturizedWithWindow: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onWindowDeminiaturizedWithWindow: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onWindowCreated: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onWindowDestroyed: (@MainActor (pid_t, CGWindowID?) -> Void)?
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
            kAXWindowZoomedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXMainWindowChangedNotification as CFString,
            kAXFocusedUIElementChangedNotification as CFString,
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

        let box = AXCallbackBox(observer: self)
        let retainedBox = Unmanaged.passRetained(box)
        let refcon = retainedBox.toOpaque()

        var axObs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let box = Unmanaged<AXCallbackBox>.fromOpaque(refcon).takeUnretainedValue()
            guard let observer = box.observer, observer.observedPID != 0 else { return }
            let notifName = notification as String

            DispatchQueue.main.async { [weak observer] in
                MainActor.assumeIsolated {
                    guard let observer = observer, observer.observedPID != 0 else { return }
                    let pid = observer.observedPID
                    observer.onAnyEvent?(pid, notifName)
                    if notifName == (kAXWindowCreatedNotification as String) {
                        let wid = WindowDetector.shared.getWindowID(for: element)
                        observer.onWindowCreated?(pid, wid)
                    } else if notifName == (kAXUIElementDestroyedNotification as String) {
                        let wid = WindowDetector.shared.getWindowID(for: element)
                        observer.onWindowDestroyed?(pid, wid)
                    } else if notifName == (kAXWindowMovedNotification as String) {
                        observer.onWindowMoved?()
                    } else if notifName == (kAXWindowResizedNotification as String) || notifName == (kAXWindowZoomedNotification as String) {
                        observer.onWindowResized?()
                    } else if notifName == (kAXFocusedWindowChangedNotification as String) {
                        let wid = WindowDetector.shared.getWindowID(for: element)
                        observer.onFocusedWindowChangedWithWindow?(pid, wid)
                        observer.onFocusedWindowChanged?()
                    } else if notifName == (kAXMainWindowChangedNotification as String) {
                        let wid = WindowDetector.shared.getWindowID(for: element)
                        observer.onMainWindowChanged?(pid, wid)
                    } else if notifName == (kAXFocusedUIElementChangedNotification as String) {
                        let wid = WindowDetector.shared.getWindowID(for: element)
                        observer.onFocusedUIElementChanged?(pid, wid)
                    } else if notifName == (kAXTitleChangedNotification as String) {
                        let wid = WindowDetector.shared.getWindowID(for: element)
                        observer.onTitleChangedWithWindow?(pid, wid)
                        observer.onTitleChanged?()
                    } else if notifName == (kAXWindowMiniaturizedNotification as String) {
                        let wid = WindowDetector.shared.getWindowID(for: element)
                        observer.onWindowMiniaturizedWithWindow?(pid, wid)
                        observer.onWindowMiniaturized?()
                    } else if notifName == (kAXWindowDeminiaturizedNotification as String) {
                        let wid = WindowDetector.shared.getWindowID(for: element)
                        observer.onWindowDeminiaturizedWithWindow?(pid, wid)
                        observer.onWindowDeminiaturized?()
                    }
                }
            }
        }

        guard AXObserverCreate(pid, callback, &axObs) == .success, let obs = axObs else {
            retainedBox.release()
            return
        }
        self.callbackBox = box

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
        if let box = callbackBox {
            box.observer = nil
            Unmanaged.passUnretained(box).release()
            self.callbackBox = nil
        }
        self.observer = nil
        self.source = nil
        self.appElement = nil
        self.observedPID = 0
    }
}
