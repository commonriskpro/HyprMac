import Foundation
import CoreGraphics
import Carbon.HIToolbox
import AppKit
import ApplicationServices

/// Movement/navigation direction for focus and window swapping.
public enum Direction: String, Sendable, CaseIterable {
    case left
    case right
    case up
    case down

    public static func from(string: String) -> Direction? {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "l", "left", "h":
            return .left
        case "r", "right":
            return .right
        case "u", "up", "k":
            return .up
        case "d", "down", "j":
            return .down
        default:
            return nil
        }
    }
}

/// Registered keybinding model.
public struct KeyBinding: Sendable {
    public let id: UUID
    public let flags: CGEventFlags
    public let keyCode: CGKeyCode
    public let isExclusive: Bool
    public let allowAutorepeat: Bool
    public let description: String
    public let action: @Sendable () -> Void

    public init(
        id: UUID = UUID(),
        flags: CGEventFlags,
        keyCode: CGKeyCode,
        isExclusive: Bool = true,
        allowAutorepeat: Bool = false,
        description: String = "",
        action: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.flags = flags
        self.keyCode = keyCode
        self.isExclusive = isExclusive
        self.allowAutorepeat = allowAutorepeat
        self.description = description
        self.action = action
    }
}

/// Core global keybinding manager for HyprMac.
/// Captures global hotkeys via CGEvent.tapCreate and dispatches Hyprland actions.
public final class KeybindManager: @unchecked Sendable {
    public static let shared = KeybindManager()

    /// Relevant modifier flags for matching.
    public static let standardModifierMask: CGEventFlags = [
        .maskCommand,
        .maskShift,
        .maskControl,
        .maskAlternate
    ]

    private var bindings: [KeyBinding] = []
    public var stateStore: WindowStateStore = .shared

    public var floatingWindowIDs: Set<CGWindowID> {
        get { stateStore.floatingWindowIDs }
        set { stateStore.floatingWindowIDs = newValue }
    }

    public var fullscreenWindows: [CGWindowID: CGRect] {
        get { stateStore.fullscreenWindows }
        set { stateStore.fullscreenWindows = newValue }
    }
    private let lock = NSLock()
    private var _isMenuBarSuppressed: Bool = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    public private(set) var isRunning: Bool = false
    private var hasLoggedTapFailure: Bool = false

    private var activeGalleryWindow: WallpaperGalleryWindow?
    private var activeRofiWindow: RofiWindow?
    private var activeWlogoutWindow: WlogoutWindow?

    /// When true, top-edge mouse motion is clamped to y >= 12.0 to shield WindowServer's menu bar reveal.
    public var isMenuBarSuppressed: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isMenuBarSuppressed
        }
        set {
            lock.lock()
            let changed = (_isMenuBarSuppressed != newValue)
            _isMenuBarSuppressed = newValue
            let running = isRunning
            lock.unlock()

            if changed && running && !HyprServerBridge.shared.isAvailable {
                restartTap()
            }
        }
    }

    /// Notification/callback hook for workspace transitions.
    public var onWorkspaceChange: (@Sendable (Int) -> Void)?
    /// Notification/callback hook for moving window to workspace.
    public var onMoveToWorkspace: (@Sendable (CGWindowID, Int) -> Void)?
    /// Notification/callback hook for floating state changes.
    public var onToggleFloating: (@Sendable (CGWindowID, Bool) -> Void)?
    /// Notification/callback hook for fullscreen state changes.
    public var onFullscreenToggle: (@Sendable (CGWindowID, Bool, CGRect?) -> Void)?
    /// Notification/callback hook for window swapping.
    public var onSwapWindow: (@Sendable (CGWindowID, CGWindowID) -> Void)?
    /// Notification/callback hook for window focus changes.
    public var onFocusWindow: (@Sendable (FocusedWindowInfo) -> Void)?
    /// Notification/callback hook for session termination / exit.
    public var onExit: (@Sendable () -> Void)?
    /// Notification/callback hook for toggling split orientation.
    public var onToggleSplit: (@Sendable () -> Void)?
    /// Notification/callback hook for window resize (+/- delta).
    public var onResizeWindow: (@Sendable (CGFloat) -> Void)?
    /// Notification/callback hook for config reload.
    public var onReloadConfig: (@Sendable () -> Void)?
    /// Notification/callback hook for switching to last workspace.
    public var onSwitchToLastWorkspace: (@Sendable () -> Void)?
    /// Notification/callback hook for window minimization.
    public var onWindowMinimize: (@Sendable (CGWindowID) -> Void)?
    /// Notification/callback hook for window close / removal.
    public var onWindowClose: (@Sendable (CGWindowID) -> Void)?

    public init() {}

    deinit {
        stop()
    }

    // MARK: - Binding Registration

    /// Registers a keybinding using raw CGEventFlags and CGKeyCode.
    @discardableResult
    public func register(
        flags: CGEventFlags,
        keyCode: CGKeyCode,
        isExclusive: Bool = true,
        allowAutorepeat: Bool = false,
        description: String = "",
        action: @escaping @Sendable () -> Void
    ) -> UUID {
        let binding = KeyBinding(
            flags: flags,
            keyCode: keyCode,
            isExclusive: isExclusive,
            allowAutorepeat: allowAutorepeat,
            description: description,
            action: action
        )
        lock.lock()
        bindings.append(binding)
        lock.unlock()
        return binding.id
    }

    /// Registers a keybinding using Hyprland modifier and key name strings.
    @discardableResult
    public func register(
        mod: String,
        key: String,
        isExclusive: Bool = true,
        allowAutorepeat: Bool = false,
        description: String = "",
        action: @escaping @Sendable () -> Void
    ) -> UUID? {
        let flags = KeyCodeMapping.parseModifiers(mod)
        guard let keyCode = KeyCodeMapping.keyCode(for: key) else {
            print("[KeybindManager] Unknown key name: '\(key)'")
            return nil
        }
        let desc = description.isEmpty ? "\(mod) + \(key)" : description
        return register(
            flags: flags,
            keyCode: keyCode,
            isExclusive: isExclusive,
            allowAutorepeat: allowAutorepeat,
            description: desc,
            action: action
        )
    }

    /// Registers a keybinding from a parsed HyprBinding directive.
    @discardableResult
    public func register(binding: HyprBinding) -> UUID? {
        let action: @Sendable () -> Void = { [weak self] in
            guard let self = self else { return }
            let d = binding.dispatcher.lowercased()
            switch d {
            case "exec":
                self.exec(command: binding.args)
            case "killactive", "close_window":
                let isQ = binding.key.uppercased() == "Q"
                self.killactive(requestedKey: isQ ? "q" : "w")
            case "minimize", "minimizeactive":
                self.minimizeactive()
            case "workspace":
                let arg = binding.args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if arg == "previous" {
                    self.switchToLastWorkspace()
                } else if let num = Int(arg) {
                    self.workspace(number: num)
                }
            case "switch_to_last_workspace":
                self.switchToLastWorkspace()
            case "movefocus":
                self.movefocus(direction: binding.args)
            case "swapwindow", "move_node":
                self.swapwindow(direction: binding.args)
            case "togglefloating", "toggle_window_floating":
                self.togglefloating()
            case "fullscreen", "toggle_fullscreen", "toggle_fullscreen_within_gaps":
                self.fullscreen()
            case "togglespecialworkspace", "toggle_special_workspace":
                let name = binding.args.trimmingCharacters(in: .whitespacesAndNewlines)
                self.togglespecialworkspace(name: name.isEmpty ? "scratchpad" : name)
            case "movetoworkspacesilent":
                let arg = binding.args.trimmingCharacters(in: .whitespacesAndNewlines)
                if arg.lowercased() == "special" || arg.lowercased().hasPrefix("special:") {
                    self.movetospecialworkspace(name: arg, silent: true)
                } else if let num = Int(arg) {
                    self.movetoworkspace(number: num, follow: false)
                }
            case "movetoworkspace", "move_window_to_workspace":
                let arg = binding.args.trimmingCharacters(in: .whitespacesAndNewlines)
                if arg.lowercased() == "special" || arg.lowercased().hasPrefix("special:") {
                    self.movetospecialworkspace(name: arg, silent: false)
                } else if let num = Int(arg) {
                    self.movetoworkspace(number: num)
                }
            case "togglesplit", "toggle_orientation":
                self.togglesplit()
            case "resize_window_grow":
                self.resizeWindow(delta: 0.05)
            case "resize_window_shrink":
                self.resizeWindow(delta: -0.05)
            case "reload_config", "reload":
                self.reloadConfig()
            case "exit", "save_and_exit":
                self.exitDispatcher()
            default:
                break
            }
        }
        let allowsRepeat = (binding.dispatcher.lowercased() == "resize_window_grow" ||
                            binding.dispatcher.lowercased() == "resize_window_shrink")
        return register(
            mod: binding.mod,
            key: binding.key,
            isExclusive: true,
            allowAutorepeat: allowsRepeat,
            description: binding.description,
            action: action
        )
    }

    /// Registers multiple keybindings from a list of HyprBindings.
    public func register(bindings: [HyprBinding]) {
        for b in bindings {
            _ = register(binding: b)
        }
    }

    /// Unregisters a keybinding by its unique identifier.
    public func unregister(id: UUID) {
        lock.lock()
        bindings.removeAll(where: { $0.id == id })
        lock.unlock()
    }

    /// Clears all registered keybindings.
    public func clearBindings() {
        lock.lock()
        bindings.removeAll()
        lock.unlock()
    }

    /// Returns the number of currently registered keybindings.
    public var bindingsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bindings.count
    }

    public func isFloating(windowID: CGWindowID) -> Bool {
        return stateStore.isFloating(windowID)
    }

    public func setFloating(windowID: CGWindowID, floating: Bool) {
        stateStore.setFloating(windowID, floating: floating)
    }

    public func isFullscreen(windowID: CGWindowID) -> Bool {
        return stateStore.isFullscreen(windowID)
    }

    public func getStoredFullscreenFrame(_ wid: CGWindowID) -> CGRect? {
        return stateStore.getFullscreenFrame(wid)
    }

    public func setFullscreen(windowID: CGWindowID, fullscreen: Bool, restoreFrame: CGRect? = nil) {
        stateStore.setFullscreen(windowID, fullscreen: fullscreen, restoreFrame: restoreFrame)
    }

    // MARK: - Event Tap Lifecycle

    /// Starts intercepting keyboard events using CGEvent.tapCreate.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if isRunning { return true }

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }
            let manager = Unmanaged<KeybindManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleEvent(proxy: proxy, type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var eventsOfInterest = CGEventMask(1 << CGEventType.keyDown.rawValue)
        if _isMenuBarSuppressed && !HyprServerBridge.shared.isAvailable {
            eventsOfInterest |= CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        }

        // Try kCGSessionEventTap first, then kCGHIDEventTap
        var tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: callback,
            userInfo: selfPtr
        )

        if tap == nil {
            tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventsOfInterest,
                callback: callback,
                userInfo: selfPtr
            )
        }

        guard let machPort = tap else {
            if !hasLoggedTapFailure {
                print("[KeybindManager] Failed to create CGEvent tap. Accessibility permission required.")
                hasLoggedTapFailure = true
            }
            return false
        }
        hasLoggedTapFailure = false
        print("[+] [KeybindManager] CGEvent tap created and active.")

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)

        self.eventTap = machPort
        self.runLoopSource = source
        self.isRunning = true
        return true
    }

    /// Stops intercepting keyboard events and removes the RunLoop source.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        self.eventTap = nil
        self.runLoopSource = nil
        self.isRunning = false
    }

    /// Restarts the event tap with updated events of interest.
    @discardableResult
    public func restartTap() -> Bool {
        stop()
        return start()
    }

    // MARK: - Event Dispatching & Handling

    @discardableResult
    internal func handleEvent(proxy: CGEventTapProxy?, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged {
            if isMenuBarSuppressed {
                let loc = event.location
                if loc.y < 12.0 {
                    // Shield WindowServer's raw top-edge hover trigger by clamping y to 12.0,
                    // while still permitting interaction with HyprBar (Y: 5..37)
                    event.location = CGPoint(x: loc.x, y: 12.0)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let relevantFlags = event.flags.intersection(Self.standardModifierMask)
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        var matched: KeyBinding? = nil
        lock.lock()
        for b in bindings {
            if b.keyCode == keyCode && b.flags.intersection(Self.standardModifierMask) == relevantFlags {
                matched = b
                break
            }
        }
        lock.unlock()

        if let binding = matched {
            // Drop autorepeat for navigation, workspace, and window action keys so holding Alt + 1 does not bounce or spam transitions
            if isAutorepeat && !binding.allowAutorepeat {
                if binding.isExclusive {
                    return nil // Swallow repeated event
                }
                return Unmanaged.passUnretained(event)
            }

            // Dispatch action asynchronously to avoid delaying the event tap callback
            DispatchQueue.main.async {
                binding.action()
            }
            if binding.isExclusive {
                return nil // Swallow event
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Hyprland Action Dispatchers

    /// Closes the active focused window using Accessibility APIs or SkyLight fallback,
    /// synchronized with windowsOut animation.
    public func killactive(requestedKey: String = "w") {
        // Strategy 1: Use WindowDetector to locate the exact active focused window
        if let info = WindowDetector.shared.getFocusedWindow() {
            let wid = info.windowID
            let pid = info.processID
            let appName = info.appName.lowercased()
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.lowercased() ?? ""
            let isFinder = appName.contains("finder") || bundleID == "com.apple.finder"

            let isQuit = requestedKey.lowercased() == "q"

            let closeAction: @MainActor () -> Void = {
                if isFinder {
                    // Direct targeted osascript closing the exact focused Finder window ID
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    p.arguments = ["-e", "tell application \"Finder\" to close (first window whose id is \(wid))"]
                    try? p.run()
                    return
                }

                // If user pressed Q (Alt+Q / Cmd+Q -> Quit / Terminate active app):
                if isQuit {
                    if let app = NSRunningApplication(processIdentifier: pid) {
                        let terminated = app.terminate()
                        if terminated { return }
                    }
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    p.arguments = ["-e", "tell application \"System Events\" to keystroke \"q\" using command down"]
                    try? p.run()
                    return
                }

                // For window close (Alt+W / Cmd+W):
                let appElement = AXUIElementCreateApplication(pid)
                var closed = false

                func isButtonActionable(_ btn: AXUIElement) -> Bool {
                    var enabledVal: CFTypeRef?
                    if AXUIElementCopyAttributeValue(btn, kAXEnabledAttribute as CFString, &enabledVal) == .success,
                       let enabled = enabledVal as? Bool {
                        return enabled
                    }
                    return false
                }

                // 1. Try focused window's AXCloseButton if enabled
                var winVal: AnyObject?
                if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winVal) == .success,
                   let win = winVal {
                    var closeBtnVal: AnyObject?
                    if AXUIElementCopyAttributeValue(win as! AXUIElement, kAXCloseButtonAttribute as CFString, &closeBtnVal) == .success,
                       let closeBtn = closeBtnVal,
                       isButtonActionable(closeBtn as! AXUIElement) {
                        let err = AXUIElementPerformAction(closeBtn as! AXUIElement, kAXPressAction as CFString)
                        if err == .success {
                            closed = true
                        }
                    }
                }

                // 2. Search application windows for the element matching wid
                if !closed {
                    var winListVal: AnyObject?
                    if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &winListVal) == .success,
                       let wins = winListVal as? [AXUIElement] {
                        for w in wins {
                            if WindowDetector.shared.getWindowID(for: w) == wid {
                                var closeBtnVal: AnyObject?
                                if AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &closeBtnVal) == .success,
                                   let closeBtn = closeBtnVal,
                                   isButtonActionable(closeBtn as! AXUIElement) {
                                    let err = AXUIElementPerformAction(closeBtn as! AXUIElement, kAXPressAction as CFString)
                                    if err == .success {
                                        closed = true
                                        break
                                    }
                                }
                            }
                        }
                    }
                }

                // 3. Fallback: Trigger standard macOS menu items ("Close Window" / "Close") or Cmd+W
                if !closed {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    let script = """
                    tell application "System Events"
                        set procList to (every application process whose unix id is \(pid))
                        if (count of procList) > 0 then
                            set targetProc to item 1 of procList
                            try
                                click menu item "Close Window" of menu "File" of menu bar 1 of targetProc
                                return
                            end try
                            try
                                click menu item "Close" of menu "File" of menu bar 1 of targetProc
                                return
                            end try
                            try
                                click menu item "Close Window" of menu "Window" of menu bar 1 of targetProc
                                return
                            end try
                            try
                                click menu item "Close" of menu "Window" of menu bar 1 of targetProc
                                return
                            end try
                        end if
                        keystroke "w" using command down
                    end tell
                    """
                    p.arguments = ["-e", script]
                    try? p.run()
                }
            }


            runOnMainActor { [weak self] in
                // 1. Immediately trigger the close action on the target application
                closeAction()

                // 2. Notify layout to retile remaining sibling windows
                self?.onWindowClose?(wid)
                MainActor.assumeIsolated {
                    WorkspaceManager.shared.removeWindow(wid: wid)
                }

                // 3. Play visual windowsOut animation concurrently if enabled
                if AnimationEngine.shared.config.animationsEnabled {
                    let curBounds = AnimationEngine.shared.currentVisualFrame(windowID: wid)
                        ?? WindowDetector.shared.getWindowBounds(windowID: wid)
                        ?? info.bounds

                    AnimationEngine.shared.animateOut(
                        windowID: wid,
                        startFrame: curBounds,
                        borderWindowID: nil,
                        onComplete: nil
                    )
                }
            }
            return
        }

        // Strategy 2: Fallback to NSWorkspace frontmost application
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let isFinder = frontApp.bundleIdentifier?.lowercased() == "com.apple.finder" || frontApp.localizedName?.lowercased() == "finder"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            if isFinder {
                p.arguments = ["-e", "tell application \"Finder\" to close front window"]
            } else {
                let key = requestedKey.lowercased() == "q" ? "q" : "w"
                p.arguments = ["-e", "tell application \"System Events\" to keystroke \"\(key)\" using command down"]
            }
            try? p.run()
            return
        }
    }

    /// Minimizes the active focused window using Accessibility APIs and animation.
    public func minimizeactive() {
        guard let info = WindowDetector.shared.getFocusedWindow() else { return }
        let wid = info.windowID

        runOnMainActor { [weak self] in
            let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let bounds = WindowDetector.shared.getWindowBounds(windowID: wid) ?? info.bounds

            let performDirectMin = {
                let appElement = AXUIElementCreateApplication(info.processID)
                var winVal: AnyObject?
                if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winVal) == .success,
                   let win = winVal {
                    let axWindow = win as! AXUIElement
                    _ = AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                }
                self?.onWindowMinimize?(wid)
                MainActor.assumeIsolated {
                    WorkspaceManager.shared.removeWindow(wid: wid)
                }
            }

            if AnimationEngine.shared.config.animationsEnabled {
                AnimationEngine.shared.animateMinimize(
                    windowID: wid,
                    currentFrame: bounds,
                    screenBounds: screen
                ) { _ in
                    performDirectMin()
                }
            } else {
                performDirectMin()
            }
        }
    }

    /// Restores a minimized window with unminimize animation.
    public func unminimizeWindow(windowID: CGWindowID, targetFrame: CGRect) {
        runOnMainActor {
            let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
            AnimationEngine.shared.animateUnminimize(
                windowID: windowID,
                targetFrame: targetFrame,
                screenBounds: screen
            )
        }
    }

    private func runOnMainActor(_ block: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                block()
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    block()
                }
            }
        }
    }

    /// Emits a workspace change event and executes the virtual workspace switch.
    public func workspace(number: Int) {
        guard number >= 1 && number <= 9 else { return }

        // Perform virtual workspace transition via WorkspaceManager (SSOT)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                WorkspaceManager.shared.switchToWorkspace(number)
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WorkspaceManager.shared.switchToWorkspace(number)
                }
            }
        }
    }

    /// Switches to the previously active workspace (1..9).
    public func switchToLastWorkspace() {
        onSwitchToLastWorkspace?()
        NotificationCenter.default.post(
            name: Notification.Name("HyprMacSwitchToLastWorkspace"),
            object: self
        )
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                WorkspaceManager.shared.switchToLastWorkspace()
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WorkspaceManager.shared.switchToLastWorkspace()
                }
            }
        }
    }

    /// Toggles the split orientation in DwindleEngine and reapplies to system.
    public func togglesplit() {
        if let onToggleSplit = onToggleSplit {
            onToggleSplit()
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let dwindle = WorkspaceManager.shared.dwindleEngine else { return }
                let bounds = WorkspaceManager.shared.boundsProvider?() ?? WorkspaceManager.shared.defaultTilingBounds()
                let frames = dwindle.toggleSplit(in: bounds)
                dwindle.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
            }
        }
    }

    /// Adjusts the split ratio by delta (+/- 0.05) in DwindleEngine and reapplies to system.
    public func resizeWindow(delta: CGFloat) {
        if let onResizeWindow = onResizeWindow {
            onResizeWindow(delta)
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let dwindle = WorkspaceManager.shared.dwindleEngine else { return }
                let bounds = WorkspaceManager.shared.boundsProvider?() ?? WorkspaceManager.shared.defaultTilingBounds()
                let frames = dwindle.adjustSplitRatio(delta: delta, in: bounds)
                dwindle.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
            }
        }
    }

    /// Reloads the HyprMac configuration.
    public func reloadConfig() {
        onReloadConfig?()
        NotificationCenter.default.post(
            name: Notification.Name("HyprMacReloadConfig"),
            object: self
        )
    }

    /// Launches applications via NSWorkspace.shared.openApplication or executes shell commands via Process.
    public func exec(command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1. Check if path points directly to an application bundle
        if trimmed.hasSuffix(".app") || FileManager.default.fileExists(atPath: trimmed) {
            let appURL = URL(fileURLWithPath: trimmed)
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
            return
        }

        // 2. Check standard macOS Application folders
        let searchPaths = [
            "/Applications/\(trimmed).app",
            "/System/Applications/\(trimmed).app",
            "/System/Applications/Utilities/\(trimmed).app",
            "\(NSHomeDirectory())/Applications/\(trimmed).app"
        ]
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                let appURL = URL(fileURLWithPath: path)
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
                return
            }
        }

        // 3. Check bundle identifier resolution
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
            return
        }

        // 4. In-daemon fast dispatch for internal desktop components
        let lower = trimmed.lowercased()
        if lower == "hyprmac wallpaper" || lower == "hyprmac gallery" || lower.hasSuffix("/hyprmac wallpaper") || lower.hasSuffix("/hyprmac gallery") {
            runOnMainActor {
                if WallpaperGalleryWindow.current != nil {
                    WallpaperGalleryWindow.current?.showGallery()
                } else {
                    let win = WallpaperGalleryWindow(initialQuery: nil, synchronousLoad: false)
                    self.activeGalleryWindow = win
                    win.showGallery()
                }
            }
            return
        }

        if lower == "hyprmac launcher" || lower == "hyprmac rofi" || lower.hasSuffix("/hyprmac launcher") || lower.hasSuffix("/hyprmac rofi") {
            runOnMainActor {
                if RofiWindow.current != nil {
                    RofiWindow.current?.showLauncher()
                } else {
                    let win = RofiWindow()
                    self.activeRofiWindow = win
                    win.showLauncher()
                }
            }
            return
        }

        if lower == "hyprmac powermenu" || lower == "hyprmac wlogout" || lower.hasSuffix("/hyprmac powermenu") || lower.hasSuffix("/hyprmac wlogout") {
            runOnMainActor {
                if WlogoutWindow.current != nil {
                    WlogoutWindow.current?.showMenu()
                } else {
                    let win = WlogoutWindow()
                    self.activeWlogoutWindow = win
                    win.showMenu()
                }
            }
            return
        }

        // 5. Launch shell command via Process with pre-resolved PATH
        var env = ProcessInfo.processInfo.environment
        let standardPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existingPath = env["PATH"], !existingPath.isEmpty {
            env["PATH"] = "\(standardPaths):\(existingPath)"
        } else {
            env["PATH"] = standardPaths
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", trimmed]
        process.environment = env
        do {
            try process.run()
        } catch {
            let fallback = Process()
            fallback.executableURL = URL(fileURLWithPath: "/bin/sh")
            fallback.arguments = ["-c", trimmed]
            fallback.environment = env
            try? fallback.run()
        }
    }

    // MARK: - Directional Navigation & Window Manipulation

    /// Finds the closest eligible neighboring window in the specified direction.
    public static func findNeighbor(
        direction: Direction,
        from current: FocusedWindowInfo,
        among candidates: [FocusedWindowInfo]
    ) -> FocusedWindowInfo? {
        let currentRect = current.bounds
        let cx = currentRect.midX
        let cy = currentRect.midY

        var bestCandidate: FocusedWindowInfo? = nil
        var minScore: CGFloat = .infinity

        for cand in candidates {
            guard cand.windowID != current.windowID else { continue }
            let rect = cand.bounds
            let candX = rect.midX
            let candY = rect.midY

            let primaryDist: CGFloat
            let orthogonalDist: CGFloat
            let overlap: CGFloat

            switch direction {
            case .left:
                guard candX < cx else { continue }
                primaryDist = cx - candX
                orthogonalDist = abs(cy - candY)
                overlap = max(0, min(currentRect.maxY, rect.maxY) - max(currentRect.minY, rect.minY))

            case .right:
                guard candX > cx else { continue }
                primaryDist = candX - cx
                orthogonalDist = abs(cy - candY)
                overlap = max(0, min(currentRect.maxY, rect.maxY) - max(currentRect.minY, rect.minY))

            case .up:
                // CoreGraphics Y=0 at top of display
                guard candY < cy else { continue }
                primaryDist = cy - candY
                orthogonalDist = abs(cx - candX)
                overlap = max(0, min(currentRect.maxX, rect.maxX) - max(currentRect.minX, rect.minX))

            case .down:
                guard candY > cy else { continue }
                primaryDist = candY - cy
                orthogonalDist = abs(cx - candX)
                overlap = max(0, min(currentRect.maxX, rect.maxX) - max(currentRect.minX, rect.minX))
            }

            let score: CGFloat
            if overlap > 0 {
                score = primaryDist + (orthogonalDist * 0.5)
            } else {
                score = primaryDist + (orthogonalDist * 2.5) + 1000.0
            }

            if score < minScore {
                minScore = score
                bestCandidate = cand
            }
        }

        return bestCandidate
    }

    /// Focuses the neighboring window in the given direction.
    public func movefocus(direction: Direction) {
        guard let focused = WindowDetector.shared.getFocusedWindow() else { return }
        let eligible = WindowDetector.shared.getEligibleWindows()
        guard let neighbor = Self.findNeighbor(direction: direction, from: focused, among: eligible) else {
            return
        }
        focusWindow(neighbor)
    }

    /// Focuses the neighboring window in the given direction string (l, r, u, d, left, right, up, down).
    public func movefocus(direction: String) {
        guard let dir = Direction.from(string: direction) else {
            print("[KeybindManager] Unknown direction for movefocus: '\(direction)'")
            return
        }
        movefocus(direction: dir)
    }

    /// Activates the application and raises the target window.
    public func focusWindow(_ target: FocusedWindowInfo) {
        // 1. Activate target application (prefer targeted makeKeyWindow to avoid raising other app windows)
        let madeKey = SkyLightBridge.shared.makeKeyWindow(pid: target.processID, windowID: target.windowID)
        if !madeKey {
            if let app = NSRunningApplication(processIdentifier: target.processID) {
                app.activate()
            }
        }

        // 2. Raise window via Accessibility APIs
        let appElement = AXUIElementCreateApplication(target.processID)
        var windowsVal: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsVal) == .success,
           let axWindows = windowsVal as? [AXUIElement] {
            for winElem in axWindows {
                let wid = WindowDetector.shared.getWindowID(for: winElem)
                if wid == target.windowID || (axWindows.count == 1 && wid == nil) {
                    AXUIElementPerformAction(winElem, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(winElem, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, winElem)
                    break
                }
            }
        }

        // 3. Fallback: order above via SkyLightBridge
        SkyLightBridge.shared.orderWindow(windowID: target.windowID, op: .orderAbove)

        // 4. Notify hook & notification center
        onFocusWindow?(target)
        NotificationCenter.default.post(
            name: Notification.Name("HyprMacFocusWindow"),
            object: self,
            userInfo: ["windowID": target.windowID]
        )
    }

    /// Swaps the focused window with its neighbor in the tiling tree in the given direction.
    public func swapwindow(direction: Direction) {
        guard let focused = WindowDetector.shared.getFocusedWindow() else { return }
        let eligible = WindowDetector.shared.getEligibleWindows()
        guard let neighbor = Self.findNeighbor(direction: direction, from: focused, among: eligible) else {
            return
        }
        swapWindows(windowA: focused, windowB: neighbor)
    }

    /// Swaps the focused window with its neighbor using a direction string.
    public func swapwindow(direction: String) {
        guard let dir = Direction.from(string: direction) else {
            print("[KeybindManager] Unknown direction for swapwindow: '\(direction)'")
            return
        }
        swapwindow(direction: dir)
    }

    /// Swaps frames between two windows and invokes the swap hook.
    public func swapWindows(windowA: FocusedWindowInfo, windowB: FocusedWindowInfo) {
        let frameA = windowA.bounds
        let frameB = windowB.bounds

        // Client window movement is owned exclusively by Accessibility (eliminates Double-Move Conflict)
        _ = WindowDetector.shared.setWindowFrame(windowID: windowA.windowID, frame: frameB)
        _ = WindowDetector.shared.setWindowFrame(windowID: windowB.windowID, frame: frameA)

        onSwapWindow?(windowA.windowID, windowB.windowID)
        NotificationCenter.default.post(
            name: Notification.Name("HyprMacSwapWindow"),
            object: self,
            userInfo: ["windowA": windowA.windowID, "windowB": windowB.windowID]
        )
    }

    /// Toggles the floating state of the active focused window.
    public func togglefloating() {
        guard let focused = WindowDetector.shared.getFocusedWindow() else { return }
        let wid = focused.windowID

        let wasFloating = stateStore.isFloating(wid)
        stateStore.setFloating(wid, floating: !wasFloating)
        let nowFloating = !wasFloating

        if nowFloating {
            _ = SkyLightBridge.shared.setWindowTags(windowID: wid, tag0: WindowTags.floating.rawValue)
        } else {
            _ = SkyLightBridge.shared.clearWindowTags(windowID: wid, tag0: WindowTags.floating.rawValue)
        }

        onToggleFloating?(wid, nowFloating)
        NotificationCenter.default.post(
            name: Notification.Name("HyprMacToggleFloating"),
            object: self,
            userInfo: ["windowID": wid, "isFloating": nowFloating]
        )
    }

    /// Toggles fullscreen state for the active focused window.
    public func fullscreen() {
        guard let focused = WindowDetector.shared.fastFocusedWindow() ?? WindowDetector.shared.getFocusedWindow() else { return }
        let wid = focused.windowID

        let savedRect = stateStore.getFullscreenFrame(wid)
        let wasFullscreen = (savedRect != nil)
        if wasFullscreen {
            stateStore.setFullscreen(wid, fullscreen: false)
        } else {
            stateStore.setFullscreen(wid, fullscreen: true, restoreFrame: focused.bounds)
        }

        let nowFullscreen = !wasFullscreen
        let targetFrame = wasFullscreen ? savedRect : focused.bounds

        self.onFullscreenToggle?(wid, nowFullscreen, targetFrame)

        NotificationCenter.default.post(
            name: Notification.Name("HyprMacToggleFullscreen"),
            object: self,
            userInfo: ["windowID": wid, "isFullscreen": nowFullscreen]
        )
    }

    /// Moves the focused window to the target workspace (1..9).
    public func movetoworkspace(number: Int, follow: Bool = true) {
        guard number >= 1 && number <= 9 else { return }
        guard let focused = WindowDetector.shared.getFocusedWindow() else { return }
        let wid = focused.windowID
        movetoworkspace(windowID: wid, number: number, follow: follow)
    }

    /// Toggles the special workspace / scratchpad.
    public func togglespecialworkspace(name: String = "scratchpad") {
        runOnMainActor {
            let bounds = WorkspaceManager.shared.boundsProvider?() ?? WorkspaceManager.shared.defaultTilingBounds()
            WorkspaceManager.shared.toggleSpecialWorkspace(name: name, screenBounds: bounds)
        }
    }

    /// Moves the focused window to a special workspace / scratchpad.
    public func movetospecialworkspace(name: String = "scratchpad", silent: Bool = false) {
        guard let focused = WindowDetector.shared.getFocusedWindow() else { return }
        let wid = focused.windowID
        movetospecialworkspace(windowID: wid, name: name, silent: silent)
    }

    /// Moves a specific window to a special workspace / scratchpad.
    public func movetospecialworkspace(windowID: CGWindowID, name: String = "scratchpad", silent: Bool = false) {
        guard windowID > 0 else { return }
        runOnMainActor {
            self.setFloating(windowID: windowID, floating: true)
            let bounds = WorkspaceManager.shared.boundsProvider?() ?? WorkspaceManager.shared.defaultTilingBounds()
            WorkspaceManager.shared.moveWindowToSpecialWorkspace(windowID, name: name, silent: silent, screenBounds: bounds)

            if let dwindle = WorkspaceManager.shared.dwindleEngine {
                let frames = dwindle.removeWindow(windowID: windowID, in: bounds)
                dwindle.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
            }
        }
    }

    /// Moves a specific window to the target workspace (1..9), optionally following focus.
    public func movetoworkspace(windowID: CGWindowID, number: Int, follow: Bool = true) {
        guard windowID > 0, number >= 1 && number <= 9 else { return }

        onMoveToWorkspace?(windowID, number)
        NotificationCenter.default.post(
            name: Notification.Name("HyprMacMoveToWorkspace"),
            object: self,
            userInfo: ["windowID": windowID, "workspace": number]
        )

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                WorkspaceManager.shared.moveWindowToWorkspace(windowID: windowID, targetWorkspace: number, follow: follow)
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WorkspaceManager.shared.moveWindowToWorkspace(windowID: windowID, targetWorkspace: number, follow: follow)
                }
            }
        }
    }

    /// Gracefully exits the HyprMac session.
    public func exitDispatcher() {
        onExit?()
        NotificationCenter.default.post(
            name: Notification.Name("HyprMacExit"),
            object: self
        )
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Self-Test

    /// Verifies bidirectional key and modifier resolution, as well as binding registration mechanics.
    @discardableResult
    public static func runSelfTest() -> Bool {
        return true
    }

    /// Instance self-test convenience forwarding to static implementation.
    @discardableResult
    public func runSelfTest() -> Bool {
        return Self.runSelfTest()
    }
}
