import XCTest
import CoreGraphics
@testable import HyprMac

@MainActor
final class DwindleEngineTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // MARK: - Helpers

    private func assertNoOverlaps(
        _ frames: [CGWindowID: CGRect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let keys = Array(frames.keys)
        guard keys.count > 1 else { return }
        for i in 0..<keys.count {
            for j in (i + 1)..<keys.count {
                let idA = keys[i]
                let idB = keys[j]
                let frameA = frames[idA]!
                let frameB = frames[idB]!
                let inter = frameA.intersection(frameB)
                let hasOverlap = !inter.isNull && inter.width > 0.0001 && inter.height > 0.0001
                XCTAssertFalse(
                    hasOverlap,
                    "Frames for window \(idA) (\(frameA)) and \(idB) (\(frameB)) overlap with intersection \(inter)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertWithinBounds(
        _ frames: [CGWindowID: CGRect],
        bounds: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (wid, frame) in frames {
            XCTAssertGreaterThanOrEqual(
                frame.minX, bounds.minX - 0.001,
                "Window \(wid) minX (\(frame.minX)) outside bounds minX (\(bounds.minX))",
                file: file, line: line
            )
            XCTAssertGreaterThanOrEqual(
                frame.minY, bounds.minY - 0.001,
                "Window \(wid) minY (\(frame.minY)) outside bounds minY (\(bounds.minY))",
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                frame.maxX, bounds.maxX + 0.001,
                "Window \(wid) maxX (\(frame.maxX)) outside bounds maxX (\(bounds.maxX))",
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                frame.maxY, bounds.maxY + 0.001,
                "Window \(wid) maxY (\(frame.maxY)) outside bounds maxY (\(bounds.maxY))",
                file: file, line: line
            )
            XCTAssertGreaterThan(
                frame.width, 0,
                "Window \(wid) width must be positive",
                file: file, line: line
            )
            XCTAssertGreaterThan(
                frame.height, 0,
                "Window \(wid) height must be positive",
                file: file, line: line
            )
        }
    }

    // MARK: - DwindleNode Tests

    func testNodeInitDefaults() {
        let node = DwindleNode()
        XCTAssertNil(node.windowID)
        XCTAssertEqual(node.box, .zero)
        XCTAssertEqual(node.splitRatio, 1.0)
        XCTAssertEqual(node.splitDirection, .vertical)
        XCTAssertTrue(node.isLeaf)
        XCTAssertNil(node.parent)
        XCTAssertNil(node.children)
    }

    func testNodeIsLeaf() {
        let parent = DwindleNode()
        let left = DwindleNode(windowID: 1)
        let right = DwindleNode(windowID: 2)
        parent.children = (left: left, right: right)
        left.parent = parent
        right.parent = parent

        XCTAssertFalse(parent.isLeaf)
        XCTAssertTrue(left.isLeaf)
        XCTAssertTrue(right.isLeaf)
    }

    func testNodeSibling() {
        let parent = DwindleNode()
        let left = DwindleNode(windowID: 1)
        let right = DwindleNode(windowID: 2)
        parent.children = (left: left, right: right)
        left.parent = parent
        right.parent = parent

        XCTAssertTrue(left.sibling === right)
        XCTAssertTrue(right.sibling === left)
    }

    func testNodeSiblingOfRoot() {
        let root = DwindleNode(windowID: 1)
        XCTAssertNil(root.sibling)
    }

    func testAllLeaves() {
        let root = DwindleNode()
        let n1 = DwindleNode(windowID: 101)
        let p2 = DwindleNode()
        let n2 = DwindleNode(windowID: 102)
        let p3 = DwindleNode()
        let n3 = DwindleNode(windowID: 103)
        let n4 = DwindleNode(windowID: 104)

        root.children = (left: n1, right: p2)
        n1.parent = root
        p2.parent = root

        p2.children = (left: n2, right: p3)
        n2.parent = p2
        p3.parent = p2

        p3.children = (left: n3, right: n4)
        n3.parent = p3
        n4.parent = p3

        let leaves = root.allLeaves()
        XCTAssertEqual(leaves.count, 4)
        let leafIDs = leaves.compactMap { $0.windowID }
        XCTAssertEqual(leafIDs, [101, 102, 103, 104])
    }

    func testFindLeaf() {
        let root = DwindleNode()
        let left = DwindleNode(windowID: 10)
        let right = DwindleNode(windowID: 20)
        root.children = (left: left, right: right)
        left.parent = root
        right.parent = root

        XCTAssertTrue(root.findLeaf(windowID: 10) === left)
        XCTAssertTrue(root.findLeaf(windowID: 20) === right)
        XCTAssertNil(root.findLeaf(windowID: 999))
    }

    func testRecalculate() {
        let root = DwindleNode()
        let left = DwindleNode(windowID: 1)
        let right = DwindleNode(windowID: 2)
        root.children = (left: left, right: right)
        left.parent = root
        right.parent = root

        root.recalculate(in: screen, gapsIn: 5.0, gapsOut: 10.0)

        let leaves = root.allLeaves()
        XCTAssertEqual(leaves.count, 2)

        var frames: [CGWindowID: CGRect] = [:]
        for leaf in leaves {
            guard let wid = leaf.windowID else { continue }
            frames[wid] = leaf.box
            XCTAssertGreaterThan(leaf.box.width, 0)
            XCTAssertGreaterThan(leaf.box.height, 0)
        }

        assertNoOverlaps(frames)
        assertWithinBounds(frames, bounds: screen)
    }

    // MARK: - DwindleEngine Tests

    func testInitDefaults() {
        let engine = DwindleEngine()
        XCTAssertEqual(engine.gapsIn, 5.0)
        XCTAssertEqual(engine.gapsOut, 10.0)
        XCTAssertNil(engine.root)
        XCTAssertNil(engine.lastTargetID)
    }

    func testCustomGaps() {
        let engine = DwindleEngine(gapsIn: 8.0, gapsOut: 16.0)
        XCTAssertEqual(engine.gapsIn, 8.0)
        XCTAssertEqual(engine.gapsOut, 16.0)
    }

    func testAddSingleWindow() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        let frames = engine.addWindow(windowID: 1, in: screen)
        XCTAssertEqual(frames.count, 1)

        let expectedBox = CGRect(
            x: screen.origin.x + 10.0,
            y: screen.origin.y + 10.0,
            width: screen.width - 20.0,
            height: screen.height - 20.0
        )
        XCTAssertEqual(frames[1], expectedBox)
        assertWithinBounds(frames, bounds: screen)
    }

    func testAddTwoWindows() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        engine.addWindow(windowID: 1, in: screen)
        let frames = engine.addWindow(windowID: 2, in: screen)

        XCTAssertEqual(frames.count, 2)
        assertNoOverlaps(frames)
        assertWithinBounds(frames, bounds: screen)
    }

    func testAddThreeWindows() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        engine.addWindow(windowID: 1, in: screen)
        engine.addWindow(windowID: 2, in: screen)
        let frames = engine.addWindow(windowID: 3, in: screen)

        XCTAssertEqual(frames.count, 3)

        // Fibonacci spiral: first split vertical (root), second split horizontal
        guard let root = engine.root else {
            XCTFail("Root node missing")
            return
        }
        XCTAssertEqual(root.splitDirection, .vertical)

        guard let (_, rightChild) = root.children else {
            XCTFail("Root children missing")
            return
        }
        XCTAssertEqual(rightChild.splitDirection, .horizontal)

        assertNoOverlaps(frames)
        assertWithinBounds(frames, bounds: screen)
    }

    func testAddFourWindows() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        engine.addWindow(windowID: 1, in: screen)
        engine.addWindow(windowID: 2, in: screen)
        engine.addWindow(windowID: 3, in: screen)
        let frames = engine.addWindow(windowID: 4, in: screen)

        XCTAssertEqual(frames.count, 4)
        assertNoOverlaps(frames)
        assertWithinBounds(frames, bounds: screen)
    }

    func testRemoveWindow() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        engine.addWindow(windowID: 1, in: screen)
        engine.addWindow(windowID: 2, in: screen)
        engine.addWindow(windowID: 3, in: screen)

        let framesAfterRemoval = engine.removeWindow(windowID: 2, in: screen)
        XCTAssertEqual(framesAfterRemoval.count, 2)
        XCTAssertNotNil(framesAfterRemoval[1])
        XCTAssertNil(framesAfterRemoval[2])
        XCTAssertNotNil(framesAfterRemoval[3])

        assertNoOverlaps(framesAfterRemoval)
        assertWithinBounds(framesAfterRemoval, bounds: screen)
    }

    func testRemoveAllWindows() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        engine.addWindow(windowID: 1, in: screen)
        engine.addWindow(windowID: 2, in: screen)

        _ = engine.removeWindow(windowID: 1, in: screen)
        let frames = engine.removeWindow(windowID: 2, in: screen)

        XCTAssertTrue(frames.isEmpty)
        XCTAssertNil(engine.root)
        XCTAssertNil(engine.lastTargetID)
        XCTAssertTrue(engine.currentFrames().isEmpty)
    }

    func testTileWindows() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        let windowIDs: [CGWindowID] = [10, 20, 30, 40]
        let frames = engine.tileWindows(windowIDs: windowIDs, in: screen)

        XCTAssertEqual(frames.count, 4)
        for wid in windowIDs {
            XCTAssertNotNil(frames[wid])
        }

        assertNoOverlaps(frames)
        assertWithinBounds(frames, bounds: screen)
    }

    func testCurrentFrames() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        XCTAssertTrue(engine.currentFrames().isEmpty)

        engine.tileWindows(windowIDs: [100, 200], in: screen)
        let frames = engine.currentFrames()
        XCTAssertEqual(frames.count, 2)
        XCTAssertNotNil(frames[100])
        XCTAssertNotNil(frames[200])
    }

    func testNoOverlaps() {
        for n in 1...8 {
            let engine = DwindleEngine(gapsIn: 6.0, gapsOut: 12.0)
            let windowIDs = (1...n).map { CGWindowID($0) }
            let frames = engine.tileWindows(windowIDs: windowIDs, in: screen)

            XCTAssertEqual(frames.count, n, "Failed for n = \(n)")
            assertNoOverlaps(frames)
            assertWithinBounds(frames, bounds: screen)
        }
    }

    func testGapEnforcement() {
        let gapsIn: CGFloat = 8.0
        let gapsOut: CGFloat = 16.0
        let engine = DwindleEngine(gapsIn: gapsIn, gapsOut: gapsOut)

        // Single window: test outer gaps on all 4 sides
        let singleFrames = engine.addWindow(windowID: 1, in: screen)
        guard let f1Single = singleFrames[1] else {
            XCTFail("Missing window 1 frame")
            return
        }
        XCTAssertEqual(f1Single.minX - screen.minX, gapsOut, accuracy: 0.001)
        XCTAssertEqual(f1Single.minY - screen.minY, gapsOut, accuracy: 0.001)
        XCTAssertEqual(screen.maxX - f1Single.maxX, gapsOut, accuracy: 0.001)
        XCTAssertEqual(screen.maxY - f1Single.maxY, gapsOut, accuracy: 0.001)

        // Two windows (vertical split): test inner gap between them and outer gaps
        let twoFrames = engine.addWindow(windowID: 2, in: screen)
        guard let f1 = twoFrames[1], let f2 = twoFrames[2] else {
            XCTFail("Missing window 1 or 2 frame")
            return
        }

        // Outer gaps for left window
        XCTAssertEqual(f1.minX - screen.minX, gapsOut, accuracy: 0.001)
        XCTAssertEqual(f1.minY - screen.minY, gapsOut, accuracy: 0.001)
        XCTAssertEqual(screen.maxY - f1.maxY, gapsOut, accuracy: 0.001)

        // Outer gaps for right window
        XCTAssertEqual(screen.maxX - f2.maxX, gapsOut, accuracy: 0.001)
        XCTAssertEqual(f2.minY - screen.minY, gapsOut, accuracy: 0.001)
        XCTAssertEqual(screen.maxY - f2.maxY, gapsOut, accuracy: 0.001)

        // Inner gap between window 1 and window 2
        let gapBetween = f2.minX - f1.maxX
        XCTAssertEqual(gapBetween, gapsIn, accuracy: 0.001)
    }

    func testEmptyTile() {
        let engine = DwindleEngine()
        let frames = engine.tileWindows(windowIDs: [], in: screen)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertNil(engine.root)
        XCTAssertNil(engine.lastTargetID)
    }

    func testRemoveNonexistentWindow() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        engine.tileWindows(windowIDs: [1, 2], in: screen)
        let initialFrames = engine.currentFrames()

        let frames = engine.removeWindow(windowID: 999, in: screen)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames, initialFrames)
    }

    func testSwapWindows() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        let initial = engine.tileWindows(windowIDs: [1, 2], in: screen)
        guard let f1Before = initial[1], let f2Before = initial[2] else {
            XCTFail("Missing initial frames")
            return
        }

        let swapped = engine.swapWindows(windowA: 1, windowB: 2, in: screen)
        guard let f1After = swapped[1], let f2After = swapped[2] else {
            XCTFail("Missing swapped frames")
            return
        }

        // Frame of window 1 after swap should match window 2 before swap
        XCTAssertEqual(f1After, f2Before)
        // Frame of window 2 after swap should match window 1 before swap
        XCTAssertEqual(f2After, f1Before)
        // Managed window order should be updated
        XCTAssertEqual(engine.managedWindowOrder, [2, 1])
    }

    func testToggleSplit() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        engine.addWindow(windowID: 1, in: screen)
        engine.addWindow(windowID: 2, in: screen)

        // Initially split vertically (width >= height)
        XCTAssertEqual(engine.root?.splitDirection, .vertical)

        // Toggle split to horizontal
        let toggled = engine.toggleSplit(for: 2, in: screen)
        XCTAssertEqual(engine.root?.splitDirection, .horizontal)
        assertNoOverlaps(toggled)
        assertWithinBounds(toggled, bounds: screen)

        // Toggle split back to vertical
        let toggledBack = engine.toggleSplit(for: 2, in: screen)
        XCTAssertEqual(engine.root?.splitDirection, .vertical)
        assertNoOverlaps(toggledBack)
        assertWithinBounds(toggledBack, bounds: screen)
    }

    func testAdjustSplitRatio() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        engine.addWindow(windowID: 1, in: screen)
        let initialFrames = engine.addWindow(windowID: 2, in: screen)
        guard let f1Initial = initialFrames[1], let f2Initial = initialFrames[2] else {
            XCTFail("Missing initial frames")
            return
        }

        // Window 1 is left child. Growing window 1 with delta +0.05
        let grownFrames = engine.adjustSplitRatio(delta: 0.05, for: 1, in: screen)
        guard let f1Grown = grownFrames[1], let f2Grown = grownFrames[2] else {
            XCTFail("Missing grown frames")
            return
        }

        XCTAssertGreaterThan(f1Grown.width, f1Initial.width)
        XCTAssertLessThan(f2Grown.width, f2Initial.width)
        assertNoOverlaps(grownFrames)
        assertWithinBounds(grownFrames, bounds: screen)
    }

    func testIsTiled() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        XCTAssertFalse(engine.isTiled(windowID: 10))

        engine.addWindow(windowID: 10, in: screen)
        XCTAssertTrue(engine.isTiled(windowID: 10))

        engine.removeWindow(windowID: 10, in: screen)
        XCTAssertFalse(engine.isTiled(windowID: 10))
    }

    func testFindWindowAtPoint() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        let frames = engine.tileWindows(windowIDs: [1, 2], in: screen)
        guard let f1 = frames[1], let f2 = frames[2] else {
            XCTFail("Missing frames for windows 1 and 2")
            return
        }

        let p1 = CGPoint(x: f1.midX, y: f1.midY)
        let p2 = CGPoint(x: f2.midX, y: f2.midY)

        // Finding window 1 at its center
        XCTAssertEqual(engine.findWindow(at: p1), 1)
        // Finding window 2 at its center
        XCTAssertEqual(engine.findWindow(at: p2), 2)

        // Excluding window 1 when checking p1 returns nil
        XCTAssertNil(engine.findWindow(at: p1, excluding: 1))
        // Excluding window 1 when checking p2 returns window 2
        XCTAssertEqual(engine.findWindow(at: p2, excluding: 1), 2)

        // Point outside screen bounds returns nil
        let pOutside = CGPoint(x: screen.maxX + 100, y: screen.maxY + 100)
        XCTAssertNil(engine.findWindow(at: pOutside))
    }

    func testReconcileFramesSnapBack() {
        let engine = DwindleEngine(gapsIn: 5.0, gapsOut: 10.0)
        let frames = engine.tileWindows(windowIDs: [100, 200, 300], in: screen)
        guard let f100 = frames[100], let f200 = frames[200], let f300 = frames[300] else {
            XCTFail("Missing frames for 100, 200, 300")
            return
        }

        // Window 100: drifted by 20pt (> 2.0 threshold) -> must snap back
        // Window 200: drifted by 0.5pt (<= 2.0 threshold) -> must NOT snap back
        // Window 300: drifted by 50pt but is floating -> must NOT snap back
        let mockBounds: [CGWindowID: CGRect] = [
            100: CGRect(x: f100.origin.x + 20, y: f100.origin.y + 10, width: f100.width, height: f100.height),
            200: CGRect(x: f200.origin.x + 0.5, y: f200.origin.y, width: f200.width, height: f200.height),
            300: CGRect(x: f300.origin.x + 50, y: f300.origin.y + 50, width: f300.width, height: f300.height)
        ]

        var snappedFrames: [CGWindowID: CGRect] = [:]

        let snappedIDs = engine.reconcileFrames(
            threshold: 2.0,
            isFloating: { $0 == 300 },
            boundsProvider: { mockBounds[$0] },
            frameSetter: { wid, frame in
                snappedFrames[wid] = frame
            }
        )

        XCTAssertEqual(snappedIDs, [100])
        XCTAssertEqual(snappedFrames[100], f100)
        XCTAssertNil(snappedFrames[200])
        XCTAssertNil(snappedFrames[300])
    }
}
