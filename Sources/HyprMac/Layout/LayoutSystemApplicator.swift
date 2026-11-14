import Foundation
import CoreGraphics
import Cocoa
import ApplicationServices

/// Unifies physical window frame application and animation dispatching across layout engines.
@MainActor
public enum LayoutSystemApplicator {
    /// Moves and resizes physical macOS windows using SkyLight GPU affine animations and Accessibility APIs.
    public static func apply(
        windowFrames: [CGWindowID: CGRect],
        newlyAddedWindows: Set<CGWindowID> = [],
        animated: Bool = true,
        bridge: SkyLightBridge = .shared,
        isFullscreen: (@Sendable (CGWindowID) -> Bool)? = nil
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
                    animEngine.animateMove(
                        windowID: wid,
                        startFrame: cur,
                        targetFrame: targetFrame,
                        borderWindowID: borderWid,
                        physicalBaseFrame: targetFrame
                    )
                    continue
                }
            }
        }
    }
}
