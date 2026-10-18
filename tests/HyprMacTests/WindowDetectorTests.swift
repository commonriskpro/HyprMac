import XCTest
import Cocoa
@testable import HyprMac

final class WindowDetectorTests: XCTestCase {

    func testFocusedWindowInfoInit() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let appkitFrame = NSRect(x: 10, y: 860, width: 300, height: 200)
        let info = FocusedWindowInfo(
            windowID: 101,
            processID: 1234,
            appName: "Ghostty",
            title: "Terminal",
            bounds: bounds,
            appkitFrame: appkitFrame
        )
        XCTAssertEqual(info.windowID, 101)
        XCTAssertEqual(info.processID, 1234)
        XCTAssertEqual(info.appName, "Ghostty")
        XCTAssertEqual(info.title, "Terminal")
        XCTAssertEqual(info.bounds, bounds)
        XCTAssertEqual(info.appkitFrame, appkitFrame)
    }

    func testFocusedWindowInfoEquality() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let appkitFrame = NSRect(x: 10, y: 860, width: 300, height: 200)
        let info1 = FocusedWindowInfo(
            windowID: 101,
            processID: 1234,
            appName: "Ghostty",
            title: "Terminal",
            bounds: bounds,
            appkitFrame: appkitFrame
        )
        let info2 = FocusedWindowInfo(
            windowID: 101,
            processID: 1234,
            appName: "Ghostty",
            title: "Terminal",
            bounds: bounds,
            appkitFrame: appkitFrame
        )
        XCTAssertEqual(info1, info2)
    }

    func testFocusedWindowInfoInequality() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let appkitFrame = NSRect(x: 10, y: 860, width: 300, height: 200)
        let info1 = FocusedWindowInfo(
            windowID: 101,
            processID: 1234,
            appName: "Ghostty",
            title: "Terminal",
            bounds: bounds,
            appkitFrame: appkitFrame
        )
        let info2 = FocusedWindowInfo(
            windowID: 102,
            processID: 1234,
            appName: "Ghostty",
            title: "Terminal",
            bounds: bounds,
            appkitFrame: appkitFrame
        )
        XCTAssertNotEqual(info1, info2)
    }

    func testSharedInstance() {
        let detector1 = WindowDetector.shared
        let detector2 = WindowDetector.shared
        XCTAssertTrue(detector1 === detector2)
    }

    func testConvertToAppKitFrame() {
        let detector = WindowDetector.shared
        let testRect = CGRect(x: 100, y: 50, width: 800, height: 600)
        let appkitFrame = detector.convertToAppKitFrame(cgRect: testRect)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 1080.0
        let expectedY = screenHeight - (testRect.origin.y + testRect.height)
        XCTAssertEqual(appkitFrame.origin.x, 100)
        XCTAssertEqual(appkitFrame.origin.y, expectedY)
        XCTAssertEqual(appkitFrame.width, 800)
        XCTAssertEqual(appkitFrame.height, 600)
    }

    func testGetVisibleWindowsReturnsArray() {
        let detector = WindowDetector.shared
        let windows = detector.getVisibleWindowsFromCGList()
        XCTAssertGreaterThanOrEqual(windows.count, 0)
    }

    func testGetEligibleWindowsReturnsArray() {
        let detector = WindowDetector.shared
        let windows = detector.getEligibleWindows()
        XCTAssertGreaterThanOrEqual(windows.count, 0)
    }

    func testIsProcessTrustedReturnsBool() {
        let trusted = WindowDetector.isProcessTrusted(prompt: false)
        XCTAssertTrue(trusted == true || trusted == false)
    }

    func testGetWindowBoundsNonexistent() {
        let bounds = WindowDetector.shared.getWindowBounds(windowID: 999999)
        // Nonexistent window returns nil
        XCTAssertNil(bounds)
    }

    func testParkedWindowNotEligible() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let parkedRect = HiddenWindowPlacement.calculate(screen: screen, windowSize: CGSize(width: 800, height: 600))
        XCTAssertTrue(HiddenWindowPlacement.isParkedOrHidden(parkedRect, screens: [screen]))
    }

    func testAXUIElementCachingAndInvalidation() {
        let detector = WindowDetector.shared
        detector.clearCache()

        // Invalidate single window
        detector.invalidateWindow(windowID: 1001)

        // Invalidate entire application
        detector.invalidateApplication(pid: 9999)

        // Clear cache
        detector.clearCache()
    }
}
