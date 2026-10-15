import Foundation
import CoreGraphics
import Carbon.HIToolbox
import AppKit
import ApplicationServices

/// Registered keybinding model.
public struct KeyBinding: Sendable {
    public let id: UUID
    public let flags: CGEventFlags
    public let keyCode: CGKeyCode
    public let isExclusive: Bool
    public let description: String
    public let action: @Sendable () -> Void

    public init(
        id: UUID = UUID(),
        flags: CGEventFlags,
        keyCode: CGKeyCode,
        isExclusive: Bool = true,
        description: String = "",
        action: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.flags = flags
        self.keyCode = keyCode
        self.isExclusive = isExclusive
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
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    public private(set) var isRunning: Bool = false

    /// Notification/callback hook for workspace transitions.
    public var onWorkspaceChange: (@Sendable (Int) -> Void)?

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
        description: String = "",
        action: @escaping @Sendable () -> Void
    ) -> UUID {
        let binding = KeyBinding(
            flags: flags,
            keyCode: keyCode,
            isExclusive: isExclusive,
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
            case "killactive":
                self.killactive()
            case "workspace":
                if let num = Int(binding.args) {
                    self.workspace(number: num)
                }
            default:
                break
            }
        }
        return register(
            mod: binding.mod,
            key: binding.key,
            isExclusive: true,
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

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let relevantFlags = event.flags.intersection(Self.standardModifierMask)

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

    /// Closes the active focused window using Accessibility APIs or SkyLight fallback.
    public func killactive() {
        // Strategy 1: Use WindowDetector to locate active window and press AXCloseButton
        if let info = WindowDetector.shared.getFocusedWindow() {
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
            SkyLightBridge.shared.orderWindow(windowID: info.windowID, op: .orderOut)
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

    /// Emits a workspace change event and executes the macOS space change.
    public func workspace(number: Int) {
        guard number >= 1 && number <= 9 else { return }

        // 1. Emit workspace event to delegates and notification center
        onWorkspaceChange?(number)
        NotificationCenter.default.post(
            name: Notification.Name("HyprMacWorkspaceDidChange"),
            object: self,
            userInfo: ["workspace": number]
        )

        // 2. Synthesize macOS space switch shortcut: Control + <number>
        if let keyCode = KeyCodeMapping.keyCode(for: "\(number)") {
            let src = CGEventSource(stateID: .hidSystemState)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
                down.flags = .maskControl
                up.flags = .maskControl
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
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

        print(allPassed ? "=== [Self-Test Result: PASSED] ===" : "=== [Self-Test Result: FAILED] ===")
        return allPassed
    }

    /// Instance self-test convenience forwarding to static implementation.
    @discardableResult
    public func runSelfTest() -> Bool {
        return Self.runSelfTest()
    }
}
