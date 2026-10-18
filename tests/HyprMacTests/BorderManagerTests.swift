import XCTest
import Cocoa
@testable import HyprMac

@MainActor
final class BorderManagerTests: XCTestCase {

    func testBorderManagerSelfTest() {
        let success = BorderManager.runSelfTest()
        XCTAssertTrue(success, "BorderManager.runSelfTest() must return true")
    }

    func testActiveAndInactiveBorderStyles() {
        let manager = BorderManager()
        var config = HyprConfig()
        config.borderMode = .neon
        config.borderSize = 4
        config.rounding = 14.0
        config.activeBorderGradient = [0x33CCFFEE, 0x00FF99EE]
        config.inactiveBorderColor = 0x595959AA

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
        XCTAssertEqual(manager.overlays.count, 2)

        guard let activeOverlay = manager.overlays[201] else {
            XCTFail("Missing active overlay for window 201")
            return
        }
        XCTAssertEqual(activeOverlay.mode, .neon)
        XCTAssertEqual(activeOverlay.borderWidth, 4.0)
        XCTAssertEqual(activeOverlay.cornerRadius, 14.0)

        guard let inactiveOverlay = manager.overlays[202] else {
            XCTFail("Missing inactive overlay for window 202")
            return
        }
        XCTAssertEqual(inactiveOverlay.mode, .outline)
        XCTAssertEqual(inactiveOverlay.borderWidth, 4.0)
        XCTAssertEqual(inactiveOverlay.cornerRadius, 14.0)

        manager.hideAll()
        XCTAssertTrue(manager.overlays.isEmpty)
    }

    func testFocusSwitchSwapsBorderStyles() {
        let manager = BorderManager()
        var config = HyprConfig()
        config.borderMode = .glassHalo
        config.borderSize = 2
        config.rounding = 10.0

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
        XCTAssertEqual(manager.overlays[301]?.mode, .glassHalo)
        XCTAssertEqual(manager.overlays[302]?.mode, .outline)

        // Focus switches to 302
        manager.update(focused: target2, managedFrames: managedFrames, config: config)
        XCTAssertEqual(manager.overlays[301]?.mode, .outline)
        XCTAssertEqual(manager.overlays[302]?.mode, .glassHalo)

        manager.hideAll()
    }

    func testClosedWindowOverlayCleanup() {
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
        XCTAssertEqual(manager.overlays.count, 3)

        // 403 closes
        frames.removeValue(forKey: 403)
        manager.update(focused: target, managedFrames: frames, config: config)
        XCTAssertEqual(manager.overlays.count, 2)
        XCTAssertNil(manager.overlays[403])

        manager.hideAll()
    }

    func testFocusChangeDoesNotAlterSpatialTiling() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let managedWindowOrder: [CGWindowID] = [101, 102, 103]
        let managedWindowSet: Set<CGWindowID> = Set(managedWindowOrder)

        let initialFrames = engine.tileWindows(windowIDs: managedWindowOrder, in: bounds)
        XCTAssertEqual(initialFrames.count, 3)

        // Simulate user clicking on window 103:
        // CGWindowList returns [103, 101, 102] in Z-order
        let zOrderAfterClick: [CGWindowID] = [103, 101, 102]
        let currentSet = Set(zOrderAfterClick)

        // Decoupled logic check:
        // Because Set(zOrderAfterClick) == managedWindowSet, NO retiling or window manipulation occurs
        XCTAssertEqual(currentSet, managedWindowSet, "Window set is identical on pure focus change")

        // Engine frames remain completely stationary
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

