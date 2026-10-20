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

    // 6. Shared Memory Layout & Protocol Verification
    print("\n[*] Suite 6: Shared Memory Layout & Ring Buffer Setup")
    assertTest(MemoryLayout<HyprShmHeader>.size == 256, "HyprShmHeader struct size is exactly 256 bytes")
    assertTest(MemoryLayout<HyprShmHeader>.stride == 256, "HyprShmHeader struct stride is exactly 256 bytes")
    assertTest(HyprProtocol.shmMagic == 0x48534D49, "SHM magic is 0x48534D49 (HSMI)")
    assertTest(HyprProtocol.shmVersion == 1, "SHM version is 1")
    assertTest(HyprProtocol.shmSize == 65536, "SHM size is 64KB (65536 bytes)")
    assertTest(HyprProtocol.cmdRingSize == 28672, "CMD ring size is 28KB (28672 bytes)")
    assertTest(HyprProtocol.rspRingSize == 28672, "RSP ring size is 28KB (28672 bytes)")
    assertTest(HyprProtocol.cmdRingOffset == 256, "CMD ring offset is 256")
    assertTest(HyprProtocol.rspRingOffset == (HyprProtocol.cmdRingOffset + HyprProtocol.cmdRingSize), "RSP ring offset is 28928 (256 + 28672)")

    let shmInitSuccess = bridge.setupSharedMemory()
    assertTest(shmInitSuccess, "setupSharedMemory() successfully mapped /tmp/hyprmac-ipc.shm")
    assertTest(bridge.isAvailable, "bridge.isAvailable is true after shared memory setup")
    assertTest(sl.isHookAvailable, "SkyLightBridge.isHookAvailable is true after shared memory setup")

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
    excludingPIDs: Set<pid_t> = [getpid()]
) -> [(windowID: CGWindowID, pid: pid_t, appName: String, title: String, bounds: CGRect)] {
    return WindowDetector.shared.getEligibleWindows(in: screenBounds, excludingPIDs: excludingPIDs).map {
        ($0.windowID, $0.processID, $0.appName, $0.title, $0.bounds)
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
func runTestWorkspace() {
    print("""
    ==================================================
              HyprMac Workspace Manager Tests
    ==================================================
    """)
    let ok = WorkspaceManager.runSelfTest()
    if ok {
        print("[+] All WorkspaceManager self-tests PASSED successfully!")
    } else {
        print("[-] WorkspaceManager self-tests FAILED!")
        exit(1)
    }
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

    // 3. Multi-window Border Manager setup (Active vs Inactive Borders)
    let borderManager = BorderManager.shared

    // 3b. Auto-tiling Dwindle Engine setup (Decoupled from transient Z-order)
    let dwindleEngine = DwindleEngine(gapsIn: config.gapsIn, gapsOut: config.gapsOut)

    // 3c. Virtual Workspaces Manager (Single Source of Truth for workspaces 1..9)
    let workspaceManager = WorkspaceManager.shared
    workspaceManager.dwindleEngine = dwindleEngine
    workspaceManager.borderManager = borderManager
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

    var strippedWindows: Set<CGWindowID> = []

    let applyDecorationsToWindow: @MainActor (CGWindowID) -> Void = { wid in
        guard wid > 0 else { return }
        guard !strippedWindows.contains(wid) else { return }
        strippedWindows.insert(wid)
        if config.stripDecorations {
            _ = SkyLightBridge.shared.stripTitlebar(windowID: wid)
            if let pid = workspaceManager.getPID(for: wid) {
                ClientDecorationLoader.shared.attachIfNeeded(pid: pid)
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
            if !strippedWindows.contains(wid) {
                applyDecorationsToWindow(wid)
            }
            dwindleEngine.applyToSystem(windowFrames: dwindleEngine.currentFrames(), bridge: SkyLightBridge.shared)
        }
        workspaceManager.focusWindow(wid: wid)
        let f = WindowDetector.shared.getFocusedWindow()
        borderManager.update(focused: f, managedFrames: dwindleEngine.currentFrames(), config: config)
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
            // When Finder activates (e.g. clicking the empty desktop), ensure menubar suppression is immediately re-dispatched
            if bundleId == "com.apple.finder" && SessionManager.shared.getCurrentMode() == .hyprMac {
                let barWid = UInt32(HyprBarWindow.shared?.windowNumber ?? bar.windowNumber)
                _ = try? HyprServerBridge.shared.setMenuBarSuppression(suppress: true, exemptWid: barWid)
            }

            // Guard against switch in progress or within 500ms settle window:
            // internal activations from switchToWorkspace must never trigger an auto-switch.
            if workspaceManager.isSwitchInProgress(settleInterval: 0.500) {
                return
            }

            guard let pid = activatedPid, pid > 0, pid != getpid() else { return }
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
            guard !appWindows.isEmpty else { return }

            // If that PID already has an active, non-parked window on activeWorkspace, do NOT switch workspaces.
            let activeWorkspace = workspaceManager.activeWorkspace
            let windowsOnCurrentWS = appWindows.filter { workspaceManager.workspace(for: $0) == activeWorkspace }
            for wid in windowsOnCurrentWS where !workspaceManager.isMinimized(wid) {
                if let bounds = WindowDetector.shared.getWindowBounds(windowID: wid, pid: pid) {
                    if !HiddenWindowPlacement.isParkedOrHidden(bounds) {
                        return
                    }
                } else {
                    return
                }
            }

            // Only switch if all windows for that activated PID belong to another workspace targetWS != activeWorkspace
            let targetWorkspaces = Set(appWindows.compactMap { workspaceManager.workspace(for: $0) })
            guard !targetWorkspaces.isEmpty else { return }

            if targetWorkspaces.contains(activeWorkspace) {
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

    // Auto-tile on startup if layout is dwindle
    if config.layout.lowercased() == "dwindle" {
        let tilingBounds = computeTilingBounds()
        let eligibleWindows = getEligibleUserWindows(in: tilingBounds, excludingPIDs: [getpid()])
        let currentIDs = eligibleWindows.map { $0.windowID }
        if !currentIDs.isEmpty {
            for w in eligibleWindows {
                workspaceManager.assignWindowIfNeeded(wid: w.windowID, pid: w.pid)
                if !strippedWindows.contains(w.windowID) {
                    applyDecorationsToWindow(w.windowID)
                }
            }
            let activeIDs = workspaceManager.activeWindowIDs()
            let activeTiledIDs = activeIDs.filter { !keyManager.isFloating(windowID: $0) }
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

    keyManager.onToggleFloating = { [weak dwindleEngine, weak workspaceManager, weak borderManager, weak keyManager] wid, isFloating in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let engine = dwindleEngine, let wsMgr = workspaceManager, let bMgr = borderManager, let km = keyManager else { return }
                let tilingBounds = computeTilingBounds()
                let activeIDs = wsMgr.activeWindowIDs()
                let activeTiledIDs = activeIDs.filter { !km.isFloating(windowID: $0) }
                let frames = engine.tileWindows(windowIDs: activeTiledIDs, in: tilingBounds)
                engine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                if isFloating {
                    bMgr.hideOverlay(for: wid)
                }
                let f = WindowDetector.shared.getFocusedWindow()
                bMgr.update(focused: f, managedFrames: engine.currentFrames(), config: config)
            }
        }
    }

    keyManager.onFullscreenToggle = { [weak dwindleEngine, weak workspaceManager, weak borderManager, weak keyManager] wid, isFullscreen, savedFrame in
        MainActor.assumeIsolated {
            guard let engine = dwindleEngine, let wsMgr = workspaceManager, let bMgr = borderManager, let km = keyManager else { return }
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
                let borderWid = bMgr.overlays[wid].flatMap { CGWindowID($0.windowNumber) }
                AnimationEngine.shared.animateFullscreen(
                    windowID: wid,
                    from: curBounds,
                    to: fullBounds,
                    isFullscreen: true,
                    borderWindowID: borderWid
                ) { _ in
                    let f = WindowDetector.shared.getFocusedWindow()
                    bMgr.update(focused: f, managedFrames: engine.currentFrames(), config: config)
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
                let borderWid = bMgr.overlays[wid].flatMap { CGWindowID($0.windowNumber) }
                AnimationEngine.shared.animateFullscreen(
                    windowID: wid,
                    from: fullBounds,
                    to: targetFrame,
                    isFullscreen: false,
                    borderWindowID: borderWid
                ) { _ in
                    let f = WindowDetector.shared.getFocusedWindow()
                    bMgr.update(focused: f, managedFrames: engine.currentFrames(), config: config)
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

    keyManager.onWindowMinimize = { [weak dwindleEngine, weak borderManager] wid in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let engine = dwindleEngine else { return }
                let tilingBounds = computeTilingBounds()
                let frames = engine.removeWindow(windowID: wid, in: tilingBounds)
                engine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                borderManager?.hideOverlay(for: wid)
            }
        }
    }

    keyManager.onWindowClose = { [weak dwindleEngine, weak borderManager] wid in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let engine = dwindleEngine else { return }
                let tilingBounds = computeTilingBounds()
                let frames = engine.removeWindow(windowID: wid, in: tilingBounds)
                engine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                borderManager?.hideOverlay(for: wid)
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
                animationEngine.config = newConfig
                bar?.barView.barColors = newConfig.barColors
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
            bar.barView.applyTheme()
            let f = WindowDetector.shared.getFocusedWindow()
            borderManager.update(focused: f, managedFrames: dwindleEngine.currentFrames(), config: newConfig)
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
                borderManager.hideAll()
                animationEngine.cancelAll()
                keyManager.stop()
                KeybindManager.shared.isMenuBarSuppressed = false
                unlink("/tmp/hyprmac.pid")
                unlink("/tmp/hyprmac.lock")
                close(lockFd)
                print("[HyprMac] Restoring stock macOS Aqua desktop...")
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

    // 6. Active tracking loop at 60Hz
    var lastWid: CGWindowID = 0
    var lastFrame: NSRect = .zero
    var lastTitle: String = ""
    var tileCheckCounter: Int = 0

    // Mouse drag tracking & snap-back state via event monitoring (zero 60Hz HID polling)
    var isMouseDownPrev: Bool = false
    var draggedWid: CGWindowID? = nil
    var dragStartFrame: CGRect? = nil
    var dragStartMousePoint: NSPoint? = nil
    var isDragging: Bool = false

    mouseState.global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
        MainActor.assumeIsolated {
            mouseState.isMouseDown = (event.type == .leftMouseDown)
        }
    }
    mouseState.local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
        MainActor.assumeIsolated {
            mouseState.isMouseDown = (event.type == .leftMouseDown)
        }
        return event
    }

    Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
        MainActor.assumeIsolated {
            tileCheckCounter += 1
            var framesChanged = false

            let now = ProcessInfo.processInfo.systemUptime
            let lastSwitch = max(transitionTracker.lastWorkspaceSwitchTime, workspaceManager.lastWorkspaceSwitchTime)
            let isSettleWindow = (now - lastSwitch) < 0.500 || workspaceManager.isSwitchInProgress(settleInterval: 0.500)

            if !keyManager.isRunning && tileCheckCounter % 60 == 0 {
                _ = keyManager.start()
            }

            if tileCheckCounter % 30 == 0 && !isSettleWindow && config.layout.lowercased() == "dwindle" {
                let tilingBounds = computeTilingBounds()
                let eligibleWindows = getEligibleUserWindows(in: tilingBounds, excludingPIDs: [getpid()])
                let currentIDs = eligibleWindows.map { $0.windowID }

                // Auto-assign any newly discovered window to active workspace with PID
                for w in eligibleWindows {
                    workspaceManager.assignWindowIfNeeded(wid: w.windowID, pid: w.pid)
                    if !strippedWindows.contains(w.windowID) {
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
                            borderManager.hideOverlay(for: wid)
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
                let allAliveWindowIDs = WindowDetector.shared.getAllAliveWindowIDs()

                // Purge dead windows across all workspaces
                for wid in workspaceManager.windowOrder {
                    if !allAliveWindowIDs.contains(wid) {
                        workspaceManager.removeWindow(wid: wid)
                        dwindleEngine.removeWindow(windowID: wid, in: tilingBounds)
                        borderManager.hideOverlay(for: wid)
                        WindowDetector.shared.invalidateWindow(windowID: wid)
                    }
                }
                strippedWindows.formIntersection(allAliveWindowIDs)

                // Filter eligible windows using WorkspaceManager so only windows
                // belonging to the active workspace are tiled by DwindleEngine
                let activeIDs = workspaceManager.activeWindowIDs()
                let activeManagedSet = Set(activeIDs)
                let activeCurrentIDs = currentIDs.filter { activeManagedSet.contains($0) && !keyManager.isFloating(windowID: $0) }
                let currentSet = Set(activeCurrentIDs)

                if minimizedChanged || currentSet != dwindleEngine.managedWindowSet {
                    let closedWindows = dwindleEngine.managedWindowSet.subtracting(currentSet)
                    let openedWindows = currentSet.subtracting(dwindleEngine.managedWindowSet)

                    for wid in closedWindows {
                        dwindleEngine.removeWindow(windowID: wid, in: tilingBounds)
                        borderManager.hideOverlay(for: wid)
                        AnimationEngine.shared.cancelAnimation(for: wid)
                        if !allAliveWindowIDs.contains(wid) {
                            workspaceManager.removeWindow(wid: wid)
                            strippedWindows.remove(wid)
                        }
                    }

                    let openedInOrder = activeCurrentIDs.filter { openedWindows.contains($0) }
                    for wid in openedInOrder {
                        dwindleEngine.addWindow(windowID: wid, in: tilingBounds)
                        if !strippedWindows.contains(wid) {
                            applyDecorationsToWindow(wid)
                        }
                    }

                    let frames = dwindleEngine.currentFrames()
                    dwindleEngine.applyToSystem(windowFrames: frames, newlyAddedWindows: openedWindows, bridge: SkyLightBridge.shared)
                    framesChanged = true
                }
            }

            let barWid = CGWindowID(bar.windowNumber)
            let rawFocused = (tileCheckCounter % 30 == 0) ? WindowDetector.shared.getFocusedWindow() : WindowDetector.shared.fastFocusedWindow()
            let isBarOrBorder = rawFocused != nil && (rawFocused!.windowID == barWid || borderManager.isBorderWindow(windowID: rawFocused!.windowID))
            let isParked = rawFocused != nil && HiddenWindowPlacement.isParkedOrHidden(rawFocused!.bounds)
            let focusedCandidate = (isBarOrBorder || isParked) ? nil : rawFocused

            // Unminimize to active workspace if a window was unminimized
            if let fc = focusedCandidate, !isSettleWindow {
                let wid = fc.windowID
                let pid = fc.processID
                let wasMin = workspaceManager.isMinimized(wid)
                let isMin = WindowDetector.shared.isWindowMinimized(windowID: wid, pid: pid)

                if wasMin && !isMin {
                    handleUnminimize(wid, pid)
                    framesChanged = true
                }
            }

            // Ensure non-standard windows (popups/dropdowns) do not receive borders.
            // If an unmanaged window is focused, check if its owning process has an admitted window in dwindleEngine.
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
                            appkitFrame: WindowDetector.shared.convertToAppKitFrame(cgRect: mainBounds)
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

            // Mouse drag tracking & snap-back for tiled windows
            if config.layout.lowercased() == "dwindle" {
                let isMouseDown = mouseState.isMouseDown

                if !isMouseDownPrev && isMouseDown {
                    // Mouse Down: If mouse transitions from up to down, and the active/focused window is managed by Dwindle and NOT floating:
                    if let f = focused {
                        let wid = f.windowID
                        if dwindleEngine.managedWindowSet.contains(wid) && !keyManager.isFloating(windowID: wid) && !keyManager.isFullscreen(windowID: wid) {
                            let pid = workspaceManager.getPID(for: wid)
                            draggedWid = wid
                            dragStartFrame = WindowDetector.shared.getWindowBounds(windowID: wid, pid: pid) ?? f.bounds
                            dragStartMousePoint = NSEvent.mouseLocation
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
                } else if isMouseDown {
                    // Mouse Drag: While mouse is down and draggedWid is set, detect drag distance via cursor position (zero AX IPC roundtrips)
                    if draggedWid != nil, let startPt = dragStartMousePoint, !isDragging {
                        let curPt = NSEvent.mouseLocation
                        if hypot(curPt.x - startPt.x, curPt.y - startPt.y) > 8.0 {
                            isDragging = true
                        }
                    }
                } else if isMouseDownPrev && !isMouseDown {
                    // Mouse Up Transition: When mouse transitions from down to up:
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
                                framesChanged = true
                            } else {
                                // Window was moved "un poco" / slightly or dropped in empty space:
                                // SNAP BACK to allocated tiled frame
                                if let targetFrame = currentFrames[wid] {
                                    _ = WindowDetector.shared.setWindowFrame(windowID: wid, frame: targetFrame, pid: pid)
                                    framesChanged = true
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
                                    framesChanged = true
                                }
                            }
                        }
                    }
                    draggedWid = nil
                    dragStartFrame = nil
                    dragStartMousePoint = nil
                    isDragging = false
                }

                // Idle Frame Reconciliation (every 30 ticks / ~500ms when idle)
                // Skip during 350ms settle window following a workspace switch
                if !isMouseDown && !isDragging && !isSettleWindow && tileCheckCounter % 30 == 0 {
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
                }

                isMouseDownPrev = isMouseDown
            }

            let currentFocusedWid = focused?.windowID ?? 0
            let currentFocusedFrame = focused?.appkitFrame ?? .zero

            if currentFocusedWid != lastWid || currentFocusedFrame != lastFrame || framesChanged {
                lastWid = currentFocusedWid
                lastFrame = currentFocusedFrame
                borderManager.update(focused: focused, managedFrames: dwindleEngine.currentFrames(), config: config)
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
    }

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
        let ok = WallpaperWatcher.runSelfTest()
        exit(ok ? 0 : 1)
    case "help", "--help", "-h":
        printUsage()
    default:
        print("[-] Unknown command: '\(command)'")
        printUsage()
        exit(1)
    }
}
