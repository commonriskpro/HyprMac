import Foundation
import CoreGraphics

public enum SplitDirection: Sendable, Equatable {
    case horizontal
    case vertical
}

public final class DwindleNode: @unchecked Sendable {
    public weak var parent: DwindleNode?
    public var children: (left: DwindleNode, right: DwindleNode)?
    public var windowID: CGWindowID?
    public var box: CGRect
    public var splitRatio: CGFloat
    public var splitDirection: SplitDirection

    public init(
        windowID: CGWindowID? = nil,
        box: CGRect = .zero,
        splitRatio: CGFloat = 1.0,
        splitDirection: SplitDirection = .vertical
    ) {
        self.parent = nil
        self.children = nil
        self.windowID = windowID
        self.box = box
        self.splitRatio = splitRatio
        self.splitDirection = splitDirection
    }

    public var isLeaf: Bool {
        return children == nil
    }

    public func allLeaves() -> [DwindleNode] {
        if let (left, right) = children {
            return left.allLeaves() + right.allLeaves()
        } else {
            return [self]
        }
    }

    public func findLeaf(windowID: CGWindowID) -> DwindleNode? {
        if let (left, right) = children {
            return left.findLeaf(windowID: windowID) ?? right.findLeaf(windowID: windowID)
        } else if self.windowID == windowID {
            return self
        }
        return nil
    }

    public var sibling: DwindleNode? {
        guard let p = parent, let (left, right) = p.children else { return nil }
        return (left === self) ? right : left
    }

    /// Recursively calculates window boxes applying gaps_out at the root and gaps_in between adjacent splits
    public func recalculate(in bounds: CGRect, gapsIn: CGFloat, gapsOut: CGFloat) {
        if parent == nil {
            let width = max(0, bounds.width - 2 * gapsOut)
            let height = max(0, bounds.height - 2 * gapsOut)
            self.box = CGRect(
                x: bounds.origin.x + gapsOut,
                y: bounds.origin.y + gapsOut,
                width: width,
                height: height
            )
        } else {
            self.box = bounds
        }

        guard let (left, right) = children else {
            return
        }

        // Determine proportion: default splitRatio 1.0 gives equal 50/50 split (ratio 0.5)
        let ratio = max(0.05, min(0.95, 0.5 * splitRatio))

        switch splitDirection {
        case .vertical:
            // Split along width: left and right children side-by-side
            let availableWidth = max(0, self.box.width - gapsIn)
            let leftWidth = availableWidth * ratio
            let rightWidth = max(0, availableWidth - leftWidth)

            let leftBox = CGRect(
                x: self.box.origin.x,
                y: self.box.origin.y,
                width: leftWidth,
                height: self.box.height
            )
            let rightBox = CGRect(
                x: self.box.origin.x + leftWidth + gapsIn,
                y: self.box.origin.y,
                width: rightWidth,
                height: self.box.height
            )

            left.recalculate(in: leftBox, gapsIn: gapsIn, gapsOut: gapsOut)
            right.recalculate(in: rightBox, gapsIn: gapsIn, gapsOut: gapsOut)

        case .horizontal:
            // Split along height: top and bottom children stacked
            let availableHeight = max(0, self.box.height - gapsIn)
            let topHeight = availableHeight * ratio
            let bottomHeight = max(0, availableHeight - topHeight)

            let topBox = CGRect(
                x: self.box.origin.x,
                y: self.box.origin.y,
                width: self.box.width,
                height: topHeight
            )
            let bottomBox = CGRect(
                x: self.box.origin.x,
                y: self.box.origin.y + topHeight + gapsIn,
                width: self.box.width,
                height: bottomHeight
            )

            left.recalculate(in: topBox, gapsIn: gapsIn, gapsOut: gapsOut)
            right.recalculate(in: bottomBox, gapsIn: gapsIn, gapsOut: gapsOut)
        }
    }
}
