import XCTest
import CoreGraphics
@testable import HyprMac

@MainActor
final class WindowRuleTests: XCTestCase {

    // MARK: - ConfigParser windowrule (v1) Tests

    func testParseWindowRuleV1DefaultClass() {
        let input = "windowrule = float, ^(kitty)$"
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.windowRules.count, 1)
        let rule = config.windowRules[0]
        XCTAssertEqual(rule.action, .float)
        XCTAssertEqual(rule.criteria, [.class(pattern: "^(kitty)$")])
    }

    func testParseWindowRuleV1ExplicitClass() {
        let input = "windowrule = tile, class:^(com.apple.Calculator)$"
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.windowRules.count, 1)
        let rule = config.windowRules[0]
        XCTAssertEqual(rule.action, .tile)
        XCTAssertEqual(rule.criteria, [.class(pattern: "^(com.apple.Calculator)$")])
    }

    func testParseWindowRuleV1SizeAndCenter() {
        let input = """
        windowrule = size 800 600, class:Finder
        windowrule = center, class:Finder
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.windowRules.count, 2)
        XCTAssertEqual(config.windowRules[0].action, .size(width: 800, height: 600))
        XCTAssertEqual(config.windowRules[0].criteria, [.class(pattern: "Finder")])
        XCTAssertEqual(config.windowRules[1].action, .center)
        XCTAssertEqual(config.windowRules[1].criteria, [.class(pattern: "Finder")])
    }

    func testParseWindowRuleV1Opacity() {
        let input = """
        windowrule = opacity 0.90 0.80, Spotify
        windowrule = opacity 0.85, Discord
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.windowRules.count, 2)
        XCTAssertEqual(config.windowRules[0].action, .opacity(active: 0.90, inactive: 0.80))
        XCTAssertEqual(config.windowRules[0].criteria, [.class(pattern: "Spotify")])
        XCTAssertEqual(config.windowRules[1].action, .opacity(active: 0.85, inactive: nil))
        XCTAssertEqual(config.windowRules[1].criteria, [.class(pattern: "Discord")])
    }

    func testParseWindowRuleV1StyleModifiers() {
        let input = """
        windowrule = noborder, class:kitty
        windowrule = noshadow, class:kitty
        windowrule = rounding 12, class:kitty
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.windowRules.count, 3)
        XCTAssertEqual(config.windowRules[0].action, .noborder)
        XCTAssertEqual(config.windowRules[1].action, .noshadow)
        XCTAssertEqual(config.windowRules[2].action, .rounding(12))
    }

    func testParseWindowRuleV1PinAndWorkspace() {
        let input = """
        windowrule = pin, title:Picture-in-Picture
        windowrule = workspace 3, class:Discord
        windowrule = workspace 4 silent, class:Slack
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.windowRules.count, 3)
        XCTAssertEqual(config.windowRules[0].action, .pin)
        XCTAssertEqual(config.windowRules[0].criteria, [.title(pattern: "Picture-in-Picture")])
        XCTAssertEqual(config.windowRules[1].action, .workspace(number: 3, silent: false))
        XCTAssertEqual(config.windowRules[2].action, .workspace(number: 4, silent: true))
    }

    // MARK: - ConfigParser windowrulev2 Tests

    func testParseWindowRuleV2MultipleCriteria() {
        let input = "windowrulev2 = float, class:^(kitty)$, title:^(kitty)$, floating:0, workspace:1"
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.windowRules.count, 1)
        let rule = config.windowRules[0]
        XCTAssertEqual(rule.action, .float)
        XCTAssertEqual(rule.criteria, [
            .class(pattern: "^(kitty)$"),
            .title(pattern: "^(kitty)$"),
            .floating(false),
            .workspace(1)
        ])
    }

    func testParseWindowRuleV2WorkspaceUnset() {
        let input = "windowrulev2 = workspace unset, class:Safari"
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.windowRules.count, 1)
        XCTAssertEqual(config.windowRules[0].action, .workspace(number: 0, silent: false))
        XCTAssertEqual(config.windowRules[0].criteria, [.class(pattern: "Safari")])
    }

    func testParseWindowRuleV2FloatingTrue() {
        let input = "windowrulev2 = noborder, class:.*, floating:1"
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.windowRules.count, 1)
        XCTAssertEqual(config.windowRules[0].action, .noborder)
        XCTAssertEqual(config.windowRules[0].criteria, [.class(pattern: ".*"), .floating(true)])
    }

    // MARK: - HyprWindowRule.matches Tests

    func testHyprWindowRuleMatchesClassBundleID() {
        let rule = HyprWindowRule(action: .float, criteria: [.class(pattern: "^(com\\.apple\\.Calculator)$")])
        XCTAssertTrue(rule.matches(
            bundleID: "com.apple.Calculator",
            appName: "Calculator",
            title: "Calculator",
            isFloating: false,
            workspace: 1
        ))
        XCTAssertFalse(rule.matches(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            title: "Safari",
            isFloating: false,
            workspace: 1
        ))
    }

    func testHyprWindowRuleMatchesClassAppName() {
        let rule = HyprWindowRule(action: .float, criteria: [.class(pattern: "^(kitty)$")])
        XCTAssertTrue(rule.matches(
            bundleID: "net.kovidgoyal.kitty",
            appName: "kitty",
            title: "Terminal",
            isFloating: false,
            workspace: 1
        ))
        XCTAssertTrue(rule.matches(
            bundleID: "",
            appName: "Kitty",
            title: "Terminal",
            isFloating: false,
            workspace: 1
        ))
    }

    func testHyprWindowRuleMatchesTitle() {
        let rule = HyprWindowRule(action: .pin, criteria: [.title(pattern: "^Picture-in-Picture$")])
        XCTAssertTrue(rule.matches(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            title: "Picture-in-Picture",
            isFloating: true,
            workspace: 1
        ))
        XCTAssertFalse(rule.matches(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            title: "YouTube - Safari",
            isFloating: true,
            workspace: 1
        ))
    }

    func testHyprWindowRuleMatchesFloating() {
        let rule = HyprWindowRule(action: .noborder, criteria: [.floating(true)])
        XCTAssertTrue(rule.matches(
            bundleID: "com.apple.finder",
            appName: "Finder",
            title: "Documents",
            isFloating: true,
            workspace: 1
        ))
        XCTAssertFalse(rule.matches(
            bundleID: "com.apple.finder",
            appName: "Finder",
            title: "Documents",
            isFloating: false,
            workspace: 1
        ))
    }

    func testHyprWindowRuleMatchesWorkspace() {
        let rule = HyprWindowRule(action: .tile, criteria: [.workspace(2)])
        XCTAssertTrue(rule.matches(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            title: "Web",
            isFloating: false,
            workspace: 2
        ))
        XCTAssertFalse(rule.matches(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            title: "Web",
            isFloating: false,
            workspace: 1
        ))
    }

    func testHyprWindowRuleMatchesMultipleCriteria() {
        let rule = HyprWindowRule(action: .float, criteria: [
            .class(pattern: "kitty"),
            .title(pattern: "floating"),
            .workspace(1)
        ])
        XCTAssertTrue(rule.matches(
            bundleID: "net.kovidgoyal.kitty",
            appName: "kitty",
            title: "kitty - floating window",
            isFloating: false,
            workspace: 1
        ))
        // Mismatched title
        XCTAssertFalse(rule.matches(
            bundleID: "net.kovidgoyal.kitty",
            appName: "kitty",
            title: "kitty - main terminal",
            isFloating: false,
            workspace: 1
        ))
        // Mismatched workspace
        XCTAssertFalse(rule.matches(
            bundleID: "net.kovidgoyal.kitty",
            appName: "kitty",
            title: "kitty - floating window",
            isFloating: false,
            workspace: 2
        ))
    }

    // MARK: - WorkspaceManager Pinned Windows Tests

    func testWorkspaceManagerPinWindowStayVisibleAcrossWorkspaceSwitches() {
        let manager = WorkspaceManager()
        let dwindle = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        let border = BorderManager()
        let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Setup windows on workspace 1 and 2
        manager.assignWindow(wid: 101, to: 1)
        manager.assignWindow(wid: 102, to: 1)
        manager.assignWindow(wid: 201, to: 2)

        // Pin window 101
        manager.pinWindow(101)
        XCTAssertTrue(manager.isPinned(101), "Window 101 must be pinned")
        XCTAssertTrue(manager.activeWindowIDs().contains(101))

        // Switch to Workspace 2
        manager.switchToWorkspace(number: 2, in: screenBounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.activeWorkspace, 2)

        // Pinned window 101 must remain visible in activeWindowIDs on Workspace 2 alongside 201!
        let activeOnWs2 = manager.activeWindowIDs()
        XCTAssertTrue(activeOnWs2.contains(101), "Pinned window 101 must remain active on Workspace 2")
        XCTAssertTrue(activeOnWs2.contains(201), "Workspace 2 window 201 must be active")

        // Dwindle tiling must exempt pinned windows (only tile window 201)
        XCTAssertEqual(dwindle.managedWindowOrder, [201], "Dwindle layout must only tile non-pinned/non-floating windows")

        // Switch to Workspace 3
        manager.switchToWorkspace(number: 3, in: screenBounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.activeWorkspace, 3)
        XCTAssertTrue(manager.activeWindowIDs().contains(101), "Pinned window 101 must remain active on Workspace 3")

        // Unpin window 101
        manager.unpinWindow(101)
        XCTAssertFalse(manager.isPinned(101), "Window 101 must now be unpinned")
        XCTAssertFalse(manager.activeWindowIDs().contains(101), "Unpinned window 101 must no longer be active on Workspace 3")
    }

    func testWorkspaceManagerHideWindowRejectsPinnedWindow() {
        let manager = WorkspaceManager()
        manager.assignWindow(wid: 301, to: 1)
        manager.pinWindow(301)

        // Attempting to hide a pinned window must fail closed (return false)
        let hidden = manager.hideWindow(wid: 301)
        XCTAssertFalse(hidden, "hideWindow must reject pinned windows and keep them on screen")
    }

    func testFocusedWindowInfoBundleID() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let appkitFrame = NSRect(x: 0, y: 0, width: 800, height: 600)

        // Default bundleID
        let defaultInfo = FocusedWindowInfo(
            windowID: 10,
            processID: 100,
            appName: "App",
            title: "Title",
            bounds: frame,
            appkitFrame: appkitFrame
        )
        XCTAssertEqual(defaultInfo.bundleID, "")

        // Explicit bundleID
        let customInfo = FocusedWindowInfo(
            windowID: 10,
            processID: 100,
            appName: "App",
            title: "Title",
            bounds: frame,
            appkitFrame: appkitFrame,
            bundleID: "com.example.app"
        )
        XCTAssertEqual(customInfo.bundleID, "com.example.app")
        XCTAssertNotEqual(defaultInfo, customInfo)
    }
}
