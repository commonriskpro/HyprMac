import Cocoa
import ApplicationServices
import Darwin

@MainActor
func printUsage() {
    let help = """
    HyprMac - macOS Window Engine & Hyprland-style Border Compositor

    Usage:
      hyprmac <command> [options]

    Commands:
      probe       Inspect and print active focused window properties (app, title, windowID, bounds, SkyLight tags)
      strip       Test dynamic titlebar / decoration removal on the active focused window
      tile        Detect visible user windows on current screen and arrange in Dwindle layout
      test-config Run unit tests verifying the hyprland.conf parser and variable expansion
      test-keys   Run unit tests verifying keycode resolution, modifier parsing, and event tap
      parse-config [path] Parse a hyprland.conf file and display its parsed rules and bindings
      daemon [conf] Launch the full integrated HyprMac desktop (Waybar + Tiling + Gradient Borders + Hotkeys)
      bar         Launch the live Waybar/Hyprland status bar on the top screen
      session [status|switch|hypr|aqua] Manage or toggle session mode between HyprMac and Aqua
      test-bar    Run unit tests verifying HyprBar window, layout, and IOPowerSources
      test-session Run unit tests verifying SessionManager serialization and mode transitions
      test-dwindle Run mathematical unit tests for 1, 2, 3, and 4 window Dwindle layouts
      test-workspace Run unit tests verifying WorkspaceManager virtual workspaces (1..9)
      server-status Inspect and report HyprServer hook status, ping, and version
      square <id>   Set 0px square corners on window via server hook IPC
      strip-shadow <id> Strip window shadow via server hook IPC
      test-bridge   Run unit tests verifying HyprServerBridge ring buffer and SkyLight routing
      menubar [suppress|restore] Completely suppress or restore native macOS menu bar reveal
      launcher [query] Launch the native Rofi application launcher (alias: rofi)
      powermenu        Launch the native Wlogout fullscreen power menu (alias: wlogout)
      wallpaper [query] Launch the native Wallpaper Gallery & selector (alias: gallery)
      help        Show this help message
    """
    print(help)
}

func parseWindowID(_ str: String) -> UInt32? {
    if str.hasPrefix("0x") || str.hasPrefix("0X") {
        return UInt32(str.dropFirst(2), radix: 16)
    }
    return UInt32(str)
}

@MainActor
func runServerStatus() {
    print("[+] Connecting to HyprServer hook via shared memory (\(HyprProtocol.shmPath))...")
    let bridge = HyprServerBridge.shared
    guard bridge.setupSharedMemory() else {
        print("[-] Failed to initialize shared memory at \(HyprProtocol.shmPath)")
        exit(1)
    }
    _ = bridge.waitForHook(timeout: 5.0)
    let status = bridge.getServerStatus()

    if status.isConnected {
        print("[+] Connection Status: CONNECTED")
        print("[+] Hook Status: ACTIVE and responding to HYPR_CMD_PING")
        if let ver = status.versionString {
            print("[+] Server Version: v\(ver) (0x\(String(status.serverVersion ?? 0, radix: 16, uppercase: true)))")
        }
        if let activeWindows = status.activeWindows {
            print("[+] Active Managed Windows: \(activeWindows)")
        }
        if let pid = bridge.hookPID {
            print("[+] Hook PID (WindowServer): \(pid)")
        }
        exit(0)
    } else {
        print("[-] Connection Status: DISCONNECTED")
        print("[-] Hook Status: INACTIVE (could not reach hook via \(HyprProtocol.shmPath))")
        exit(1)
    }
}

@MainActor
func runSquare(args: [String]) {
    guard let arg = args.first, let wid = parseWindowID(arg) else {
        print("[-] Usage: hyprmac square <window-id>")
        exit(1)
    }

    print("[+] Sending HYPR_CMD_SET_CORNER_RADIUS (0.0px) for window ID: \(wid)...")
    let bridge = HyprServerBridge.shared
    guard bridge.setupSharedMemory() else {
        print("[-] Failed to initialize shared memory at \(HyprProtocol.shmPath)")
        exit(1)
    }
    guard bridge.waitForHook(timeout: 5.0) else {
        print("[-] Failed to connect to HyprServer hook (not ready after 5.0s)")
        exit(1)
    }

    let success = bridge.setCornerRadius(windowId: wid, radius: 0.0)
    if success {
        print("[+] Successfully set 0px square corners on window \(wid)")
        exit(0)
    } else {
        print("[-] Failed to set 0px square corners on window \(wid) (timeout or hook error)")
        exit(1)
    }
}

@MainActor
func runStripShadow(args: [String]) {
    guard let arg = args.first, let wid = parseWindowID(arg) else {
        print("[-] Usage: hyprmac strip-shadow <window-id>")
        exit(1)
    }

    print("[+] Sending HYPR_CMD_SET_SHADOW_STATE (disabled) for window ID: \(wid)...")
    let bridge = HyprServerBridge.shared
    guard bridge.setupSharedMemory() else {
        print("[-] Failed to initialize shared memory at \(HyprProtocol.shmPath)")
        exit(1)
    }
    guard bridge.waitForHook(timeout: 5.0) else {
        print("[-] Failed to connect to HyprServer hook (not ready after 5.0s)")
        exit(1)
    }

    let success = bridge.setShadow(windowId: wid, enabled: false)
    if success {
        print("[+] Successfully stripped shadow on window \(wid)")
        exit(0)
    } else {
        print("[-] Failed to strip shadow on window \(wid) (timeout or hook error)")
        exit(1)
    }
}

@MainActor
func runMenuBar(args: [String]) {
    let sub = args.first?.lowercased() ?? "suppress"
    let suppress = (sub != "restore" && sub != "0" && sub != "false" && sub != "show")

    if suppress {
        FileManager.default.createFile(atPath: SessionManager.menubarSuppressionFlag, contents: nil)
        print("[+] Created menu bar suppression flag at \(SessionManager.menubarSuppressionFlag)")
    } else {
        try? FileManager.default.removeItem(atPath: SessionManager.menubarSuppressionFlag)
        print("[+] Removed menu bar suppression flag at \(SessionManager.menubarSuppressionFlag)")
    }

    print("[+] Connecting to HyprServer hook via shared memory (\(HyprProtocol.shmPath))...")
    let bridge = HyprServerBridge.shared
    guard bridge.setupSharedMemory() else {
        print("[-] Failed to initialize shared memory at \(HyprProtocol.shmPath)")
        exit(1)
    }
    guard bridge.waitForHook(timeout: 5.0) else {
        print("[-] Failed to connect to HyprServer hook (not ready after 5.0s)")
        exit(1)
    }

    do {
        let ok = try bridge.setMenuBarSuppression(suppress: suppress)
        if ok {
            print("[+] Successfully \(suppress ? "suppressed" : "restored") native menu bar reveal via compositor hook.")
            exit(0)
        } else {
            print("[-] Server rejected menu bar suppression request.")
            exit(1)
        }
    } catch {
        print("[-] Failed to set menu bar suppression: \(error)")
        exit(1)
    }
}

@MainActor
func runTestBridge() {
    print("[+] HyprMac Bridge & IPC Tests have moved to 'swift test'.")
}

@MainActor
func runProbe() {
    let allWindows = WindowDetector.shared.getVisibleWindowsFromCGList()
    guard let info = WindowDetector.shared.getFocusedWindow() ?? allWindows.first else {
        print("[-] No active on-screen window found.")
        exit(1)
    }

    let cid = SkyLightBridge.shared.mainConnectionID
    let tags = SkyLightBridge.shared.getWindowTags(windowID: info.windowID)
    let slsBounds = SkyLightBridge.shared.getWindowBounds(windowID: info.windowID)

    let tag0Str = tags.map { String(format: "0x%08X", $0.tag0) } ?? "N/A"
    let tag1Str = tags.map { String(format: "0x%08X", $0.tag1) } ?? "N/A"
    let slsBoundsStr = slsBounds.map { String(format: "(x: %.1f, y: %.1f, w: %.1f, h: %.1f)", $0.origin.x, $0.origin.y, $0.width, $0.height) } ?? "N/A"

    print("""
    ==================================================
                  HyprMac Window Probe
    ==================================================
    Application:    \(info.appName) (PID: \(info.processID))
    Window Title:   \(info.title.isEmpty ? "(untitled)" : info.title)
    Window ID:      \(info.windowID)
    CoreGraphics:   origin: (x: \(info.bounds.origin.x), y: \(info.bounds.origin.y))
                    size:   (w: \(info.bounds.width), h: \(info.bounds.height))
    AppKit Frame:   origin: (x: \(info.appkitFrame.origin.x), y: \(info.appkitFrame.origin.y))
                    size:   (w: \(info.appkitFrame.width), h: \(info.appkitFrame.height))
    SkyLight CID:   \(cid)
    SkyLight Bounds:\(slsBoundsStr)
    SkyLight Tags:  [\(tag0Str), \(tag1Str)]
    ==================================================
    """)

    if allWindows.count > 1 {
        print("Visible on-screen windows (use ID with square / strip-shadow):")
        for w in allWindows {
            let marker = (w.windowID == info.windowID) ? " -> " : "    "
            print("\(marker)ID: \(w.windowID) | App: \(w.appName) | Title: \(w.title.isEmpty ? "(untitled)" : w.title)")
        }
        print("==================================================")
    }
}

@MainActor
func runStrip() {
    if !WindowDetector.isProcessTrusted() {
        print("[!] Warning: Accessibility permissions not granted. Requesting...")
        _ = WindowDetector.isProcessTrusted(prompt: true)
    }

    guard let info = WindowDetector.shared.getFocusedWindow() else {
        print("[-] No active focused window found to strip.")
        exit(1)
    }

    let wid = info.windowID
    let beforeTags = SkyLightBridge.shared.getWindowTags(windowID: wid)
    let before0 = beforeTags.map { String(format: "0x%08X", $0.tag0) } ?? "N/A"
    let before1 = beforeTags.map { String(format: "0x%08X", $0.tag1) } ?? "N/A"

    print("[+] Targeting window \(wid) (\(info.appName): \"\(info.title)\")...")
    print("[+] Current Tags: [\(before0), \(before1)]")

    let success = SkyLightBridge.shared.stripTitlebar(windowID: wid)
    if success {
        let afterTags = SkyLightBridge.shared.getWindowTags(windowID: wid)
        let after0 = afterTags.map { String(format: "0x%08X", $0.tag0) } ?? "N/A"
        let after1 = afterTags.map { String(format: "0x%08X", $0.tag1) } ?? "N/A"
        print("[+] SkyLight stripTitlebar applied successfully.")
        print("[+] Updated Tags: [\(after0), \(after1)]")
    } else {
        print("[-] Failed to apply SkyLight stripTitlebar to window \(wid).")
        exit(1)
    }
}

@MainActor
func getEligibleUserWindows(
    in screenBounds: CGRect,
    excludingPIDs: Set<pid_t> = [getpid()],
    windowListSnapshot: [[String: Any]]? = nil
) -> [(windowID: CGWindowID, pid: pid_t, appName: String, title: String, bounds: CGRect, bundleID: String)] {
    return WindowDetector.shared.getEligibleWindows(in: screenBounds, excludingPIDs: excludingPIDs, windowListSnapshot: windowListSnapshot).map {
        ($0.windowID, $0.processID, $0.appName, $0.title, $0.bounds, $0.bundleID)
    }
}

@MainActor
func computeTilingBounds(bar: HyprBarWindow? = nil) -> CGRect {
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
func runTile() {
    if !WindowDetector.isProcessTrusted() {
        print("[!] Warning: Accessibility permissions not granted. Requesting...")
        _ = WindowDetector.isProcessTrusted(prompt: true)
    }

    let screenBounds = computeTilingBounds()
    guard screenBounds.width > 0 && screenBounds.height > 0 else {
        print("[-] No valid display bounds found to tile.")
        return
    }

    print(String(format: "[+] Current Monitor Usable Bounds: (x: %.1f, y: %.1f, w: %.1f, h: %.1f)", screenBounds.origin.x, screenBounds.origin.y, screenBounds.width, screenBounds.height))

    let userWindows = getEligibleUserWindows(in: screenBounds, excludingPIDs: [getpid()])

    guard !userWindows.isEmpty else {
        print("[-] No eligible user application windows found on the current screen to tile.")
        return
    }

    print("[+] Detected \(userWindows.count) user window(s) to tile:")
    for w in userWindows {
        let titleDesc = w.title.isEmpty ? "<no title>" : "\"\(w.title)\""
        print("    • [ID: \(w.windowID)] \(w.appName): \(titleDesc)")
    }

    let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
    let windowIDs = userWindows.map { $0.windowID }
    let frames = engine.tileWindows(windowIDs: windowIDs, in: screenBounds)

    print("\n[+] Computed Dwindle Layout Frames:")
    for wid in windowIDs {
        if let f = frames[wid] {
            print(String(format: "    • Window %u -> (x: %.1f, y: %.1f, w: %.1f, h: %.1f)", wid, f.origin.x, f.origin.y, f.width, f.height))
        }
    }

    print("[+] Applying layout to macOS WindowServer...")
    engine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
    print("[+] Dwindle layout successfully applied to all windows.")
}

@MainActor
func runTestDwindle() {
    print("[+] HyprMac Dwindle Tests have moved to 'swift test'.")
}

@MainActor
func runTestConfig() {
    print("[+] HyprMac Config Parser Tests have moved to 'swift test'.")
}

@MainActor
func runTestKeys() {
    print("[+] HyprMac Keybind Manager Tests have moved to 'swift test'.")
}

@MainActor
func runParseConfig(path: String?) {
    let config: HyprConfig
    if let path = path {
        print("[+] Parsing Hyprland configuration from \(path)...")
        config = ConfigParser.parseFile(atPath: path)
    } else {
        print("[+] No file specified. Parsing built-in Hyprland sample configuration...")
        let sample = """
        # HyprMac Default Sample Config
        $mainMod = SUPER
        $terminal = Ghostty
        $fileManager = Finder

        general {
            gaps_in = 8
            gaps_out = 16
            border_size = 2
            col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
            col.inactive_border = rgba(595959aa)
            layout = dwindle
        }

        decoration {
            rounding = 12
        }

        bind = $mainMod, Q, exec, $terminal
        bind = $mainMod, C, killactive
        bind = CTRL $mainMod, Q, exit
        bind = $mainMod, E, exec, $fileManager
        bind = $mainMod, V, togglefloating
        bind = $mainMod, 1, workspace, 1
        bind = $mainMod, 2, workspace, 2
        """
        config = ConfigParser.parse(text: sample)
    }

    print("[+] HyprMac Parsed Configuration:")
    print("    • Gaps: in=\(config.gapsIn) pt, out=\(config.gapsOut) pt")
    print("    • Border Size: \(config.borderSize) px")
    print("    • Rounding: \(config.rounding) pt")
    print("    • Layout: \(config.layout)")
    print("    • Active Opacity: \(config.windowOpacity)")
    print("    • Inactive Opacity: \(config.inactiveOpacity)")
    print("    • Blur: enabled=\(config.blurEnabled), radius=\(config.blurRadius) pt")
    print("    • Total Bindings: \(config.bindings.count)")
    for (idx, b) in config.bindings.enumerated() {
        print("      [\(idx + 1)] mod: '\(b.mod)' | key: '\(b.key)' | dispatcher: '\(b.dispatcher)' | args: '\(b.args)'")
    }
}


@MainActor
func runTestBar() {
    print("[+] HyprMac HyprBar Tests have moved to 'swift test'.")
}

@MainActor
func runTestSession() {
    print("[+] HyprMac Session Manager Tests have moved to 'swift test'.")
}

@MainActor
func runTestWorkspace() {
    print("[+] HyprMac Workspace Manager Tests have moved to 'swift test'.")
}

@MainActor
func runBarDaemon() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let bar = HyprBarWindow()
    HyprBarWindow.shared = bar
    let defaultHyprConf = NSString(string: "~/.config/hypr/hyprland.conf").expandingTildeInPath
    if FileManager.default.fileExists(atPath: defaultHyprConf) {
        let cfg = ConfigParser.parseFile(atPath: defaultHyprConf)
        bar.barView.barColors = cfg.barColors
        bar.barView.applyTheme()
    }
    NotificationCenterManager.shared.start()
    bar.showBar()
    print("""
    [HyprMac] Native Waybar / HyprBar Active on Top Screen
    [HyprMac] Workspaces: [1..6] | Clock | Battery | Active Window
    [HyprMac] Press Ctrl+C to terminate.
    """)

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler {
        print("\n[HyprMac] Closing HyprBar...")
        bar.hideBar()
        exit(0)
    }
    sigintSource.resume()

    final class BarDaemonController: @unchecked Sendable {
        var lastWid: CGWindowID = 0
        var lastTitle: String = ""
        let bar: HyprBarWindow

        init(bar: HyprBarWindow) {
            self.bar = bar
        }

        @MainActor
        func update() {
            if let focused = WindowDetector.shared.getFocusedWindow() {
                if focused.windowID != lastWid || focused.title != lastTitle {
                    lastWid = focused.windowID
                    lastTitle = focused.title
                    bar.updateActiveWindow(title: focused.title, app: focused.appName)
                }
            }
        }
    }

    let controller = BarDaemonController(bar: bar)
    let axObserver = AXEventObserver()
    axObserver.onTitleChanged = { controller.update() }
    axObserver.onFocusedWindowChanged = { controller.update() }

    // Initial update & attach Accessibility observer to active application
    controller.update()
    if let frontApp = NSWorkspace.shared.frontmostApplication {
        axObserver.observe(pid: frontApp.processIdentifier)
    }

    // Event-driven active window updates on application activation
    _ = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
    ) { notif in
        let activatedApp = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let activatedPid = activatedApp?.processIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        MainActor.assumeIsolated {
            controller.update()
            if let pid = activatedPid {
                axObserver.observe(pid: pid)
            }
        }
    }

    app.run()
}

@MainActor
func runSessionCommand(subcmd: String?) {
    let mgr = SessionManager.shared
    let current = mgr.getCurrentMode()

    switch subcmd ?? "status" {
    case "status":
        print("""
        ==================================================
                      HyprMac Session Status
        ==================================================
        Active Mode:    \(current.displayName) (\(current.rawValue))
        Native MenuBar: \(current == .hyprMac ? "Hidden (Auto-hide)" : "Visible (Stock)")
        Dock Autohide:  \(current == .hyprMac ? "Enabled (HyprMac)" : "Standard (Stock)")
        Config Path:    ~/.config/hypr/session.json
        ==================================================
        """)
    case "switch", "toggle":
        let newMode = mgr.toggleSession()
        print("[+] Session switched in 0.5s to: \(newMode.displayName) (Mode: \(newMode.rawValue))")
    case "hypr", "hyprmac":
        let ok = mgr.switchTo(mode: .hyprMac)
        print("[+] Switched to HyprMac: \(ok ? "SUCCESS" : "FAILED")")
    case "aqua", "stock", "regular":
        let ok = mgr.switchTo(mode: .aqua)
        print("[+] Switched to macOS Aqua (Stock): \(ok ? "SUCCESS" : "FAILED")")
    default:
        print("[-] Unknown session subcommand: '\(subcmd ?? "")'. Use status, switch, hypr, or aqua.")
    }
}


@MainActor
func runIntegratedDaemon(configPath: String?) {
    // Ensure single instance daemon execution via exclusive file lock
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

    if !WindowDetector.isProcessTrusted() {
        print("[!] Warning: Accessibility permissions required. Requesting...")
        _ = WindowDetector.isProcessTrusted(prompt: true)
    }

    let config: HyprConfig
    let defaultHyprConf = NSString(string: "~/.config/hypr/hyprland.conf").expandingTildeInPath

    if let path = configPath {
        print("[HyprMac] Loading user configuration from: \(path)")
        config = ConfigParser.parseFile(atPath: path)
    } else if FileManager.default.fileExists(atPath: defaultHyprConf) {
        print("[HyprMac] Found local dotfile: \(defaultHyprConf)")
        config = ConfigParser.parseFile(atPath: defaultHyprConf)
    } else {
        print("[HyprMac] No custom config found. Running with default Hyprland profile.")
        config = HyprConfig()
    }

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

    let app = NSApplication.shared
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
    let bar = HyprBarWindow()
    HyprBarWindow.shared = bar
    bar.barView.barColors = config.barColors
    NotificationCenterManager.shared.start()
    bar.showBar()
    _ = try? HyprServerBridge.shared.setMenuBarSuppression(suppress: true, exemptWid: UInt32(bar.windowNumber))

    // 3. Compositor Effects Manager setup (Opacity & Backdrop Blur)
    let effectsManager = CompositorEffectsManager.shared

    // 3b. Auto-tiling Dwindle Engine setup (Decoupled from transient Z-order)
    let dwindleEngine = DwindleEngine(gapsIn: config.gapsIn, gapsOut: config.gapsOut)

    // 3c. Virtual Workspaces Manager (Single Source of Truth for workspaces 1..9)
    let workspaceManager = WorkspaceManager.shared
    workspaceManager.dwindleEngine = dwindleEngine
    workspaceManager.borderManager = effectsManager
    workspaceManager.boundsProvider = { computeTilingBounds() }

    // 3d. Hyprland-identical window animation subsystem
    let animationEngine = AnimationEngine.shared
    animationEngine.config = config

    final class TransitionTracker: @unchecked Sendable {
        var lastWorkspaceSwitchTime: TimeInterval = 0
    }
    let transitionTracker = TransitionTracker()

    workspaceManager.onWorkspaceChange = { ws in
        transitionTracker.lastWorkspaceSwitchTime = ProcessInfo.processInfo.systemUptime
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                bar.updateActiveWorkspace(ws)
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    bar.updateActiveWorkspace(ws)
                }
            }
        }
    }

    // 4. Initialize Keybinds
    let keyManager = KeybindManager.shared
    keyManager.register(bindings: config.bindings)

    workspaceManager.isFloating = { [weak keyManager] wid in
        keyManager?.isFloating(windowID: wid) ?? false
    }
    workspaceManager.isFullscreen = { [weak keyManager] wid in
        keyManager?.isFullscreen(windowID: wid) ?? false
    }
    dwindleEngine.isFullscreen = { [weak keyManager] wid in
        keyManager?.isFullscreen(windowID: wid) ?? false
    }

    let stateStore = WindowStateStore.shared

    let applyWindowRulesToWindow: @MainActor (CGWindowID, pid_t, String, String, String, CGRect, Bool) -> Void = { wid, pid, appName, bundleID, title, bounds, isNewWindow in
        let isFloating = keyManager.isFloating(windowID: wid) || workspaceManager.isPinned(wid)
        let currentWs = workspaceManager.workspace(for: wid) ?? workspaceManager.activeWorkspace
        let tilingBounds = computeTilingBounds()

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
                        bar.updateActiveWorkspace(num)
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

    let applyDecorationsToWindow: @MainActor (CGWindowID) -> Void = { wid in
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

    let handleUnminimize: @MainActor (CGWindowID, pid_t?) -> Void = { wid, pid in
        guard wid > 0 else { return }
        let tilingBounds = computeTilingBounds()
        workspaceManager.assignWindow(wid: wid, to: workspaceManager.activeWorkspace, pid: pid)
        workspaceManager.setWindowMinimized(wid, minimized: false)
        if !keyManager.isFloating(windowID: wid) && config.layout.lowercased() == "dwindle" {
            dwindleEngine.addWindow(windowID: wid, in: tilingBounds)
            if !stateStore.isStripped(wid) {
                applyDecorationsToWindow(wid)
            }
            dwindleEngine.applyToSystem(windowFrames: dwindleEngine.currentFrames(), bridge: SkyLightBridge.shared)
        }
        workspaceManager.focusWindow(wid: wid)
        let f = WindowDetector.shared.getFocusedWindow()
        effectsManager.update(focused: f, managedFrames: dwindleEngine.currentFrames(), config: config)
        if let focused = f {
            bar.updateActiveWindow(title: focused.title, app: focused.appName)
        }
    }

    let handleAutoSwitchWorkspace: @MainActor (CGWindowID, Int, String, String) -> Void = { wid, targetWS, appName, title in
        guard wid > 0, targetWS >= 1 && targetWS <= 9, targetWS != workspaceManager.activeWorkspace else { return }
        workspaceManager.switchToWorkspace(targetWS)
        workspaceManager.focusWindow(wid: wid)
        bar.updateActiveWorkspace(targetWS)
        if !title.isEmpty {
            bar.updateActiveWindow(title: title, app: appName)
        }
    }

    final class NotificationTokenHolder: @unchecked Sendable {
        var token: (any NSObjectProtocol)?
    }
    let activationObserverHolder = NotificationTokenHolder()

    // Restore any orphaned parked windows from prior daemon crashes or restarts
    let startupTilingBounds = computeTilingBounds()
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

    // Auto-tile on startup if layout is dwindle
    if config.layout.lowercased() == "dwindle" {
        let tilingBounds = computeTilingBounds()
        let eligibleWindows = getEligibleUserWindows(in: tilingBounds, excludingPIDs: [getpid()])
        let currentIDs = eligibleWindows.map { $0.windowID }
        if !currentIDs.isEmpty {
            for w in eligibleWindows {
                let isNew = !stateStore.isRuleEvaluated(w.windowID)
                if isNew {
                    applyWindowRulesToWindow(w.windowID, w.pid, w.appName, w.bundleID, w.title, w.bounds, true)
                }
                workspaceManager.assignWindowIfNeeded(wid: w.windowID, pid: w.pid)
                if !stateStore.isStripped(w.windowID) {
                    applyDecorationsToWindow(w.windowID)
                }
            }
            let activeIDs = workspaceManager.activeWindowIDs()
            let activeTiledIDs = activeIDs.filter { !keyManager.isFloating(windowID: $0) && !workspaceManager.isPinned($0) }
            let frames = dwindleEngine.tileWindows(windowIDs: activeTiledIDs, in: tilingBounds)
            dwindleEngine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
        }
    }



    keyManager.onSwapWindow = { [weak dwindleEngine] widA, widB in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let engine = dwindleEngine else { return }
                let tilingBounds = computeTilingBounds()
                let frames = engine.swapWindows(windowA: widA, windowB: widB, in: tilingBounds)
                engine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
            }
        }
    }

    keyManager.onToggleFloating = { [weak dwindleEngine, weak workspaceManager, weak effectsManager, weak keyManager] wid, isFloating in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let engine = dwindleEngine, let wsMgr = workspaceManager, let eMgr = effectsManager, let km = keyManager else { return }
                let tilingBounds = computeTilingBounds()
                let activeIDs = wsMgr.activeWindowIDs()
                let activeTiledIDs = activeIDs.filter { !km.isFloating(windowID: $0) }
                let frames = engine.tileWindows(windowIDs: activeTiledIDs, in: tilingBounds)
                engine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                if isFloating {
                    eMgr.hideOverlay(for: wid)
                }
                let f = WindowDetector.shared.getFocusedWindow()
                eMgr.update(focused: f, managedFrames: engine.currentFrames(), config: config)
            }
        }
    }

    keyManager.onFullscreenToggle = { [weak dwindleEngine, weak workspaceManager, weak effectsManager, weak keyManager] wid, isFullscreen, savedFrame in
        MainActor.assumeIsolated {
            guard let engine = dwindleEngine, let wsMgr = workspaceManager, let eMgr = effectsManager, let km = keyManager else { return }
            let tilingBounds = computeTilingBounds()
            let activeIDs = wsMgr.activeWindowIDs()

            SkyLightBridge.shared.disableUpdate()
            defer { SkyLightBridge.shared.reenableUpdate() }

            if isFullscreen {
                let fullBounds = computeTilingBounds()
                let curBounds = savedFrame ?? engine.currentFrames()[wid] ?? WindowDetector.shared.fastFocusedWindow()?.bounds ?? WindowDetector.shared.getWindowBounds(windowID: wid) ?? fullBounds
                wsMgr.setStoredFrame(fullBounds, for: wid)

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
                ) { _ in
                    let f = WindowDetector.shared.getFocusedWindow()
                    eMgr.update(focused: f, managedFrames: engine.currentFrames(), config: config)
                }
            } else {
                // Restoring from fullscreen: recompute tiling with all active windows restored
                let allTiledIDs = activeIDs.filter { !km.isFloating(windowID: $0) }
                let frames = engine.tileWindows(windowIDs: allTiledIDs, in: tilingBounds)
                let fullBounds = computeTilingBounds()
                let targetFrame: CGRect

                if km.isFloating(windowID: wid) {
                    targetFrame = savedFrame ?? km.getStoredFullscreenFrame(wid) ?? tilingBounds
                } else if let targetTile = frames[wid] {
                    targetFrame = targetTile
                } else {
                    targetFrame = savedFrame ?? tilingBounds
                }
                wsMgr.setStoredFrame(targetFrame, for: wid)

                // 1. Apply physical frame for wid back to its tiled frame
                WindowDetector.shared.setWindowFrame(windowID: wid, frame: targetFrame)

                // 2. For remaining windows: only write frame if their layout slot physically changed
                var otherFrames = frames
                otherFrames.removeValue(forKey: wid)
                for (otherWid, otherFrame) in otherFrames {
                    let curFrame = engine.currentFrames()[otherWid] ?? wsMgr.storedFrame(for: otherWid)
                    if curFrame != otherFrame {
                        wsMgr.setStoredFrame(otherFrame, for: otherWid)
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
                ) { _ in
                    let f = WindowDetector.shared.getFocusedWindow()
                    eMgr.update(focused: f, managedFrames: engine.currentFrames(), config: config)
                }
            }
        }
    }

    keyManager.onMoveToWorkspace = { [weak workspaceManager] wid, _ in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let wsMgr = workspaceManager else { return }
                bar.updateActiveWorkspace(wsMgr.activeWorkspace)
            }
        }
    }

    keyManager.onWindowMinimize = { [weak dwindleEngine, weak effectsManager] wid in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let engine = dwindleEngine else { return }
                let tilingBounds = computeTilingBounds()
                let frames = engine.removeWindow(windowID: wid, in: tilingBounds)
                engine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                effectsManager?.hideOverlay(for: wid)
            }
        }
    }

    keyManager.onWindowClose = { [weak dwindleEngine, weak effectsManager] wid in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let engine = dwindleEngine else { return }
                let tilingBounds = computeTilingBounds()
                let frames = engine.removeWindow(windowID: wid, in: tilingBounds)
                engine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                effectsManager?.hideOverlay(for: wid)
            }
        }
    }

    keyManager.onToggleSplit = { [weak dwindleEngine] in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let engine = dwindleEngine else { return }
                let tilingBounds = computeTilingBounds()
                let frames = engine.toggleSplit(in: tilingBounds)
                engine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
            }
        }
    }

    keyManager.onResizeWindow = { [weak dwindleEngine] delta in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let engine = dwindleEngine else { return }
                let tilingBounds = computeTilingBounds()
                let frames = engine.adjustSplitRatio(delta: delta, in: tilingBounds)
                engine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
            }
        }
    }

    keyManager.onReloadConfig = { [weak keyManager, weak bar] in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let km = keyManager else { return }
                let confPath = configPath ?? defaultHyprConf
                guard FileManager.default.fileExists(atPath: confPath) else {
                    print("[HyprMac] Config file not found at \(confPath)")
                    return
                }
                print("[HyprMac] Hot-reloading configuration from \(confPath)...")
                let newConfig = ConfigParser.parseFile(atPath: confPath)
                stateStore.evaluatedRuleWindows.removeAll()
                animationEngine.config = newConfig
                bar?.barView.barColors = newConfig.barColors
                ClientDecorationLoader.shared.ignoredApps = newConfig.ignoredClientApps
                km.clearBindings()
                km.register(bindings: newConfig.bindings)
                print("[HyprMac] Successfully reloaded \(newConfig.bindings.count) bindings from \(confPath)")
            }
        }
    }

    keyManager.start()

    // 4b. Native Kernel-Level Event-Driven Wallpaper & Theming Watcher (FSEvents)
    let watcher = WallpaperWatcher.shared
    watcher.onThemeReload = {
        let confPath = configPath ?? NSString(string: "~/.config/hypr/hyprland.conf").expandingTildeInPath
        if FileManager.default.fileExists(atPath: confPath) {
            let newConfig = ConfigParser.parseFile(atPath: confPath)
            animationEngine.config = newConfig
            bar.barView.barColors = newConfig.barColors
            ClientDecorationLoader.shared.ignoredApps = newConfig.ignoredClientApps
            bar.barView.applyTheme()
            let f = WindowDetector.shared.getFocusedWindow()
            effectsManager.update(focused: f, managedFrames: dwindleEngine.currentFrames(), config: newConfig)
            print("[HyprMac] Dynamic theme & border colors reloaded from \(confPath)")
        }
    }
    watcher.start()

    // 5. Setup graceful shutdown handlers (SIGINT and SIGTERM)
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    final class MouseStateHolder: @unchecked Sendable {
        var isMouseDown: Bool = false
        var global: Any?
        var local: Any?
    }
    let mouseState = MouseStateHolder()

    let cleanupAndExit: @Sendable () -> Void = {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                print("\n[HyprMac] Gracefully shutting down...")
                ClientDecorationLoader.shared.stop()
                WallpaperWatcher.shared.stop()
                NotificationCenterManager.shared.stop()
                AXProcessObserverPool.shared.stop()
                if let token = activationObserverHolder.token {
                    NSWorkspace.shared.notificationCenter.removeObserver(token)
                }
                if let m = mouseState.global {
                    NSEvent.removeMonitor(m)
                    mouseState.global = nil
                }
                if let m = mouseState.local {
                    NSEvent.removeMonitor(m)
                    mouseState.local = nil
                }
                bar.hideBar()
                effectsManager.hideAll()
                animationEngine.cancelAll()
                keyManager.stop()
                KeybindManager.shared.isMenuBarSuppressed = false
                unlink("/tmp/hyprmac.pid")
                unlink("/tmp/hyprmac.lock")
                close(lockFd)
                print("[HyprMac] Restoring stock macOS Aqua desktop...")
                let allScreens = HiddenWindowPlacement.allCGScreens()
                for wid in workspaceManager.windowOrder {
                    if let bounds = WindowDetector.shared.getWindowBounds(windowID: wid),
                       HiddenWindowPlacement.isParkedOrHidden(bounds, screens: allScreens) {
                        _ = workspaceManager.restoreWindow(wid: wid)
                    }
                }
                _ = try? HyprServerBridge.shared.setMenuBarSuppression(suppress: false)
                _ = SessionManager.shared.switchTo(mode: .aqua)
                print("[HyprMac] Restored. Goodbye!")
                exit(0)
            }
        }
    }

    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler(handler: cleanupAndExit)
    sigintSource.resume()

    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler(handler: cleanupAndExit)
    sigtermSource.resume()

    keyManager.onExit = cleanupAndExit

    // 6. Reactive event-driven tracking (Zero 60Hz polling, 100% idle sleep)
    var lastWid: CGWindowID = 0
    var lastFrame: NSRect = .zero
    var lastTitle: String = ""

    // Dedicated focus & borders update routine
    let updateFocusAndBorders: @MainActor (Bool) -> Void = { forceUpdate in
        let barWid = CGWindowID(bar.windowNumber)
        let rawFocused = WindowDetector.shared.getFocusedWindow()
        let isBarOrBorder = rawFocused != nil && (rawFocused!.windowID == barWid)
        let isParked = rawFocused != nil && HiddenWindowPlacement.isParkedOrHidden(rawFocused!.bounds)
        let focusedCandidate = (isBarOrBorder || isParked) ? nil : rawFocused

        let now = ProcessInfo.processInfo.systemUptime
        let lastSwitch = max(transitionTracker.lastWorkspaceSwitchTime, workspaceManager.lastWorkspaceSwitchTime)
        let isSettleWindow = (now - lastSwitch) < 0.500 || workspaceManager.isSwitchInProgress(settleInterval: 0.500)

        // Unminimize to active workspace if a window was unminimized
        if let fc = focusedCandidate, !isSettleWindow {
            let wid = fc.windowID
            let pid = fc.processID
            let wasMin = workspaceManager.isMinimized(wid)
            let isMin = WindowDetector.shared.isWindowMinimized(windowID: wid, pid: pid)

            if wasMin && !isMin {
                handleUnminimize(wid, pid)
            }
        }

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
    }

    // On-demand window reconciliation
    let reconcileWindows: @MainActor (Bool) -> Void = { forceRetile in
        let now = ProcessInfo.processInfo.systemUptime
        let lastSwitch = max(transitionTracker.lastWorkspaceSwitchTime, workspaceManager.lastWorkspaceSwitchTime)
        let isSettleWindow = (now - lastSwitch) < 0.500 || workspaceManager.isSwitchInProgress(settleInterval: 0.500)
        guard !isSettleWindow else { return }
        guard config.layout.lowercased() == "dwindle" else { return }

        AXProcessObserverPool.shared.isSuppressingTilingEvents = true
        defer { AXProcessObserverPool.shared.isSuppressingTilingEvents = false }

        var framesChanged = false
        let tilingBounds = computeTilingBounds()

        // Unpark any orphaned windows alive in WindowServer that are not tracked in an inactive workspace
        let snapshot = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
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
        let eligibleWindows = getEligibleUserWindows(in: tilingBounds, excludingPIDs: [getpid()], windowListSnapshot: snapshot)
        let currentIDs = eligibleWindows.map { $0.windowID }

        // Auto-assign any newly discovered window to active workspace with PID
        for w in eligibleWindows {
            let isNew = !stateStore.isRuleEvaluated(w.windowID)
            if isNew {
                applyWindowRulesToWindow(w.windowID, w.pid, w.appName, w.bundleID, w.title, w.bounds, true)
            }
            if workspaceManager.workspace(for: w.windowID) == nil {
                workspaceManager.assignWindow(wid: w.windowID, to: workspaceManager.activeWorkspace, pid: w.pid)
            } else {
                workspaceManager.assignWindowIfNeeded(wid: w.windowID, pid: w.pid)
            }
            if !stateStore.isStripped(w.windowID) {
                applyDecorationsToWindow(w.windowID)
            }
        }

        // Check minimization status for each managed window in workspaceManager
        var minimizedChanged = false
        for wid in workspaceManager.windowOrder {
            let pid = workspaceManager.getPID(for: wid)
            let wasMinimized = workspaceManager.isMinimized(wid)
            let isMin = WindowDetector.shared.isWindowMinimized(windowID: wid, pid: pid)
            if isMin {
                workspaceManager.setWindowMinimized(wid, minimized: true)
                if dwindleEngine.managedWindowSet.contains(wid) {
                    dwindleEngine.removeWindow(windowID: wid, in: tilingBounds)
                    effectsManager.hideOverlay(for: wid)
                    minimizedChanged = true
                }
            } else if wasMinimized && !isMin {
                handleUnminimize(wid, pid)
                framesChanged = true
                minimizedChanged = true
            } else {
                workspaceManager.setWindowMinimized(wid, minimized: false)
            }
        }

        // Query all physical windows alive in macOS WindowServer
        let allAliveWindowIDs = WindowDetector.shared.getAllAliveWindowIDs(fromSnapshot: snapshot)
        WindowDetector.shared.pruneCache(aliveWindowIDs: allAliveWindowIDs)
        stateStore.prune(aliveWindowIDs: allAliveWindowIDs)

        // Purge dead windows across all workspaces
        for wid in workspaceManager.windowOrder {
            if !allAliveWindowIDs.contains(wid) {
                workspaceManager.removeWindow(wid: wid)
                dwindleEngine.removeWindow(windowID: wid, in: tilingBounds)
                effectsManager.hideOverlay(for: wid)
                WindowDetector.shared.invalidateWindow(windowID: wid)
            }
        }
        stateStore.strippedWindows.formIntersection(allAliveWindowIDs)

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
                    applyDecorationsToWindow(wid)
                }
            }

            let frames = dwindleEngine.currentFrames()
            dwindleEngine.applyToSystem(windowFrames: frames, newlyAddedWindows: openedWindows, bridge: SkyLightBridge.shared)
            framesChanged = true
        }

        // Reconcile frames if shifted
        let snapped = dwindleEngine.reconcileFrames(
            threshold: 2.0,
            isFloating: { keyManager.isFloating(windowID: $0) || keyManager.isFullscreen(windowID: $0) },
            boundsProvider: { WindowDetector.shared.getWindowBounds(windowID: $0, pid: workspaceManager.getPID(for: $0)) },
            frameSetter: { wid, frame in
                let pid = workspaceManager.getPID(for: wid)
                _ = WindowDetector.shared.setWindowFrame(windowID: wid, frame: frame, pid: pid)
            }
        )
        if !snapped.isEmpty {
            framesChanged = true
        }

        updateFocusAndBorders(framesChanged)
    }

    // Auto-switch workspace on external application activation (Dock, Cmd+Tab, Finder)
    activationObserverHolder.token = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
    ) { notif in
        let activatedApp = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let activatedPid = activatedApp?.processIdentifier
        let bundleId = activatedApp?.bundleIdentifier
        MainActor.assumeIsolated {
            // Guard against switch in progress or within 500ms settle window:
            // internal activations from switchToWorkspace must never trigger an auto-switch or re-suppression.
            if workspaceManager.isSwitchInProgress(settleInterval: 0.500) {
                return
            }

            guard let pid = activatedPid, pid > 0, pid != getpid() else { return }

            // When Finder activates (e.g. clicking the empty desktop), ensure menubar suppression is active asynchronously without blocking the main thread
            if bundleId == "com.apple.finder" && SessionManager.shared.getCurrentMode() == .hyprMac {
                if !KeybindManager.shared.isMenuBarSuppressed {
                    let barWid = UInt32(HyprBarWindow.shared?.windowNumber ?? bar.windowNumber)
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
            _ = WindowDetector.shared.getFocusedWindow()

            // 1. Check if any window belonging to the activated application unminimized
            for wid in workspaceManager.windowOrder where workspaceManager.getPID(for: wid) == pid {
                if workspaceManager.isMinimized(wid) && !WindowDetector.shared.isWindowMinimized(windowID: wid, pid: pid) {
                    handleUnminimize(wid, pid)
                    return
                }
            }

            // 2. Inspect windows belonging to this activated application PID
            let appWindows = workspaceManager.windowOrder.filter { workspaceManager.getPID(for: $0) == pid }
            guard !appWindows.isEmpty else {
                reconcileWindows(false)
                return
            }

            // If that PID already has an active, non-parked window on activeWorkspace, do NOT switch workspaces.
            let activeWorkspace = workspaceManager.activeWorkspace
            let windowsOnCurrentWS = appWindows.filter { workspaceManager.workspace(for: $0) == activeWorkspace }
            for wid in windowsOnCurrentWS where !workspaceManager.isMinimized(wid) {
                if let bounds = WindowDetector.shared.getWindowBounds(windowID: wid, pid: pid) {
                    if !HiddenWindowPlacement.isParkedOrHidden(bounds) {
                        reconcileWindows(false)
                        return
                    }
                } else {
                    reconcileWindows(false)
                    return
                }
            }

            // Only switch if all windows for that activated PID belong to another workspace targetWS != activeWorkspace
            let targetWorkspaces = Set(appWindows.compactMap { workspaceManager.workspace(for: $0) })
            guard !targetWorkspaces.isEmpty else {
                reconcileWindows(false)
                return
            }

            if targetWorkspaces.contains(activeWorkspace) {
                reconcileWindows(false)
                return
            }

            guard targetWorkspaces.count == 1, let targetWS = targetWorkspaces.first, targetWS != activeWorkspace else {
                return
            }

            // Resolve target window to focus on targetWS
            let targetWid = workspaceManager.lastFocused(for: targetWS) ?? appWindows.first(where: { workspaceManager.workspace(for: $0) == targetWS }) ?? appWindows.first
            guard let wid = targetWid else { return }

            let appName = activatedApp?.localizedName ?? WindowDetector.shared.getWindowTitle(windowID: wid, pid: pid) ?? "App"
            let title = WindowDetector.shared.getWindowTitle(windowID: wid, pid: pid) ?? ""

            handleAutoSwitchWorkspace(wid, targetWS, appName, title)
        }
    }

    // Mouse drag tracking & snap-back state via event monitoring (zero 60Hz HID polling)
    var draggedWid: CGWindowID? = nil
    var dragStartFrame: CGRect? = nil
    var dragStartMousePoint: NSPoint? = nil
    var isDragging: Bool = false

    let handleMouseEvent: @MainActor (NSEvent) -> Void = { event in
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
                        let tilingBounds = computeTilingBounds()
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
                updateFocusAndBorders(false)
            }
            draggedWid = nil
            dragStartFrame = nil
            dragStartMousePoint = nil
            isDragging = false

        default:
            break
        }
    }

    mouseState.global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
        MainActor.assumeIsolated {
            handleMouseEvent(event)
        }
    }
    mouseState.local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
        MainActor.assumeIsolated {
            handleMouseEvent(event)
        }
        return event
    }

    // 7. Start reactive Accessibility Observer Pool (Multi-Process)
    let axPool = AXProcessObserverPool.shared
    axPool.onTilingLayoutDirty = {
        reconcileWindows(false)
    }
    axPool.onFocusedWindowChanged = { _ in
        if let focused = WindowDetector.shared.getFocusedWindow(),
           !dwindleEngine.managedWindowSet.contains(focused.windowID),
           !keyManager.isFloating(windowID: focused.windowID),
           focused.windowID != CGWindowID(bar.windowNumber) {
            reconcileWindows(false)
        } else {
            updateFocusAndBorders(false)
        }
    }
    axPool.onTitleChanged = { _ in
        if let focused = WindowDetector.shared.getFocusedWindow() {
            applyWindowRulesToWindow(focused.windowID, focused.processID, focused.appName, focused.bundleID, focused.title, focused.bounds, false)
        }
        updateFocusAndBorders(false)
    }
    axPool.onWindowMiniaturized = { _ in
        reconcileWindows(false)
    }
    axPool.onWindowDeminiaturized = { _ in
        reconcileWindows(false)
    }
    axPool.start()

    // Initial focus & borders sync
    updateFocusAndBorders(false)

    app.run()
}

MainActor.assumeIsolated {
    setlinebuf(stdout)
    _ = CGSetLocalEventsSuppressionInterval(0.0)
    SkyLightBridge.shared.setLocalEventsSuppressionInterval(0.0)

    let args = CommandLine.arguments.dropFirst()
    let command = args.first ?? "help"

    switch command {
    case "probe":
        runProbe()
    case "daemon", "start":
        runIntegratedDaemon(configPath: args.dropFirst().first)
    case "strip":
        runStrip()
    case "tile":
        runTile()
    case "test-config":
        runTestConfig()
    case "test-keys":
        runTestKeys()
    case "test-bar":
        runTestBar()
    case "test-session":
        runTestSession()
    case "bar":
        runBarDaemon()
    case "session":
        runSessionCommand(subcmd: args.dropFirst().first)
    case "parse-config":
        runParseConfig(path: args.dropFirst().first)
    case "test-dwindle":
        runTestDwindle()
    case "test-workspace":
        runTestWorkspace()
    case "server-status":
        runServerStatus()
    case "square":
        runSquare(args: Array(args.dropFirst()))
    case "strip-shadow":
        runStripShadow(args: Array(args.dropFirst()))
    case "test-bridge":
        runTestBridge()
    case "menubar":
        runMenuBar(args: Array(args.dropFirst()))
    case "launcher", "rofi":
        runRofiLauncher(args: Array(args.dropFirst()))
    case "powermenu", "wlogout":
        runWlogoutMenu(args: Array(args.dropFirst()))
    case "wallpaper", "gallery":
        runWallpaperGallery(args: Array(args.dropFirst()))
    case "test-watcher":
        print("[+] HyprMac WallpaperWatcher Tests have moved to 'swift test'.")
        exit(0)
    case "help", "--help", "-h":
        printUsage()
    default:
        print("[-] Unknown command: '\(command)'")
        printUsage()
        exit(1)
    }
}
