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
      border [--halo|--neon] Launch the real-time Hyprland floating glass halo / gradient border daemon
      strip       Test dynamic titlebar / decoration removal on the active focused window
      tile        Detect visible user windows on current screen and arrange in Dwindle layout
      test-border Run unit tests verifying BorderWindow, Glass Halo modes, bounds, and self-tests
      test-config Run unit tests verifying the hyprland.conf parser and variable expansion
      test-keys   Run unit tests verifying keycode resolution, modifier parsing, and event tap
      parse-config [path] Parse a hyprland.conf file and display its parsed rules and bindings
      daemon [conf] Launch the full integrated HyprMac desktop (Waybar + Tiling + Gradient Borders + Hotkeys)
      bar         Launch the live Waybar/Hyprland status bar on the top screen
      session [status|switch|hypr|aqua] Manage or toggle session mode between HyprMac and Aqua
      test-bar    Run unit tests verifying HyprBar window, layout, and IOPowerSources
      test-session Run unit tests verifying SessionManager serialization and mode transitions
      test-dwindle Run mathematical unit tests for 1, 2, 3, and 4 window Dwindle layouts
      server-status Inspect and report HyprServer hook status, ping, and version
      square <id>   Set 0px square corners on window via server hook IPC
      strip-shadow <id> Strip window shadow via server hook IPC
      test-bridge   Run unit tests verifying HyprServerBridge ring buffer and SkyLight routing
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
    print("[+] Connecting to HyprServer hook at \(HyprProtocol.socketPath)...")
    let bridge = HyprServerBridge.shared
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
        exit(0)
    } else {
        print("[-] Connection Status: DISCONNECTED")
        print("[-] Hook Status: INACTIVE (could not connect to \(HyprProtocol.socketPath))")
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
    guard bridge.connect(maxAttempts: 1) else {
        print("[-] Failed to connect to HyprServer hook at \(HyprProtocol.socketPath)")
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
    guard bridge.connect(maxAttempts: 1) else {
        print("[-] Failed to connect to HyprServer hook at \(HyprProtocol.socketPath)")
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
func runTestBridge() {
    print("""
    ==================================================
                 HyprMac Bridge & IPC Tests
    ==================================================
    """)

    var passCount = 0
    var failCount = 0

    func assertTest(_ condition: Bool, _ name: String, _ details: String = "") {
        if condition {
            print("  [PASS] \(name)")
            passCount += 1
        } else {
            print("  [FAIL] \(name) - \(details)")
            failCount += 1
        }
    }

    // 1. Ring Buffer Capacity & FIFO Ordering
    print("[*] Suite 1: CommandRingBuffer FIFO & Drop Oldest")
    let rb = CommandRingBuffer(capacity: 4)
    assertTest(rb.isEmpty, "Initial buffer is empty")
    assertTest(rb.count == 0, "Initial count is 0")

    rb.enqueue(Data([1]))
    rb.enqueue(Data([2]))
    rb.enqueue(Data([3]))
    assertTest(rb.count == 3, "Buffer count is 3 after 3 enqueues")

    let d1 = rb.dequeue()
    assertTest(d1 == Data([1]), "First dequeued item is 1 (FIFO)")
    assertTest(rb.count == 2, "Buffer count is 2 after dequeue")

    rb.enqueue(Data([4]))
    rb.enqueue(Data([5]))
    assertTest(rb.count == 4, "Buffer reaches capacity (4)")

    // Overflow test: capacity is 4. Currently contains [2, 3, 4, 5].
    // Enqueue 6 -> drops oldest (2), contains [3, 4, 5, 6].
    rb.enqueue(Data([6]))
    assertTest(rb.count == 4, "Buffer count stays at capacity (4) after overflow")

    let allItems = rb.dequeueAll()
    assertTest(allItems == [Data([3]), Data([4]), Data([5]), Data([6])],
               "dequeueAll returns [3, 4, 5, 6] dropping oldest (2)",
               "got: \(allItems.map { [UInt8]($0) })")
    assertTest(rb.isEmpty, "Buffer is empty after dequeueAll")

    // 2. Default Capacity 64 (REQ-WS-010)
    print("\n[*] Suite 2: Default Capacity 64 (REQ-WS-010)")
    let defaultRb = CommandRingBuffer()
    assertTest(defaultRb.capacity == 64, "Default capacity is 64")
    for i in 0..<80 {
        defaultRb.enqueue(Data([UInt8(i % 256)]))
    }
    assertTest(defaultRb.count == 64, "Ring buffer bounded to 64 items after 80 enqueues")
    let defAll = defaultRb.dequeueAll()
    assertTest(defAll.count == 64, "Dequeued exactly 64 items")
    assertTest(defAll.first == Data([16]), "Oldest 16 items were dropped (first is item 16)")
    assertTest(defAll.last == Data([79]), "Last item is 79")

    // 3. Thread Safety with Concurrent Enqueue / Dequeue
    print("\n[*] Suite 3: Thread Safety Concurrent Access")
    let concurrentRb = CommandRingBuffer(capacity: 64)
    DispatchQueue.concurrentPerform(iterations: 500) { i in
        concurrentRb.enqueue(Data([UInt8(i % 256)]))
        _ = concurrentRb.dequeue()
    }
    assertTest(true, "Concurrent perform completed without deadlock or crash")

    // 4. SkyLightBridge Routing & Hook Availability
    print("\n[*] Suite 4: SkyLightBridge Routing Check")
    let sl = SkyLightBridge.shared
    assertTest(sl.isHookAvailable == HyprServerBridge.shared.isAvailable, "SkyLightBridge.isHookAvailable matches HyprServerBridge.isAvailable")
    assertTest(sl.checkHookAvailable() == HyprServerBridge.shared.isAvailable, "SkyLightBridge.checkHookAvailable() matches HyprServerBridge.isAvailable")

    // 5. Wire Protocol Serialization
    print("\n[*] Suite 5: Wire Protocol Serialization")
    let bridge = HyprServerBridge.shared
    var sampleFloat: Float = 12.5
    var floatData = Data()
    withUnsafeBytes(of: &sampleFloat) { floatData.append(contentsOf: $0) }
    let msg = bridge.buildMessage(command: .setCornerRadius, windowId: 0x1234, payload: floatData)
    assertTest(msg.count == 20 + 4, "Serialized message has 20-byte header + 4-byte payload (24 bytes)")
    let magic = msg.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
    let version = msg.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }
    let cmdId = msg.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self) }
    let wid = msg.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
    let payloadSize = msg.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
    assertTest(magic == HyprProtocol.magic, "Header magic is 0x48595052 (HYPR)")
    assertTest(version == HyprProtocol.version, "Header version is 1")
    assertTest(cmdId == HyprCommand.setCornerRadius.rawValue, "Command ID is 0x0010 (setCornerRadius)")
    assertTest(wid == 0x1234, "Window ID is 0x1234")
    assertTest(payloadSize == 4, "Payload size is 4 bytes")

    print("""
    ==================================================
    Test Summary: \(passCount) Passed, \(failCount) Failed
    ==================================================
    """)

    if failCount > 0 {
        exit(1)
    }
}

@MainActor
func runProbe() {
    if !WindowDetector.isProcessTrusted() {
        print("[!] Warning: Accessibility permissions not granted. Requesting...")
        _ = WindowDetector.isProcessTrusted(prompt: true)
    }

    guard let info = WindowDetector.shared.getFocusedWindow() else {
        print("[-] No active focused window found.")
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
    Window Title:   \(info.title.isEmpty ? "<no title>" : info.title)
    Window ID:      \(info.windowID)
    CoreGraphics:   origin: (x: \(info.bounds.origin.x), y: \(info.bounds.origin.y))
                    size:   (w: \(info.bounds.width), h: \(info.bounds.height))
    AppKit Frame:   origin: (x: \(info.appkitFrame.origin.x), y: \(info.appkitFrame.origin.y))
                    size:   (w: \(info.appkitFrame.width), h: \(info.appkitFrame.height))
    SkyLight CID:   \(cid)
    SkyLight Bounds:\(slsBoundsStr)
    SkyLight Tags:  [\(tag0Str), \(tag1Str)]
    ==================================================
    """
    )
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
func runBorderDaemon(mode: BorderMode = .glassHalo) {
    if !WindowDetector.isProcessTrusted() {
        print("[!] Accessibility permission required for window tracking. Requesting...")
        _ = WindowDetector.isProcessTrusted(prompt: true)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let borderWindow = BorderWindow()
    borderWindow.mode = mode

    let modeDescription: String
    switch mode {
    case .glassHalo:
        modeDescription = "Glass Halo: Frosted dark glass bezel (\(borderWindow.haloPadding)pt padding, \(borderWindow.cornerRadius)pt rounding, soft drop shadow, titlebar strip)"
    case .neon:
        modeDescription = "Neon: Cyan (#33CCFF) -> Neon Green (#00FF99) rotating gradient"
    case .outline:
        modeDescription = "Outline: Minimal crisp window border"
    }

    print("""
    [HyprMac] Hyprland Window Shell Daemon Active (Mode: \(mode.rawValue))
    [HyprMac] \(modeDescription)
    [HyprMac] Tracking active window at 60Hz. Press Ctrl+C to terminate.
    """
    )

    // Handle SIGINT and SIGTERM gracefully via DispatchSource
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler {
        print("\n[HyprMac] Shutting down border daemon...")
        borderWindow.hideBorder()
        NSApplication.shared.stop(nil)
        exit(0)
    }
    sigintSource.resume()

    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler {
        print("\n[HyprMac] Terminating border daemon...")
        borderWindow.hideBorder()
        NSApplication.shared.stop(nil)
        exit(0)
    }
    sigtermSource.resume()

    var lastWid: CGWindowID = 0
    var lastFrame: NSRect = .zero

    Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
        
        MainActor.assumeIsolated {
            if let focused = WindowDetector.shared.getFocusedWindow() {
                let selfWid = CGWindowID(borderWindow.windowNumber)
                if focused.windowID != selfWid {
                    if focused.windowID != lastWid || focused.appkitFrame != lastFrame {
                        lastWid = focused.windowID
                        lastFrame = focused.appkitFrame
                        borderWindow.update(for: focused)
                    }
                }
            } else {
                if lastWid != 0 {
                    lastWid = 0
                    lastFrame = .zero
                    borderWindow.hideBorder()
                }
            }
        }
    }

    app.run()
}

@MainActor
func runTestBorder() {
    print("""
    ==================================================
               HyprMac Border Window Tests
    ==================================================
    """)
    let ok = BorderWindow.runSelfTest()
    if ok {
        print("[+] All BorderWindow self-tests PASSED successfully!")
    } else {
        print("[-] BorderWindow self-tests FAILED!")
        exit(1)
    }
}

@MainActor
func runTile() {
    if !WindowDetector.isProcessTrusted() {
        print("[!] Warning: Accessibility permissions not granted. Requesting...")
        _ = WindowDetector.isProcessTrusted(prompt: true)
    }

    let screen = NSScreen.main ?? NSScreen.screens.first
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080.0
    let screenBounds: CGRect
    if let sc = screen {
        let vis = sc.visibleFrame
        let cgY = primaryHeight - (vis.origin.y + vis.height)
        screenBounds = CGRect(x: vis.origin.x, y: cgY, width: vis.width, height: vis.height)
    } else {
        screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    print(String(format: "[+] Current Monitor Usable Bounds: (x: %.1f, y: %.1f, w: %.1f, h: %.1f)", screenBounds.origin.x, screenBounds.origin.y, screenBounds.width, screenBounds.height))

    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        print("[-] Unable to query WindowServer window list.")
        exit(1)
    }

    let myPID = getpid()
    let excludedApps: Set<String> = [
        "Dock", "Window Server", "ControlCenter", "NotificationCenter",
        "SystemUIServer", "Spotlight", "HyprMac", "Wallpaper", "screencapture",
        "Simulator Trampoline"
    ]

    var userWindows: [(windowID: CGWindowID, appName: String, title: String, bounds: CGRect)] = []

    for item in windowList {
        guard let wid = item[kCGWindowNumber as String] as? CGWindowID, wid > 0 else { continue }
        guard let layer = item[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
        guard let pid = item[kCGWindowOwnerPID as String] as? pid_t, pid != myPID else { continue }
        guard let appName = item[kCGWindowOwnerName as String] as? String, !excludedApps.contains(appName) else { continue }
        let title = (item[kCGWindowName as String] as? String) ?? ""
        let alpha = (item[kCGWindowAlpha as String] as? Double) ?? 1.0
        guard alpha > 0.01 else { continue }

        guard let boundsDict = item[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }

        guard rect.width >= 100 && rect.height >= 100 else { continue }

        if rect.intersects(screenBounds) {
            userWindows.append((windowID: wid, appName: appName, title: title, bounds: rect))
        }
    }

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
    print("""
    ==================================================
              HyprMac Dwindle Algorithm Tests
    ==================================================
    """)

    let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let gapsIn: CGFloat = 5.0
    let gapsOut: CGFloat = 10.0
    let tol: CGFloat = 0.001

    func isNear(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) <= tol
    }

    func isRectNear(_ r1: CGRect, _ r2: CGRect) -> Bool {
        isNear(r1.origin.x, r2.origin.x) &&
        isNear(r1.origin.y, r2.origin.y) &&
        isNear(r1.width, r2.width) &&
        isNear(r1.height, r2.height)
    }

    func noOverlap(_ r1: CGRect, _ r2: CGRect) -> Bool {
        if !r1.intersects(r2) { return true }
        let inter = r1.intersection(r2)
        return inter.width <= tol || inter.height <= tol
    }

    var passCount = 0
    var failCount = 0

    func assertTest(_ condition: Bool, _ name: String, _ details: String = "") {
        if condition {
            print("  [PASS] \(name)")
            passCount += 1
        } else {
            print("  [FAIL] \(name) - \(details)")
            failCount += 1
        }
    }

    // ------------------------------------------------------------------------
    // TEST 1: Single Window (N = 1)
    // ------------------------------------------------------------------------
    print("[*] Suite 1: Single Window Tiling")
    let engine1 = DwindleEngine(gapsIn: gapsIn, gapsOut: gapsOut)
    let f1 = engine1.addWindow(windowID: 101, in: screenBounds)
    guard let w1_f1 = f1[101] else {
        print("  [FAIL] Window 101 not found in frames")
        exit(1)
    }

    let expected1 = CGRect(
        x: screenBounds.origin.x + gapsOut,
        y: screenBounds.origin.y + gapsOut,
        width: screenBounds.width - 2 * gapsOut,
        height: screenBounds.height - 2 * gapsOut
    )
    assertTest(isRectNear(w1_f1, expected1), "1 Window occupies full workArea respecting gaps_out",
               "got: \(w1_f1), expected: \(expected1)")
    assertTest(isNear(w1_f1.minX - screenBounds.minX, gapsOut), "1 Window left gap equals gaps_out (10.0)")
    assertTest(isNear(screenBounds.maxX - w1_f1.maxX, gapsOut), "1 Window right gap equals gaps_out (10.0)")
    assertTest(isNear(w1_f1.minY - screenBounds.minY, gapsOut), "1 Window top gap equals gaps_out (10.0)")
    assertTest(isNear(screenBounds.maxY - w1_f1.maxY, gapsOut), "1 Window bottom gap equals gaps_out (10.0)")

    // ------------------------------------------------------------------------
    // TEST 2: Two Windows (N = 2, vertical split)
    // ------------------------------------------------------------------------
    print("\n[*] Suite 2: Two Windows Vertical Split")
    let engine2 = DwindleEngine(gapsIn: gapsIn, gapsOut: gapsOut)
    let f2 = engine2.tileWindows(windowIDs: [101, 102], in: screenBounds)
    guard let w1_f2 = f2[101], let w2_f2 = f2[102] else {
        print("  [FAIL] Missing windows in 2-window layout")
        exit(1)
    }

    let availWidth2 = screenBounds.width - 2 * gapsOut - gapsIn
    let expectedW2 = availWidth2 / 2.0
    let expectedH2 = screenBounds.height - 2 * gapsOut
    let expW1_f2 = CGRect(x: 10.0, y: 10.0, width: expectedW2, height: expectedH2)
    let expW2_f2 = CGRect(x: 10.0 + expectedW2 + gapsIn, y: 10.0, width: expectedW2, height: expectedH2)

    assertTest(isRectNear(w1_f2, expW1_f2), "2 Windows: Left window frame matches expected geometry",
               "got: \(w1_f2), expected: \(expW1_f2)")
    assertTest(isRectNear(w2_f2, expW2_f2), "2 Windows: Right window frame matches expected geometry",
               "got: \(w2_f2), expected: \(expW2_f2)")
    assertTest(noOverlap(w1_f2, w2_f2), "2 Windows: Zero overlap between W1 and W2")
    assertTest(isNear(w2_f2.minX - w1_f2.maxX, gapsIn), "2 Windows: Exact gaps_in between W1 and W2 (5.0)")
    assertTest(isNear(w1_f2.minX - screenBounds.minX, gapsOut), "2 Windows: Outer left gap is 10.0")
    assertTest(isNear(screenBounds.maxX - w2_f2.maxX, gapsOut), "2 Windows: Outer right gap is 10.0")

    // ------------------------------------------------------------------------
    // TEST 3: Three Windows (N = 3, horizontal split of right side)
    // ------------------------------------------------------------------------
    print("\n[*] Suite 3: Three Windows Dwindle Spiral")
    let engine3 = DwindleEngine(gapsIn: gapsIn, gapsOut: gapsOut)
    let f3 = engine3.tileWindows(windowIDs: [101, 102, 103], in: screenBounds)
    guard let w1_f3 = f3[101], let w2_f3 = f3[102], let w3_f3 = f3[103] else {
        print("  [FAIL] Missing windows in 3-window layout")
        exit(1)
    }

    let availHeight3 = (screenBounds.height - 2 * gapsOut - gapsIn) / 2.0
    let expW1_f3 = CGRect(x: 10.0, y: 10.0, width: expectedW2, height: expectedH2)
    let expW2_f3 = CGRect(x: 10.0 + expectedW2 + gapsIn, y: 10.0, width: expectedW2, height: availHeight3)
    let expW3_f3 = CGRect(x: 10.0 + expectedW2 + gapsIn, y: 10.0 + availHeight3 + gapsIn, width: expectedW2, height: availHeight3)

    assertTest(isRectNear(w1_f3, expW1_f3), "3 Windows: W1 stays left column",
               "got: \(w1_f3), expected: \(expW1_f3)")
    assertTest(isRectNear(w2_f3, expW2_f3), "3 Windows: W2 splits top-right",
               "got: \(w2_f3), expected: \(expW2_f3)")
    assertTest(isRectNear(w3_f3, expW3_f3), "3 Windows: W3 splits bottom-right",
               "got: \(w3_f3), expected: \(expW3_f3)")
    assertTest(noOverlap(w1_f3, w2_f3) && noOverlap(w1_f3, w3_f3) && noOverlap(w2_f3, w3_f3),
               "3 Windows: Zero pairwise overlaps across all windows")
    assertTest(isNear(w3_f3.minY - w2_f3.maxY, gapsIn), "3 Windows: Exact vertical gap between W2 and W3 (5.0)")
    assertTest(isNear(w2_f3.minX - w1_f3.maxX, gapsIn), "3 Windows: Exact horizontal gap between W1 and W2 (5.0)")
    assertTest(isNear(w3_f3.minX - w1_f3.maxX, gapsIn), "3 Windows: Exact horizontal gap between W1 and W3 (5.0)")

    // ------------------------------------------------------------------------
    // TEST 4: Four Windows (N = 4, vertical split of bottom-right)
    // ------------------------------------------------------------------------
    print("\n[*] Suite 4: Four Windows Golden Ratio Dwindle")
    let engine4 = DwindleEngine(gapsIn: gapsIn, gapsOut: gapsOut)
    let f4 = engine4.tileWindows(windowIDs: [101, 102, 103, 104], in: screenBounds)
    guard let w1_f4 = f4[101], let w2_f4 = f4[102], let w3_f4 = f4[103], let w4_f4 = f4[104] else {
        print("  [FAIL] Missing windows in 4-window layout")
        exit(1)
    }

    let availWidth4 = (expectedW2 - gapsIn) / 2.0
    let expW1_f4 = expW1_f3
    let expW2_f4 = expW2_f3
    let expW3_f4 = CGRect(x: 10.0 + expectedW2 + gapsIn, y: 10.0 + availHeight3 + gapsIn, width: availWidth4, height: availHeight3)
    let expW4_f4 = CGRect(x: 10.0 + expectedW2 + gapsIn + availWidth4 + gapsIn, y: 10.0 + availHeight3 + gapsIn, width: availWidth4, height: availHeight3)

    assertTest(isRectNear(w1_f4, expW1_f4), "4 Windows: W1 unchanged", "got: \(w1_f4), expected: \(expW1_f4)")
    assertTest(isRectNear(w2_f4, expW2_f4), "4 Windows: W2 unchanged", "got: \(w2_f4), expected: \(expW2_f4)")
    assertTest(isRectNear(w3_f4, expW3_f4), "4 Windows: W3 splits bottom-left", "got: \(w3_f4), expected: \(expW3_f4)")
    assertTest(isRectNear(w4_f4, expW4_f4), "4 Windows: W4 splits bottom-right", "got: \(w4_f4), expected: \(expW4_f4)")

    let pairs = [(w1_f4, w2_f4), (w1_f4, w3_f4), (w1_f4, w4_f4), (w2_f4, w3_f4), (w2_f4, w4_f4), (w3_f4, w4_f4)]
    let allNonOverlapping = pairs.allSatisfy { noOverlap($0.0, $0.1) }
    assertTest(allNonOverlapping, "4 Windows: Zero pairwise overlaps across all 6 pairs")
    assertTest(isNear(w4_f4.minX - w3_f4.maxX, gapsIn), "4 Windows: Exact gap between W3 and W4 (5.0)")
    assertTest(isNear(w3_f4.minY - w2_f4.maxY, gapsIn), "4 Windows: Exact vertical gap between W2 and W3 (5.0)")
    assertTest(isNear(w4_f4.minY - w2_f4.maxY, gapsIn), "4 Windows: Exact vertical gap between W2 and W4 (5.0)")
    assertTest(isNear(screenBounds.maxX - w4_f4.maxX, gapsOut), "4 Windows: Outer right gap to screen edge is 10.0")
    assertTest(isNear(screenBounds.maxY - w4_f4.maxY, gapsOut), "4 Windows: Outer bottom gap to screen edge is 10.0")

    // ------------------------------------------------------------------------
    // TEST 5: Dynamic Window Removal & Tree Collapse
    // ------------------------------------------------------------------------
    print("\n[*] Suite 5: Dynamic Window Removal and Tree Collapse")
    let fRem3 = engine4.removeWindow(windowID: 103, in: screenBounds)
    assertTest(fRem3.count == 3, "Removing W3 leaves 3 windows")
    assertTest(fRem3[103] == nil, "W3 is removed from frames")
    if let rw1 = fRem3[101], let rw2 = fRem3[102], let rw4 = fRem3[104] {
        assertTest(noOverlap(rw1, rw2) && noOverlap(rw1, rw4) && noOverlap(rw2, rw4),
                   "Post-removal 3-window layout has zero overlaps")
    }

    let fRem4 = engine4.removeWindow(windowID: 104, in: screenBounds)
    assertTest(fRem4.count == 2, "Removing W4 leaves 2 windows")
    if let rw1 = fRem4[101], let rw2 = fRem4[102] {
        assertTest(noOverlap(rw1, rw2), "Post-removal 2-window layout has zero overlaps")
        assertTest(isNear(rw2.minX - rw1.maxX, gapsIn), "Post-removal 2-window layout has exact gap (5.0)")
    }

    let fRem2 = engine4.removeWindow(windowID: 102, in: screenBounds)
    assertTest(fRem2.count == 1, "Removing W2 leaves 1 window")
    if let rw1 = fRem2[101] {
        assertTest(isRectNear(rw1, expected1), "Last remaining window recovers full workArea (1900x1060)")
    }

    let fRem1 = engine4.removeWindow(windowID: 101, in: screenBounds)
    assertTest(fRem1.isEmpty && engine4.root == nil, "Removing last window empties tree (root == nil)")

    print("""
    ==================================================
    Test Summary: \(passCount) Passed, \(failCount) Failed
    ==================================================
    """)

    if failCount > 0 {
        exit(1)
    }
}

@MainActor
func runTestConfig() {
    print("""
    ==================================================
              HyprMac Config Parser Tests
    ==================================================
    """)
    let ok = ConfigParser.runSelfTest()
    if ok {
        print("[+] All ConfigParser self-tests PASSED successfully!")
    } else {
        print("[-] ConfigParser self-tests FAILED!")
        exit(1)
    }
}

@MainActor
func runTestKeys() {
    print("""
    ==================================================
              HyprMac Keybind Manager Tests
    ==================================================
    """)
    let ok = KeybindManager.runSelfTest()
    if ok {
        print("[+] All KeybindManager self-tests PASSED successfully!")
    } else {
        print("[-] KeybindManager self-tests FAILED!")
        exit(1)
    }
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
        bind = $mainMod, M, exit
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
    print("    • Total Bindings: \(config.bindings.count)")
    for (idx, b) in config.bindings.enumerated() {
        print("      [\(idx + 1)] mod: '\(b.mod)' | key: '\(b.key)' | dispatcher: '\(b.dispatcher)' | args: '\(b.args)'")
    }
}


@MainActor
func runTestBar() {
    print("""
    ==================================================
                 HyprMac HyprBar Tests
    ==================================================
    """)
    let ok = HyprBarWindow.runSelfTest()
    if ok {
        print("[+] All HyprBar self-tests PASSED successfully!")
    } else {
        print("[-] HyprBar self-tests FAILED!")
        exit(1)
    }
}

@MainActor
func runTestSession() {
    print("""
    ==================================================
              HyprMac Session Manager Tests
    ==================================================
    """)
    let ok = SessionManager.runSelfTest()
    if ok {
        print("[+] All SessionManager self-tests PASSED successfully!")
    } else {
        print("[-] SessionManager self-tests FAILED!")
        exit(1)
    }
}

@MainActor
func runBarDaemon() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let bar = HyprBarWindow()
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

    var lastWid: CGWindowID = 0
    var lastTitle = ""

    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        MainActor.assumeIsolated {
            if let focused = WindowDetector.shared.getFocusedWindow() {
                if focused.windowID != lastWid || focused.title != lastTitle {
                    lastWid = focused.windowID
                    lastTitle = focused.title
                    bar.updateActiveWindow(title: focused.title, app: focused.appName)
                }
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
    Bindings:       \(config.bindings.count) shortcuts registered
    Shell:          HyprBar (Waybar native) active on top screen
    Session:        Apple menu bar hidden, full screen reserved
    Press Ctrl+C to stop and restore native macOS Aqua.
    ==================================================
    """)

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // 1. Enter HyprMac session mode (hide native Apple bar & auto-hide dock)
    _ = SessionManager.shared.switchTo(mode: .hyprMac)

    // 2. Launch native Waybar-style status bar
    let bar = HyprBarWindow()
    bar.showBar()

    // 3. Launch animated gradient border
    let borderWindow = BorderWindow()
    borderWindow.mode = config.borderMode
    borderWindow.haloPadding = config.haloPadding
    borderWindow.stripDecorations = config.stripDecorations
    borderWindow.targetWindowAlpha = Float(config.windowOpacity)
    
    // 4. Initialize Keybinds
    let keyManager = KeybindManager.shared
    keyManager.register(bindings: config.bindings)
    keyManager.start()

    // 5. Setup graceful shutdown handlers (SIGINT and SIGTERM)
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    let cleanupAndExit = {
        print("\n[HyprMac] Gracefully shutting down...")
        bar.hideBar()
        borderWindow.hideBorder()
        keyManager.stop()
        print("[HyprMac] Restoring stock macOS Aqua desktop...")
        _ = SessionManager.shared.switchTo(mode: .aqua)
        print("[HyprMac] Restored. Goodbye!")
        exit(0)
    }

    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler(handler: cleanupAndExit)
    sigintSource.resume()

    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler(handler: cleanupAndExit)
    sigtermSource.resume()

    // 6. Active tracking loop at 60Hz
    var lastWid: CGWindowID = 0
    var lastFrame: NSRect = .zero
    var lastTitle: String = ""

    Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
        MainActor.assumeIsolated {
            if let focused = WindowDetector.shared.getFocusedWindow() {
                let selfWid = CGWindowID(borderWindow.windowNumber)
                let barWid = CGWindowID(bar.windowNumber)

                if focused.windowID != selfWid && focused.windowID != barWid {
                    if focused.windowID != lastWid || focused.appkitFrame != lastFrame {
                        lastWid = focused.windowID
                        lastFrame = focused.appkitFrame
                        borderWindow.update(for: focused)
                    }

                    if focused.title != lastTitle {
                        lastTitle = focused.title
                        bar.updateActiveWindow(title: focused.title, app: focused.appName)
                    }
                }
            } else {
                if lastWid != 0 {
                    lastWid = 0
                    lastFrame = .zero
                    borderWindow.hideBorder()
                }
            }
        }
    }

    app.run()
}

MainActor.assumeIsolated {
    let args = CommandLine.arguments.dropFirst()
    let command = args.first ?? "help"

    switch command {
    case "probe":
        runProbe()
    case "daemon", "start":
        runIntegratedDaemon(configPath: args.dropFirst().first)
    case "border":
        let subArg = args.dropFirst().first?.lowercased()
        let mode: BorderMode
        if subArg == "--neon" || subArg == "-neon" || subArg == "neon" {
            mode = .neon
        } else if subArg == "--outline" || subArg == "-outline" || subArg == "outline" {
            mode = .outline
        } else {
            mode = .glassHalo
        }
        runBorderDaemon(mode: mode)
    case "strip":
        runStrip()
    case "tile":
        runTile()
    case "test-border":
        runTestBorder()
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
    case "server-status":
        runServerStatus()
    case "square":
        runSquare(args: Array(args.dropFirst()))
    case "strip-shadow":
        runStripShadow(args: Array(args.dropFirst()))
    case "test-bridge":
        runTestBridge()
    case "help", "--help", "-h":
        printUsage()
    default:
        print("[-] Unknown command: '\(command)'")
        printUsage()
        exit(1)
    }
}
