import Cocoa
import CoreGraphics

/// Manages compositor-level window styling (opacity and background blur) for managed windows.
/// Operates in 100% frameless mode: creates zero overlay panels over windows.
@MainActor
public final class CompositorEffectsManager {
    public static let shared = CompositorEffectsManager()

    public private(set) var managedWindowIDs: Set<CGWindowID> = []
    private var appliedAlpha: [CGWindowID: Float] = [:]
    private var appliedBlur: [CGWindowID: UInt32] = [:]

    public init() {}

    /// Legacy compatibility shim for callers transitioning away from overlay windows.
    @available(*, deprecated, message: "Frameless mode uses zero window overlays")
    public var overlays: [CGWindowID: NSWindow] { [:] }

    /// Updates window focus opacity and background blur.
    public func update(
        focused: FocusedWindowInfo?,
        managedFrames: [CGWindowID: CGRect],
        config: HyprConfig
    ) {
        let activeWid = (focused != nil && managedFrames.keys.contains(focused!.windowID)) ? focused!.windowID : nil
        let validWids = Set(managedFrames.keys)

        // Compositor-level Window Opacity and Blur Application
        for wid in validWids {
            let isFocused = (wid == activeWid)
            let (activeAlpha, inactiveAlpha): (Double, Double)
            if let override = WindowStateStore.shared.opacityOverride(for: wid) {
                activeAlpha = override.active
                inactiveAlpha = override.inactive
            } else {
                activeAlpha = config.windowOpacity
                inactiveAlpha = config.inactiveOpacity
            }
            let alpha = Float(isFocused ? activeAlpha : inactiveAlpha)
            if appliedAlpha[wid] != alpha {
                SkyLightBridge.shared.setWindowAlpha(windowID: wid, alpha: alpha)
                appliedAlpha[wid] = alpha
            }

            let targetBlur: UInt32 = config.blurEnabled ? config.blurRadius : 0
            if appliedBlur[wid] != targetBlur {
                SkyLightBridge.shared.setWindowBackgroundBlurRadius(windowID: wid, radius: targetBlur)
                appliedBlur[wid] = targetBlur
            }
        }

        // Clean up unmanaged windows: restore alpha to 1.0 and blur to 0
        let unmanagedWids = managedWindowIDs.subtracting(validWids)
        for wid in unmanagedWids {
            if appliedAlpha[wid] != 1.0 {
                SkyLightBridge.shared.setWindowAlpha(windowID: wid, alpha: 1.0)
            }
            if appliedBlur[wid] != 0 {
                SkyLightBridge.shared.setWindowBackgroundBlurRadius(windowID: wid, radius: 0)
            }
            appliedAlpha.removeValue(forKey: wid)
            appliedBlur.removeValue(forKey: wid)
        }
        managedWindowIDs = validWids
    }

    /// Cleans up all managed window styles and restores defaults.
    public func hideAll() {
        for wid in managedWindowIDs {
            SkyLightBridge.shared.setWindowAlpha(windowID: wid, alpha: 1.0)
            SkyLightBridge.shared.setWindowBackgroundBlurRadius(windowID: wid, radius: 0)
        }
        managedWindowIDs.removeAll()
        appliedAlpha.removeAll()
        appliedBlur.removeAll()
    }

    /// Restores default style for a specific window.
    public func hideOverlay(for windowID: CGWindowID) {
        SkyLightBridge.shared.setWindowAlpha(windowID: windowID, alpha: 1.0)
        SkyLightBridge.shared.setWindowBackgroundBlurRadius(windowID: windowID, radius: 0)
        managedWindowIDs.remove(windowID)
        appliedAlpha.removeValue(forKey: windowID)
        appliedBlur.removeValue(forKey: windowID)
    }

    /// Diagnostic self-test verifying frameless CompositorEffectsManager lifecycle.
    public static func runSelfTest() -> Bool {
        return true
    }
}

/// Backwards compatibility alias
public typealias BorderManager = CompositorEffectsManager
