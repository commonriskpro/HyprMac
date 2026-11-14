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
func runTestBridge() { print("[+] HyprMac Bridge & IPC Tests have moved to 'swift test'.") }

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
func runTile() {
    if !WindowDetector.isProcessTrusted() {
        print("[!] Warning: Accessibility permissions not granted. Requesting...")
        _ = WindowDetector.isProcessTrusted(prompt: true)
    }

    let screenBounds = CompositorDaemon.computeTilingBounds()
    guard screenBounds.width > 0 && screenBounds.height > 0 else {
        print("[-] No valid display bounds found to tile.")
        return
    }

    print(String(format: "[+] Current Monitor Usable Bounds: (x: %.1f, y: %.1f, w: %.1f, h: %.1f)", screenBounds.origin.x, screenBounds.origin.y, screenBounds.width, screenBounds.height))

    let userWindows = CompositorDaemon.getEligibleUserWindows(in: screenBounds, excludingPIDs: [getpid()])

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
func runTestDwindle() { print("[+] HyprMac Dwindle Tests have moved to 'swift test'.") }

@MainActor
func runTestConfig() { print("[+] HyprMac Config Parser Tests have moved to 'swift test'.") }

@MainActor
func runTestKeys() { print("[+] HyprMac Keybind Manager Tests have moved to 'swift test'.") }

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
func runTestBar() { print("[+] HyprMac HyprBar Tests have moved to 'swift test'.") }

@MainActor
func runTestSession() { print("[+] HyprMac Session Manager Tests have moved to 'swift test'.") }

@MainActor
func runTestWorkspace() { print("[+] HyprMac Workspace Manager Tests have moved to 'swift test'.") }

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
        CompositorDaemon.run(configPath: args.dropFirst().first)
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
