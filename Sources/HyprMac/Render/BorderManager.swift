import Cocoa
import CoreGraphics

/// Manages multiple window border overlays (active vs inactive borders) for HyprMac.
@MainActor
public final class BorderManager {
    public static let shared = BorderManager()

    public private(set) var overlays: [CGWindowID: BorderWindow] = [:]
    public private(set) var managedWindowIDs: Set<CGWindowID> = []
    private var appliedAlpha: [CGWindowID: Float] = [:]
    private var appliedBlur: [CGWindowID: UInt32] = [:]

    public init() {}

    /// Set of window IDs for all managed border overlay panels.
    public var overlayWindowIDs: Set<CGWindowID> {
        Set(overlays.values.map { CGWindowID($0.windowNumber) })
    }

    /// Checks if a given window ID belongs to an active border overlay.
    public func isBorderWindow(windowID: CGWindowID) -> Bool {
        overlays.values.contains { CGWindowID($0.windowNumber) == windowID }
    }

    /// Updates active and inactive window border overlays.
    /// - Parameters:
    ///   - focused: The currently focused window (if any).
    ///   - managedFrames: Mapped frames for all tiled windows (in CoreGraphics coordinates).
    ///   - config: Current Hyprland configuration.
    public func update(
        focused: FocusedWindowInfo?,
        managedFrames: [CGWindowID: CGRect],
        config: HyprConfig
    ) {
        // Active border target: must be an admitted window in managedFrames.
        // If a non-standard window (like Chrome's omnibox popup) is focused,
        // it must not receive a border overlay.
        let activeWid: CGWindowID?
        if let f = focused, managedFrames.keys.contains(f.windowID) {
            activeWid = f.windowID
        } else {
            activeWid = nil
        }

        let validWids = Set(managedFrames.keys)

        // 1. Compositor-level Window Opacity and Blur Application
        // Invariant: Windows must receive their focus opacity and backdrop blur
        // regardless of whether borderSize > 0 or borderSize == 0 (frameless mode).
        // Only dispatch CGS calls when alpha or blur delta changes to minimize IPC overhead.
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

        // Clean up windows that are no longer managed: restore alpha to 1.0 and blur to 0
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

        // Compositor / Border Invariant:
        // When config.borderSize == 0, cleanly hide and order out all border overlays
        // so zero overlay windows are drawn over or around the frameless windows.
        if config.borderSize <= 0 {
            if !overlays.isEmpty {
                for overlay in overlays.values {
                    overlay.hideBorder()
                    overlay.orderOut(nil)
                    overlay.close()
                }
                overlays.removeAll()
            }
            return
        }

        // 2. Clean up overlays for windows that are no longer present
        let staleWids = Set(overlays.keys).subtracting(validWids)
        for wid in staleWids {
            if let overlay = overlays.removeValue(forKey: wid) {
                overlay.hideBorder()
                overlay.close()
            }
        }

        // 3. Configure and update the active focused window overlay (if admitted in managedFrames)
        if let activeWid = activeWid, let frame = managedFrames[activeWid] {
            let overlay = overlays[activeWid] ?? createOverlay(for: activeWid)
            overlays[activeWid] = overlay

            overlay.mode = config.borderMode
            overlay.borderWidth = CGFloat(config.borderSize)
            overlay.cornerRadius = config.rounding
            overlay.haloPadding = config.haloPadding
            overlay.stripDecorations = config.stripDecorations
            overlay.targetWindowAlpha = Float(config.windowOpacity)
            overlay.gradientColors = config.activeBorderGradient.map { NSColor(hex: $0) }
            overlay.level = .floating
            if let f = focused, f.windowID == activeWid {
                overlay.update(for: f)
            } else {
                let appkitFrame = WindowDetector.shared.convertToAppKitFrame(cgRect: frame)
                overlay.update(windowID: activeWid, appkitFrame: appkitFrame)
            }
        }

        // 4. Configure and update inactive window overlays
        let inactiveColor = NSColor(hex: config.inactiveBorderColor)
        for (wid, cgFrame) in managedFrames {
            if wid == activeWid {
                continue
            }
            let overlay = overlays[wid] ?? createOverlay(for: wid)
            overlays[wid] = overlay

            overlay.mode = .outline
            overlay.borderWidth = CGFloat(config.borderSize)
            overlay.cornerRadius = config.rounding
            overlay.haloPadding = config.haloPadding
            overlay.stripDecorations = config.stripDecorations
            overlay.targetWindowAlpha = Float(config.inactiveOpacity)
            overlay.gradientColors = [inactiveColor]
            overlay.level = .floating

            let appkitFrame = WindowDetector.shared.convertToAppKitFrame(cgRect: cgFrame)
            overlay.update(windowID: wid, appkitFrame: appkitFrame)
        }
    }

    /// Hides and tears down all active border overlays and restores window styles.
    public func hideAll() {
        for wid in managedWindowIDs {
            SkyLightBridge.shared.setWindowAlpha(windowID: wid, alpha: 1.0)
            SkyLightBridge.shared.setWindowBackgroundBlurRadius(windowID: wid, radius: 0)
        }
        managedWindowIDs.removeAll()
        appliedAlpha.removeAll()
        appliedBlur.removeAll()

        for overlay in overlays.values {
            overlay.hideBorder()
            overlay.close()
        }
        overlays.removeAll()
    }

    /// Hides and removes the overlay for a specific window and restores default style.
    public func hideOverlay(for windowID: CGWindowID) {
        SkyLightBridge.shared.setWindowAlpha(windowID: windowID, alpha: 1.0)
        SkyLightBridge.shared.setWindowBackgroundBlurRadius(windowID: windowID, radius: 0)
        managedWindowIDs.remove(windowID)
        appliedAlpha.removeValue(forKey: windowID)
        appliedBlur.removeValue(forKey: windowID)
        if let overlay = overlays.removeValue(forKey: windowID) {
            overlay.hideBorder()
            overlay.close()
        }
    }

    private func createOverlay(for windowID: CGWindowID) -> BorderWindow {
        let window = BorderWindow()
        return window
    }

    /// Diagnostic self-test verifying BorderManager lifecycle, active/inactive styling, and cleanup
    @discardableResult
    public static func runSelfTest() -> Bool {
        print("=== [BorderManager Self-Test] ===")
        let manager = BorderManager()

        var config = HyprConfig()
        config.borderMode = .neon
        config.borderSize = 3
        config.rounding = 12.0
        config.activeBorderGradient = [0x33CCFFEE, 0x00FF99EE]
        config.inactiveBorderColor = 0x595959AA

        let target1 = FocusedWindowInfo(
            windowID: 1001,
            processID: 501,
            appName: "Ghostty",
            title: "Terminal 1",
            bounds: CGRect(x: 10, y: 10, width: 900, height: 1000),
            appkitFrame: NSRect(x: 10, y: 10, width: 900, height: 1000)
        )

        let managedFrames: [CGWindowID: CGRect] = [
            1001: CGRect(x: 10, y: 10, width: 900, height: 1000),
            1002: CGRect(x: 920, y: 10, width: 900, height: 1000)
        ]

        // 1. Initial update with 1001 focused and 1002 inactive
        manager.update(focused: target1, managedFrames: managedFrames, config: config)
        guard manager.overlays.count == 2 else {
            print("  [-] Expected 2 overlays, got \(manager.overlays.count)")
            return false
        }
        print("  [✓] Managed overlays count is 2 (1 active + 1 inactive)")

        guard let o1 = manager.overlays[1001], o1.mode == .neon else {
            print("  [-] Overlay 1001 should have mode .neon")
            return false
        }
        print("  [✓] Active window 1001 has mode .neon")

        guard let o2 = manager.overlays[1002], o2.mode == .outline else {
            print("  [-] Overlay 1002 should have mode .outline")
            return false
        }
        print("  [✓] Inactive window 1002 has mode .outline")

        // 2. Focus switch from 1001 to 1002
        let target2 = FocusedWindowInfo(
            windowID: 1002,
            processID: 502,
            appName: "Safari",
            title: "Web",
            bounds: CGRect(x: 920, y: 10, width: 900, height: 1000),
            appkitFrame: NSRect(x: 920, y: 10, width: 900, height: 1000)
        )
        manager.update(focused: target2, managedFrames: managedFrames, config: config)

        guard let o2New = manager.overlays[1002], o2New.mode == .neon else {
            print("  [-] Overlay 1002 should now have mode .neon")
            return false
        }
        guard let o1New = manager.overlays[1001], o1New.mode == .outline else {
            print("  [-] Overlay 1001 should now have mode .outline")
            return false
        }
        print("  [✓] Focus switch correctly swapped modes: 1002 is .neon, 1001 is .outline")

        // 3. Window 1001 closed -> removed from managedFrames
        let updatedFrames: [CGWindowID: CGRect] = [
            1002: CGRect(x: 10, y: 10, width: 1900, height: 1000)
        ]
        manager.update(focused: target2, managedFrames: updatedFrames, config: config)
        guard manager.overlays.count == 1 && manager.overlays[1001] == nil else {
            print("  [-] Overlay 1001 was not removed after window closed")
            return false
        }
        print("  [✓] Closed window overlay 1001 successfully ordered out and removed")

        // 3b. Non-standard window (popup) focused check: must not create an overlay for unmanaged popup
        let popupWindow = FocusedWindowInfo(
            windowID: 9999,
            processID: 502,
            appName: "Safari",
            title: "Autocomplete Popup",
            bounds: CGRect(x: 950, y: 100, width: 300, height: 200),
            appkitFrame: NSRect(x: 950, y: 100, width: 300, height: 200)
        )
        manager.update(focused: popupWindow, managedFrames: updatedFrames, config: config)
        guard manager.overlays[9999] == nil else {
            print("  [-] Overlays must not contain unmanaged popup 9999")
            return false
        }
        guard manager.overlays.count == 1 else {
            print("  [-] Overlays count should remain 1 when unmanaged popup is focused")
            return false
        }
        print("  [✓] Unmanaged popup window 9999 did not spawn an overlay")

        // 3b. Border size == 0 frameless invariant check
        var zeroBorderConfig = config
        zeroBorderConfig.borderSize = 0
        manager.update(focused: target2, managedFrames: updatedFrames, config: zeroBorderConfig)
        guard manager.overlays.isEmpty else {
            print("  [-] Overlays must be empty when borderSize == 0 (got \(manager.overlays.count))")
            return false
        }
        print("  [✓] borderSize == 0 cleanly hid and tore down all overlays (frameless mode verified)")

        // 4. Hide all and clean teardown
        manager.hideAll()
        guard manager.overlays.isEmpty else {
            print("  [-] hideAll failed to empty overlays dictionary")
            return false
        }
        print("  [✓] hideAll clean teardown verified")

        print("=== [BorderManager Self-Test Result: PASSED] ===")
        return true
    }
}
