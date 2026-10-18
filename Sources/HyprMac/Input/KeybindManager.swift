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
    private var floatingWindowIDs: Set<CGWindowID> = []
    private var fullscreenWindows: [CGWindowID: CGRect] = [:]
    private let lock = NSLock()
    private var _isMenuBarSuppressed: Bool = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    public private(set) var isRunning: Bool = false

    /// When true, top-edge mouse motion is clamped to y >= 12.0 to shield WindowServer's menu bar reveal.
    public var isMenuBarSuppressed: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isMenuBarSuppressed
        }
        set {
            lock.lock()
            _isMenuBarSuppressed = newValue
            lock.unlock()
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
                self.killactive()
            case "minimize", "minimizeactive":
                self.minimizeactive()
            case "workspace":
                let arg = binding.args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if arg == "previous" {
                    self.switchToLastWorkspace()
                } else if let num = Int(binding.args) {
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
            case "movetoworkspace", "move_window_to_workspace":
                if let num = Int(binding.args) {
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
        lock.lock()
        defer { lock.unlock() }
        return floatingWindowIDs.contains(windowID)
    }

    public func setFloating(windowID: CGWindowID, floating: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if floating {
            floatingWindowIDs.insert(windowID)
        } else {
            floatingWindowIDs.remove(windowID)
        }
    }

    public func isFullscreen(windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fullscreenWindows[windowID] != nil
    }

    public func getStoredFullscreenFrame(_ wid: CGWindowID) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return fullscreenWindows[wid]
    }

    public func setFullscreen(windowID: CGWindowID, fullscreen: Bool, restoreFrame: CGRect? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if fullscreen {
            fullscreenWindows[windowID] = restoreFrame ?? fullscreenWindows[windowID] ?? .zero
        } else {
            fullscreenWindows.removeValue(forKey: windowID)
        }
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
        let eventsOfInterest = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)

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
            print("[KeybindManager] Failed to create CGEvent tap. Accessibility permission required.")
            return false
        }

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
    public func killactive() {
        // Strategy 1: Use WindowDetector to locate active window and press AXCloseButton
        if let info = WindowDetector.shared.getFocusedWindow() {
            let wid = info.windowID
            let closeAction: @MainActor () -> Void = {
                let appElement = AXUIElementCreateApplication(info.processID)
                var winVal: AnyObject?
                if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winVal) == .success,
                   let win = winVal {
                    var closeBtnVal: AnyObject?
                    if AXUIElementCopyAttributeValue(win as! AXUIElement, kAXCloseButtonAttribute as CFString, &closeBtnVal) == .success,
                       let closeBtn = closeBtnVal {
                        let err = AXUIElementPerformAction(closeBtn as! AXUIElement, kAXPressAction as CFString)
                        if err == .success {
                            return
                        }
                    }
                }
                // Fallback: Order window out via SkyLight bridge
                SkyLightBridge.shared.orderWindow(windowID: wid, op: .orderOut)
            }

            runOnMainActor { [weak self] in
                let performCloseAndNotify = {
                    closeAction()
                    self?.onWindowClose?(wid)
                    MainActor.assumeIsolated {
                        WorkspaceManager.shared.removeWindow(wid: wid)
                    }
                }

                if AnimationEngine.shared.config.animationsEnabled {
                    let curBounds = AnimationEngine.shared.currentVisualFrame(windowID: wid)
                        ?? WindowDetector.shared.getWindowBounds(windowID: wid)
                        ?? info.bounds
                    let borderWid = BorderManager.shared.overlays[wid].flatMap { CGWindowID($0.windowNumber) }

                    // Notify layout to adjust sibling windows concurrently with windowsOut animation
                    self?.onWindowClose?(wid)

                    AnimationEngine.shared.animateOut(
                        windowID: wid,
                        startFrame: curBounds,
                        borderWindowID: borderWid
                    ) { _ in
                        closeAction()
                        MainActor.assumeIsolated {
                            WorkspaceManager.shared.removeWindow(wid: wid)
                        }
                    }
                } else {
                    performCloseAndNotify()
                }
            }
            return
        }

        // Strategy 2: Fallback to NSWorkspace frontmost application
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
            var winVal: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winVal) == .success,
               let win = winVal {
                var closeBtnVal: AnyObject?
                if AXUIElementCopyAttributeValue(win as! AXUIElement, kAXCloseButtonAttribute as CFString, &closeBtnVal) == .success,
                   let closeBtn = closeBtnVal {
                    _ = AXUIElementPerformAction(closeBtn as! AXUIElement, kAXPressAction as CFString)
                }
            }
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

        // 4. Launch shell command via Process in user login shell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", trimmed]
        do {
            try process.run()
        } catch {
            let fallback = Process()
            fallback.executableURL = URL(fileURLWithPath: "/bin/sh")
            fallback.arguments = ["-c", trimmed]
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

        lock.lock()
        let wasFloating = floatingWindowIDs.contains(wid)
        if wasFloating {
            floatingWindowIDs.remove(wid)
        } else {
            floatingWindowIDs.insert(wid)
        }
        let nowFloating = !wasFloating
        lock.unlock()

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

        lock.lock()
        let savedRect = fullscreenWindows[wid]
        let wasFullscreen = (savedRect != nil)
        if wasFullscreen {
            fullscreenWindows.removeValue(forKey: wid)
        } else {
            fullscreenWindows[wid] = focused.bounds
        }
        lock.unlock()

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
    public func movetoworkspace(number: Int) {
        guard number >= 1 && number <= 9 else { return }
        guard let focused = WindowDetector.shared.getFocusedWindow() else { return }
        let wid = focused.windowID
        movetoworkspace(windowID: wid, number: number, follow: true)
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
        print("=== [KeybindManager Self-Test] ===")
        var allPassed = true

        func assertCond(_ condition: Bool, _ message: String) {
            if condition {
                print("  [✓] \(message)")
            } else {
                print("  [✗] FAILED: \(message)")
                allPassed = false
            }
        }

        // 1. Core Hyprland keys resolution
        assertCond(KeyCodeMapping.keyCode(for: "Q") == CGKeyCode(kVK_ANSI_Q), "Q -> 0x0C (kVK_ANSI_Q)")
        assertCond(KeyCodeMapping.keyCode(for: "RETURN") == CGKeyCode(kVK_Return), "RETURN -> 0x24 (kVK_Return)")
        assertCond(KeyCodeMapping.keyCode(for: "SPACE") == CGKeyCode(kVK_Space), "SPACE -> 0x31 (kVK_Space)")
        assertCond(KeyCodeMapping.keyCode(for: "ESCAPE") == CGKeyCode(kVK_Escape), "ESCAPE -> 0x35 (kVK_Escape)")
        assertCond(KeyCodeMapping.keyCode(for: "TAB") == CGKeyCode(kVK_Tab), "TAB -> 0x30 (kVK_Tab)")
        assertCond(KeyCodeMapping.keyCode(for: "LEFT") == CGKeyCode(kVK_LeftArrow), "LEFT -> 0x7B (kVK_LeftArrow)")
        assertCond(KeyCodeMapping.keyCode(for: "RIGHT") == CGKeyCode(kVK_RightArrow), "RIGHT -> 0x7C (kVK_RightArrow)")
        assertCond(KeyCodeMapping.keyCode(for: "UP") == CGKeyCode(kVK_UpArrow), "UP -> 0x7E (kVK_UpArrow)")
        assertCond(KeyCodeMapping.keyCode(for: "DOWN") == CGKeyCode(kVK_DownArrow), "DOWN -> 0x7D (kVK_DownArrow)")
        assertCond(KeyCodeMapping.keyCode(for: "C") == CGKeyCode(kVK_ANSI_C), "C -> 0x08 (kVK_ANSI_C)")
        assertCond(KeyCodeMapping.keyCode(for: "V") == CGKeyCode(kVK_ANSI_V), "V -> 0x09 (kVK_ANSI_V)")
        assertCond(KeyCodeMapping.keyCode(for: "M") == CGKeyCode(kVK_ANSI_M), "M -> 0x2E (kVK_ANSI_M)")
        assertCond(KeyCodeMapping.keyCode(for: "E") == CGKeyCode(kVK_ANSI_E), "E -> 0x0E (kVK_ANSI_E)")
        assertCond(KeyCodeMapping.keyCode(for: "R") == CGKeyCode(kVK_ANSI_R), "R -> 0x0F (kVK_ANSI_R)")

        // Digits 1...9
        for i in 1...9 {
            let code = KeyCodeMapping.keyCode(for: "\(i)")
            assertCond(code != nil, "Digit \(i) resolves to valid CGKeyCode")
        }

        // 2. Reverse mapping
        assertCond(KeyCodeMapping.keyName(for: CGKeyCode(kVK_ANSI_Q)) == "Q", "0x0C -> 'Q'")
        assertCond(KeyCodeMapping.keyName(for: CGKeyCode(kVK_Return)) == "RETURN", "0x24 -> 'RETURN'")
        assertCond(KeyCodeMapping.keyName(for: CGKeyCode(kVK_Space)) == "SPACE", "0x31 -> 'SPACE'")
        assertCond(KeyCodeMapping.keyName(for: CGKeyCode(kVK_Escape)) == "ESCAPE", "0x35 -> 'ESCAPE'")
        assertCond(KeyCodeMapping.keyName(for: CGKeyCode(kVK_Tab)) == "TAB", "0x30 -> 'TAB'")

        // 3. Modifiers resolution
        assertCond(KeyCodeMapping.modifier(for: "SUPER") == .maskCommand, "SUPER -> .maskCommand")
        assertCond(KeyCodeMapping.modifier(for: "CMD") == .maskCommand, "CMD -> .maskCommand")
        assertCond(KeyCodeMapping.modifier(for: "SHIFT") == .maskShift, "SHIFT -> .maskShift")
        assertCond(KeyCodeMapping.modifier(for: "CTRL") == .maskControl, "CTRL -> .maskControl")
        assertCond(KeyCodeMapping.modifier(for: "CONTROL") == .maskControl, "CONTROL -> .maskControl")
        assertCond(KeyCodeMapping.modifier(for: "ALT") == .maskAlternate, "ALT -> .maskAlternate")
        assertCond(KeyCodeMapping.modifier(for: "MOD1") == .maskAlternate, "MOD1 -> .maskAlternate")

        // Combined modifiers parsing
        let combo1 = KeyCodeMapping.parseModifiers("SUPER, SHIFT")
        assertCond(combo1.contains([.maskCommand, .maskShift]), "Parse 'SUPER, SHIFT'")
        let combo2 = KeyCodeMapping.parseModifiers("CMD+ALT")
        assertCond(combo2.contains([.maskCommand, .maskAlternate]), "Parse 'CMD+ALT'")
        let combo3 = KeyCodeMapping.parseModifiers("SUPER_SHIFT")
        assertCond(combo3.contains([.maskCommand, .maskShift]), "Parse 'SUPER_SHIFT'")

        // 4. KeybindManager registration & lookup mechanics
        let testManager = KeybindManager()
        guard let testID = testManager.register(mod: "SUPER", key: "Q", action: {}) else {
            print("  [✗] FAILED: Register binding SUPER+Q")
            return false
        }
        assertCond(testManager.bindingsCount == 1, "Binding registered in manager")
        testManager.unregister(id: testID)
        assertCond(testManager.bindingsCount == 0, "Binding unregistered from manager")

        // 5. Direction parsing test
        assertCond(Direction.from(string: "l") == .left, "Parse direction 'l' -> .left")
        assertCond(Direction.from(string: "left") == .left, "Parse direction 'left' -> .left")
        assertCond(Direction.from(string: "r") == .right, "Parse direction 'r' -> .right")
        assertCond(Direction.from(string: "right") == .right, "Parse direction 'right' -> .right")
        assertCond(Direction.from(string: "u") == .up, "Parse direction 'u' -> .up")
        assertCond(Direction.from(string: "up") == .up, "Parse direction 'up' -> .up")
        assertCond(Direction.from(string: "d") == .down, "Parse direction 'd' -> .down")
        assertCond(Direction.from(string: "down") == .down, "Parse direction 'down' -> .down")
        assertCond(Direction.from(string: "invalid") == nil, "Parse direction 'invalid' -> nil")

        // 6. Geometry findNeighbor test with synthetic windows
        let winCenter = FocusedWindowInfo(
            windowID: 10,
            processID: 100,
            appName: "Center",
            title: "Center",
            bounds: CGRect(x: 500, y: 300, width: 400, height: 300),
            appkitFrame: .zero
        )
        let winLeft = FocusedWindowInfo(
            windowID: 11,
            processID: 101,
            appName: "Left",
            title: "Left",
            bounds: CGRect(x: 50, y: 300, width: 400, height: 300),
            appkitFrame: .zero
        )
        let winRight = FocusedWindowInfo(
            windowID: 12,
            processID: 102,
            appName: "Right",
            title: "Right",
            bounds: CGRect(x: 950, y: 300, width: 400, height: 300),
            appkitFrame: .zero
        )
        let winUp = FocusedWindowInfo(
            windowID: 13,
            processID: 103,
            appName: "Up",
            title: "Up",
            bounds: CGRect(x: 500, y: 20, width: 400, height: 250),
            appkitFrame: .zero
        )
        let winDown = FocusedWindowInfo(
            windowID: 14,
            processID: 104,
            appName: "Down",
            title: "Down",
            bounds: CGRect(x: 500, y: 650, width: 400, height: 300),
            appkitFrame: .zero
        )

        let mockWindows = [winCenter, winLeft, winRight, winUp, winDown]

        let foundLeft = findNeighbor(direction: .left, from: winCenter, among: mockWindows)
        assertCond(foundLeft?.windowID == 11, "findNeighbor(.left) identifies window 11")

        let foundRight = findNeighbor(direction: .right, from: winCenter, among: mockWindows)
        assertCond(foundRight?.windowID == 12, "findNeighbor(.right) identifies window 12")

        let foundUp = findNeighbor(direction: .up, from: winCenter, among: mockWindows)
        assertCond(foundUp?.windowID == 13, "findNeighbor(.up) identifies window 13")

        let foundDown = findNeighbor(direction: .down, from: winCenter, among: mockWindows)
        assertCond(foundDown?.windowID == 14, "findNeighbor(.down) identifies window 14")

        // 7. Dispatchers registration test
        let bindMove = HyprBinding(mod: "ALT", key: "H", dispatcher: "movefocus", args: "l")
        let bindSwap = HyprBinding(mod: "CTRL ALT", key: "H", dispatcher: "swapwindow", args: "l")
        let bindFloat = HyprBinding(mod: "ALT", key: "V", dispatcher: "togglefloating")
        let bindFull = HyprBinding(mod: "ALT", key: "F", dispatcher: "fullscreen")
        let bindMoveWork = HyprBinding(mod: "ALT SHIFT", key: "1", dispatcher: "movetoworkspace", args: "1")
        let bindExit = HyprBinding(mod: "CTRL ALT", key: "Q", dispatcher: "exit")
        let bindLastWS = HyprBinding(mod: "ALT", key: "TAB", dispatcher: "switch_to_last_workspace")
        let bindSplit = HyprBinding(mod: "ALT", key: "SLASH", dispatcher: "togglesplit")
        let bindGrow = HyprBinding(mod: "ALT", key: "EQUAL", dispatcher: "resize_window_grow")
        let bindShrink = HyprBinding(mod: "ALT", key: "MINUS", dispatcher: "resize_window_shrink")
        let bindReload = HyprBinding(mod: "ALT SHIFT", key: "R", dispatcher: "reload_config")
        let bindMinimize = HyprBinding(mod: "SUPER", key: "M", dispatcher: "minimizeactive")

        assertCond(testManager.register(binding: bindMove) != nil, "Register dispatcher 'movefocus'")
        assertCond(testManager.register(binding: bindSwap) != nil, "Register dispatcher 'swapwindow'")
        assertCond(testManager.register(binding: bindFloat) != nil, "Register dispatcher 'togglefloating'")
        assertCond(testManager.register(binding: bindFull) != nil, "Register dispatcher 'fullscreen'")
        assertCond(testManager.register(binding: bindMoveWork) != nil, "Register dispatcher 'movetoworkspace'")
        assertCond(testManager.register(binding: bindExit) != nil, "Register dispatcher 'exit' (CTRL ALT + Q)")
        assertCond(testManager.register(binding: bindLastWS) != nil, "Register dispatcher 'switch_to_last_workspace'")
        assertCond(testManager.register(binding: bindSplit) != nil, "Register dispatcher 'togglesplit'")
        assertCond(testManager.register(binding: bindGrow) != nil, "Register dispatcher 'resize_window_grow'")
        assertCond(testManager.register(binding: bindShrink) != nil, "Register dispatcher 'resize_window_shrink'")
        assertCond(testManager.register(binding: bindReload) != nil, "Register dispatcher 'reload_config'")
        assertCond(testManager.register(binding: bindMinimize) != nil, "Register dispatcher 'minimizeactive'")
        assertCond(testManager.bindingsCount == 12, "Total registered test bindings == 12")

        print(allPassed ? "=== [Self-Test Result: PASSED] ===" : "=== [Self-Test Result: FAILED] ===")
        return allPassed
    }

    /// Instance self-test convenience forwarding to static implementation.
    @discardableResult
    public func runSelfTest() -> Bool {
        return Self.runSelfTest()
    }
}
