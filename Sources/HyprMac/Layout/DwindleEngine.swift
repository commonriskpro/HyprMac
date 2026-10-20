import Foundation
import CoreGraphics
import Cocoa
import ApplicationServices

@MainActor
public final class DwindleEngine {
    public var root: DwindleNode?
    public var gapsIn: CGFloat
    public var gapsOut: CGFloat
    public private(set) var lastTargetID: CGWindowID?
    public var managedWindowOrder: [CGWindowID] = []
    public var managedWindowSet: Set<CGWindowID> = []
    public var isFullscreen: (@Sendable (CGWindowID) -> Bool)?
    private var _cachedFrames: [CGWindowID: CGRect]? = nil

    public func invalidateCachedFrames() {
        _cachedFrames = nil
    }

    public init(gapsIn: CGFloat = 5.0, gapsOut: CGFloat = 10.0) {
        self.root = nil
        self.gapsIn = gapsIn
        self.gapsOut = gapsOut
        self.lastTargetID = nil
        self.managedWindowOrder = []
        self.managedWindowSet = []
    }

    /// Adds a window to the Dwindle layout tree.
    /// If empty, occupies the screen respecting gaps_out.
    /// If nodes exist, splits the target window (or active/last added) deciding direction based on aspect ratio (width >= height -> vertical, else horizontal).
    @discardableResult
    public func addWindow(
        windowID: CGWindowID,
        in screenBounds: CGRect,
        targetWindowID: CGWindowID? = nil
    ) -> [CGWindowID: CGRect] {
        guard let currentRoot = root else {
            let node = DwindleNode(windowID: windowID)
            root = node
            lastTargetID = windowID
            if !managedWindowSet.contains(windowID) {
                managedWindowOrder.append(windowID)
                managedWindowSet.insert(windowID)
            }
            node.recalculate(in: screenBounds, gapsIn: gapsIn, gapsOut: gapsOut)
            invalidateCachedFrames()
            return currentFrames()
        }

        // If window already exists, recalculate and return
        if currentRoot.findLeaf(windowID: windowID) != nil {
            lastTargetID = windowID
            if !managedWindowSet.contains(windowID) {
                managedWindowOrder.append(windowID)
                managedWindowSet.insert(windowID)
            }
            currentRoot.recalculate(in: screenBounds, gapsIn: gapsIn, gapsOut: gapsOut)
            invalidateCachedFrames()
            return currentFrames()
        }

        // Find split target node
        var target: DwindleNode? = nil
        if let tid = targetWindowID {
            target = currentRoot.findLeaf(windowID: tid)
        }
        if target == nil, let lastID = lastTargetID {
            target = currentRoot.findLeaf(windowID: lastID)
        }
        if target == nil {
            target = currentRoot.allLeaves().last
        }
        guard let splitTarget = target else {
            return currentFrames()
        }

        // Aspect ratio decision: if width >= height split vertical, else horizontal
        let direction: SplitDirection = (splitTarget.box.width >= splitTarget.box.height) ? .vertical : .horizontal

        let newParent = DwindleNode(
            box: splitTarget.box,
            splitRatio: 1.0,
            splitDirection: direction
        )
        newParent.parent = splitTarget.parent

        let newNode = DwindleNode(windowID: windowID)

        if let parent = splitTarget.parent {
            if parent.children?.left === splitTarget {
                parent.children = (left: newParent, right: parent.children!.right)
            } else if parent.children?.right === splitTarget {
                parent.children = (left: parent.children!.left, right: newParent)
            }
        } else {
            root = newParent
        }

        splitTarget.parent = newParent
        newNode.parent = newParent
        newParent.children = (left: splitTarget, right: newNode)

        lastTargetID = windowID
        if !managedWindowSet.contains(windowID) {
            managedWindowOrder.append(windowID)
            managedWindowSet.insert(windowID)
        }

        root?.recalculate(in: screenBounds, gapsIn: gapsIn, gapsOut: gapsOut)
        invalidateCachedFrames()
        return currentFrames()
    }

    /// Removes a window leaf node and collapses its sibling into the parent, recalculating the tree.
    @discardableResult
    public func removeWindow(
        windowID: CGWindowID,
        in screenBounds: CGRect
    ) -> [CGWindowID: CGRect] {
        managedWindowOrder.removeAll { $0 == windowID }
        managedWindowSet.remove(windowID)

        guard let node = root?.findLeaf(windowID: windowID) else {
            return currentFrames()
        }

        guard let parent = node.parent else {
            // Node was root
            root = nil
            lastTargetID = nil
            invalidateCachedFrames()
            return [:]
        }

        guard let (left, right) = parent.children else {
            root = nil
            lastTargetID = nil
            invalidateCachedFrames()
            return [:]
        }

        let sibling = (left === node) ? right : left
        sibling.parent = parent.parent

        if let grandParent = parent.parent {
            if grandParent.children?.left === parent {
                grandParent.children = (left: sibling, right: grandParent.children!.right)
            } else if grandParent.children?.right === parent {
                grandParent.children = (left: grandParent.children!.left, right: sibling)
            }
        } else {
            root = sibling
        }

        // Clean up unlinked node references
        node.parent = nil
        parent.parent = nil
        parent.children = nil

        if lastTargetID == windowID {
            lastTargetID = root?.allLeaves().last?.windowID
        }

        root?.recalculate(in: screenBounds, gapsIn: gapsIn, gapsOut: gapsOut)
        invalidateCachedFrames()
        return currentFrames()
    }

    /// Reconstructs the Dwindle tree from a list of window IDs.
    @discardableResult
    public func tileWindows(
        windowIDs: [CGWindowID],
        in screenBounds: CGRect
    ) -> [CGWindowID: CGRect] {
        root = nil
        lastTargetID = nil
        managedWindowOrder = []
        managedWindowSet = []
        invalidateCachedFrames()
        for wid in windowIDs {
            _ = addWindow(windowID: wid, in: screenBounds)
        }
        return currentFrames()
    }

    /// Swaps the tree positions of two window leaves and recalculates the layout.
    @discardableResult
    public func swapWindows(
        windowA: CGWindowID,
        windowB: CGWindowID,
        in screenBounds: CGRect
    ) -> [CGWindowID: CGRect] {
        guard windowA != windowB else { return currentFrames() }
        guard let nodeA = root?.findLeaf(windowID: windowA),
              let nodeB = root?.findLeaf(windowID: windowB) else {
            return currentFrames()
        }
        nodeA.windowID = windowB
        nodeB.windowID = windowA
        if let idxA = managedWindowOrder.firstIndex(of: windowA),
           let idxB = managedWindowOrder.firstIndex(of: windowB) {
            managedWindowOrder.swapAt(idxA, idxB)
        }
        root?.recalculate(in: screenBounds, gapsIn: gapsIn, gapsOut: gapsOut)
        invalidateCachedFrames()
        return currentFrames()
    }

    /// Toggles the split orientation (vertical <-> horizontal) of the active window or root and recalculates.
    @discardableResult
    public func toggleSplit(
        for windowID: CGWindowID? = nil,
        in screenBounds: CGRect
    ) -> [CGWindowID: CGRect] {
        guard let r = root else { return [:] }
        let targetID = windowID ?? WindowDetector.shared.getFocusedWindow()?.windowID ?? lastTargetID
        var splitNode: DwindleNode? = nil

        if let wid = targetID, let leaf = r.findLeaf(windowID: wid), let p = leaf.parent {
            splitNode = p
        } else if r.children != nil {
            splitNode = r
        }

        if let node = splitNode {
            node.splitDirection = (node.splitDirection == .vertical) ? .horizontal : .vertical
            r.recalculate(in: screenBounds, gapsIn: gapsIn, gapsOut: gapsOut)
            invalidateCachedFrames()
        }
        return currentFrames()
    }

    /// Adjusts the split ratio by delta (e.g. +/- 0.05) on the active window's parent node and recalculates.
    @discardableResult
    public func adjustSplitRatio(
        delta: CGFloat,
        for windowID: CGWindowID? = nil,
        in screenBounds: CGRect
    ) -> [CGWindowID: CGRect] {
        guard let r = root else { return [:] }
        let targetID = windowID ?? WindowDetector.shared.getFocusedWindow()?.windowID ?? lastTargetID
        var targetNode: DwindleNode? = nil

        if let wid = targetID, let leaf = r.findLeaf(windowID: wid), let p = leaf.parent {
            let isRightChild = (p.children?.right === leaf)
            let effectiveDelta = isRightChild ? -delta : delta
            p.splitRatio = max(0.1, min(1.9, p.splitRatio + effectiveDelta))
            targetNode = p
        } else if let p = (r.children != nil ? r : nil) {
            p.splitRatio = max(0.1, min(1.9, p.splitRatio + delta))
            targetNode = p
        }

        if targetNode != nil {
            r.recalculate(in: screenBounds, gapsIn: gapsIn, gapsOut: gapsOut)
            invalidateCachedFrames()
        }
        return currentFrames()
    }

    /// Adjusts the active window size by delta ratio (+/- 0.05).
    @discardableResult
    public func resizeWindow(
        delta: CGFloat,
        for windowID: CGWindowID? = nil,
        in screenBounds: CGRect
    ) -> [CGWindowID: CGRect] {
        adjustSplitRatio(delta: delta, for: windowID, in: screenBounds)
    }

    /// Returns current mapped window frames from all leaf nodes (cached until tree topology or split changes).
    public func currentFrames() -> [CGWindowID: CGRect] {
        if let cached = _cachedFrames {
            return cached
        }
        guard let r = root else { return [:] }
        var dict: [CGWindowID: CGRect] = [:]
        for leaf in r.allLeaves() {
            if let wid = leaf.windowID {
                dict[wid] = leaf.box
            }
        }
        _cachedFrames = dict
        return dict
    }

    /// Moves and resizes physical macOS windows using SkyLight GPU affine animations and Accessibility APIs.
    public func applyToSystem(
        windowFrames: [CGWindowID: CGRect],
        newlyAddedWindows: Set<CGWindowID> = [],
        animated: Bool = true,
        bridge: SkyLightBridge = .shared
    ) {
        bridge.disableUpdate()
        defer { bridge.reenableUpdate() }

        let animEngine = AnimationEngine.shared
        for (wid, targetFrame) in windowFrames {
            if isFullscreen?(wid) == true { continue }
            let curBounds = animEngine.currentVisualFrame(windowID: wid) ?? WindowDetector.shared.getWindowBounds(windowID: wid)
            // Immediately apply physical frame at t = 0 so the application starts resizing
            WindowDetector.shared.setWindowFrame(windowID: wid, frame: targetFrame)

            if animated && animEngine.config.animationsEnabled {
                let borderWid = BorderManager.shared.overlays[wid].flatMap { CGWindowID($0.windowNumber) }
                if newlyAddedWindows.contains(wid) {
                    animEngine.animateIn(windowID: wid, targetFrame: targetFrame, borderWindowID: borderWid)
                    continue
                }
                if let cur = curBounds, cur != targetFrame {
                    animEngine.animateMove(windowID: wid, startFrame: cur, targetFrame: targetFrame, borderWindowID: borderWid, physicalBaseFrame: targetFrame)
                    continue
                }
            }
        }
    }

    /// Checks if a window ID is actively tiled as a leaf in the Dwindle tree.
    public func isTiled(windowID: CGWindowID) -> Bool {
        return managedWindowSet.contains(windowID) && root?.findLeaf(windowID: windowID) != nil
    }

    /// Finds a tiled window leaf whose frame contains the given point, excluding a specified window ID.
    public func findWindow(at point: CGPoint, excluding: CGWindowID? = nil) -> CGWindowID? {
        for (wid, frame) in currentFrames() {
            if let exc = excluding, wid == exc { continue }
            if frame.contains(point) {
                return wid
            }
        }
        return nil
    }

    /// Reconciles physical window bounds with their allocated Dwindle tiles, snapping back any drifted windows.
    @discardableResult
    public func reconcileFrames(
        threshold: CGFloat = 2.0,
        isFloating: (CGWindowID) -> Bool = { _ in false },
        boundsProvider: (CGWindowID) -> CGRect? = { AnimationEngine.shared.currentVisualFrame(windowID: $0) ?? WindowDetector.shared.getWindowBounds(windowID: $0) },
        frameSetter: (CGWindowID, CGRect) -> Void = { wid, frame in
            _ = WindowDetector.shared.setWindowFrame(windowID: wid, frame: frame)
        }
    ) -> [CGWindowID] {
        var snapped: [CGWindowID] = []
        let frames = currentFrames()
        for (wid, allocatedFrame) in frames {
            if isFloating(wid) || isFullscreen?(wid) == true { continue }
            if AnimationEngine.shared.isAnimating(windowID: wid) { continue }
            guard let physBounds = boundsProvider(wid) else { continue }
            let diff = max(
                abs(physBounds.origin.x - allocatedFrame.origin.x),
                abs(physBounds.origin.y - allocatedFrame.origin.y),
                abs(physBounds.width - allocatedFrame.width),
                abs(physBounds.height - allocatedFrame.height)
            )
            if diff > threshold {
                frameSetter(wid, allocatedFrame)
                snapped.append(wid)
            }
        }
        return snapped
    }
}
