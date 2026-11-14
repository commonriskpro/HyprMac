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

    // Pending enrollment registry: window identities (pid, windowID) that still need an
    // eligibility re-check on the next coalesced reconcile pass. It tracks identity only;
    // workspace assignment stays derived from eligibility at pass time (SSOT in WorkspaceManager).
    private struct PendingEnrollmentKey: Hashable {
        let pid: pid_t
        let windowID: CGWindowID
    }
    private var pendingEnrollments: Set<PendingEnrollmentKey> = []

    /// When true, layout changes applied by HyprMac itself will not trigger recursive tiling passes.
    public var isSuppressingTilingEvents: Bool = false

    // Excluded application names
    public var excludedAppNames: Set<String> = [
        "HyprMac", "Window Server", "Dock", "NotificationCenter", "ControlCenter",
        "SystemUIServer", "Spotlight", "Wallpaper", "screencapture", "Simulator Trampoline"
    ]

    // Public reactive callbacks
    public var onWindowCreated: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onWindowDestroyed: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onWindowMoved: (@MainActor (pid_t) -> Void)?
    public var onWindowResized: (@MainActor (pid_t) -> Void)?
    public var onFocusedWindowChanged: (@MainActor (pid_t) -> Void)?
    public var onFocusChanged: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onTitleChanged: (@MainActor (pid_t) -> Void)?
    public var onTitleChangedWithWindow: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onMainWindowChanged: (@MainActor (pid_t, CGWindowID?) -> Void)?
    public var onFocusedUIElementChanged: (@MainActor (pid_t, CGWindowID?) -> Void)?
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
        pendingEnrollments.removeAll()
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
                // Enqueue windows that already materialized before observer attachment,
                // so a missed window-created event cannot leave them untracked.
                self.schedulePendingEnrollment(pid: pid, windowIDs: Self.currentCGWindowIDs(for: pid))
                self.scheduleCoalescedTilingUpdate()
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
                self.discardPendingEnrollments(pid: pid, windowID: nil)
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
        pendingEnrollments.removeAll()
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
        obs.onWindowCreated = { [weak self] p, maybeWid in
            self?.onWindowCreated?(p, maybeWid)
            if let wid = maybeWid, wid > 0 {
                self?.schedulePendingEnrollment(pid: p, windowIDs: [wid])
            } else {
                // Window-handle resolution failed; fall back to the PID's current CG windows.
                self?.schedulePendingEnrollment(pid: p, windowIDs: Self.currentCGWindowIDs(for: p))
            }
            self?.scheduleCoalescedTilingUpdate()
        }
        obs.onWindowDestroyed = { [weak self] p, maybeWid in
            self?.onWindowDestroyed?(p, maybeWid)
            self?.discardPendingEnrollments(pid: p, windowID: maybeWid)
            self?.scheduleCoalescedTilingUpdate()
        }
        obs.onWindowMoved = { [weak self] in
            self?.onWindowMoved?(pid)
            // Window materialization events re-arm the same coalesced pass that drains
            // pending enrollments, so a window that becomes eligible after launch is
            // enrolled on the very event that moved it.
            self?.scheduleCoalescedTilingUpdate()
        }
        obs.onWindowResized = { [weak self] in
            self?.onWindowResized?(pid)
            self?.scheduleCoalescedTilingUpdate()
        }
        obs.onFocusedWindowChangedWithWindow = { [weak self] p, wid in
            self?.onFocusChanged?(p, wid)
            if self?.hasPendingEnrollments(for: p) == true {
                self?.scheduleCoalescedTilingUpdate()
            }
        }
        obs.onFocusedWindowChanged = { [weak self] in
            self?.onFocusedWindowChanged?(pid)
            if self?.hasPendingEnrollments(for: pid) == true {
                self?.scheduleCoalescedTilingUpdate()
            }
        }
        obs.onTitleChanged = { [weak self] in
            self?.onTitleChanged?(pid)
        }
        obs.onTitleChangedWithWindow = { [weak self] p, wid in
            self?.onTitleChangedWithWindow?(p, wid)
        }
        obs.onMainWindowChanged = { [weak self] p, wid in
            self?.onMainWindowChanged?(p, wid)
        }
        obs.onFocusedUIElementChanged = { [weak self] p, wid in
            self?.onFocusedUIElementChanged?(p, wid)
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

    // MARK: - Pending Enrollment


    /// Enumerates the current layer-0 window IDs owned by a given PID from the global window list.
    private static func currentCGWindowIDs(for pid: pid_t) -> [CGWindowID] {
        guard let snapshot = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return snapshot.compactMap { item in
            guard let itemPID = item[kCGWindowOwnerPID as String] as? pid_t, itemPID == pid,
                  let wid = item[kCGWindowNumber as String] as? CGWindowID, wid > 0,
                  let layer = item[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
            return wid
        }
    }

    /// Enqueues window identities that must be re-checked for workspace enrollment on the next coalesced pass.
    public func schedulePendingEnrollment(pid: pid_t, windowIDs: [CGWindowID]) {
        lock.lock()
        defer { lock.unlock() }
        for wid in windowIDs where wid > 0 {
            pendingEnrollments.insert(PendingEnrollmentKey(pid: pid, windowID: wid))
        }
    }

    /// Checks whether any window identities for the given PID are pending enrollment.
    public func hasPendingEnrollments(for pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingEnrollments.contains { $0.pid == pid }
    }

    /// Snapshot of window identities pending an eligibility re-check.
    public func pendingEnrollmentSnapshot() -> [(pid: pid_t, windowID: CGWindowID)] {
        lock.lock()
        defer { lock.unlock() }
        return pendingEnrollments.map { (pid: $0.pid, windowID: $0.windowID) }
    }

    /// Clears identities that were eligible at pass time and got enrolled (idempotent removal).
    public func completePendingEnrollment(_ enrolled: [(pid: pid_t, windowID: CGWindowID)]) {
        lock.lock()
        defer { lock.unlock() }
        for entry in enrolled {
            pendingEnrollments.remove(PendingEnrollmentKey(pid: entry.pid, windowID: entry.windowID))
        }
    }

    /// Clears identities whose windows are no longer alive (window IDs are unique app-wide).
    public func prunePendingEnrollments(aliveWindowIDs: Set<CGWindowID>) {
        lock.lock()
        defer { lock.unlock() }
        pendingEnrollments = pendingEnrollments.filter { aliveWindowIDs.contains($0.windowID) }
    }

    /// Symmetric lifecycle cleanup: an exact key is dropped when a destroyed window's handle
    /// is still resolvable; otherwise every pending window of the PID is dropped (destroyed
    /// app element or application termination).
    private func discardPendingEnrollments(pid: pid_t, windowID: CGWindowID?) {
        lock.lock()
        defer { lock.unlock() }
        if let wid = windowID, wid > 0 {
            pendingEnrollments.remove(PendingEnrollmentKey(pid: pid, windowID: wid))
        } else {
            pendingEnrollments = pendingEnrollments.filter { $0.pid != pid }
        }
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
