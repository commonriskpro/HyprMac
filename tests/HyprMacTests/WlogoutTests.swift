import XCTest
import Cocoa
@testable import HyprMac

@MainActor
final class WlogoutTests: XCTestCase {

    // MARK: - Default Items

    func testDefaultItemsCountAndLabels() {
        let items = WlogoutItem.defaultItems
        XCTAssertEqual(items.count, 6)

        let expectedLabels = ["lock", "suspend", "logout", "shutdown", "reboot", "hibernate"]
        XCTAssertEqual(items.map { $0.label }, expectedLabels)

        let expectedKeybinds: [Character] = ["l", "u", "e", "s", "r", "h"]
        XCTAssertEqual(items.map { $0.keybind }, expectedKeybinds)

        let expectedIcons = ["󰌾", "󰤄", "󰍃", "󰐥", "󰜉", "󰒲"]
        XCTAssertEqual(items.map { $0.text }, expectedIcons)
    }

    func testDefaultItemsDisplayTitlesAndHints() {
        let items = WlogoutItem.defaultItems
        XCTAssertEqual(items[0].displayTitle, "Lock")
        XCTAssertEqual(items[0].keybindHint, "[L]")
        XCTAssertEqual(items[1].displayTitle, "Suspend")
        XCTAssertEqual(items[1].keybindHint, "[U]")
        XCTAssertEqual(items[2].displayTitle, "Logout")
        XCTAssertEqual(items[2].keybindHint, "[E]")
        XCTAssertEqual(items[3].displayTitle, "Shutdown")
        XCTAssertEqual(items[3].keybindHint, "[S]")
        XCTAssertEqual(items[4].displayTitle, "Reboot")
        XCTAssertEqual(items[4].keybindHint, "[R]")
        XCTAssertEqual(items[5].displayTitle, "Hibernate")
        XCTAssertEqual(items[5].keybindHint, "[H]")
    }

    func testFallbackSFSymbolNames() {
        let items = WlogoutItem.defaultItems
        XCTAssertEqual(items[0].fallbackSFSymbolName, "lock.fill")
        XCTAssertEqual(items[1].fallbackSFSymbolName, "moon.fill")
        XCTAssertEqual(items[2].fallbackSFSymbolName, "rectangle.portrait.and.arrow.right")
        XCTAssertEqual(items[3].fallbackSFSymbolName, "power")
        XCTAssertEqual(items[4].fallbackSFSymbolName, "arrow.clockwise")
        XCTAssertEqual(items[5].fallbackSFSymbolName, "powersleep")
    }

    // MARK: - Layout Parsing

    func testParseConcatenatedJsonObjects() {
        let ndjson = """
        {
            "label": "lock",
            "action": "sleep 1; hyprlock",
            "text": "󰌾",
            "keybind": "l"
        }
        {
            "label": "suspend",
            "action": "sleep 1; systemctl suspend",
            "text": "󰤄",
            "keybind": "u"
        }
        """
        let parsed = WlogoutLayoutLoader.parse(jsonString: ndjson)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].label, "lock")
        XCTAssertEqual(parsed[0].keybind, "l")
        XCTAssertEqual(parsed[0].text, "󰌾")
        XCTAssertEqual(parsed[0].actionCommand, "sleep 1; hyprlock")
        XCTAssertEqual(parsed[1].label, "suspend")
        XCTAssertEqual(parsed[1].keybind, "u")
    }

    func testParseStandardJsonArray() {
        let jsonArray = """
        [
            {
                "label": "reboot",
                "actionCommand": "reboot",
                "text": "󰜉",
                "keybind": "r"
            },
            {
                "label": "shutdown",
                "actionCommand": "poweroff",
                "text": "󰐥",
                "keybind": "s"
            }
        ]
        """
        let parsed = WlogoutLayoutLoader.parse(jsonString: jsonArray)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].label, "reboot")
        XCTAssertEqual(parsed[0].actionCommand, "reboot")
        XCTAssertEqual(parsed[1].label, "shutdown")
    }

    func testParseEmptyOrMalformedStringReturnsEmpty() {
        XCTAssertTrue(WlogoutLayoutLoader.parse(jsonString: "").isEmpty)
        XCTAssertTrue(WlogoutLayoutLoader.parse(jsonString: "   ").isEmpty)
        XCTAssertTrue(WlogoutLayoutLoader.parse(jsonString: "not valid json").isEmpty)
    }

    func testLoadItemsFromReferenceConfig() {
        let loader = WlogoutLayoutLoader()
        let items = loader.loadItems(fromPath: "/Users/saturno/Developer/REA/reference/mxmrn/config/wlogout/layout")
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items[0].label, "lock")
        XCTAssertEqual(items[1].label, "suspend")
        XCTAssertEqual(items[2].label, "logout")
        XCTAssertEqual(items[3].label, "shutdown")
        XCTAssertEqual(items[4].label, "reboot")
        XCTAssertEqual(items[5].label, "hibernate")
    }

    func testLoadItemsNonExistentFileFallsBackToDefault() {
        let loader = WlogoutLayoutLoader()
        let items = loader.loadItems(fromPath: "/non/existent/path/layout")
        XCTAssertEqual(items, WlogoutItem.defaultItems)
    }

    // MARK: - Action Resolution & Dispatching

    func testLinuxCommandMappingToMac() {
        let lockItem = WlogoutItem(label: "lock", text: "󰌾", keybind: "l", actionCommand: "sleep 1; hyprlock")
        XCTAssertEqual(lockItem.resolvedMacActionCommand, "/usr/bin/pmset displaysleepnow")

        let suspendItem = WlogoutItem(label: "suspend", text: "󰤄", keybind: "u", actionCommand: "sleep 1; systemctl suspend")
        XCTAssertEqual(suspendItem.resolvedMacActionCommand, "/usr/bin/pmset sleepnow")

        let logoutItem = WlogoutItem(label: "logout", text: "󰍃", keybind: "e", actionCommand: "hyprctl dispatch exit")
        XCTAssertEqual(logoutItem.resolvedMacActionCommand, "hyprmac-logout")

        let shutdownItem = WlogoutItem(label: "shutdown", text: "󰐥", keybind: "s", actionCommand: "sleep 1; systemctl poweroff")
        XCTAssertEqual(shutdownItem.resolvedMacActionCommand, "osascript -e 'tell application \"System Events\" to shut down'")

        let rebootItem = WlogoutItem(label: "reboot", text: "󰜉", keybind: "r", actionCommand: "sleep 1; systemctl reboot")
        XCTAssertEqual(rebootItem.resolvedMacActionCommand, "osascript -e 'tell application \"System Events\" to restart'")

        let customItem = WlogoutItem(label: "custom", text: "󰚥", keybind: "c", actionCommand: "echo hello")
        XCTAssertEqual(customItem.resolvedMacActionCommand, "echo hello")
    }

    func testDispatcherLogoutTriggered() {
        var logoutCalled = false
        var executedCmd: String? = nil
        let dispatcher = WlogoutActionDispatcher(
            commandRunner: { cmd in executedCmd = cmd },
            logoutHandler: { logoutCalled = true }
        )

        let logoutItem = WlogoutItem(label: "logout", text: "󰍃", keybind: "e", actionCommand: "hyprmac-logout")
        dispatcher.dispatch(item: logoutItem)

        XCTAssertTrue(logoutCalled)
        XCTAssertNil(executedCmd)
    }

    func testDispatcherCommandTriggered() {
        var logoutCalled = false
        var executedCmd: String? = nil
        let dispatcher = WlogoutActionDispatcher(
            commandRunner: { cmd in executedCmd = cmd },
            logoutHandler: { logoutCalled = true }
        )

        let lockItem = WlogoutItem(label: "lock", text: "󰌾", keybind: "l", actionCommand: "/usr/bin/pmset displaysleepnow")
        dispatcher.dispatch(item: lockItem)

        XCTAssertFalse(logoutCalled)
        XCTAssertEqual(executedCmd, "/usr/bin/pmset displaysleepnow")
    }

    // MARK: - Window & Keybinds

    func testWindowConfiguration() {
        let window = WlogoutWindow(items: WlogoutItem.defaultItems)
        defer { window.close() }

        XCTAssertEqual(window.level, .screenSaver)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertFalse(window.hasShadow)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.canBecomeMain)
    }

    func testWlogoutWindowShowMenuAndCurrent() {
        let window = WlogoutWindow(items: WlogoutItem.defaultItems)
        defer {
            window.dismiss()
            window.close()
        }
        XCTAssertNotNil(WlogoutWindow.current)
        window.showMenu()
        XCTAssertTrue(window.isVisible)
    }

    func testWindowExecuteAndDismissCallbacks() {
        var executedItem: WlogoutItem? = nil
        var dismissed = false

        let dispatcher = WlogoutActionDispatcher(
            commandRunner: { _ in },
            logoutHandler: { }
        )
        let window = WlogoutWindow(items: WlogoutItem.defaultItems, actionDispatcher: dispatcher)
        defer {
            window.dismiss()
            window.close()
        }
        window.onActionExecuted = { item in executedItem = item }
        window.onDismiss = { dismissed = true }

        let target = WlogoutItem.defaultItems[0]
        window.execute(item: target)
        XCTAssertEqual(executedItem, target)

        window.dismiss()
        XCTAssertTrue(dismissed)
    }

    func testWindowKeyEvents() {
        var executedItem: WlogoutItem? = nil
        var dismissed = false

        let dispatcher = WlogoutActionDispatcher(
            commandRunner: { _ in },
            logoutHandler: { }
        )
        let window = WlogoutWindow(items: WlogoutItem.defaultItems, actionDispatcher: dispatcher)
        defer {
            window.dismiss()
            window.close()
        }
        window.onActionExecuted = { item in executedItem = item }
        window.onDismiss = { dismissed = true }

        // Escape key (keyCode 53)
        if let escEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) {
            window.keyDown(with: escEvent)
            XCTAssertTrue(dismissed)
        }

        // 'l' key for Lock
        if let lEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "l",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 37
        ) {
            window.keyDown(with: lEvent)
            XCTAssertEqual(executedItem?.label, "lock")
        }

        // 'S' uppercase key for Shutdown
        if let sEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "S",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: 1
        ) {
            window.keyDown(with: sEvent)
            XCTAssertEqual(executedItem?.label, "shutdown")
        }
    }
}
