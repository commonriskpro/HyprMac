import Cocoa
import CoreGraphics

/// Manages compositor-level window styling (opacity and background blur) for managed windows.
/// Operates in 100% frameless mode: creates zero overlay panels over windows.
@MainActor
public final class BorderManager {
    public static let shared = BorderManager()

    public private(set) var managedWindowIDs: Set<CGWindowID> = []
    private var appliedAlpha: [CGWindowID: Float] = [:]
    private var appliedBlur: [CGWindowID: UInt32] = [:]

    public init() {}

    /// Always empty in frameless mode (zero overlay windows).
    public var overlays: [CGWindowID: NSWindow] { [:] }

    /// Always empty in frameless mode.
    public var overlayWindowIDs: Set<CGWindowID> { [] }

    /// Always false in frameless mode (no border windows exist).
    public func isBorderWindow(windowID: CGWindowID) -> Bool {
        return false
    }

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
            let alpha = Float(isFocused ? config.windowOpacity : config.inactiveOpacity)
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

    /// Diagnostic self-test verifying frameless BorderManager lifecycle.
    public static func runSelfTest() -> Bool {
        print("=== [BorderManager Self-Test (Frameless Mode)] ===")
        let manager = BorderManager()
        var config = HyprConfig()
        config.borderSize = 0
        config.windowOpacity = 0.95
        config.inactiveOpacity = 0.90

        let target = FocusedWindowInfo(
            windowID: 1001,
            processID: 100,
            appName: "Ghostty",
            title: "Terminal",
            bounds: CGRect(x: 10, y: 10, width: 800, height: 600),
            appkitFrame: NSRect(x: 10, y: 10, width: 800, height: 600)
        )
        let frames: [CGWindowID: CGRect] = [
            1001: CGRect(x: 10, y: 10, width: 800, height: 600),
            1002: CGRect(x: 820, y: 10, width: 800, height: 600)
        ]

        manager.update(focused: target, managedFrames: frames, config: config)
        guard manager.overlays.isEmpty else {
            print("  [-] Overlays should be empty in frameless mode")
            return false
        }
        print("  [✓] Zero overlays spawned in frameless mode")

        guard !manager.isBorderWindow(windowID: 1001) else {
            print("  [-] isBorderWindow should always return false")
            return false
        }
        print("  [✓] isBorderWindow cleanly returns false")

        manager.hideAll()
        guard manager.managedWindowIDs.isEmpty else {
            print("  [-] hideAll failed to clear managed window IDs")
            return false
        }
        print("  [✓] Clean teardown verified")
        print("=== [BorderManager Self-Test Result: PASSED] ===")
        return true
    }
}
