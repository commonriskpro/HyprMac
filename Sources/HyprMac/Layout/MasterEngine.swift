import Foundation
import CoreGraphics
import Cocoa
import ApplicationServices

/// Layout orientation for the Master column in MasterEngine.
public enum MasterOrientation: String, Equatable, Sendable, CaseIterable {
    case left
    case right
    case center
}

/// Dynamic Master-and-Stack layout engine for HyprMac, matching Hyprland's master layout.
/// Features a configurable number of master windows (mfact ratio) and stack columns.
@MainActor
public final class MasterEngine {
    public var gapsIn: CGFloat
    public var gapsOut: CGFloat
    public var mfact: CGFloat = 0.55 {
        didSet {
            mfact = max(0.10, min(0.90, mfact))
        }
    }
    public var numMaster: Int = 1 {
        didSet {
            numMaster = max(1, numMaster)
        }
    }
    public var orientation: MasterOrientation = .left
    public var newOnTop: Bool = false
    public var managedWindowOrder: [CGWindowID] = []
    public var managedWindowSet: Set<CGWindowID> = []
    public var isFullscreen: (@Sendable (CGWindowID) -> Bool)?

    private var _cachedFrames: [CGWindowID: CGRect] = [:]

    public func invalidateCachedFrames() {
        _cachedFrames.removeAll()
    }

    public init(
        gapsIn: CGFloat = 5.0,
        gapsOut: CGFloat = 10.0,
        mfact: CGFloat = 0.55,
        numMaster: Int = 1,
        orientation: MasterOrientation = .left,
        newOnTop: Bool = false
    ) {
        self.gapsIn = gapsIn
        self.gapsOut = gapsOut
        self.mfact = max(0.10, min(0.90, mfact))
        self.numMaster = max(1, numMaster)
        self.orientation = orientation
        self.newOnTop = newOnTop
    }

    // MARK: - Layout Geometry Calculation

    /// Computes physical window frames according to Master/Stack specifications and active screen bounds.
    public func recalculate(in screenBounds: CGRect) -> [CGWindowID: CGRect] {
        guard !managedWindowOrder.isEmpty else {
            _cachedFrames = [:]
            return [:]
        }

        let usableX = screenBounds.origin.x + gapsOut
        let usableY = screenBounds.origin.y + gapsOut
        let usableWidth = max(0.0, screenBounds.width - (2.0 * gapsOut))
        let usableHeight = max(0.0, screenBounds.height - (2.0 * gapsOut))
        let usableRect = CGRect(x: usableX, y: usableY, width: usableWidth, height: usableHeight)

        let totalCount = managedWindowOrder.count
        var frames: [CGWindowID: CGRect] = [:]

        // If total windows <= numMaster: master windows take full width and stack vertically
        if totalCount <= numMaster {
            let colFrames = tileColumn(windows: managedWindowOrder, in: usableRect)
            _cachedFrames = colFrames
            return colFrames
        }

        // More windows than numMaster: split into Master and Stack
        let masterWindows = Array(managedWindowOrder.prefix(numMaster))
        let stackWindows = Array(managedWindowOrder.dropFirst(numMaster))

        switch orientation {
        case .left:
            let availableWidth = max(0.0, usableWidth - gapsIn)
            let masterWidth = availableWidth * mfact
            let stackWidth = availableWidth - masterWidth

            let masterRect = CGRect(x: usableX, y: usableY, width: masterWidth, height: usableHeight)
            let stackRect = CGRect(x: usableX + masterWidth + gapsIn, y: usableY, width: stackWidth, height: usableHeight)

            let mFrames = tileColumn(windows: masterWindows, in: masterRect)
            let sFrames = tileColumn(windows: stackWindows, in: stackRect)
            frames.merge(mFrames) { _, new in new }
            frames.merge(sFrames) { _, new in new }

        case .right:
            let availableWidth = max(0.0, usableWidth - gapsIn)
            let masterWidth = availableWidth * mfact
            let stackWidth = availableWidth - masterWidth

            let stackRect = CGRect(x: usableX, y: usableY, width: stackWidth, height: usableHeight)
            let masterRect = CGRect(x: usableX + stackWidth + gapsIn, y: usableY, width: masterWidth, height: usableHeight)

            let sFrames = tileColumn(windows: stackWindows, in: stackRect)
            let mFrames = tileColumn(windows: masterWindows, in: masterRect)
            frames.merge(sFrames) { _, new in new }
            frames.merge(mFrames) { _, new in new }

        case .center:
            if stackWindows.count == 1 {
                // Single stack window: Master on left, stack on right
                let availableWidth = max(0.0, usableWidth - gapsIn)
                let masterWidth = availableWidth * mfact
                let stackWidth = availableWidth - masterWidth

                let masterRect = CGRect(x: usableX, y: usableY, width: masterWidth, height: usableHeight)
                let stackRect = CGRect(x: usableX + masterWidth + gapsIn, y: usableY, width: stackWidth, height: usableHeight)

                let mFrames = tileColumn(windows: masterWindows, in: masterRect)
                let sFrames = tileColumn(windows: stackWindows, in: stackRect)
                frames.merge(mFrames) { _, new in new }
                frames.merge(sFrames) { _, new in new }
            } else {
                // Multiple stack windows: Left stack, Center master, Right stack
                let availableWidth = max(0.0, usableWidth - (2.0 * gapsIn))
                let masterWidth = availableWidth * mfact
                let remainingWidth = availableWidth - masterWidth
                let leftStackWidth = remainingWidth / 2.0
                let rightStackWidth = remainingWidth - leftStackWidth

                let leftCount = (stackWindows.count + 1) / 2
                let leftStackWindows = Array(stackWindows.prefix(leftCount))
                let rightStackWindows = Array(stackWindows.dropFirst(leftCount))

                let leftRect = CGRect(x: usableX, y: usableY, width: leftStackWidth, height: usableHeight)
                let masterRect = CGRect(x: usableX + leftStackWidth + gapsIn, y: usableY, width: masterWidth, height: usableHeight)
                let rightRect = CGRect(x: usableX + leftStackWidth + gapsIn + masterWidth + gapsIn, y: usableY, width: rightStackWidth, height: usableHeight)

                let lFrames = tileColumn(windows: leftStackWindows, in: leftRect)
                let mFrames = tileColumn(windows: masterWindows, in: masterRect)
                let rFrames = tileColumn(windows: rightStackWindows, in: rightRect)
                frames.merge(lFrames) { _, new in new }
                frames.merge(mFrames) { _, new in new }
                frames.merge(rFrames) { _, new in new }
            }
        }

        _cachedFrames = frames
        return frames
    }

    private func tileColumn(windows: [CGWindowID], in columnRect: CGRect) -> [CGWindowID: CGRect] {
        guard !windows.isEmpty else { return [:] }
        let count = windows.count
        let totalGaps = CGFloat(count - 1) * gapsIn
        let itemH = max(10.0, (columnRect.height - totalGaps) / CGFloat(count))
        var dict: [CGWindowID: CGRect] = [:]
        for (i, wid) in windows.enumerated() {
            let y = columnRect.origin.y + CGFloat(i) * (itemH + gapsIn)
            dict[wid] = CGRect(x: columnRect.origin.x, y: y, width: columnRect.width, height: itemH)
        }
        return dict
    }

    // MARK: - Window Management Operations

    @discardableResult
    public func addWindow(windowID: CGWindowID, in screenBounds: CGRect) -> [CGWindowID: CGRect] {
        if managedWindowSet.contains(windowID) {
            return recalculate(in: screenBounds)
        }
        if newOnTop {
            managedWindowOrder.insert(windowID, at: 0)
        } else {
            managedWindowOrder.append(windowID)
        }
        managedWindowSet.insert(windowID)
        return recalculate(in: screenBounds)
    }

    @discardableResult
    public func removeWindow(windowID: CGWindowID, in screenBounds: CGRect) -> [CGWindowID: CGRect] {
        managedWindowOrder.removeAll(where: { $0 == windowID })
        managedWindowSet.remove(windowID)
        return recalculate(in: screenBounds)
    }

    @discardableResult
    public func tileWindows(windowIDs: [CGWindowID], in screenBounds: CGRect) -> [CGWindowID: CGRect] {
        managedWindowOrder = windowIDs
        managedWindowSet = Set(windowIDs)
        return recalculate(in: screenBounds)
    }

    public func currentFrames() -> [CGWindowID: CGRect] {
        return _cachedFrames
    }

    @discardableResult
    public func swapWindows(windowA: CGWindowID, windowB: CGWindowID, in screenBounds: CGRect) -> [CGWindowID: CGRect] {
        guard let idxA = managedWindowOrder.firstIndex(of: windowA),
              let idxB = managedWindowOrder.firstIndex(of: windowB),
              idxA != idxB else {
            return recalculate(in: screenBounds)
        }
        managedWindowOrder.swapAt(idxA, idxB)
        return recalculate(in: screenBounds)
    }

    @discardableResult
    public func swapWithMaster(windowID: CGWindowID?, in screenBounds: CGRect) -> [CGWindowID: CGRect] {
        guard !managedWindowOrder.isEmpty else { return [:] }
        let target = windowID ?? managedWindowOrder.first!
        guard let idx = managedWindowOrder.firstIndex(of: target) else {
            return recalculate(in: screenBounds)
        }

        if idx == 0 {
            if managedWindowOrder.count > 1 {
                managedWindowOrder.swapAt(0, 1)
            }
        } else {
            managedWindowOrder.swapAt(0, idx)
        }
        return recalculate(in: screenBounds)
    }

    @discardableResult
    public func addMaster(in screenBounds: CGRect) -> [CGWindowID: CGRect] {
        numMaster += 1
        return recalculate(in: screenBounds)
    }

    @discardableResult
    public func removeMaster(in screenBounds: CGRect) -> [CGWindowID: CGRect] {
        numMaster = max(1, numMaster - 1)
        return recalculate(in: screenBounds)
    }

    public func cycleNext(from current: CGWindowID?) -> CGWindowID? {
        guard !managedWindowOrder.isEmpty else { return nil }
        guard let cur = current, let idx = managedWindowOrder.firstIndex(of: cur) else {
            return managedWindowOrder.first
        }
        let nextIdx = (idx + 1) % managedWindowOrder.count
        return managedWindowOrder[nextIdx]
    }

    public func cyclePrev(from current: CGWindowID?) -> CGWindowID? {
        guard !managedWindowOrder.isEmpty else { return nil }
        guard let cur = current, let idx = managedWindowOrder.firstIndex(of: cur) else {
            return managedWindowOrder.last
        }
        let prevIdx = (idx - 1 + managedWindowOrder.count) % managedWindowOrder.count
        return managedWindowOrder[prevIdx]
    }

    public func handleLayoutMsg(
        _ rawMsg: String,
        activeWindowID: CGWindowID?,
        in screenBounds: CGRect
    ) -> (frames: [CGWindowID: CGRect], focusTarget: CGWindowID?) {
        let trimmed = rawMsg.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if lower == "swapwithmaster" {
            let frames = swapWithMaster(windowID: activeWindowID, in: screenBounds)
            return (frames, managedWindowOrder.first)
        } else if lower == "addmaster" {
            let frames = addMaster(in: screenBounds)
            return (frames, activeWindowID)
        } else if lower == "removemaster" {
            let frames = removeMaster(in: screenBounds)
            return (frames, activeWindowID)
        } else if lower == "cyclenext" {
            let target = cycleNext(from: activeWindowID)
            return (currentFrames(), target)
        } else if lower == "cycleprev" {
            let target = cyclePrev(from: activeWindowID)
            return (currentFrames(), target)
        } else if lower == "orientationleft" {
            orientation = .left
            let frames = recalculate(in: screenBounds)
            return (frames, activeWindowID)
        } else if lower == "orientationright" {
            orientation = .right
            let frames = recalculate(in: screenBounds)
            return (frames, activeWindowID)
        } else if lower == "orientationcenter" {
            orientation = .center
            let frames = recalculate(in: screenBounds)
            return (frames, activeWindowID)
        } else if lower.hasPrefix("mfact") {
            let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if tokens.count >= 2, let delta = Double(tokens[1]) {
                if tokens[1].hasPrefix("+") || tokens[1].hasPrefix("-") {
                    mfact += CGFloat(delta)
                } else {
                    mfact = CGFloat(delta)
                }
            }
            let frames = recalculate(in: screenBounds)
            return (frames, activeWindowID)
        }

        return (currentFrames(), activeWindowID)
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
            WindowDetector.shared.setWindowFrame(windowID: wid, frame: targetFrame)

            if animated && animEngine.config.animationsEnabled {
                if newlyAddedWindows.contains(wid) {
                    animEngine.animateIn(windowID: wid, targetFrame: targetFrame)
                    continue
                }
                if let cur = curBounds, cur != targetFrame {
                    animEngine.animateMove(windowID: wid, startFrame: cur, targetFrame: targetFrame, physicalBaseFrame: targetFrame)
                    continue
                }
            }
        }
    }
}

