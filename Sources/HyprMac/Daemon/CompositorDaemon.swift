import Cocoa
import ApplicationServices
import Darwin

final class TransitionTracker: @unchecked Sendable {
    var lastWorkspaceSwitchTime: TimeInterval = 0
}

final class NotificationTokenHolder: @unchecked Sendable {
    var token: (any NSObjectProtocol)?
    var activeSpaceToken: (any NSObjectProtocol)?
}

final class MouseStateHolder: @unchecked Sendable {
    var isMouseDown: Bool = false
    var global: Any?
    var local: Any?
}

@MainActor
public final class CompositorDaemon {
    public static let defaultHyprConf: String = NSString(string: "~/.config/hypr/hyprland.conf").expandingTildeInPath

    private let configPath: String?
    private var lockFd: Int32
    private var config: HyprConfig

    private let app = NSApplication.shared
    private var bar: HyprBarWindow?
    private let effectsManager = CompositorEffectsManager.shared
    private var dwindleEngine: DwindleEngine!
    private var masterEngine: MasterEngine!
    private let workspaceManager = WorkspaceManager.shared
    private let animationEngine = AnimationEngine.shared
    private let keyManager = KeybindManager.shared
    private let stateStore = WindowStateStore.shared

    private let transitionTracker = TransitionTracker()
    private let activationObserverHolder = NotificationTokenHolder()
    private let mouseState = MouseStateHolder()
    private var screenParamsObserver: (any NSObjectProtocol)?

    private var sigintSource: (any DispatchSourceSignal)?
    private var sigtermSource: (any DispatchSourceSignal)?

    private var lastWid: CGWindowID = 0
    private var lastFrame: NSRect = .zero
    private var lastTitle: String = ""

    private var draggedWid: CGWindowID? = nil
    private var dragStartFrame: CGRect? = nil
    private var dragStartMousePoint: NSPoint? = nil
    private var isDragging: Bool = false

    // MARK: - Shared Static Helpers

    @MainActor
    public static func getEligibleUserWindows(
        in screenBounds: CGRect,
        excludingPIDs: Set<pid_t> = [getpid()],
        windowListSnapshot: [[String: Any]]? = nil,
        pendingWindowIDs: Set<CGWindowID> = []
    ) -> [(windowID: CGWindowID, pid: pid_t, appName: String, title: String, bounds: CGRect, bundleID: String)] {
        return WindowDetector.shared.getEligibleWindows(
            in: screenBounds,
            excludingPIDs: excludingPIDs,
            windowListSnapshot: windowListSnapshot,
            pendingWindowIDs: pendingWindowIDs
        ).map {
            ($0.windowID, $0.processID, $0.appName, $0.title, $0.bounds, $0.bundleID)
        }
    }

    @MainActor
    public static func computeTilingBounds(bar: HyprBarWindow? = nil) -> CGRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return .zero
        }
        let screenFrame = screen.frame
        let vis = screen.visibleFrame
        let menuBarHeight = max(0.0, (screenFrame.origin.y + screenFrame.height) - (vis.origin.y + vis.height))
        let effectiveBar = bar ?? HyprBarWindow.shared
        let rawBarBottomY = effectiveBar?.barBottomY ?? 0.0
        let barBottomY = rawBarBottomY > 0.0 ? rawBarBottomY : 37.0

        let topOrigin = max(menuBarHeight, barBottomY)
        let tilingHeight = max(0.0, screenFrame.height - topOrigin)

        return CGRect(
            x: screenFrame.origin.x,
            y: topOrigin,
            width: screenFrame.width,
            height: tilingHeight
        )
    }

    @MainActor
    public static func computeFullscreenBounds(bar: HyprBarWindow? = nil) -> CGRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return .zero
        }
        let screenFrame = screen.frame
        return CGRect(
            x: screenFrame.origin.x,
            y: 0.0,
            width: screenFrame.width,
            height: screenFrame.height
        )
    }

    // MARK: - Public Run Entry Points

    public static func run(configPath: String? = nil) {
        let lockFd = acquireLockOrExit()

        if !WindowDetector.isProcessTrusted() {
            print("[!] Warning: Accessibility permissions required. Requesting...")
            _ = WindowDetector.isProcessTrusted(prompt: true)
        }

        let daemon = CompositorDaemon(configPath: configPath, lockFd: lockFd)
        daemon.start()
    }

    public static func run(configPath: String) {
        run(configPath: Optional(configPath))
    }

    // MARK: - Initialization & Single-Instance Lock

    private static func acquireLockOrExit() -> Int32 {
        let lockPath = "/tmp/hyprmac.lock"
        let lockFd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
            var existingPID: pid_t = 0
            if let pidStr = try? String(contentsOfFile: "/tmp/hyprmac.pid", encoding: .utf8),
               let p = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                existingPID = p
            }
            print("[HyprMac] Another instance of hyprmac daemon is already running (PID \(existingPID)). Exiting cleanly.")
            exit(0)
        }
        let currentPID = getpid()
        try? "\(currentPID)\n".write(toFile: "/tmp/hyprmac.pid", atomically: true, encoding: .utf8)
        return lockFd
    }

    private init(configPath: String?, lockFd: Int32) {
        self.configPath = configPath
        self.lockFd = lockFd

        if let path = configPath {
            print("[HyprMac] Loading user configuration from: \(path)")
            self.config = ConfigParser.parseFile(atPath: path)
        } else if FileManager.default.fileExists(atPath: Self.defaultHyprConf) {
            print("[HyprMac] Found local dotfile: \(Self.defaultHyprConf)")
            self.config = ConfigParser.parseFile(atPath: Self.defaultHyprConf)
        } else {
            print("[HyprMac] No custom config found. Running with default Hyprland profile.")
            self.config = HyprConfig()
        }

        self.dwindleEngine = DwindleEngine(gapsIn: self.config.gapsIn, gapsOut: self.config.gapsOut)
        self.masterEngine = MasterEngine(
            gapsIn: self.config.gapsIn,
            gapsOut: self.config.gapsOut,
            mfact: self.config.masterMfact,
            orientation: MasterOrientation(rawValue: self.config.masterOrientation.lowercased()) ?? .left,
            newOnTop: self.config.masterNewOnTop
        )
    }

    // MARK: - Lifecycle Pipeline

    public func start() {
        printBanner()
        setupEnvironmentAndSession()
        setupEnginesAndWorkspaces()
        setupKeybinds()
        setupWallpaperWatcher()
        setupSignalHandlers()
        restoreOrphanedParkedWindows()
        applyInitialTilingIfNeeded()
        setupWorkspaceAndSpaceObservers()
        setupMouseMonitoring()
        setupAccessibilityObservers()

        // Initial focus & borders sync
        updateFocusAndBorders(forceUpdate: false)

        app.run()
    }

    private func printBanner() {
        print("""
        ==================================================
                  🚀 HyprMac Full Desktop Active
        ==================================================
        Gaps:           in: \(config.gapsIn) pt | out: \(config.gapsOut) pt
        Border:         \(config.borderSize) px | rounding: \(config.rounding) pt
        Shell Mode:     \(config.borderMode.rawValue) (haloPadding: \(config.haloPadding) pt, opacity: \(config.windowOpacity))
        Decorations:    Titlebars stripped: \(config.stripDecorations)
        Layout:         \(config.layout)
        Animations:     Enabled: \(config.animationsEnabled)
        Bindings:       \(config.bindings.count) shortcuts registered
        Shell:          HyprBar (Waybar native) active on top screen
        Session:        Apple menu bar hidden, full screen reserved
        Press Ctrl+C to stop and restore native macOS Aqua.
        ==================================================
        """)
    }

    private func setupEnvironmentAndSession() {
        app.setActivationPolicy(.accessory)

        // Zero Local Events Suppression Interval (eliminates macOS 250ms synthetic latency following window operations)
        _ = CGSetLocalEventsSuppressionInterval(0.0)
        SkyLightBridge.shared.setLocalEventsSuppressionInterval(0.0)

        // 1. Enter HyprMac session mode (hide native Apple bar & auto-hide dock)
        _ = SessionManager.shared.switchTo(mode: .hyprMac)
        KeybindManager.shared.isMenuBarSuppressed = true
        _ = try? HyprServerBridge.shared.setMenuBarSuppression(suppress: true)

        if config.stripDecorations || config.rounding == 0 {
            let policy = HyprGlobalPolicy(
                autoSquareCorners: config.rounding == 0,
                autoStripShadow: true,
                autoStripTitlebar: config.stripDecorations,
                autoSetBorder: false,
                borderWidth: Float(config.borderSize),
                borderColorActive: 0,
                borderColorInactive: 0
            )
            _ = HyprServerBridge.shared.setGlobalPolicy(policy)
        }

        // 1b. Start unattended client decoration stripper (Técnica B: zero-flicker process attachment)
        ClientDecorationLoader.shared.ignoredApps = config.ignoredClientApps
        ClientDecorationLoader.shared.start(stripDecorations: config.stripDecorations)

        // 2. Launch native Waybar-style status bar
        let barWindow = HyprBarWindow()
        self.bar = barWindow
        HyprBarWindow.shared = barWindow
        barWindow.barView.barColors = config.barColors
        NotificationCenterManager.shared.start()
        barWindow.showBar()
        _ = try? HyprServerBridge.shared.setMenuBarSuppression(suppress: true, exemptWid: UInt32(barWindow.windowNumber))
        _ = SkyLightBridge.shared.setMenuBarSuppressed(true)
    }

    private func setupEnginesAndWorkspaces() {
        // 3c. Virtual Workspaces Manager (Single Source of Truth for workspaces 1..9)
        workspaceManager.dwindleEngine = dwindleEngine
        if config.layout.lowercased() == "master" {
            workspaceManager.masterEngine = masterEngine
        }
        workspaceManager.borderManager = effectsManager
        workspaceManager.boundsProvider = { Self.computeTilingBounds() }
        workspaceManager.fullscreenBoundsProvider = { MainActor.assumeIsolated { Self.computeFullscreenBounds() } }

        // 3c-2. Apply workspace-monitor bindings from config
        for (ws, spec) in config.workspaceMonitorBindings {
            if let idx = Int(spec), idx >= 0 && idx < NSScreen.screens.count {
                let scr = NSScreen.screens[idx]
                if let dID = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                    workspaceManager.bindWorkspace(ws, toDisplay: dID)
                }
            }
        }

        // Reconcile multi-monitor layout on display hot-plug/unplug
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let displayIDs = NSScreen.screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
                WorkspaceManager.shared.reconcileMonitors(availableDisplays: displayIDs)
            }
        }

        // 3d. Hyprland-identical window animation subsystem
        animationEngine.config = config

        workspaceManager.onWorkspaceChange = { [weak self] ws in
            guard let self = self else { return }
            self.transitionTracker.lastWorkspaceSwitchTime = ProcessInfo.processInfo.systemUptime
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self.bar?.updateActiveWorkspace(ws)
                    self.syncBarFullscreenState()
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.bar?.updateActiveWorkspace(ws)
                        self.syncBarFullscreenState()
                    }
                }
            }
        }

        workspaceManager.isFloating = { [weak keyManager] wid in
            keyManager?.isFloating(windowID: wid) ?? false
        }
        workspaceManager.isFullscreen = { [weak keyManager] wid in
            keyManager?.isFullscreen(windowID: wid) ?? false
        }
        dwindleEngine.isFullscreen = { [weak keyManager] wid in
            keyManager?.isFullscreen(windowID: wid) ?? false
        }
    }

    private func setupKeybinds() {
        keyManager.masterEngine = masterEngine
        keyManager.register(bindings: config.bindings)
        keyManager.onBuiltinShellAction = { action in
            ShellCommandCoordinator.shared.handleAction(action)
        }

        keyManager.onSwapWindow = { [weak self] widA, widB in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    let tilingBounds = Self.computeTilingBounds()
                    if self.config.layout.lowercased() == "master" {
                        let frames = self.masterEngine.swapWindows(windowA: widA, windowB: widB, in: tilingBounds)
                        self.masterEngine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                    } else {
                        let frames = self.dwindleEngine.swapWindows(windowA: widA, windowB: widB, in: tilingBounds)
                        self.dwindleEngine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                    }
                }
            }
        }

        keyManager.onToggleFloating = { [weak self] wid, isFloating in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    let tilingBounds = Self.computeTilingBounds()
                    let activeIDs = self.workspaceManager.activeWindowIDs()
                    let activeTiledIDs = activeIDs.filter { !self.keyManager.isFloating(windowID: $0) }
                    let frames = self.dwindleEngine.tileWindows(windowIDs: activeTiledIDs, in: tilingBounds)
                    self.dwindleEngine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                    if isFloating {
                        self.effectsManager.hideOverlay(for: wid)
                    }
                    let f = WindowDetector.shared.getFocusedWindow()
                    self.effectsManager.update(focused: f, managedFrames: self.dwindleEngine.currentFrames(), config: self.config)
                }
            }
        }

        keyManager.onFullscreenToggle = { [weak self] wid, isFullscreen, savedFrame in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                let tilingBounds = Self.computeTilingBounds()
                let activeIDs = self.workspaceManager.activeWindowIDs()

                SkyLightBridge.shared.disableUpdate()
                defer { SkyLightBridge.shared.reenableUpdate() }

                if isFullscreen {
                    let fullBounds = Self.computeFullscreenBounds()
                    let curBounds = savedFrame ?? self.dwindleEngine.currentFrames()[wid] ?? WindowDetector.shared.fastFocusedWindow()?.bounds ?? WindowDetector.shared.getWindowBounds(windowID: wid) ?? fullBounds
                    self.workspaceManager.setStoredFrame(fullBounds, for: wid)
                    self.bar?.setFullscreenAutoHide(true, animated: true)

                    // 1. Immediately apply physical frame for the fullscreen window at t = 0
                    WindowDetector.shared.setWindowFrame(windowID: wid, frame: fullBounds)

                    // 2. The remaining windows stay intact in their current layout slots under the fullscreen window.
                    // We do NOT retile or resize them to prevent background DOM reflows and relayout thrashing.

                    // 3. Trigger smooth visual animation from curBounds to fullBounds
                    AnimationEngine.shared.animateFullscreen(
                        windowID: wid,
                        from: curBounds,
                        to: fullBounds,
                        isFullscreen: true,
                        borderWindowID: nil
                    ) { [weak self] _ in
                        guard let self = self else { return }
                        let f = WindowDetector.shared.getFocusedWindow()
                        self.effectsManager.update(focused: f, managedFrames: self.dwindleEngine.currentFrames(), config: self.config)
                    }
                } else {
                    // Restoring from fullscreen: recompute tiling with all active windows restored
                    let allTiledIDs = activeIDs.filter { !self.keyManager.isFloating(windowID: $0) }
                    let frames = self.dwindleEngine.tileWindows(windowIDs: allTiledIDs, in: tilingBounds)
                    let fullBounds = Self.computeFullscreenBounds()
                    let targetFrame: CGRect

                    if self.keyManager.isFloating(windowID: wid) {
                        targetFrame = savedFrame ?? self.keyManager.getStoredFullscreenFrame(wid) ?? tilingBounds
                    } else if let targetTile = frames[wid] {
                        targetFrame = targetTile
                    } else {
                        targetFrame = savedFrame ?? tilingBounds
                    }
                    self.workspaceManager.setStoredFrame(targetFrame, for: wid)

                    // 1. Apply physical frame for wid back to its tiled frame
                    WindowDetector.shared.setWindowFrame(windowID: wid, frame: targetFrame)

                    // 2. For remaining windows: only write frame if their layout slot physically changed
                    var otherFrames = frames
                    otherFrames.removeValue(forKey: wid)
                    for (otherWid, otherFrame) in otherFrames {
                        let curFrame = self.dwindleEngine.currentFrames()[otherWid] ?? self.workspaceManager.storedFrame(for: otherWid)
                        if curFrame != otherFrame {
                            self.workspaceManager.setStoredFrame(otherFrame, for: otherWid)
                            WindowDetector.shared.setWindowFrame(windowID: otherWid, frame: otherFrame)
                        }
                    }

                    // 3. Animate fullscreen window from fullBounds to targetFrame
                    AnimationEngine.shared.animateFullscreen(
                        windowID: wid,
                        from: fullBounds,
                        to: targetFrame,
                        isFullscreen: false,
                        borderWindowID: nil
                    ) { [weak self] _ in
                        guard let self = self else { return }
                        let f = WindowDetector.shared.getFocusedWindow()
                        self.effectsManager.update(focused: f, managedFrames: self.dwindleEngine.currentFrames(), config: self.config)
                    }
                    self.syncBarFullscreenState()
                }
            }
        }

        keyManager.onMoveToWorkspace = { [weak self] wid, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.bar?.updateActiveWorkspace(self.workspaceManager.activeWorkspace)
                }
            }
        }

        keyManager.onWindowMinimize = { [weak self] wid in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    let tilingBounds = Self.computeTilingBounds()
                    let frames = self.dwindleEngine.removeWindow(windowID: wid, in: tilingBounds)
                    self.dwindleEngine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                    self.effectsManager.hideOverlay(for: wid)
                }
            }
        }

        keyManager.onWindowClose = { [weak self] wid in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    let tilingBounds = Self.computeTilingBounds()
                    let frames = self.dwindleEngine.removeWindow(windowID: wid, in: tilingBounds)
                    self.dwindleEngine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                    self.effectsManager.hideOverlay(for: wid)
                    self.syncBarFullscreenState()
                }
            }
        }

        keyManager.onToggleSplit = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    let tilingBounds = Self.computeTilingBounds()
                    let frames = self.dwindleEngine.toggleSplit(in: tilingBounds)
                    self.dwindleEngine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                }
            }
        }

        keyManager.onResizeWindow = { [weak self] delta in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    let tilingBounds = Self.computeTilingBounds()
                    let frames = self.dwindleEngine.adjustSplitRatio(delta: delta, in: tilingBounds)
                    self.dwindleEngine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                }
            }
        }

        keyManager.onReloadConfig = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    let confPath = self.configPath ?? Self.defaultHyprConf
                    guard FileManager.default.fileExists(atPath: confPath) else {
                        print("[HyprMac] Config file not found at \(confPath)")
                        return
                    }
                    print("[HyprMac] Hot-reloading configuration from \(confPath)...")
                    let newConfig = ConfigParser.parseFile(atPath: confPath)
                    self.config = newConfig
                    self.stateStore.resetEvaluatedRules()
                    self.animationEngine.config = newConfig
                    self.bar?.barView.barColors = newConfig.barColors
                    ClientDecorationLoader.shared.ignoredApps = newConfig.ignoredClientApps
                    self.keyManager.clearBindings()
                    self.keyManager.register(bindings: newConfig.bindings)
                    print("[HyprMac] Successfully reloaded \(newConfig.bindings.count) bindings from \(confPath)")
                }
            }
        }

        keyManager.onExit = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.cleanupAndExit()
                }
            }
        }

        keyManager.start()
    }

    private func setupWallpaperWatcher() {
        // 4b. Native Kernel-Level Event-Driven Wallpaper & Theming Watcher (FSEvents)
        let watcher = WallpaperWatcher.shared
        watcher.onThemeReload = { [weak self] in
            guard let self = self else { return }
            let confPath = self.configPath ?? NSString(string: "~/.config/hypr/hyprland.conf").expandingTildeInPath
            if FileManager.default.fileExists(atPath: confPath) {
                let newConfig = ConfigParser.parseFile(atPath: confPath)
                self.config = newConfig
                self.animationEngine.config = newConfig
                self.bar?.barView.barColors = newConfig.barColors
                ClientDecorationLoader.shared.ignoredApps = newConfig.ignoredClientApps
                self.bar?.barView.applyTheme()
                let f = WindowDetector.shared.getFocusedWindow()
                self.effectsManager.update(focused: f, managedFrames: self.dwindleEngine.currentFrames(), config: newConfig)
                print("[HyprMac] Dynamic theme & border colors reloaded from \(confPath)")
            }
        }
        watcher.start()
    }

    private func setupSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.cleanupAndExit()
            }
        }
        sigint.resume()
        self.sigintSource = sigint

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.cleanupAndExit()
            }
        }
        sigterm.resume()
        self.sigtermSource = sigterm
    }

    private func restoreOrphanedParkedWindows() {
        // Restore any orphaned parked windows from prior daemon crashes or restarts
        let startupTilingBounds = Self.computeTilingBounds()
        let initialScreens = HiddenWindowPlacement.allCGScreens()
        if let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for item in windowList {
                guard let wid = item[kCGWindowNumber as String] as? CGWindowID, wid > 0,
                      let pid = item[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                      let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
                      let boundsDict = item[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
                if HiddenWindowPlacement.isParkedOrHidden(rect, screens: initialScreens) {
                    _ = WindowDetector.shared.setWindowFrame(windowID: wid, frame: startupTilingBounds, pid: pid)
                }
            }
        }
    }

    private func applyInitialTilingIfNeeded() {
        let isTilingLayout = (config.layout.lowercased() == "dwindle" || config.layout.lowercased() == "master")
        if isTilingLayout {
            let tilingBounds = Self.computeTilingBounds()
            let eligibleWindows = Self.getEligibleUserWindows(in: tilingBounds, excludingPIDs: [getpid()])
            let currentIDs = eligibleWindows.map { $0.windowID }
            if !currentIDs.isEmpty {
                for w in eligibleWindows {
                    let isNew = !stateStore.isRuleEvaluated(w.windowID)
                    if isNew {
                        applyWindowRules(wid: w.windowID, pid: w.pid, appName: w.appName, bundleID: w.bundleID, title: w.title, bounds: w.bounds, isNewWindow: true)
                    }
                    workspaceManager.assignWindowIfNeeded(wid: w.windowID, pid: w.pid)
                    if !stateStore.isStripped(w.windowID) {
                        applyDecorations(wid: w.windowID)
                    }
                }
                let activeIDs = workspaceManager.activeWindowIDs()
                let activeTiledIDs = activeIDs.filter { !keyManager.isFloating(windowID: $0) && !workspaceManager.isPinned($0) }
                if config.layout.lowercased() == "master" {
                    let frames = masterEngine.tileWindows(windowIDs: activeTiledIDs, in: tilingBounds)
                    masterEngine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                } else {
                    let frames = dwindleEngine.tileWindows(windowIDs: activeTiledIDs, in: tilingBounds)
                    dwindleEngine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                }
            }
        }
    }

    private func setupWorkspaceAndSpaceObservers() {
        // Auto-switch workspace on external application activation (Dock, Cmd+Tab, Finder)
        activationObserverHolder.token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let activatedApp = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedPid = activatedApp?.processIdentifier
            let bundleId = activatedApp?.bundleIdentifier
            let localizedName = activatedApp?.localizedName
            MainActor.assumeIsolated {
                self?.handleApplicationActivated(pid: activatedPid, bundleId: bundleId, localizedName: localizedName)
            }
        }

        activationObserverHolder.activeSpaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if SessionManager.shared.getCurrentMode() == .hyprMac {
                    _ = SkyLightBridge.shared.setMenuBarSuppressed(true)
                }
                self?.syncBarFullscreenState()
            }
        }
    }

    private func handleApplicationActivated(pid activatedPid: pid_t?, bundleId: String?, localizedName: String?) {
        // Guard against switch in progress or within 500ms settle window:
        // internal activations from switchToWorkspace must never trigger an auto-switch or re-suppression.
        if workspaceManager.isSwitchInProgress(settleInterval: 0.500) {
            return
        }

        guard let pid = activatedPid, pid > 0, pid != getpid() else { return }

        if SessionManager.shared.getCurrentMode() == .hyprMac {
            _ = SkyLightBridge.shared.setMenuBarSuppressed(true)
        }

        // When Finder activates (e.g. clicking the empty desktop), ensure menubar suppression is active asynchronously without blocking the main thread
        if bundleId == "com.apple.finder" && SessionManager.shared.getCurrentMode() == .hyprMac {
            if !KeybindManager.shared.isMenuBarSuppressed {
                let barWid = UInt32(HyprBarWindow.shared?.windowNumber ?? self.bar?.windowNumber ?? 0)
                DispatchQueue.global(qos: .utility).async {
                    _ = try? HyprServerBridge.shared.setMenuBarSuppression(suppress: true, exemptWid: barWid)
                }
            }
        }

        // Finder Desktop filter: if Finder activated because the desktop was clicked or windows were hidden,
        // check if there is an actual standard window focused. If not, it is the desktop background,
        // so we do NOT auto-switch workspaces.
        if bundleId == "com.apple.finder" {
            let focused = WindowDetector.shared.fastFocusedWindow() ?? WindowDetector.shared.getFocusedWindow()
            if focused == nil || !WindowDetector.shared.isStandardWindow(windowID: focused?.windowID ?? 0, pid: pid) {
                return
            }
        }
        AXProcessObserverPool.shared.observeApplication(pid: pid)
        let rawFocused = WindowDetector.shared.fastFocusedWindow() ?? WindowDetector.shared.getFocusedWindow()

        // 1. Check if the activated application's focused window is minimized and needs unminimizing
        if let f = rawFocused, f.processID == pid {
            let wid = f.windowID
            if WindowDetector.shared.minimizedState(windowID: wid, pid: pid) == .minimized {
                _ = WindowDetector.shared.setWindowMinimized(windowID: wid, minimized: false, pid: pid)
                handleUnminimize(wid: wid, pid: pid)
                return
            }
        }

        // Check if any window belonging to the activated application unminimized
        for wid in workspaceManager.windowOrder where workspaceManager.getPID(for: wid) == pid {
            if workspaceManager.isMinimized(wid),
               WindowDetector.shared.minimizedState(windowID: wid, pid: pid) == .visible {
                handleUnminimize(wid: wid, pid: pid)
                return
            }
        }

        // 2. Inspect windows belonging to this activated application PID
        let appWindows = workspaceManager.windowOrder.filter { workspaceManager.getPID(for: $0) == pid }
        guard !appWindows.isEmpty else {
            reconcileWindows(forceRetile: false)
            return
        }

        // If ALL windows of this application are minimized:
        // Do NOT auto-switch workspaces to an inactive workspace!
        // Instead, restore/unminimize into the currently active workspace.
        let nonMinimizedAppWindows = appWindows.filter {
            !workspaceManager.isMinimized($0) &&
            WindowDetector.shared.minimizedState(windowID: $0, pid: pid) != .minimized
        }
        if nonMinimizedAppWindows.isEmpty {
            if let minWid = appWindows.first(where: {
                workspaceManager.isMinimized($0) ||
                WindowDetector.shared.minimizedState(windowID: $0, pid: pid) == .minimized
            }) {
                _ = WindowDetector.shared.setWindowMinimized(windowID: minWid, minimized: false, pid: pid)
                handleUnminimize(wid: minWid, pid: pid)
            }
            return
        }

        // If that PID already has an active, non-parked window on activeWorkspace, do NOT switch workspaces.
        let activeWorkspace = workspaceManager.activeWorkspace
        let windowsOnCurrentWS = nonMinimizedAppWindows.filter { workspaceManager.workspace(for: $0) == activeWorkspace }
        for wid in windowsOnCurrentWS {
            if let bounds = WindowDetector.shared.getWindowBounds(windowID: wid, pid: pid) {
                if !HiddenWindowPlacement.isParkedOrHidden(bounds) {
                    reconcileWindows(forceRetile: false)
                    return
                }
            } else {
                reconcileWindows(forceRetile: false)
                return
            }
        }

        // Only switch if all NON-MINIMIZED windows for that activated PID belong to another workspace targetWS != activeWorkspace
        let targetWorkspaces = Set(nonMinimizedAppWindows.compactMap { workspaceManager.workspace(for: $0) })
        guard !targetWorkspaces.isEmpty else {
            reconcileWindows(forceRetile: false)
            return
        }

        if targetWorkspaces.contains(activeWorkspace) {
            reconcileWindows(forceRetile: false)
            return
        }

        guard targetWorkspaces.count == 1, let targetWS = targetWorkspaces.first, targetWS != activeWorkspace else {
            return
        }

        // Resolve target window to focus on targetWS
        let targetWid = workspaceManager.lastFocused(for: targetWS) ?? nonMinimizedAppWindows.first(where: { workspaceManager.workspace(for: $0) == targetWS }) ?? nonMinimizedAppWindows.first
        guard let wid = targetWid else { return }

        let appName = localizedName ?? WindowDetector.shared.getWindowTitle(windowID: wid, pid: pid) ?? "App"
        let title = WindowDetector.shared.getWindowTitle(windowID: wid, pid: pid) ?? ""

        handleAutoSwitchWorkspace(wid: wid, targetWS: targetWS, appName: appName, title: title)
    }

    private func setupMouseMonitoring() {
        mouseState.global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseEvent(event)
            }
        }
        mouseState.local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseEvent(event)
            }
            return event
        }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard config.layout.lowercased() == "dwindle" else { return }

        switch event.type {
        case .leftMouseDown:
            let curPt = NSEvent.mouseLocation
            let rawFocused = WindowDetector.shared.fastFocusedWindow() ?? WindowDetector.shared.getFocusedWindow()
            if let f = rawFocused {
                let wid = f.windowID
                if dwindleEngine.managedWindowSet.contains(wid) && !keyManager.isFloating(windowID: wid) && !keyManager.isFullscreen(windowID: wid) {
                    let pid = workspaceManager.getPID(for: wid)
                    draggedWid = wid
                    dragStartFrame = WindowDetector.shared.getWindowBounds(windowID: wid, pid: pid) ?? f.bounds
                    dragStartMousePoint = curPt
                    isDragging = false
                } else {
                    draggedWid = nil
                    dragStartFrame = nil
                    dragStartMousePoint = nil
                    isDragging = false
                }
            } else {
                draggedWid = nil
                dragStartFrame = nil
                dragStartMousePoint = nil
                isDragging = false
            }

        case .leftMouseDragged:
            if draggedWid != nil, let startPt = dragStartMousePoint, !isDragging {
                let curPt = NSEvent.mouseLocation
                if hypot(curPt.x - startPt.x, curPt.y - startPt.y) > 8.0 {
                    isDragging = true
                }
            }

        case .leftMouseUp:
            if let wid = draggedWid {
                let pid = workspaceManager.getPID(for: wid)
                if isDragging {
                    let droppedBounds = WindowDetector.shared.getWindowBounds(windowID: wid, pid: pid) ?? dragStartFrame ?? .zero
                    let dropCenter = CGPoint(x: droppedBounds.midX, y: droppedBounds.midY)
                    let currentFrames = dwindleEngine.currentFrames()

                    if let otherWid = dwindleEngine.findWindow(at: dropCenter, excluding: wid) {
                        let tilingBounds = Self.computeTilingBounds()
                        let frames = dwindleEngine.swapWindows(windowA: wid, windowB: otherWid, in: tilingBounds)
                        dwindleEngine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                    } else {
                        // Window was moved slightly or dropped in empty space: snap back to allocated tiled frame
                        if let targetFrame = currentFrames[wid] {
                            _ = WindowDetector.shared.setWindowFrame(windowID: wid, frame: targetFrame, pid: pid)
                        }
                    }
                } else {
                    // Window clicked or shifted < 8pt. Check if shifted > 2.0pt and snap back
                    if let targetFrame = dwindleEngine.currentFrames()[wid],
                       let currentBounds = WindowDetector.shared.getWindowBounds(windowID: wid, pid: pid) {
                        let diff = max(
                            abs(currentBounds.origin.x - targetFrame.origin.x),
                            abs(currentBounds.origin.y - targetFrame.origin.y),
                            abs(currentBounds.width - targetFrame.width),
                            abs(currentBounds.height - targetFrame.height)
                        )
                        if diff > 2.0 {
                            _ = WindowDetector.shared.setWindowFrame(windowID: wid, frame: targetFrame, pid: pid)
                        }
                    }
                }
                updateFocusAndBorders(forceUpdate: false)
            }
            draggedWid = nil
            dragStartFrame = nil
            dragStartMousePoint = nil
            isDragging = false

        default:
            break
        }
    }

    private func setupAccessibilityObservers() {
        let axPool = AXProcessObserverPool.shared
        axPool.onWindowResized = { [weak self] _ in
            self?.syncBarFullscreenState()
        }
        axPool.onTilingLayoutDirty = { [weak self] in
            self?.reconcileWindows(forceRetile: false)
        }
        axPool.onFocusChanged = { [weak self] pid, maybeWid in
            guard let self = self else { return }
            let barWid = UInt32(self.bar?.windowNumber ?? 0)
            if let wid = maybeWid, wid > 0,
               !self.dwindleEngine.managedWindowSet.contains(wid),
               !self.keyManager.isFloating(windowID: wid),
               wid != barWid {
                self.reconcileWindows(forceRetile: false)
                return
            }
            if let focused = WindowDetector.shared.getFocusedWindow(),
               !self.dwindleEngine.managedWindowSet.contains(focused.windowID),
               !self.keyManager.isFloating(windowID: focused.windowID),
               focused.windowID != barWid {
                self.reconcileWindows(forceRetile: false)
            } else {
                self.updateFocusAndBorders(forceUpdate: false)
            }
        }
        axPool.onFocusedWindowChanged = { [weak self] _ in
            guard let self = self else { return }
            let barWid = UInt32(self.bar?.windowNumber ?? 0)
            if let focused = WindowDetector.shared.getFocusedWindow(),
               !self.dwindleEngine.managedWindowSet.contains(focused.windowID),
               !self.keyManager.isFloating(windowID: focused.windowID),
               focused.windowID != barWid {
                self.reconcileWindows(forceRetile: false)
            } else {
                self.updateFocusAndBorders(forceUpdate: false)
            }
        }

        axPool.onTitleChangedWithWindow = { [weak self] pid, maybeWid in
            self?.handleReactiveWindowEvent(pid: pid, maybeWid: maybeWid)
        }
        axPool.onMainWindowChanged = { [weak self] pid, maybeWid in
            self?.handleReactiveWindowEvent(pid: pid, maybeWid: maybeWid)
        }
        axPool.onFocusedUIElementChanged = { [weak self] pid, maybeWid in
            self?.handleReactiveWindowEvent(pid: pid, maybeWid: maybeWid)
        }

        axPool.onTitleChanged = { [weak self] _ in
            guard let self = self else { return }
            if let focused = WindowDetector.shared.getFocusedWindow() {
                self.applyWindowRules(wid: focused.windowID, pid: focused.processID, appName: focused.appName, bundleID: focused.bundleID, title: focused.title, bounds: focused.bounds, isNewWindow: false)
            }
            self.updateFocusAndBorders(forceUpdate: false)
        }
        axPool.onWindowMiniaturized = { [weak self] pid, maybeWid in
            guard let self = self else { return }
            if let wid = maybeWid, wid > 0 {
                self.workspaceManager.setWindowMinimized(wid, minimized: true)
                let tilingBounds = Self.computeTilingBounds()
                if self.dwindleEngine.managedWindowSet.contains(wid) {
                    self.dwindleEngine.removeWindow(windowID: wid, in: tilingBounds)
                    self.effectsManager.hideOverlay(for: wid)
                    self.dwindleEngine.applyToSystem(windowFrames: self.dwindleEngine.currentFrames(), bridge: SkyLightBridge.shared)
                }
            }
            self.reconcileWindows(forceRetile: false)
        }
        axPool.onWindowDeminiaturized = { [weak self] pid, maybeWid in
            guard let self = self else { return }
            if let wid = maybeWid, wid > 0 {
                self.handleUnminimize(wid: wid, pid: pid)
            } else {
                for wid in self.workspaceManager.windowOrder where self.workspaceManager.getPID(for: wid) == pid {
                    if self.workspaceManager.isMinimized(wid),
                       WindowDetector.shared.minimizedState(windowID: wid, pid: pid) == .visible {
                        self.handleUnminimize(wid: wid, pid: pid)
                        break
                    }
                }
            }
            self.reconcileWindows(forceRetile: false)
        }
        axPool.start()
    }

    private func handleReactiveWindowEvent(pid: pid_t, maybeWid: CGWindowID?) {
        let axPool = AXProcessObserverPool.shared
        let barWid = UInt32(bar?.windowNumber ?? 0)
        if let wid = maybeWid, wid > 0 {
            let isUnmanagedCandidate = !dwindleEngine.managedWindowSet.contains(wid) &&
                                       !keyManager.isFloating(windowID: wid) &&
                                       wid != barWid &&
                                       !workspaceManager.isMinimized(wid)
            if isUnmanagedCandidate || axPool.hasPendingEnrollments(for: pid) {
                axPool.schedulePendingEnrollment(pid: pid, windowIDs: [wid])
                axPool.scheduleCoalescedTilingUpdate()
            }
        } else if axPool.hasPendingEnrollments(for: pid) {
            axPool.scheduleCoalescedTilingUpdate()
        }
    }

    // MARK: - Layout, Rules & Window Decorations

    private func applyWindowRules(
        wid: CGWindowID,
        pid: pid_t,
        appName: String,
        bundleID: String,
        title: String,
        bounds: CGRect,
        isNewWindow: Bool
    ) {
        let isFloating = keyManager.isFloating(windowID: wid) || workspaceManager.isPinned(wid)
        let currentWs = workspaceManager.workspace(for: wid) ?? workspaceManager.activeWorkspace
        let tilingBounds = Self.computeTilingBounds()

        for rule in config.windowRules {
            guard rule.matches(
                bundleID: bundleID,
                appName: appName,
                title: title,
                isFloating: isFloating,
                workspace: currentWs
            ) else { continue }

            switch rule.action {
            case .float:
                keyManager.setFloating(windowID: wid, floating: true)
                _ = SkyLightBridge.shared.setWindowTags(windowID: wid, tag0: WindowTags.floating.rawValue)
                if dwindleEngine.managedWindowSet.contains(wid) {
                    dwindleEngine.removeWindow(windowID: wid, in: tilingBounds)
                    effectsManager.hideOverlay(for: wid)
                    dwindleEngine.applyToSystem(windowFrames: dwindleEngine.currentFrames(), bridge: SkyLightBridge.shared)
                }

            case .tile:
                keyManager.setFloating(windowID: wid, floating: false)
                _ = SkyLightBridge.shared.clearWindowTags(windowID: wid, tag0: WindowTags.floating.rawValue)
                if !dwindleEngine.managedWindowSet.contains(wid) && workspaceManager.workspace(for: wid) == workspaceManager.activeWorkspace {
                    dwindleEngine.addWindow(windowID: wid, in: tilingBounds)
                    dwindleEngine.applyToSystem(windowFrames: dwindleEngine.currentFrames(), bridge: SkyLightBridge.shared)
                }

            case .workspace(let num, let silent):
                if num > 0 && num <= 9 && isNewWindow {
                    workspaceManager.assignWindow(wid: wid, to: num, pid: pid)
                    if !silent && num != workspaceManager.activeWorkspace {
                        workspaceManager.switchToWorkspace(num)
                        bar?.updateActiveWorkspace(num)
                    } else if silent && num != workspaceManager.activeWorkspace {
                        workspaceManager.hideWindow(wid: wid)
                        effectsManager.hideOverlay(for: wid)
                    }
                }

            case .specialWorkspace(let name, let silent):
                if isNewWindow {
                    keyManager.setFloating(windowID: wid, floating: true)
                    workspaceManager.moveWindowToSpecialWorkspace(wid, name: name, silent: silent, screenBounds: tilingBounds)
                    if dwindleEngine.managedWindowSet.contains(wid) {
                        dwindleEngine.removeWindow(windowID: wid, in: tilingBounds)
                        effectsManager.hideOverlay(for: wid)
                        dwindleEngine.applyToSystem(windowFrames: dwindleEngine.currentFrames(), bridge: SkyLightBridge.shared)
                    }
                }

            case .size(let w, let h):
                let curBounds = WindowDetector.shared.getWindowBounds(windowID: wid, pid: pid) ?? bounds
                let newFrame = CGRect(x: curBounds.origin.x, y: curBounds.origin.y, width: w, height: h)
                _ = WindowDetector.shared.setWindowFrame(windowID: wid, frame: newFrame, pid: pid)
                workspaceManager.setStoredFrame(newFrame, for: wid)

            case .center:
                let curBounds = WindowDetector.shared.getWindowBounds(windowID: wid, pid: pid) ?? bounds
                let screen = NSScreen.main?.visibleFrame ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
                let x = screen.origin.x + max(0, (screen.width - curBounds.width) / 2.0)
                let y = screen.origin.y + max(0, (screen.height - curBounds.height) / 2.0)
                let newFrame = CGRect(x: x, y: y, width: curBounds.width, height: curBounds.height)
                _ = WindowDetector.shared.setWindowFrame(windowID: wid, frame: newFrame, pid: pid)
                workspaceManager.setStoredFrame(newFrame, for: wid)

            case .opacity(let active, let inactive):
                let inact = inactive ?? active
                stateStore.setOpacityOverride((active: active, inactive: inact), for: wid)
                let isFocused = WindowDetector.shared.fastFocusedWindow()?.windowID == wid
                let alpha = Float(isFocused ? active : inact)
                _ = SkyLightBridge.shared.setWindowAlpha(windowID: wid, alpha: alpha)

            case .noborder:
                stateStore.setNoBorder(wid, noBorder: true)
                effectsManager.hideOverlay(for: wid)
                _ = SkyLightBridge.shared.setBorder(windowID: wid, width: 0.0, activeColor: 0, inactiveColor: 0)

            case .noshadow:
                _ = HyprServerBridge.shared.setShadow(windowId: wid, enabled: false)

            case .rounding(let r):
                _ = HyprServerBridge.shared.setCornerRadius(windowId: wid, radius: Float(r))

            case .pin:
                workspaceManager.pinWindow(wid)
                keyManager.setFloating(windowID: wid, floating: true)
            }
        }
        stateStore.setRuleEvaluated(wid, evaluated: true)
    }

    private func applyDecorations(wid: CGWindowID) {
        guard wid > 0 else { return }
        guard !stateStore.isStripped(wid) else { return }
        stateStore.setStripped(wid, stripped: true)
        if config.stripDecorations {
            _ = SkyLightBridge.shared.stripTitlebar(windowID: wid)
            if let pid = workspaceManager.getPID(for: wid) {
                let app = NSRunningApplication(processIdentifier: pid)
                let name = app?.localizedName ?? ""
                let bundle = app?.bundleIdentifier ?? ""
                if !ClientDecorationLoader.shared.isIgnored(appName: name, bundleId: bundle) {
                    ClientDecorationLoader.shared.attachIfNeeded(pid: pid)
                }
            }
        }
        if config.rounding == 0 {
            _ = SkyLightBridge.shared.setCornerRadius(windowID: wid, radius: 0.0)
        }
        if config.blurEnabled {
            _ = SkyLightBridge.shared.setWindowBackgroundBlurRadius(windowID: wid, radius: config.blurRadius)
        }
    }

    private func handleUnminimize(wid: CGWindowID, pid: pid_t?) {
        guard wid > 0 else { return }
        let tilingBounds = Self.computeTilingBounds()
        workspaceManager.assignWindow(wid: wid, to: workspaceManager.activeWorkspace, pid: pid)
        workspaceManager.setWindowMinimized(wid, minimized: false)
        if !keyManager.isFloating(windowID: wid) && config.layout.lowercased() == "dwindle" {
            dwindleEngine.addWindow(windowID: wid, in: tilingBounds)
            if !stateStore.isStripped(wid) {
                applyDecorations(wid: wid)
            }
            dwindleEngine.applyToSystem(windowFrames: dwindleEngine.currentFrames(), bridge: SkyLightBridge.shared)
        } else {
            let cur = WindowDetector.shared.getWindowBounds(windowID: wid, pid: pid) ?? .zero
            if HiddenWindowPlacement.isParkedOrHidden(cur) || cur.width < 100 || cur.height < 100 {
                let defaultFrame = CGRect(
                    x: tilingBounds.midX - 400,
                    y: tilingBounds.midY - 300,
                    width: 800,
                    height: 600
                )
                _ = WindowDetector.shared.setWindowFrame(windowID: wid, frame: defaultFrame, pid: pid)
            }
        }
        workspaceManager.focusWindow(wid: wid)
        let f = WindowDetector.shared.getFocusedWindow()
        effectsManager.update(focused: f, managedFrames: dwindleEngine.currentFrames(), config: config)
        if let focused = f {
            bar?.updateActiveWindow(title: focused.title, app: focused.appName)
        }
    }

    private func handleAutoSwitchWorkspace(wid: CGWindowID, targetWS: Int, appName: String, title: String) {
        guard wid > 0, targetWS >= 1 && targetWS <= 9, targetWS != workspaceManager.activeWorkspace else { return }
        workspaceManager.switchToWorkspace(targetWS)
        workspaceManager.focusWindow(wid: wid)
        bar?.updateActiveWorkspace(targetWS)
        if !title.isEmpty {
            bar?.updateActiveWindow(title: title, app: appName)
        }
    }

    private func syncBarFullscreenState() {
        guard let bar = self.bar else { return }
        let activeWS = workspaceManager.activeWorkspace
        let activeWindows = workspaceManager.windowOrder.filter {
            workspaceManager.workspace(for: $0) == activeWS &&
            !workspaceManager.isMinimized($0) &&
            WindowDetector.shared.isWindowAlive(windowID: $0)
        }

        var isActiveFullscreen = false
        for wid in activeWindows {
            if keyManager.isFullscreen(windowID: wid) ||
               WindowDetector.shared.isWindowNativeFullscreen(windowID: wid, pid: workspaceManager.getPID(for: wid)) {
                isActiveFullscreen = true
                break
            }
        }

        if !isActiveFullscreen {
            if let focused = WindowDetector.shared.fastFocusedWindow() ?? WindowDetector.shared.getFocusedWindow() {
                if focused.windowID != CGWindowID(bar.windowNumber) &&
                   WindowDetector.shared.isWindowNativeFullscreen(windowID: focused.windowID, pid: focused.processID) {
                    isActiveFullscreen = true
                }
            }
        }

        bar.setFullscreenAutoHide(isActiveFullscreen, animated: true)
    }

    private func updateFocusAndBorders(forceUpdate: Bool) {
        guard let bar = self.bar else { return }
        let barWid = CGWindowID(bar.windowNumber)
        let rawFocused = WindowDetector.shared.getFocusedWindow()
        let isBarOrBorder = rawFocused != nil && (rawFocused!.windowID == barWid)
        let isParked = rawFocused != nil && HiddenWindowPlacement.isParkedOrHidden(rawFocused!.bounds)
        let focusedCandidate = (isBarOrBorder || isParked) ? nil : rawFocused

        // Ensure non-standard windows (popups/dropdowns) do not receive borders.
        let focused: FocusedWindowInfo?
        if let fc = focusedCandidate {
            if dwindleEngine.managedWindowSet.contains(fc.windowID) {
                focused = fc
            } else if let mainWid = dwindleEngine.managedWindowOrder.first(where: { workspaceManager.getPID(for: $0) == fc.processID }) {
                if let mainBounds = WindowDetector.shared.getWindowBounds(windowID: mainWid, pid: fc.processID) {
                    focused = FocusedWindowInfo(
                        windowID: mainWid,
                        processID: fc.processID,
                        appName: fc.appName,
                        title: fc.title,
                        bounds: mainBounds,
                        appkitFrame: WindowDetector.shared.convertToAppKitFrame(cgRect: mainBounds),
                        bundleID: fc.bundleID
                    )
                } else {
                    focused = nil
                }
            } else {
                focused = nil
            }
        } else {
            focused = nil
        }

        let currentFocusedWid = focused?.windowID ?? 0
        let currentFocusedFrame = focused?.appkitFrame ?? .zero

        if currentFocusedWid != lastWid || currentFocusedFrame != lastFrame || forceUpdate {
            lastWid = currentFocusedWid
            lastFrame = currentFocusedFrame
            effectsManager.update(focused: focused, managedFrames: dwindleEngine.currentFrames(), config: config)
        }

        if let focused = focused {
            if workspaceManager.workspace(for: focused.windowID) == workspaceManager.activeWorkspace {
                workspaceManager.setLastFocused(focused.windowID, for: workspaceManager.activeWorkspace)
            }
            if focused.title != lastTitle {
                lastTitle = focused.title
                bar.updateActiveWindow(title: focused.title, app: focused.appName)
            }
        }
        syncBarFullscreenState()
    }

    private func reconcileWindows(forceRetile: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let lastSwitch = max(transitionTracker.lastWorkspaceSwitchTime, workspaceManager.lastWorkspaceSwitchTime)
        let isSettleWindow = (now - lastSwitch) < 0.500 || workspaceManager.isSwitchInProgress(settleInterval: 0.500)
        guard config.layout.lowercased() == "dwindle" else { return }
        let snapshot = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        let pendingEnrollments = AXProcessObserverPool.shared.pendingEnrollmentSnapshot()
        let pendingWindowIDs = Set(pendingEnrollments.map(\.windowID))

        if isSettleWindow {
            // During a workspace-switch settle window, enrollment is an idempotent SSOT insert
            // and must still run so windows created during the switch are not lost, while
            // tiling/frame mutation writes remain deferred to the next full pass.
            guard !pendingEnrollments.isEmpty else { return }
            let eligibleWindows = Self.getEligibleUserWindows(in: Self.computeTilingBounds(), excludingPIDs: [getpid()], windowListSnapshot: snapshot, pendingWindowIDs: pendingWindowIDs)
            var enrolled: [(pid: pid_t, windowID: CGWindowID)] = []
            for w in eligibleWindows where pendingWindowIDs.contains(w.windowID) {
                if workspaceManager.workspace(for: w.windowID) == nil {
                    workspaceManager.assignWindow(wid: w.windowID, to: workspaceManager.activeWorkspace, pid: w.pid)
                } else {
                    workspaceManager.assignWindowIfNeeded(wid: w.windowID, pid: w.pid)
                }
                enrolled.append((pid: w.pid, windowID: w.windowID))
            }
            AXProcessObserverPool.shared.completePendingEnrollment(enrolled)
            return
        }

        AXProcessObserverPool.shared.isSuppressingTilingEvents = true
        defer { AXProcessObserverPool.shared.isSuppressingTilingEvents = false }

        var framesChanged = false
        let tilingBounds = Self.computeTilingBounds()

        // Unpark any orphaned windows alive in WindowServer that are not tracked in an inactive workspace
        let allScreens = HiddenWindowPlacement.allCGScreens()
        if let windowList = snapshot {
            for item in windowList {
                guard let wid = item[kCGWindowNumber as String] as? CGWindowID, wid > 0,
                      let pid = item[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                      let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
                      let boundsDict = item[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
                if HiddenWindowPlacement.isParkedOrHidden(rect, screens: allScreens) {
                    let ws = workspaceManager.workspace(for: wid)
                    if ws == nil || ws == workspaceManager.activeWorkspace {
                        _ = WindowDetector.shared.setWindowFrame(windowID: wid, frame: tilingBounds, pid: pid)
                    }
                }
            }
        }
        let eligibleWindows = Self.getEligibleUserWindows(in: tilingBounds, excludingPIDs: [getpid()], windowListSnapshot: snapshot, pendingWindowIDs: pendingWindowIDs)
        let currentIDs = eligibleWindows.map { $0.windowID }

        // Auto-assign any newly discovered window to active workspace with PID
        for w in eligibleWindows {
            let isNew = !stateStore.isRuleEvaluated(w.windowID)
            if isNew {
                applyWindowRules(wid: w.windowID, pid: w.pid, appName: w.appName, bundleID: w.bundleID, title: w.title, bounds: w.bounds, isNewWindow: true)
            }
            if workspaceManager.workspace(for: w.windowID) == nil {
                workspaceManager.assignWindow(wid: w.windowID, to: workspaceManager.activeWorkspace, pid: w.pid)
            } else {
                workspaceManager.assignWindowIfNeeded(wid: w.windowID, pid: w.pid)
            }
            if !stateStore.isStripped(w.windowID) {
                applyDecorations(wid: w.windowID)
            }
        }
        let eligibleWindowIDs = Set(eligibleWindows.map(\.windowID))
        AXProcessObserverPool.shared.completePendingEnrollment(
            pendingEnrollments.filter { eligibleWindowIDs.contains($0.windowID) }
        )

        // Check minimization status for each managed window in workspaceManager
        var minimizedChanged = false
        for wid in workspaceManager.windowOrder {
            let pid = workspaceManager.getPID(for: wid)
            // Convergence is one-directional: a confirmed minimized window is pulled out of the
            // layout. The reverse is never inferred from polling here. Accessibility answers
            // .visible for a few frames after a minimize request returns success, so
            // "stored minimized && AX visible" is not proof that the user restored the window;
            // restores are event-driven (AXWindowDeminiaturized, app activation).
            if WindowDetector.shared.minimizedState(windowID: wid, pid: pid) == .minimized {
                workspaceManager.setWindowMinimized(wid, minimized: true)
                if dwindleEngine.managedWindowSet.contains(wid) {
                    dwindleEngine.removeWindow(windowID: wid, in: tilingBounds)
                    effectsManager.hideOverlay(for: wid)
                    minimizedChanged = true
                }
            }
        }

        // Query all physical windows alive in macOS WindowServer
        let allAliveWindowIDs = WindowDetector.shared.getAllAliveWindowIDs(fromSnapshot: snapshot)
        WindowDetector.shared.pruneCache(aliveWindowIDs: allAliveWindowIDs)
        stateStore.prune(aliveWindowIDs: allAliveWindowIDs)
        // Symmetric cleanup: pending identities whose windows are gone can never enroll.
        AXProcessObserverPool.shared.prunePendingEnrollments(aliveWindowIDs: allAliveWindowIDs)

        // Purge dead windows across all workspaces
        for wid in workspaceManager.windowOrder {
            if !allAliveWindowIDs.contains(wid) {
                workspaceManager.removeWindow(wid: wid)
                dwindleEngine.removeWindow(windowID: wid, in: tilingBounds)
                effectsManager.hideOverlay(for: wid)
                WindowDetector.shared.invalidateWindow(windowID: wid)
            }
        }

        // Filter eligible windows using WorkspaceManager so only windows
        // belonging to the active workspace are tiled by DwindleEngine
        let activeIDs = workspaceManager.activeWindowIDs()
        let activeManagedSet = Set(activeIDs)
        let activeCurrentIDs = currentIDs.filter { activeManagedSet.contains($0) && !keyManager.isFloating(windowID: $0) && !workspaceManager.isPinned($0) }
        let currentSet = Set(activeCurrentIDs)

        if minimizedChanged || currentSet != dwindleEngine.managedWindowSet || forceRetile {
            let closedWindows = dwindleEngine.managedWindowSet.subtracting(currentSet)
            let openedWindows = currentSet.subtracting(dwindleEngine.managedWindowSet)

            for wid in closedWindows {
                dwindleEngine.removeWindow(windowID: wid, in: tilingBounds)
                effectsManager.hideOverlay(for: wid)
                AnimationEngine.shared.cancelAnimation(for: wid)
                if !allAliveWindowIDs.contains(wid) {
                    workspaceManager.removeWindow(wid: wid)
                    stateStore.setStripped(wid, stripped: false)
                }
            }

            let openedInOrder = activeCurrentIDs.filter { openedWindows.contains($0) }
            for wid in openedInOrder {
                dwindleEngine.addWindow(windowID: wid, in: tilingBounds)
                if !stateStore.isStripped(wid) {
                    applyDecorations(wid: wid)
                }
            }

            let frames = dwindleEngine.currentFrames()
            dwindleEngine.applyToSystem(windowFrames: frames, newlyAddedWindows: openedWindows, bridge: SkyLightBridge.shared)
            framesChanged = true
        }

        // Reconcile frames if shifted
        let snapped = dwindleEngine.reconcileFrames(
            threshold: 2.0,
            isFloating: {
                keyManager.isFloating(windowID: $0) ||
                keyManager.isFullscreen(windowID: $0) ||
                WindowDetector.shared.isWindowNativeFullscreen(windowID: $0, pid: workspaceManager.getPID(for: $0))
            },
            boundsProvider: { WindowDetector.shared.getWindowBounds(windowID: $0, pid: workspaceManager.getPID(for: $0)) },
            frameSetter: { wid, frame in
                let pid = workspaceManager.getPID(for: wid)
                _ = WindowDetector.shared.setWindowFrame(windowID: wid, frame: frame, pid: pid)
            }
        )
        if !snapped.isEmpty {
            framesChanged = true
        }

        updateFocusAndBorders(forceUpdate: framesChanged)
        syncBarFullscreenState()
    }

    // MARK: - Graceful Shutdown

    private func cleanupAndExit() {
        print("\n[HyprMac] Gracefully shutting down...")
                ClientDecorationLoader.shared.stop()
                WallpaperWatcher.shared.stop()
                NotificationCenterManager.shared.stop()
                AXProcessObserverPool.shared.stop()
                if let token = self.activationObserverHolder.token {
                    NSWorkspace.shared.notificationCenter.removeObserver(token)
                    self.activationObserverHolder.token = nil
                }
                if let spaceToken = self.activationObserverHolder.activeSpaceToken {
                    NSWorkspace.shared.notificationCenter.removeObserver(spaceToken)
                    self.activationObserverHolder.activeSpaceToken = nil
                }
                if let screenToken = self.screenParamsObserver {
                    NotificationCenter.default.removeObserver(screenToken)
                    self.screenParamsObserver = nil
                }
                if let m = self.mouseState.global {
                    NSEvent.removeMonitor(m)
                    self.mouseState.global = nil
                }
                if let m = self.mouseState.local {
                    NSEvent.removeMonitor(m)
                    self.mouseState.local = nil
                }
                self.sigintSource?.cancel()
                self.sigintSource = nil
                self.sigtermSource?.cancel()
                self.sigtermSource = nil

                self.bar?.hideBar()
                self.effectsManager.hideAll()
                self.animationEngine.cancelAll()
                self.keyManager.stop()
                KeybindManager.shared.isMenuBarSuppressed = false
                unlink("/tmp/hyprmac.pid")
                unlink("/tmp/hyprmac.lock")
                if self.lockFd >= 0 {
                    close(self.lockFd)
                    self.lockFd = -1
                }
                print("[HyprMac] Restoring stock macOS Aqua desktop...")
                let allScreens = HiddenWindowPlacement.allCGScreens()
                for wid in self.workspaceManager.windowOrder {
                    if let bounds = WindowDetector.shared.getWindowBounds(windowID: wid),
                       HiddenWindowPlacement.isParkedOrHidden(bounds, screens: allScreens) {
                        _ = self.workspaceManager.restoreWindow(wid: wid)
                    }
                }
                _ = try? HyprServerBridge.shared.setMenuBarSuppression(suppress: false)
                _ = SkyLightBridge.shared.setMenuBarSuppressed(false)
                _ = SessionManager.shared.switchTo(mode: .aqua)
                print("[HyprMac] Restored. Goodbye!")
        exit(0)
    }
}

// MARK: - Global Convenience Forwarders

@MainActor
public func computeTilingBounds(bar: HyprBarWindow? = nil) -> CGRect {
    CompositorDaemon.computeTilingBounds(bar: bar)
}

@MainActor
public func computeFullscreenBounds(bar: HyprBarWindow? = nil) -> CGRect {
    CompositorDaemon.computeFullscreenBounds(bar: bar)
}

@MainActor
public func getEligibleUserWindows(
    in screenBounds: CGRect,
    excludingPIDs: Set<pid_t> = [getpid()],
    windowListSnapshot: [[String: Any]]? = nil,
    pendingWindowIDs: Set<CGWindowID> = []
) -> [(windowID: CGWindowID, pid: pid_t, appName: String, title: String, bounds: CGRect, bundleID: String)] {
    CompositorDaemon.getEligibleUserWindows(
        in: screenBounds,
        excludingPIDs: excludingPIDs,
        windowListSnapshot: windowListSnapshot,
        pendingWindowIDs: pendingWindowIDs
    )
}

