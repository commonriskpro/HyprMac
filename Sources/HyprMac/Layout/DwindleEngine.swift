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

    public init(gapsIn: CGFloat = 5.0, gapsOut: CGFloat = 10.0) {
        self.root = nil
        self.gapsIn = gapsIn
        self.gapsOut = gapsOut
        self.lastTargetID = nil
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
            node.recalculate(in: screenBounds, gapsIn: gapsIn, gapsOut: gapsOut)
            return currentFrames()
        }

        // If window already exists, recalculate and return
        if currentRoot.findLeaf(windowID: windowID) != nil {
            lastTargetID = windowID
            currentRoot.recalculate(in: screenBounds, gapsIn: gapsIn, gapsOut: gapsOut)
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

        root?.recalculate(in: screenBounds, gapsIn: gapsIn, gapsOut: gapsOut)
        return currentFrames()
    }

    /// Removes a window leaf node and collapses its sibling into the parent, recalculating the tree.
    @discardableResult
    public func removeWindow(
        windowID: CGWindowID,
        in screenBounds: CGRect
    ) -> [CGWindowID: CGRect] {
        guard let node = root?.findLeaf(windowID: windowID) else {
            return currentFrames()
        }

        guard let parent = node.parent else {
            // Node was root
            root = nil
            lastTargetID = nil
            return [:]
        }

        guard let (left, right) = parent.children else {
            root = nil
            lastTargetID = nil
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
        for wid in windowIDs {
            _ = addWindow(windowID: wid, in: screenBounds)
        }
        return currentFrames()
    }

    /// Returns current mapped window frames from all leaf nodes.
    public func currentFrames() -> [CGWindowID: CGRect] {
        guard let r = root else { return [:] }
        var dict: [CGWindowID: CGRect] = [:]
        for leaf in r.allLeaves() {
            if let wid = leaf.windowID {
                dict[wid] = leaf.box
            }
        }
        return dict
    }

    /// Moves and resizes physical macOS windows using SkyLight and Accessibility APIs.
    public func applyToSystem(
        windowFrames: [CGWindowID: CGRect],
        bridge: SkyLightBridge = .shared
    ) {
        for (wid, frame) in windowFrames {
            // Move via SkyLight bridge
            bridge.moveWindow(windowID: wid, to: frame.origin)
            // Move and resize via Accessibility
            WindowDetector.shared.setWindowFrame(windowID: wid, frame: frame)
        }
    }
}
