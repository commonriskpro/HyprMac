import XCTest
import CoreGraphics
@testable import HyprMac

@MainActor
final class MultiMonitorAndMasterLayoutTests: XCTestCase {

    // MARK: - MasterEngine Geometry Tests

    func testMasterEngineSingleWindowFillsUsableBounds() {
        let engine = MasterEngine(gapsIn: 10, gapsOut: 20)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let frames = engine.tileWindows(windowIDs: [101], in: screen)
        XCTAssertEqual(frames.count, 1)

        // Usable width: 1920 - 40 = 1880, height: 1080 - 40 = 1040
        let expected = CGRect(x: 20, y: 20, width: 1880, height: 1040)
        XCTAssertEqual(frames[101], expected)
    }

    func testMasterEngineTwoWindowsLeftAndRightOrientations() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let engine = MasterEngine(gapsIn: 10, gapsOut: 20, mfact: 0.60, orientation: .left)

        // 1. Orientation: .left
        let leftFrames = engine.tileWindows(windowIDs: [101, 102], in: screen)
        XCTAssertEqual(leftFrames.count, 2)

        // Available width = 1880 - 10 = 1870
        // Master width = 1870 * 0.60 = 1122
        // Stack width = 1870 - 1122 = 748
        let expectedMaster = CGRect(x: 20, y: 20, width: 1122, height: 1040)
        let expectedStack = CGRect(x: 1152, y: 20, width: 748, height: 1040)

        XCTAssertEqual(leftFrames[101], expectedMaster, "Window 101 must be the Master on the left")
        XCTAssertEqual(leftFrames[102], expectedStack, "Window 102 must be the Stack on the right")

        // 2. Orientation: .right
        engine.orientation = .right
        let rightFrames = engine.recalculate(in: screen)

        let expectedStackLeft = CGRect(x: 20, y: 20, width: 748, height: 1040)
        let expectedMasterRight = CGRect(x: 778, y: 20, width: 1122, height: 1040)

        XCTAssertEqual(rightFrames[102], expectedStackLeft, "Window 102 must be the Stack on the left")
        XCTAssertEqual(rightFrames[101], expectedMasterRight, "Window 101 must be the Master on the right")
    }

    func testMasterEngineThreeWindowsCenterOrientation() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let engine = MasterEngine(gapsIn: 10, gapsOut: 20, mfact: 0.50, orientation: .center)

        let frames = engine.tileWindows(windowIDs: [101, 102, 103], in: screen)
        XCTAssertEqual(frames.count, 3)

        // Usable width = 1880. Two gaps between 3 columns: 2 * 10 = 20
        // Available width = 1860
        // Master width = 1860 * 0.50 = 930
        // Remaining width = 930 -> leftStack = 465, rightStack = 465
        let expectedLeftStack = CGRect(x: 20, y: 20, width: 465, height: 1040)
        let expectedCenterMaster = CGRect(x: 495, y: 20, width: 930, height: 1040)
        let expectedRightStack = CGRect(x: 1435, y: 20, width: 465, height: 1040)

        XCTAssertEqual(frames[102], expectedLeftStack, "Stack window 102 must be in left column")
        XCTAssertEqual(frames[101], expectedCenterMaster, "Master window 101 must be in center column")
        XCTAssertEqual(frames[103], expectedRightStack, "Stack window 103 must be in right column")
    }

    func testMasterEngineFourWindowsVerticalStackTiling() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let engine = MasterEngine(gapsIn: 10, gapsOut: 20, mfact: 0.60, orientation: .left)

        let frames = engine.tileWindows(windowIDs: [101, 102, 103, 104], in: screen)
        XCTAssertEqual(frames.count, 4)

        // Master window 101: width 1122, height 1040
        XCTAssertEqual(frames[101], CGRect(x: 20, y: 20, width: 1122, height: 1040))

        // Stack windows 102, 103, 104: width 748, tiled vertically
        // Usable height = 1040. Two gaps: 20 -> available = 1020 / 3 = 340
        XCTAssertEqual(frames[102], CGRect(x: 1152, y: 20, width: 748, height: 340))
        XCTAssertEqual(frames[103], CGRect(x: 1152, y: 370, width: 748, height: 340))
        XCTAssertEqual(frames[104], CGRect(x: 1152, y: 720, width: 748, height: 340))
    }

    // MARK: - MasterEngine Operations & LayoutMsg Tests

    func testMasterEngineOperationsAndLayoutMsg() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let engine = MasterEngine(gapsIn: 10, gapsOut: 20, mfact: 0.55, orientation: .left)
        _ = engine.tileWindows(windowIDs: [101, 102, 103], in: screen)

        // 1. CycleNext and CyclePrev
        XCTAssertEqual(engine.cycleNext(from: 101), 102)
        XCTAssertEqual(engine.cycleNext(from: 103), 101)
        XCTAssertEqual(engine.cyclePrev(from: 101), 103)
        XCTAssertEqual(engine.cyclePrev(from: 102), 101)

        // 2. SwapWithMaster: window 103 swapped into master position 0
        let swappedFrames = engine.swapWithMaster(windowID: 103, in: screen)
        XCTAssertEqual(engine.managedWindowOrder.first, 103)
        XCTAssertEqual(swappedFrames[103]?.origin.x, 20.0, "Window 103 must now occupy the Master left column")

        // 3. AddMaster and RemoveMaster
        XCTAssertEqual(engine.numMaster, 1)
        _ = engine.addMaster(in: screen)
        XCTAssertEqual(engine.numMaster, 2)
        _ = engine.removeMaster(in: screen)
        XCTAssertEqual(engine.numMaster, 1)

        // 4. HandleLayoutMsg
        let msgRes = engine.handleLayoutMsg("orientationright", activeWindowID: 101, in: screen)
        XCTAssertEqual(engine.orientation, .right)
        XCTAssertEqual(msgRes.focusTarget, 101)

        let mfactRes = engine.handleLayoutMsg("mfact +0.05", activeWindowID: 101, in: screen)
        XCTAssertEqual(engine.mfact, 0.60, accuracy: 1e-4)
        XCTAssertEqual(mfactRes.focusTarget, 101)
    }

    // MARK: - ConfigParser Master & Workspace-Monitor Directives Tests

    func testConfigParserMasterAndWorkspaceMonitorDirectives() {
        let input = """
        master {
            mfact = 0.65
            orientation = center
            new_on_top = true
        }

        workspace = 1, monitor:0
        workspace = 2, monitor:1
        workspace = 3, monitor:DP-1
        """

        let config = ConfigParser.parse(text: input)

        XCTAssertEqual(config.masterMfact, 0.65, accuracy: 1e-4)
        XCTAssertEqual(config.masterOrientation, "center")
        XCTAssertEqual(config.masterNewOnTop, true)

        XCTAssertEqual(config.workspaceMonitorBindings.count, 3)
        XCTAssertEqual(config.workspaceMonitorBindings[1], "0")
        XCTAssertEqual(config.workspaceMonitorBindings[2], "1")
        XCTAssertEqual(config.workspaceMonitorBindings[3], "DP-1")
    }

    // MARK: - Multi-Monitor WorkspaceManager Topology Tests

    func testWorkspaceManagerMultiMonitorTopologyAndReconciliation() {
        let manager = WorkspaceManager()

        let display1: CGDirectDisplayID = 1001
        let display2: CGDirectDisplayID = 1002

        // Bind workspaces
        manager.bindWorkspace(1, toDisplay: display1)
        manager.bindWorkspace(2, toDisplay: display2)

        XCTAssertEqual(manager.displayForWorkspace(1, availableDisplays: [display1, display2]), display1)
        XCTAssertEqual(manager.displayForWorkspace(2, availableDisplays: [display1, display2]), display2)

        // Setup active workspaces per monitor
        manager.setActiveWorkspace(1, for: display1)
        manager.setActiveWorkspace(2, for: display2)
        manager.focusedMonitorID = display1

        // Assign windows to workspaces 1 and 2
        manager.assignWindow(wid: 11, to: 1)
        manager.assignWindow(wid: 12, to: 1)
        manager.assignWindow(wid: 21, to: 2)
        manager.assignWindow(wid: 22, to: 2)

        // Both monitor 1 (ws 1) and monitor 2 (ws 2) active windows must be included in activeWindowIDs()
        let activeIDs = Set(manager.activeWindowIDs())
        XCTAssertTrue(activeIDs.contains(11))
        XCTAssertTrue(activeIDs.contains(12))
        XCTAssertTrue(activeIDs.contains(21))
        XCTAssertTrue(activeIDs.contains(22))

        // Reconcile monitors when display2 is unplugged
        manager.reconcileMonitors(availableDisplays: [display1])
        XCTAssertEqual(manager.activeWorkspaceByMonitor[display2], nil, "Unplugged display must be removed")
        XCTAssertEqual(manager.workspaceMonitorBindings[2], display1, "Unplugged display workspace bindings must migrate to primary display")

        // Reconcile monitors when display3 is hot-plugged
        let display3: CGDirectDisplayID = 1003
        manager.reconcileMonitors(availableDisplays: [display1, display3])
        XCTAssertNotNil(manager.activeWorkspaceByMonitor[display3], "Newly connected display must be assigned an active workspace")
    }

    func testWorkspaceManagerResolveTargetMonitor() {
        let displays: [(id: CGDirectDisplayID, frame: CGRect)] = [
            (id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            (id: 2, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        ]

        // 1. Index resolution
        XCTAssertEqual(WorkspaceManager.resolveTargetMonitor(from: 1, spec: "0", displays: displays), 1)
        XCTAssertEqual(WorkspaceManager.resolveTargetMonitor(from: 1, spec: "1", displays: displays), 2)

        // 2. Relative resolution
        XCTAssertEqual(WorkspaceManager.resolveTargetMonitor(from: 1, spec: "+1", displays: displays), 2)
        XCTAssertEqual(WorkspaceManager.resolveTargetMonitor(from: 2, spec: "-1", displays: displays), 1)
        XCTAssertEqual(WorkspaceManager.resolveTargetMonitor(from: 1, spec: "next", displays: displays), 2)
        XCTAssertEqual(WorkspaceManager.resolveTargetMonitor(from: 2, spec: "prev", displays: displays), 1)

        // 3. Directional resolution
        XCTAssertEqual(WorkspaceManager.resolveTargetMonitor(from: 1, spec: "r", displays: displays), 2)
        XCTAssertEqual(WorkspaceManager.resolveTargetMonitor(from: 1, spec: "right", displays: displays), 2)
        XCTAssertEqual(WorkspaceManager.resolveTargetMonitor(from: 2, spec: "l", displays: displays), 1)
        XCTAssertEqual(WorkspaceManager.resolveTargetMonitor(from: 2, spec: "left", displays: displays), 1)
    }

    func testWorkspaceManagerRetilingWithMasterEngine() {
        let manager = WorkspaceManager()
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        manager.boundsProvider = { screen }

        let master = MasterEngine(gapsIn: 10, gapsOut: 20, mfact: 0.60, orientation: .left)
        manager.masterEngine = master

        manager.assignWindow(wid: 101, to: 1)
        manager.assignWindow(wid: 102, to: 1)
        manager.assignWindow(wid: 201, to: 2)

        // Switch to workspace 2
        manager.switchToWorkspace(2)
        XCTAssertEqual(manager.activeWorkspace, 2)
        XCTAssertEqual(manager.activeWindowIDs(), [201])

        // Switch back to workspace 1
        manager.switchToWorkspace(1)
        XCTAssertEqual(manager.activeWorkspace, 1)
        XCTAssertEqual(Set(manager.activeWindowIDs()), Set([101, 102]))

        // Move window 102 to workspace 2 without following
        manager.moveWindowToWorkspace(windowID: 102, targetWorkspace: 2, follow: false)
        XCTAssertEqual(manager.activeWorkspace, 1)
        XCTAssertEqual(manager.activeWindowIDs(), [101])
        XCTAssertEqual(Set(manager.windows(for: 2)), Set([201, 102]))
        XCTAssertEqual(master.managedWindowOrder, [101], "MasterEngine must retile remaining windows on workspace 1")

        // Move window 101 to workspace 2 with follow
        manager.moveWindowToWorkspace(windowID: 101, targetWorkspace: 2, follow: true)
        XCTAssertEqual(manager.activeWorkspace, 2)
        XCTAssertEqual(Set(manager.activeWindowIDs()), Set([201, 102, 101]))
    }
}

