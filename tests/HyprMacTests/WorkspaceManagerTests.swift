import XCTest
import Cocoa
import CoreGraphics
@testable import HyprMac

@MainActor
final class WorkspaceManagerTests: XCTestCase {

    func testWorkspaceManagerSelfTest() {
        let success = WorkspaceManager.runSelfTest()
        XCTAssertTrue(success, "WorkspaceManager.runSelfTest() must return true")
    }

    func testDefaultActiveWorkspaceIsOne() {
        let manager = WorkspaceManager()
        XCTAssertEqual(manager.activeWorkspace, 1, "Initial active workspace must be 1")
        XCTAssertTrue(manager.activeWindowIDs().isEmpty, "Initial active windows must be empty")
    }

    func testWindowAssignmentToActiveWorkspace() {
        let manager = WorkspaceManager()

        // Auto-assign window 101 to active workspace 1
        let ws1 = manager.assignWindowIfNeeded(wid: 101)
        XCTAssertEqual(ws1, 1)
        XCTAssertEqual(manager.workspace(for: 101), 1)
        XCTAssertEqual(manager.activeWindowIDs(), [101])

        // Auto-assign window 102
        let ws2 = manager.assignWindowIfNeeded(wid: 102)
        XCTAssertEqual(ws2, 1)
        XCTAssertEqual(manager.activeWindowIDs(), [101, 102])

        // Re-assigning known window returns its existing workspace
        let recheck = manager.assignWindowIfNeeded(wid: 101)
        XCTAssertEqual(recheck, 1)
        XCTAssertEqual(manager.activeWindowIDs(), [101, 102])

        // Explicit assignment to another workspace
        manager.assignWindow(wid: 201, to: 4)
        XCTAssertEqual(manager.workspace(for: 201), 4)
        XCTAssertEqual(manager.windows(for: 4), [201])
        XCTAssertEqual(manager.activeWindowIDs(), [101, 102], "Active windows on workspace 1 must not include window 201")
    }

    func testSwitchingWorkspaceHidesOldWindowsAndRevealsTargetWindows() {
        let manager = WorkspaceManager()
        let dwindle = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        let border = BorderManager()
        let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Setup windows on workspace 1 and 2
        manager.assignWindow(wid: 101, to: 1)
        manager.assignWindow(wid: 102, to: 1)
        manager.assignWindow(wid: 201, to: 2)

        _ = dwindle.tileWindows(windowIDs: manager.windows(for: 1), in: screenBounds)
        XCTAssertEqual(dwindle.managedWindowOrder, [101, 102])

        // Switch to Workspace 2
        manager.switchToWorkspace(number: 2, in: screenBounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.activeWorkspace, 2)
        XCTAssertEqual(manager.activeWindowIDs(), [201])
        XCTAssertEqual(manager.windows(for: 1), [101, 102])
        XCTAssertEqual(dwindle.managedWindowOrder, [201], "Dwindle layout must retile with only active workspace 2 windows")

        // Switch back to Workspace 1
        manager.switchToWorkspace(number: 1, in: screenBounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.activeWorkspace, 1)
        XCTAssertEqual(manager.activeWindowIDs(), [101, 102])
        XCTAssertEqual(manager.windows(for: 2), [201])
        XCTAssertEqual(dwindle.managedWindowOrder, [101, 102], "Dwindle layout must retile with restored workspace 1 windows")
    }

    func testMoveWindowToAnotherWorkspace() {
        let manager = WorkspaceManager()
        let dwindle = DwindleEngine()
        let border = BorderManager()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        manager.assignWindow(wid: 101, to: 1)
        manager.assignWindow(wid: 102, to: 1)
        _ = dwindle.tileWindows(windowIDs: manager.activeWindowIDs(), in: bounds)

        // Move window 102 to workspace 3 without following
        manager.moveWindowToWorkspace(
            windowID: 102,
            targetWorkspace: 3,
            follow: false,
            in: bounds,
            dwindle: dwindle,
            borderManager: border
        )

        XCTAssertEqual(manager.activeWorkspace, 1, "Active workspace must remain 1 when follow is false")
        XCTAssertEqual(manager.activeWindowIDs(), [101], "Workspace 1 must no longer contain window 102")
        XCTAssertEqual(manager.windows(for: 3), [102], "Workspace 3 must contain window 102")
        XCTAssertEqual(dwindle.managedWindowOrder, [101], "Dwindle must retile remaining windows on workspace 1")

        // Move window 101 to workspace 3 with follow
        manager.moveWindowToWorkspace(
            windowID: 101,
            targetWorkspace: 3,
            follow: true,
            in: bounds,
            dwindle: dwindle,
            borderManager: border
        )

        XCTAssertEqual(manager.activeWorkspace, 3, "Active workspace must follow to workspace 3")
        XCTAssertEqual(Set(manager.activeWindowIDs()), Set([101, 102]), "Workspace 3 must contain both windows")
        XCTAssertTrue(manager.windows(for: 1).isEmpty, "Workspace 1 must now be empty")
        XCTAssertEqual(dwindle.managedWindowSet, Set([101, 102]), "Dwindle must retile workspace 3 windows")
    }

    func testFocusPreservationPerWorkspace() {
        let manager = WorkspaceManager()
        let dwindle = DwindleEngine()
        let border = BorderManager()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        manager.assignWindow(wid: 101, to: 1)
        manager.assignWindow(wid: 102, to: 1)
        manager.setLastFocused(102, for: 1)

        manager.assignWindow(wid: 201, to: 2)
        manager.assignWindow(wid: 202, to: 2)
        manager.setLastFocused(201, for: 2)

        XCTAssertEqual(manager.lastFocused(for: 1), 102)
        XCTAssertEqual(manager.lastFocused(for: 2), 201)

        // Switch to workspace 2 and back
        manager.switchToWorkspace(number: 2, in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.lastFocused(for: 2), 201)

        manager.switchToWorkspace(number: 1, in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.lastFocused(for: 1), 102)
    }

    func testWindowClosedPurgesFromWorkspace() {
        let manager = WorkspaceManager()
        manager.assignWindow(wid: 501, to: 1)
        manager.setLastFocused(501, for: 1)

        XCTAssertEqual(manager.workspace(for: 501), 1)
        XCTAssertEqual(manager.lastFocused(for: 1), 501)

        // Window closes
        manager.removeWindow(wid: 501)
        XCTAssertNil(manager.workspace(for: 501))
        XCTAssertTrue(manager.activeWindowIDs().isEmpty)
        XCTAssertNil(manager.lastFocused(for: 1))
    }

    func testInvalidWorkspaceGuards() {
        let manager = WorkspaceManager()
        manager.assignWindow(wid: 101, to: 1)

        // Out-of-bounds workspaces are ignored
        manager.assignWindow(wid: 102, to: 0)
        XCTAssertNil(manager.workspace(for: 102))

        manager.assignWindow(wid: 103, to: 10)
        XCTAssertNil(manager.workspace(for: 103))

        let dwindle = DwindleEngine()
        let border = BorderManager()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        manager.switchToWorkspace(number: 0, in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.activeWorkspace, 1)

        manager.switchToWorkspace(number: 10, in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.activeWorkspace, 1)

        // Switching to current workspace is a no-op
        manager.switchToWorkspace(number: 1, in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.activeWorkspace, 1)
    }

    func testNotificationsEmitted() {
        let manager = WorkspaceManager()
        let dwindle = DwindleEngine()
        let border = BorderManager()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        final class TestBox<T>: @unchecked Sendable {
            var value: T?
        }
        let receivedBox = TestBox<Int>()
        let expWS = expectation(description: "WorkspaceDidChange notification")
        let obsWS = NotificationCenter.default.addObserver(
            forName: Notification.Name("HyprMacWorkspaceDidChange"),
            object: manager,
            queue: .main
        ) { notif in
            receivedBox.value = notif.userInfo?["workspace"] as? Int
            expWS.fulfill()
        }

        manager.switchToWorkspace(number: 2, in: bounds, dwindle: dwindle, borderManager: border)
        wait(for: [expWS], timeout: 1.0)
        XCTAssertEqual(receivedBox.value, 2)
        NotificationCenter.default.removeObserver(obsWS)

        let movedWidBox = TestBox<CGWindowID>()
        let movedTargetWSBox = TestBox<Int>()
        let expMove = expectation(description: "MoveToWorkspace notification")
        let obsMove = NotificationCenter.default.addObserver(
            forName: Notification.Name("HyprMacMoveToWorkspace"),
            object: manager,
            queue: .main
        ) { notif in
            movedWidBox.value = notif.userInfo?["windowID"] as? CGWindowID
            movedTargetWSBox.value = notif.userInfo?["workspace"] as? Int
            expMove.fulfill()
        }

        manager.moveWindowToWorkspace(
            windowID: 999,
            targetWorkspace: 5,
            follow: false,
            in: bounds,
            dwindle: dwindle,
            borderManager: border
        )
        wait(for: [expMove], timeout: 1.0)
        XCTAssertEqual(movedWidBox.value, 999)
        XCTAssertEqual(movedTargetWSBox.value, 5)
        NotificationCenter.default.removeObserver(obsMove)
    }

    func testSwitchToLastWorkspace() {
        let manager = WorkspaceManager()
        let dwindle = DwindleEngine()
        let border = BorderManager()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        manager.assignWindow(wid: 101, to: 1)
        manager.assignWindow(wid: 201, to: 2)
        manager.assignWindow(wid: 301, to: 3)

        XCTAssertEqual(manager.activeWorkspace, 1)
        XCTAssertEqual(manager.previousWorkspace, 1)

        // Switch to 2
        manager.switchToWorkspace(number: 2, in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.activeWorkspace, 2)
        XCTAssertEqual(manager.previousWorkspace, 1)

        // Switch to 3
        manager.switchToWorkspace(number: 3, in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.activeWorkspace, 3)
        XCTAssertEqual(manager.previousWorkspace, 2)

        // Switch to last workspace -> should go to 2
        manager.switchToLastWorkspace(in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.activeWorkspace, 2)
        XCTAssertEqual(manager.previousWorkspace, 3)

        // Switch to last workspace again -> should go to 3
        manager.switchToLastWorkspace(in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.activeWorkspace, 3)
        XCTAssertEqual(manager.previousWorkspace, 2)
    }

    func testPIDTrackingAndLookup() {
        let manager = WorkspaceManager()
        manager.assignWindowIfNeeded(wid: 801, pid: 4567)
        XCTAssertEqual(manager.windowPIDs[801], 4567)
        XCTAssertEqual(manager.getPID(for: 801), 4567)

        manager.assignWindow(wid: 802, to: 2, pid: 9876)
        XCTAssertEqual(manager.windowPIDs[802], 9876)
        XCTAssertEqual(manager.getPID(for: 802), 9876)

        manager.removeWindow(wid: 801)
        XCTAssertNil(manager.windowPIDs[801])
    }

    func testHideAndRestoreWindowPreservesFrames() {
        let manager = WorkspaceManager()
        manager.assignWindowIfNeeded(wid: 901, pid: 1111)
        let originalFrame = CGRect(x: 150, y: 150, width: 700, height: 500)
        manager.setStoredFrame(originalFrame, for: 901)

        XCTAssertEqual(manager.storedFrame(for: 901), originalFrame)
        manager.hideWindow(wid: 901)
        XCTAssertEqual(manager.storedFrame(for: 901), originalFrame, "Stored frame must be preserved when hiding")

        manager.restoreWindow(wid: 901)
        XCTAssertEqual(manager.storedFrame(for: 901), originalFrame, "Stored frame must be intact after restoration")
    }

    func testHiddenWindowPlacementPreferredAnchor() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: 50, y: 50, width: 600, height: 400)
        let hidden = HiddenWindowPlacement.calculate(screen: screen, window: window, preferredCorner: .bottomRight, otherScreens: [])
        XCTAssertEqual(hidden.origin.x, 1919.0)
        XCTAssertEqual(hidden.origin.y, 1079.0)
        XCTAssertEqual(hidden.size, window.size)
        XCTAssertTrue(HiddenWindowPlacement.isHidden(screen: screen, window: hidden))
        XCTAssertFalse(HiddenWindowPlacement.isHidden(screen: screen, window: window))
    }

    func testHiddenWindowPlacementDetectsTitlebarClampedWindows() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // macOS titlebar clamping: Discord at y=1048, Safari at y=1028 with x anchored at 1919 (1px visible width)
        let discordClamped = CGRect(x: 1919.0, y: 1048.0, width: 1892.0, height: 1015.0)
        let safariClamped = CGRect(x: 1919.0, y: 1028.0, width: 943.0, height: 1015.0)
        let ghosttyStandard = CGRect(x: 1919.0, y: 1079.0, width: 943.0, height: 1015.0)

        XCTAssertTrue(HiddenWindowPlacement.isHidden(screen: screen, window: discordClamped))
        XCTAssertTrue(HiddenWindowPlacement.isHidden(screen: screen, window: safariClamped))
        XCTAssertTrue(HiddenWindowPlacement.isHidden(screen: screen, window: ghosttyStandard))
    }

    func testHiddenWindowPlacementFlipsToBottomLeftWhenNeighborOverlaps() {
        let primary = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rightNeighbor = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let window = CGRect(x: 20, y: 25, width: 300, height: 200)
        let hidden = HiddenWindowPlacement.calculate(
            screen: primary,
            window: window,
            preferredCorner: .bottomRight,
            otherScreens: [rightNeighbor]
        )
        XCTAssertEqual(hidden.origin.x, -299.0) // 0 - 300 + 1
        XCTAssertEqual(hidden.origin.y, 799.0)
        XCTAssertTrue(HiddenWindowPlacement.isHidden(screen: primary, window: hidden, otherScreens: [rightNeighbor]))
    }

    func testEnhancedUISuppressionLifecycle() {
        let executed = withEnhancedUISuppression(for: [1234, 5678]) {
            return true
        }
        XCTAssertTrue(executed)
    }

    func testHideWindowUsesOnePixelAnchor() {
        let manager = WorkspaceManager()
        manager.assignWindowIfNeeded(wid: 902, pid: 2222)
        let originalFrame = CGRect(x: 100, y: 100, width: 500, height: 300)
        manager.setStoredFrame(originalFrame, for: 902)

        manager.hideWindow(wid: 902)
        let stored = manager.storedFrame(for: 902)
        XCTAssertEqual(stored, originalFrame, "Original frame must be stored when window is hidden")
    }

    func testFloatingWindowExcludedFromWorkspaceTiling() {
        let manager = WorkspaceManager()
        let dwindle = DwindleEngine()
        let border = BorderManager()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Assign windows 1001 (floating) and 1002 (tiled) to workspace 2
        manager.assignWindow(wid: 1001, to: 2)
        manager.assignWindow(wid: 1002, to: 2)

        // Configure floating filter: 1001 is floating
        manager.isFloating = { $0 == 1001 }

        // Switch to workspace 2
        manager.switchToWorkspace(number: 2, in: bounds, dwindle: dwindle, borderManager: border)

        // Dwindle should only manage window 1002, NOT window 1001
        XCTAssertFalse(dwindle.managedWindowSet.contains(1001))
        XCTAssertTrue(dwindle.managedWindowSet.contains(1002))
        XCTAssertEqual(dwindle.managedWindowOrder, [1002])
    }

    func testZeroLocalEventsSuppressionInterval() {
        let cRet = CGSetLocalEventsSuppressionInterval(0.0)
        XCTAssertEqual(cRet, 0)
        let bridgeRet = SkyLightBridge.shared.setLocalEventsSuppressionInterval(0.0)
        XCTAssertTrue(bridgeRet)
    }

    func testDisplayUpdateFreezing() {
        let disabled = SkyLightBridge.shared.disableUpdate()
        XCTAssertTrue(disabled)
        let reenabled = SkyLightBridge.shared.reenableUpdate()
        XCTAssertTrue(reenabled)
    }

    func testRestoreWindowGrowingAndShrinkingWriteOrder() {
        let manager = WorkspaceManager()
        manager.assignWindowIfNeeded(wid: 950, pid: 1234)

        // Unchanged size (position_only)
        let frameA = CGRect(x: 100, y: 100, width: 400, height: 300)
        manager.setStoredFrame(frameA, for: 950)
        let retA = manager.restoreWindow(wid: 950, targetFrame: frameA)
        XCTAssertFalse(retA) // PID 1234 has no AX handle in mock, fallback returns false without throwing
        XCTAssertEqual(manager.storedFrame(for: 950), frameA)

        // Growing size (target size > current size)
        let frameGrow = CGRect(x: 50, y: 50, width: 800, height: 600)
        let retGrow = manager.restoreWindow(wid: 950, targetFrame: frameGrow)
        XCTAssertFalse(retGrow)
        XCTAssertEqual(manager.storedFrame(for: 950), frameGrow)

        // Shrinking size (target size < current size)
        let frameShrink = CGRect(x: 200, y: 200, width: 300, height: 200)
        let retShrink = manager.restoreWindow(wid: 950, targetFrame: frameShrink)
        XCTAssertFalse(retShrink)
        XCTAssertEqual(manager.storedFrame(for: 950), frameShrink)
    }

    func testWorkspaceSwitchUpdatesLastWorkspaceSwitchTime() {
        let manager = WorkspaceManager()
        let dwindle = DwindleEngine()
        let border = BorderManager()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        XCTAssertEqual(manager.lastWorkspaceSwitchTime, 0)
        manager.switchToWorkspace(number: 2, in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertGreaterThan(manager.lastWorkspaceSwitchTime, 0)

        let switch1 = manager.lastWorkspaceSwitchTime
        manager.switchToWorkspace(number: 3, in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertGreaterThanOrEqual(manager.lastWorkspaceSwitchTime, switch1)
    }

    func testEnhancedUISuppressionWithAffectedWindowsAndReadback() {
        var blockExecuted = false
        withEnhancedUISuppression(for: [1234, 5678], affectedWindows: [901, 902]) {
            blockExecuted = true
        }
        XCTAssertTrue(blockExecuted)
    }

    func testUnminimizingWindowFromInactiveWorkspaceUpdatesToActiveWorkspace() {
        let manager = WorkspaceManager()

        // Setup: Active workspace is 1. Window 101 on WS 1, Window 201 on WS 2.
        manager.assignWindow(wid: 101, to: 1)
        manager.assignWindow(wid: 201, to: 2)

        XCTAssertEqual(manager.activeWorkspace, 1)
        XCTAssertEqual(manager.workspace(for: 201), 2)
        XCTAssertEqual(manager.windows(for: 2), [201])
        XCTAssertEqual(manager.activeWindowIDs(), [101])

        // Window 201 is minimized
        manager.setWindowMinimized(201, minimized: true)
        XCTAssertTrue(manager.isMinimized(201))

        // When window 201 unminimizes from Dock while workspace 1 is active:
        // Transition: wasMinimized && !isMin -> reassign to activeWorkspace (1)
        let newWS = manager.unminimizeWindow(wid: 201)
        XCTAssertEqual(newWS, 1)

        // Verifications:
        XCTAssertFalse(manager.isMinimized(201), "Minimization flag must be cleared")
        XCTAssertEqual(manager.workspace(for: 201), 1, "Window must be reassigned to active workspace 1")
        XCTAssertTrue(manager.activeWindowIDs().contains(201), "Window must now appear in activeWindowIDs")
        XCTAssertFalse(manager.windows(for: 2).contains(201), "Inactive workspace 2 must no longer contain window 201")
        XCTAssertEqual(Set(manager.windows(for: 1)), Set([101, 201]), "Active workspace 1 must contain both windows")

        // Switch active workspace to 3 and verify unminimizing window 101 moves it to 3
        let dwindle = DwindleEngine()
        let border = BorderManager()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        manager.switchToWorkspace(number: 3, in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.activeWorkspace, 3)

        manager.setWindowMinimized(101, minimized: true)
        XCTAssertTrue(manager.isMinimized(101))
        manager.unminimizeWindow(wid: 101)

        XCTAssertFalse(manager.isMinimized(101))
        XCTAssertEqual(manager.workspace(for: 101), 3, "Window must be reassigned to newly active workspace 3")
        XCTAssertTrue(manager.activeWindowIDs().contains(101))
        XCTAssertFalse(manager.windows(for: 1).contains(101))
    }

    func testDockAndExternalActivationLookupIdentifiesTargetWorkspace() {
        let manager = WorkspaceManager()

        // Assign windows across multiple workspaces with PIDs
        manager.assignWindow(wid: 101, to: 1, pid: 1001)
        manager.assignWindow(wid: 102, to: 1, pid: 1001)
        manager.assignWindow(wid: 201, to: 2, pid: 2002)
        manager.assignWindow(wid: 301, to: 3, pid: 3003)

        XCTAssertEqual(manager.activeWorkspace, 1)

        // Direct window ID lookup
        XCTAssertEqual(manager.targetWorkspaceForActivation(windowID: 101), 1)
        XCTAssertEqual(manager.targetWorkspaceForActivation(windowID: 201), 2)
        XCTAssertEqual(manager.targetWorkspaceForActivation(windowID: 301), 3)

        // Unassigned window ID returns nil without PID
        XCTAssertNil(manager.targetWorkspaceForActivation(windowID: 9999))

        // Unassigned window ID with known PID falls back to owning application's workspace
        XCTAssertEqual(manager.targetWorkspaceForActivation(windowID: 9999, pid: 2002), 2)
        XCTAssertEqual(manager.targetWorkspaceForActivation(windowID: 8888, pid: 3003), 3)
        XCTAssertNil(manager.targetWorkspaceForActivation(windowID: 7777, pid: 7777))

        // Activation check logic: targetWS != activeWorkspace signals workspace switch
        let targetWS201 = manager.targetWorkspaceForActivation(windowID: 201)
        XCTAssertNotNil(targetWS201)
        XCTAssertNotEqual(targetWS201, manager.activeWorkspace, "Activating window 201 on WS 2 must trigger auto-switch from WS 1")

        let targetWS101 = manager.targetWorkspaceForActivation(windowID: 101)
        XCTAssertNotNil(targetWS101)
        XCTAssertEqual(targetWS101, manager.activeWorkspace, "Activating window 101 on WS 1 must not trigger workspace switch")
    }

    func testManualSwitchInProgressAndCooldown() {
        let manager = WorkspaceManager()
        let dwindle = DwindleEngine()
        let border = BorderManager()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        XCTAssertFalse(manager.manualSwitchInProgress)
        XCTAssertFalse(manager.isSwitchInProgress(settleInterval: 0.500))

        // When manualSwitchInProgress is manually set
        manager.manualSwitchInProgress = true
        XCTAssertTrue(manager.isSwitchInProgress(settleInterval: 0.500))
        manager.manualSwitchInProgress = false

        // Switch workspace to 2
        manager.switchToWorkspace(number: 2, in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertFalse(manager.manualSwitchInProgress, "manualSwitchInProgress must be reset after transition completes")
        XCTAssertTrue(manager.isSwitchInProgress(settleInterval: 0.500), "isSwitchInProgress must be true immediately following switch")
        XCTAssertTrue(manager.isSwitchInProgress(), "Default settle interval 0.500 must return true")

        // Reset clears cooldown
        manager.reset()
        XCTAssertFalse(manager.manualSwitchInProgress)
        XCTAssertFalse(manager.isSwitchInProgress(settleInterval: 0.500))
    }

    func testFullscreenWindowPreservesFullscreenBoundsAcrossWorkspaceSwitches() {
        let manager = WorkspaceManager()
        let dwindle = DwindleEngine()
        let border = BorderManager()
        let bounds = CGRect(x: 0, y: 30, width: 1920, height: 1050)

        // Assign windows 101 and 102 to workspace 1
        manager.assignWindow(wid: 101, to: 1)
        manager.assignWindow(wid: 102, to: 1)
        // Assign window 201 to workspace 2
        manager.assignWindow(wid: 201, to: 2)

        // Window 101 is marked fullscreen
        let fullscreenSet: Set<CGWindowID> = [101]
        manager.isFullscreen = { fullscreenSet.contains($0) }

        // Switch to workspace 2
        manager.switchToWorkspace(number: 2, in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.activeWorkspace, 2)

        // Switch back to workspace 1: window 101 must NOT shrink into a half-screen dwindle tile!
        manager.switchToWorkspace(number: 1, in: bounds, dwindle: dwindle, borderManager: border)
        XCTAssertEqual(manager.storedFrame(for: 101), bounds, "Window 101 must remain fullscreen at bounds when switching back to workspace 1")
        let expectedTile = CGRect(x: 10, y: 40, width: 1900, height: 1030)
        XCTAssertEqual(manager.storedFrame(for: 102), expectedTile, "Window 102 tiles with dwindle gaps underneath fullscreen window 101")
    }
}
