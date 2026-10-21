import Cocoa
@preconcurrency import ApplicationServices

/// Multi-process Accessibility Event Observer Pool.
/// Dynamically attaches `AXEventObserver` instances to all active GUI applications (`activationPolicy == .regular`).
/// Replaces recurring polling loops with a pure 0% CPU event-driven reactive architecture.
public final class AXProcessObserverPool: @unchecked Sendable {
    public static let shared = AXProcessObserverPool()

    private let lock = NSLock()
    private var observers: [pid_t: AXEventObserver] = [:]
    private var workspaceObservers: [any NSObjectProtocol] = []
    public private(set) var isRunning: Bool = false

    // Debounce / Coalescing state for tiling and frame updates
    private var pendingTilingWorkItem: DispatchWorkItem?
    private let tilingCoalesceInterval: TimeInterval = 0.020 // 20ms

    /// When true, layout changes applied by HyprMac itself will not trigger recursive tiling passes.
    public var isSuppressingTilingEvents: Bool = false

    // Excluded application names
    public var excludedAppNames: Set<String> = [
        "HyprMac", "Window Server", "Dock", "NotificationCenter", "ControlCenter",
        "SystemUIServer", "Spotlight", "Wallpaper", "screencapture", "Simulator Trampoline"
    ]

    // Public reactive callbacks
    public var onWindowCreated: (@MainActor (pid_t) -> Void)?
    public var onWindowDestroyed: (@MainActor (pid_t) -> Void)?
    public var onWindowMoved: (@MainActor (pid_t) -> Void)?
    public var onWindowResized: (@MainActor (pid_t) -> Void)?
    public var onFocusedWindowChanged: (@MainActor (pid_t) -> Void)?
    public var onTitleChanged: (@MainActor (pid_t) -> Void)?
    public var onWindowMiniaturized: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onWindowDeminiaturized: (@MainActor (pid_t, CGWindowID?) -> Void)?

    /// Coalesced callback triggered whenever window creation, destruction, or layout changes occur.
    public var onTilingLayoutDirty: (@MainActor () -> Void)?

    public init() {}

    deinit {
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        pendingTilingWorkItem?.cancel()
        lock.lock()
        let allObservers = observers.values
        observers.removeAll()
        lock.unlock()
        for obs in allObservers {
            obs.stop()
        }
    }

    /// Starts observing all currently running regular GUI applications and listens for app launches/terminations.
    @MainActor
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // 1. Initial attachment to all running GUI applications
        let myPID = getpid()
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            let pid = app.processIdentifier
            guard pid > 0, pid != myPID else { continue }
            guard app.activationPolicy == .regular else { continue }
            if let name = app.localizedName, excludedAppNames.contains(name) { continue }
            observeApplication(pid: pid)
        }

        // 2. Listen for newly launched applications
        let launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self else { return }
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            guard pid > 0, pid != getpid() else { return }
            guard app.activationPolicy == .regular else { return }
            if let name = app.localizedName, self.excludedAppNames.contains(name) { return }

            MainActor.assumeIsolated {
                self.observeApplication(pid: pid)
                self.scheduleCoalescedTilingUpdate()

                // Staggered follow-up reconciliation passes as the newly launched app initializes its window
                for delay in [0.150, 0.350, 0.700, 1.200] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self = self, self.isRunning else { return }
                            self.observeApplication(pid: pid)
                            self.scheduleCoalescedTilingUpdate()
                        }
                    }
                }
            }
        }
        workspaceObservers.append(launchToken)

        // 3. Listen for terminated applications
        let termToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self else { return }
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            guard pid > 0 else { return }

            MainActor.assumeIsolated {
                self.unobserveApplication(pid: pid)
                self.scheduleCoalescedTilingUpdate()
            }
        }
        workspaceObservers.append(termToken)
    }

    /// Detaches all observers and stops listening to workspace events.
    @MainActor
    public func stop() {
        guard isRunning else { return }
        isRunning = false

        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()

        pendingTilingWorkItem?.cancel()
        pendingTilingWorkItem = nil

        lock.lock()
        let allObservers = observers.values
        observers.removeAll()
        lock.unlock()

        for obs in allObservers {
            obs.stop()
        }
    }

    /// Returns the number of currently observed processes.
    public var observedProcessCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observers.count
    }

    /// Attaches an AXEventObserver to a given PID.
    @MainActor
    public func observeApplication(pid: pid_t) {
        lock.lock()
        if let existing = observers[pid] {
            if existing.isObserving {
                lock.unlock()
                return
            }
            // If previous attachment attempt failed (e.g. process was still starting up), retry
            existing.observe(pid: pid)
            lock.unlock()
            return
        }
        lock.unlock()

        let obs = AXEventObserver()
        obs.onWindowCreated = { [weak self] p in
            self?.onWindowCreated?(p)
            self?.scheduleCoalescedTilingUpdate()
        }
        obs.onWindowDestroyed = { [weak self] p in
            self?.onWindowDestroyed?(p)
            self?.scheduleCoalescedTilingUpdate()
        }
        obs.onWindowMoved = { [weak self] in
            self?.onWindowMoved?(pid)
        }
        obs.onWindowResized = { [weak self] in
            self?.onWindowResized?(pid)
        }
        obs.onFocusedWindowChanged = { [weak self] in
            self?.onFocusedWindowChanged?(pid)
        }
        obs.onTitleChanged = { [weak self] in
            self?.onTitleChanged?(pid)
        }
        obs.onWindowMiniaturizedWithWindow = { [weak self] p, wid in
            self?.onWindowMiniaturized?(p, wid)
            self?.scheduleCoalescedTilingUpdate()
        }
        obs.onWindowDeminiaturizedWithWindow = { [weak self] p, wid in
            self?.onWindowDeminiaturized?(p, wid)
            self?.scheduleCoalescedTilingUpdate()
        }

        obs.observe(pid: pid)

        lock.lock()
        observers[pid] = obs
        lock.unlock()
    }

    /// Detaches and discards the AXEventObserver for a given PID.
    @MainActor
    public func unobserveApplication(pid: pid_t) {
        lock.lock()
        let obs = observers.removeValue(forKey: pid)
        lock.unlock()

        obs?.stop()
    }

    /// Coalesces high-frequency layout changes into a single MainActor invocation.
    /// Non-starving coalesce: if an update is already scheduled, lets it execute at its deadline
    /// instead of cancelling and postponing into the future on every event.
    @MainActor
    public func scheduleCoalescedTilingUpdate() {
        guard !isSuppressingTilingEvents else { return }

        if pendingTilingWorkItem != nil {
            // Already scheduled and will execute within tilingCoalesceInterval.
            // Do not postpone execution on new events (prevents starvation lag).
            return
        }

        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.pendingTilingWorkItem = nil
                guard !self.isSuppressingTilingEvents else { return }
                self.onTilingLayoutDirty?()
            }
        }
        pendingTilingWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + tilingCoalesceInterval, execute: item)
    }

    /// Immediately triggers any pending coalesced tiling update without waiting for debounce.
    @MainActor
    public func flushTilingUpdate() {
        pendingTilingWorkItem?.cancel()
        pendingTilingWorkItem = nil
        onTilingLayoutDirty?()
    }
}
