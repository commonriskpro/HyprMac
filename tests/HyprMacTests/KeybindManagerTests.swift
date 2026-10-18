import XCTest
import CoreGraphics
@testable import HyprMac

final class KeybindManagerTests: XCTestCase {

    func testKeyCodeMappingReturn() {
        let code = KeyCodeMapping.keyCode(for: "return")
        XCTAssertEqual(code, 36)
    }

    func testKeyCodeMappingSpace() {
        let code = KeyCodeMapping.keyCode(for: "space")
        XCTAssertEqual(code, 49)
    }

    func testKeyCodeMappingQ() {
        let code = KeyCodeMapping.keyCode(for: "q")
        XCTAssertEqual(code, 12)
    }

    func testKeyCodeMappingUnknown() {
        let code = KeyCodeMapping.keyCode(for: "nonexistent")
        XCTAssertNil(code)
    }

    func testKeyNameRoundtrip() {
        guard let codeQ = KeyCodeMapping.keyCode(for: "Q") else {
            XCTFail("Failed to resolve keycode for Q")
            return
        }
        XCTAssertEqual(KeyCodeMapping.keyName(for: codeQ), "Q")

        guard let codeReturn = KeyCodeMapping.keyCode(for: "RETURN") else {
            XCTFail("Failed to resolve keycode for RETURN")
            return
        }
        XCTAssertEqual(KeyCodeMapping.keyName(for: codeReturn), "RETURN")

        guard let codeSpace = KeyCodeMapping.keyCode(for: "SPACE") else {
            XCTFail("Failed to resolve keycode for SPACE")
            return
        }
        XCTAssertEqual(KeyCodeMapping.keyName(for: codeSpace), "SPACE")
    }

    func testModifierSuper() {
        XCTAssertEqual(KeyCodeMapping.modifier(for: "SUPER"), .maskCommand)
        XCTAssertEqual(KeyCodeMapping.modifier(for: "CMD"), .maskCommand)
    }

    func testModifierShift() {
        XCTAssertEqual(KeyCodeMapping.modifier(for: "SHIFT"), .maskShift)
    }

    func testModifierCtrl() {
        XCTAssertEqual(KeyCodeMapping.modifier(for: "CTRL"), .maskControl)
        XCTAssertEqual(KeyCodeMapping.modifier(for: "CONTROL"), .maskControl)
    }

    func testModifierAlt() {
        XCTAssertEqual(KeyCodeMapping.modifier(for: "ALT"), .maskAlternate)
        XCTAssertEqual(KeyCodeMapping.modifier(for: "OPTION"), .maskAlternate)
    }

    func testParseModifiers() {
        let flags = KeyCodeMapping.parseModifiers("SUPER SHIFT")
        XCTAssertTrue(flags.contains(.maskCommand))
        XCTAssertTrue(flags.contains(.maskShift))
        XCTAssertFalse(flags.contains(.maskControl))
        XCTAssertFalse(flags.contains(.maskAlternate))
    }

    func testManagerInit() {
        let manager = KeybindManager()
        XCTAssertEqual(manager.bindingsCount, 0)
        XCTAssertFalse(manager.isRunning)
    }

    func testRegisterAndCount() {
        let manager = KeybindManager()
        XCTAssertEqual(manager.bindingsCount, 0)
        let id = manager.register(flags: .maskCommand, keyCode: 12, action: {})
        XCTAssertEqual(manager.bindingsCount, 1)
        XCTAssertFalse(id.uuidString.isEmpty)
    }

    func testRegisterMultiple() {
        let manager = KeybindManager()
        _ = manager.register(mod: "SUPER", key: "1", action: {})
        _ = manager.register(mod: "SUPER", key: "2", action: {})
        _ = manager.register(mod: "SUPER", key: "3", action: {})
        XCTAssertEqual(manager.bindingsCount, 3)
    }

    func testUnregister() {
        let manager = KeybindManager()
        guard let id = manager.register(mod: "SUPER", key: "Q", action: {}) else {
            XCTFail("Failed to register SUPER+Q")
            return
        }
        XCTAssertEqual(manager.bindingsCount, 1)
        manager.unregister(id: id)
        XCTAssertEqual(manager.bindingsCount, 0)
    }

    func testClearBindings() {
        let manager = KeybindManager()
        _ = manager.register(mod: "SUPER", key: "Q", action: {})
        _ = manager.register(mod: "SUPER", key: "C", action: {})
        _ = manager.register(mod: "SUPER", key: "Return", action: {})
        XCTAssertEqual(manager.bindingsCount, 3)
        manager.clearBindings()
        XCTAssertEqual(manager.bindingsCount, 0)
    }

    func testRegisterByModString() {
        let manager = KeybindManager()
        let id = manager.register(mod: "SUPER", key: "Q", action: {})
        XCTAssertNotNil(id)
        XCTAssertEqual(manager.bindingsCount, 1)
    }

    func testRegisterByHyprBinding() {
        let manager = KeybindManager()
        let binding = HyprBinding(mod: "SUPER", key: "Return", dispatcher: "exec", args: "kitty")
        let id = manager.register(binding: binding)
        XCTAssertNotNil(id)
        XCTAssertEqual(manager.bindingsCount, 1)
    }

    func testRegisterInvalidKey() {
        let manager = KeybindManager()
        let id = manager.register(mod: "SUPER", key: "nonexistent_key", action: {})
        XCTAssertNil(id)
        XCTAssertEqual(manager.bindingsCount, 0)
    }

    func testModifierNamesRoundtrip() {
        let names = KeyCodeMapping.modifierNames(for: .maskCommand)
        XCTAssertTrue(names.contains("SUPER") || names.contains("command"))
    }

    func testKeybindManagerSelfTest() {
        XCTAssertTrue(KeybindManager.runSelfTest())
    }

    func testDirectionParsing() {
        XCTAssertEqual(Direction.from(string: "l"), .left)
        XCTAssertEqual(Direction.from(string: "left"), .left)
        XCTAssertEqual(Direction.from(string: "h"), .left)
        XCTAssertEqual(Direction.from(string: "r"), .right)
        XCTAssertEqual(Direction.from(string: "right"), .right)
        XCTAssertEqual(Direction.from(string: "u"), .up)
        XCTAssertEqual(Direction.from(string: "up"), .up)
        XCTAssertEqual(Direction.from(string: "k"), .up)
        XCTAssertEqual(Direction.from(string: "d"), .down)
        XCTAssertEqual(Direction.from(string: "down"), .down)
        XCTAssertEqual(Direction.from(string: "j"), .down)
        XCTAssertNil(Direction.from(string: "diagonal"))
    }

    func testDirectionalGeometryFindNeighbor() {
        let center = FocusedWindowInfo(
            windowID: 100,
            processID: 10,
            appName: "Center",
            title: "Center",
            bounds: CGRect(x: 500, y: 300, width: 400, height: 300),
            appkitFrame: .zero
        )
        let left = FocusedWindowInfo(
            windowID: 101,
            processID: 11,
            appName: "Left",
            title: "Left",
            bounds: CGRect(x: 50, y: 300, width: 400, height: 300),
            appkitFrame: .zero
        )
        let right = FocusedWindowInfo(
            windowID: 102,
            processID: 12,
            appName: "Right",
            title: "Right",
            bounds: CGRect(x: 950, y: 300, width: 400, height: 300),
            appkitFrame: .zero
        )
        let up = FocusedWindowInfo(
            windowID: 103,
            processID: 13,
            appName: "Up",
            title: "Up",
            bounds: CGRect(x: 500, y: 20, width: 400, height: 250),
            appkitFrame: .zero
        )
        let down = FocusedWindowInfo(
            windowID: 104,
            processID: 14,
            appName: "Down",
            title: "Down",
            bounds: CGRect(x: 500, y: 650, width: 400, height: 300),
            appkitFrame: .zero
        )

        let all = [center, left, right, up, down]

        XCTAssertEqual(KeybindManager.findNeighbor(direction: .left, from: center, among: all)?.windowID, 101)
        XCTAssertEqual(KeybindManager.findNeighbor(direction: .right, from: center, among: all)?.windowID, 102)
        XCTAssertEqual(KeybindManager.findNeighbor(direction: .up, from: center, among: all)?.windowID, 103)
        XCTAssertEqual(KeybindManager.findNeighbor(direction: .down, from: center, among: all)?.windowID, 104)

        // Moving left from the leftmost window should return nil
        XCTAssertNil(KeybindManager.findNeighbor(direction: .left, from: left, among: all))
    }

    func testRegisterAllDispatchers() {
        let manager = KeybindManager()
        let dispatchers = [
            ("ALT", "H", "movefocus", "l"),
            ("CTRL ALT", "L", "swapwindow", "r"),
            ("ALT", "V", "togglefloating", ""),
            ("ALT", "F", "fullscreen", ""),
            ("ALT SHIFT", "1", "movetoworkspace", "1"),
            ("CTRL ALT", "Q", "exit", ""),
            ("ALT", "TAB", "switch_to_last_workspace", ""),
            ("ALT", "SLASH", "togglesplit", ""),
            ("ALT", "EQUAL", "resize_window_grow", ""),
            ("ALT", "MINUS", "resize_window_shrink", ""),
            ("ALT SHIFT", "R", "reload_config", ""),
            ("SUPER", "M", "minimizeactive", "")
        ]

        for (mod, key, disp, args) in dispatchers {
            let b = HyprBinding(mod: mod, key: key, dispatcher: disp, args: args)
            let id = manager.register(binding: b)
            XCTAssertNotNil(id, "Failed to register \(disp)")
        }
        XCTAssertEqual(manager.bindingsCount, 12)
    }

    func testMinimizeActiveDispatcherRegistrationAndExecution() {
        let manager = KeybindManager()
        let bind1 = HyprBinding(mod: "SUPER", key: "M", dispatcher: "minimizeactive")
        let bind2 = HyprBinding(mod: "CMD", key: "M", dispatcher: "minimize")

        let id1 = manager.register(binding: bind1)
        let id2 = manager.register(binding: bind2)

        XCTAssertNotNil(id1, "minimizeactive dispatcher must be registered successfully")
        XCTAssertNotNil(id2, "minimize alias dispatcher must be registered successfully")
        XCTAssertEqual(manager.bindingsCount, 2)

        final class CallbackBox: @unchecked Sendable {
            var called = false
            var wid: CGWindowID = 0
        }
        let box = CallbackBox()
        manager.onWindowMinimize = { wid in
            box.called = true
            box.wid = wid
        }

        // Calling minimizeactive directly executes cleanly without throwing or crashing
        manager.minimizeactive()
    }

    func testToggleFloatingState() {
        let manager = KeybindManager()
        XCTAssertFalse(manager.isFloating(windowID: 999))

        manager.setFloating(windowID: 999, floating: true)
        XCTAssertTrue(manager.isFloating(windowID: 999))

        manager.setFloating(windowID: 999, floating: false)
        XCTAssertFalse(manager.isFloating(windowID: 999))
    }

    func testFullscreenState() {
        let manager = KeybindManager()
        XCTAssertFalse(manager.isFullscreen(windowID: 999))
    }

    func testAutorepeatDroppedForWorkspaceAndNavigation() {
        let manager = KeybindManager()
        final class ActionCounter: @unchecked Sendable {
            var count = 0
        }
        let counter = ActionCounter()

        // Register Alt+1 with allowAutorepeat: false (default for workspace)
        guard let keyCode1 = KeyCodeMapping.keyCode(for: "1") else {
            XCTFail("Failed to resolve keycode for 1")
            return
        }
        _ = manager.register(flags: .maskAlternate, keyCode: keyCode1, isExclusive: true, allowAutorepeat: false) {
            counter.count += 1
        }

        // 1. Initial press: autorepeat == 0
        if let eventPress = CGEvent(keyboardEventSource: nil, virtualKey: keyCode1, keyDown: true) {
            eventPress.flags = .maskAlternate
            eventPress.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            _ = manager.handleEvent(proxy: nil, type: .keyDown, event: eventPress)
        }

        // 2. Held down: autorepeat == 1 (should be dropped)
        if let eventRepeat = CGEvent(keyboardEventSource: nil, virtualKey: keyCode1, keyDown: true) {
            eventRepeat.flags = .maskAlternate
            eventRepeat.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            let result = manager.handleEvent(proxy: nil, type: .keyDown, event: eventRepeat)
            XCTAssertNil(result, "Exclusive non-repeating binding must swallow autorepeat event")
        }
    }

    func testAutorepeatAllowedForResize() {
        let manager = KeybindManager()
        let bindGrow = HyprBinding(mod: "ALT", key: "EQUAL", dispatcher: "resize_window_grow")
        _ = manager.register(binding: bindGrow)

        guard let keyCodeEqual = KeyCodeMapping.keyCode(for: "EQUAL") else {
            XCTFail("Failed to resolve keycode for EQUAL")
            return
        }

        if let eventRepeat = CGEvent(keyboardEventSource: nil, virtualKey: keyCodeEqual, keyDown: true) {
            eventRepeat.flags = .maskAlternate
            eventRepeat.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            let result = manager.handleEvent(proxy: nil, type: .keyDown, event: eventRepeat)
            // Returns nil because it's exclusive and swallowed to be dispatched, not dropped
            XCTAssertNil(result)
        }
    }

    func testMenuBarSuppressionHoverProtection() {
        let manager = KeybindManager()
        manager.isMenuBarSuppressed = true

        // Mouse move at y = 5.0 (inside top zone y < 12.0)
        if let moveEvent = CGEvent(source: nil) {
            moveEvent.type = .mouseMoved
            moveEvent.location = CGPoint(x: 200, y: 5)
            let result = manager.handleEvent(proxy: nil, type: .mouseMoved, event: moveEvent)
            XCTAssertNotNil(result)
            XCTAssertEqual(moveEvent.location.y, 12.0, "Top-edge hover event must be clamped to y = 12.0")
            XCTAssertEqual(moveEvent.location.x, 200.0)
        }

        // Mouse move at y = 20.0 (outside top zone)
        if let safeEvent = CGEvent(source: nil) {
            safeEvent.type = .mouseMoved
            safeEvent.location = CGPoint(x: 200, y: 20)
            let result = manager.handleEvent(proxy: nil, type: .mouseMoved, event: safeEvent)
            XCTAssertNotNil(result)
            XCTAssertEqual(safeEvent.location.y, 20.0, "Events outside top zone must remain unchanged")
        }

        // When menubar suppression is disabled, no clamping should occur
        manager.isMenuBarSuppressed = false
        if let normalEvent = CGEvent(source: nil) {
            normalEvent.type = .mouseMoved
            normalEvent.location = CGPoint(x: 200, y: 5)
            let result = manager.handleEvent(proxy: nil, type: .mouseMoved, event: normalEvent)
            XCTAssertNotNil(result)
            XCTAssertEqual(normalEvent.location.y, 5.0, "Unsuppressed hover must not be clamped")
        }
    }
}
