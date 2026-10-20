import XCTest
import Cocoa
@testable import HyprMac

@MainActor
final class BorderManagerTests: XCTestCase {

    func testBorderManagerSelfTest() {
        let success = BorderManager.runSelfTest()
        XCTAssertTrue(success, "BorderManager.runSelfTest() must return true")
    }

    func testFramelessModeSpawnsZeroOverlays() {
        let manager = BorderManager()
        var config = HyprConfig()
        config.borderSize = 0
        config.rounding = 14.0

        let target1 = FocusedWindowInfo(
            windowID: 201,
            processID: 10,
            appName: "Ghostty",
            title: "Terminal",
            bounds: CGRect(x: 10, y: 10, width: 800, height: 600),
            appkitFrame: NSRect(x: 10, y: 10, width: 800, height: 600)
        )

        let managedFrames: [CGWindowID: CGRect] = [
            201: CGRect(x: 10, y: 10, width: 800, height: 600),
            202: CGRect(x: 820, y: 10, width: 800, height: 600)
        ]

        manager.update(focused: target1, managedFrames: managedFrames, config: config)
        XCTAssertTrue(manager.overlays.isEmpty, "Frameless mode must never spawn window overlays")
        XCTAssertFalse(manager.isBorderWindow(windowID: 201))
        XCTAssertFalse(manager.isBorderWindow(windowID: 202))
        XCTAssertEqual(manager.managedWindowIDs, Set([201, 202]))

        manager.hideAll()
        XCTAssertTrue(manager.managedWindowIDs.isEmpty)
    }

    func testFocusSwitchUpdatesManagedWindowsWithoutOverlays() {
        let manager = BorderManager()
        var config = HyprConfig()
        config.borderSize = 0

        let target1 = FocusedWindowInfo(
            windowID: 301,
            processID: 11,
            appName: "App1",
            title: "Title1",
            bounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            appkitFrame: NSRect(x: 0, y: 0, width: 500, height: 500)
        )
        let target2 = FocusedWindowInfo(
            windowID: 302,
            processID: 12,
            appName: "App2",
            title: "Title2",
            bounds: CGRect(x: 500, y: 0, width: 500, height: 500),
            appkitFrame: NSRect(x: 500, y: 0, width: 500, height: 500)
        )
        let managedFrames: [CGWindowID: CGRect] = [
            301: CGRect(x: 0, y: 0, width: 500, height: 500),
            302: CGRect(x: 500, y: 0, width: 500, height: 500)
        ]

        manager.update(focused: target1, managedFrames: managedFrames, config: config)
        XCTAssertTrue(manager.overlays.isEmpty)

        // Focus switches to 302
        manager.update(focused: target2, managedFrames: managedFrames, config: config)
        XCTAssertTrue(manager.overlays.isEmpty)
        XCTAssertEqual(manager.managedWindowIDs, Set([301, 302]))

        manager.hideAll()
    }

    func testClosedWindowCleanup() {
        let manager = BorderManager()
        let config = HyprConfig()

        let target = FocusedWindowInfo(
            windowID: 401,
            processID: 13,
            appName: "App",
            title: "Title",
            bounds: CGRect(x: 0, y: 0, width: 400, height: 400),
            appkitFrame: NSRect(x: 0, y: 0, width: 400, height: 400)
        )
        var frames: [CGWindowID: CGRect] = [
            401: CGRect(x: 0, y: 0, width: 400, height: 400),
            402: CGRect(x: 400, y: 0, width: 400, height: 400),
            403: CGRect(x: 800, y: 0, width: 400, height: 400)
        ]

        manager.update(focused: target, managedFrames: frames, config: config)
        XCTAssertEqual(manager.managedWindowIDs.count, 3)

        // 403 closes
        frames.removeValue(forKey: 403)
        manager.update(focused: target, managedFrames: frames, config: config)
        XCTAssertEqual(manager.managedWindowIDs.count, 2)
        XCTAssertFalse(manager.managedWindowIDs.contains(403))

        manager.hideAll()
    }

    func testFocusChangeDoesNotAlterSpatialTiling() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let managedWindowOrder: [CGWindowID] = [101, 102, 103]
        let managedWindowSet: Set<CGWindowID> = Set(managedWindowOrder)

        let initialFrames = engine.tileWindows(windowIDs: managedWindowOrder, in: bounds)
        XCTAssertEqual(initialFrames.count, 3)

        let zOrderAfterClick: [CGWindowID] = [103, 101, 102]
        let currentSet = Set(zOrderAfterClick)

        XCTAssertEqual(currentSet, managedWindowSet, "Window set is identical on pure focus change")

        let framesAfterFocus = engine.currentFrames()
        XCTAssertEqual(framesAfterFocus, initialFrames, "Windows must remain completely stationary upon focus change")
        XCTAssertEqual(framesAfterFocus[101], initialFrames[101])
        XCTAssertEqual(framesAfterFocus[102], initialFrames[102])
        XCTAssertEqual(framesAfterFocus[103], initialFrames[103])
    }

    func testBorderSizeZeroHidesAllOverlays() {
        let manager = BorderManager()
        var config = HyprConfig()
        config.borderSize = 0

        let target = FocusedWindowInfo(
            windowID: 501,
            processID: 55,
            appName: "FramelessApp",
            title: "Frameless Window",
            bounds: CGRect(x: 10, y: 10, width: 600, height: 400),
            appkitFrame: NSRect(x: 10, y: 10, width: 600, height: 400)
        )
        let frames: [CGWindowID: CGRect] = [
            501: CGRect(x: 10, y: 10, width: 600, height: 400),
            502: CGRect(x: 620, y: 10, width: 600, height: 400)
        ]

        manager.update(focused: target, managedFrames: frames, config: config)
        XCTAssertTrue(manager.overlays.isEmpty, "Overlays must be completely empty when borderSize == 0")
    }
}
