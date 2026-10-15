import Cocoa
import QuartzCore

/// Presentation mode for the active window shell compositor
public enum BorderMode: String, Sendable, CaseIterable, Equatable {
    case glassHalo = "glass_halo"
    case neon = "neon"
    case outline = "outline"
}

extension NSColor {
    public convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

/// Content view rendering the dynamic Hyprland-style floating glass halo or gradient border
@MainActor
public final class BorderView: NSView {
    public var mode: BorderMode = .glassHalo {
        didSet {
            guard mode != oldValue else { return }
            updateModeAppearance()
        }
    }

    public var haloPadding: CGFloat = 12.0 {
        didSet { updateLayout() }
    }

    public var borderWidth: CGFloat = 3.5 {
        didSet { updateLayout() }
    }

    public var cornerRadius: CGFloat = 16.0 {
        didSet { updateLayout() }
    }

    public var gradientColors: [NSColor] = [
        NSColor(hex: 0x33CCFF), // Hyprland Cyan
        NSColor(hex: 0x00FF99)  // Hyprland Neon Green
    ] {
        didSet {
            gradientLayer.colors = gradientColors.map(\.cgColor)
            outlineLayer.strokeColor = (gradientColors.first ?? NSColor(hex: 0x33CCFF)).cgColor
        }
    }

    // Glass Halo Subviews & Mask
    private let glassContainerView = NSView()
    private let visualEffectView = NSVisualEffectView()
    private let darkOverlay = NSView()
    private let glassMaskLayer = CAShapeLayer()
    private let glassBorderLayer = CAShapeLayer()

    // Neon Border Sublayers & Animation
    private let gradientLayer = CAGradientLayer()
    private let neonMaskLayer = CAShapeLayer()
    private var angleTimer: Timer?
    private var currentAngle: CGFloat = 0.0

    // Outline Border Sublayer
    private let outlineLayer = CAShapeLayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        angleTimer?.invalidate()
    }

    private func commonInit() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        // 1. Setup Glass Halo container and layers
        glassContainerView.wantsLayer = true
        glassContainerView.layer?.backgroundColor = NSColor.clear.cgColor
        glassContainerView.layer?.masksToBounds = true
        glassMaskLayer.fillRule = .evenOdd
        glassContainerView.layer?.mask = glassMaskLayer

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true

        darkOverlay.wantsLayer = true
        darkOverlay.layer?.backgroundColor = NSColor(hex: 0x16171E, alpha: 0.75).cgColor
        darkOverlay.layer?.borderWidth = 1.0
        darkOverlay.layer?.borderColor = NSColor(white: 1.0, alpha: 0.18).cgColor

        glassBorderLayer.fillColor = nil
        glassBorderLayer.strokeColor = NSColor(white: 1.0, alpha: 0.18).cgColor
        glassBorderLayer.lineWidth = 1.0

        glassContainerView.addSubview(visualEffectView)
        glassContainerView.addSubview(darkOverlay)
        glassContainerView.layer?.addSublayer(glassBorderLayer)
        addSubview(glassContainerView)

        // 2. Setup Neon Gradient Sublayers
        gradientLayer.colors = gradientColors.map(\.cgColor)
        gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        gradientLayer.type = .axial
        neonMaskLayer.fillRule = .evenOdd
        gradientLayer.mask = neonMaskLayer
        layer?.addSublayer(gradientLayer)

        // 3. Setup Outline Border Sublayer
        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = (gradientColors.first ?? NSColor(hex: 0x33CCFF)).cgColor
        outlineLayer.lineWidth = borderWidth
        layer?.addSublayer(outlineLayer)

        // 4. Set Initial Visibility State
        updateModeAppearance()
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLayout()
        CATransaction.commit()
    }

    private func updateModeAppearance() {
        switch mode {
        case .glassHalo:
            glassContainerView.isHidden = false
            gradientLayer.isHidden = true
            outlineLayer.isHidden = true
            stopGradientRotation()
        case .neon:
            glassContainerView.isHidden = true
            gradientLayer.isHidden = false
            outlineLayer.isHidden = true
            startGradientRotation()
        case .outline:
            glassContainerView.isHidden = true
            gradientLayer.isHidden = true
            outlineLayer.isHidden = false
            stopGradientRotation()
        }
        needsLayout = true
    }

    private func updateLayout() {
        guard bounds.width > 0 && bounds.height > 0 else { return }

        switch mode {
        case .glassHalo:
            glassContainerView.frame = bounds
            visualEffectView.frame = bounds
            darkOverlay.frame = bounds
            darkOverlay.layer?.cornerRadius = cornerRadius
            darkOverlay.layer?.borderWidth = 1.0
            darkOverlay.layer?.borderColor = NSColor(white: 1.0, alpha: 0.18).cgColor
            darkOverlay.layer?.backgroundColor = NSColor(hex: 0x16171E, alpha: 0.75).cgColor

            // Outer halo path and inner cutout path for window content
            let outerPath = CGPath(
                roundedRect: bounds,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )

            let innerRect = bounds.insetBy(dx: haloPadding, dy: haloPadding)
            let innerRadius = max(0.0, cornerRadius - haloPadding)
            let innerPath = CGPath(
                roundedRect: innerRect,
                cornerWidth: innerRadius,
                cornerHeight: innerRadius,
                transform: nil
            )

            let combined = CGMutablePath()
            combined.addPath(outerPath)
            combined.addPath(innerPath)

            glassMaskLayer.frame = bounds
            glassMaskLayer.path = combined

            // Outer 1px perimeter highlight
            glassBorderLayer.frame = bounds
            let borderRect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let borderRad = max(0.0, cornerRadius - 0.5)
            glassBorderLayer.path = CGPath(roundedRect: borderRect, cornerWidth: borderRad, cornerHeight: borderRad, transform: nil)

            // Hardware-accelerated soft drop shadow on outer bounds
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowRadius = 14.0
            layer?.shadowOpacity = 0.40
            layer?.shadowOffset = .zero
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        case .neon:
            gradientLayer.frame = bounds

            let outerPath = CGPath(
                roundedRect: bounds,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )

            let innerRect = bounds.insetBy(dx: borderWidth, dy: borderWidth)
            let innerRadius = max(0.0, cornerRadius - borderWidth)
            let innerPath = CGPath(
                roundedRect: innerRect,
                cornerWidth: innerRadius,
                cornerHeight: innerRadius,
                transform: nil
            )

            let combined = CGMutablePath()
            combined.addPath(outerPath)
            combined.addPath(innerPath)

            neonMaskLayer.frame = bounds
            neonMaskLayer.path = combined

            layer?.shadowOpacity = 0.0
            layer?.shadowPath = nil

        case .outline:
            outlineLayer.frame = bounds
            let half = borderWidth / 2.0
            let outlineRect = bounds.insetBy(dx: half, dy: half)
            let outlineRad = max(0.0, cornerRadius - half)
            outlineLayer.path = CGPath(roundedRect: outlineRect, cornerWidth: outlineRad, cornerHeight: outlineRad, transform: nil)
            outlineLayer.lineWidth = borderWidth
            outlineLayer.strokeColor = (gradientColors.first ?? NSColor(hex: 0x33CCFF)).cgColor

            layer?.shadowOpacity = 0.0
            layer?.shadowPath = nil
        }
    }

    /// Animates the gradient angle along the perimeter for the Hyprland active border feel
    private func startGradientRotation() {
        guard angleTimer == nil else { return }
        angleTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.currentAngle += 0.03
                if self.currentAngle > 2 * .pi {
                    self.currentAngle -= 2 * .pi
                }

                let x1 = 0.5 + 0.5 * cos(self.currentAngle)
                let y1 = 0.5 + 0.5 * sin(self.currentAngle)
                let x2 = 0.5 + 0.5 * cos(self.currentAngle + .pi)
                let y2 = 0.5 + 0.5 * sin(self.currentAngle + .pi)

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.gradientLayer.startPoint = CGPoint(x: x1, y: y1)
                self.gradientLayer.endPoint = CGPoint(x: x2, y: y2)
                CATransaction.commit()
            }
        }
    }

    private func stopGradientRotation() {
        angleTimer?.invalidate()
        angleTimer = nil
    }
}

/// Transparent overlay window that frames the active focused window
@MainActor
public final class BorderWindow: NSPanel {
    public var mode: BorderMode {
        get { borderView.mode }
        set { borderView.mode = newValue }
    }

    public var haloPadding: CGFloat {
        get { borderView.haloPadding }
        set { borderView.haloPadding = newValue }
    }

    public var borderWidth: CGFloat {
        get { borderView.borderWidth }
        set { borderView.borderWidth = newValue }
    }

    public var cornerRadius: CGFloat {
        get { borderView.cornerRadius }
        set { borderView.cornerRadius = newValue }
    }

    public var stripDecorations: Bool = true
    public var targetWindowAlpha: Float = 0.96

    public private(set) var currentTargetWindowID: CGWindowID = 0
    public private(set) var lastFocusedTarget: FocusedWindowInfo?

    public var isHookActive: Bool = false {
        didSet {
            guard isHookActive != oldValue else { return }
            if isHookActive {
                hideBorder()
            } else if let target = lastFocusedTarget {
                update(for: target)
            }
        }
    }

    private let borderView = BorderView(frame: .zero)

    public init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = borderView

        self.isHookActive = HyprServerBridge.shared.isAvailable

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHookAvailable(_:)),
            name: .hyprServerHookAvailable,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHookUnavailable(_:)),
            name: .hyprServerHookUnavailable,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleHookAvailable(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.isHookActive = true
        }
    }

    @objc private func handleHookUnavailable(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.isHookActive = false
        }
    }

    /// Computes the overlay frame to wrap the target window based on the active border mode
    public func computeFrame(for targetFrame: NSRect) -> NSRect {
        let inset: CGFloat
        switch mode {
        case .glassHalo:
            inset = haloPadding
        case .neon, .outline:
            inset = borderWidth
        }
        return targetFrame.insetBy(dx: -inset, dy: -inset)
    }

    /// Updates the overlay position, bounds, window tags, and alpha to wrap the target window
    public func update(for target: FocusedWindowInfo) {
        lastFocusedTarget = target
        currentTargetWindowID = target.windowID

        if stripDecorations {
            SkyLightBridge.shared.stripTitlebar(windowID: target.windowID)
        }

        if targetWindowAlpha < 1.0 {
            SkyLightBridge.shared.setWindowAlpha(windowID: target.windowID, alpha: targetWindowAlpha)
        }

        // When hook is active in WindowServer, in-compositor rendering handles borders.
        // Deactivate (hide) the AppKit overlay window (REQ-SAF-002).
        guard !isHookActive else {
            if isVisible {
                orderOut(nil)
            }
            return
        }

        let overlayFrame = computeFrame(for: target.appkitFrame)

        if frame != overlayFrame {
            setFrame(overlayFrame, display: true, animate: false)
        }

        if level != .floating {
            level = .floating
        }

        let targetCollection: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .ignoresCycle,
            .transient,
            .fullScreenAuxiliary
        ]
        if collectionBehavior != targetCollection {
            collectionBehavior = targetCollection
        }

        if !isVisible {
            orderFrontRegardless()
        }

        let borderWid = CGWindowID(self.windowNumber)
        SkyLightBridge.shared.orderWindow(windowID: borderWid, op: .orderAbove, relativeTo: target.windowID)
    }

    /// Hides the overlay border when no valid window is focused
    public func hideBorder() {
        if isVisible {
            orderOut(nil)
        }
        currentTargetWindowID = 0
    }

    /// Self-test diagnostic verifying BorderWindow initialization, mode switching, bounds calculation, and teardown
    public static func runSelfTest() -> Bool {
        print("=== [BorderWindow Self-Test] ===")
        let window = BorderWindow()

        // 1. Initial State Assertions
        guard window.mode == .glassHalo else {
            print("  [-] Default mode != .glassHalo (got \(window.mode))")
            return false
        }
        print("  [✓] Initial mode defaults to .glassHalo")

        guard window.haloPadding == 12.0 else {
            print("  [-] Default haloPadding != 12.0 (got \(window.haloPadding))")
            return false
        }
        print("  [✓] Default haloPadding is 12.0pt")

        guard window.stripDecorations == true else {
            print("  [-] Default stripDecorations != true")
            return false
        }
        print("  [✓] Default stripDecorations is true")

        guard window.targetWindowAlpha == 0.96 else {
            print("  [-] Default targetWindowAlpha != 0.96 (got \(window.targetWindowAlpha))")
            return false
        }
        print("  [✓] Default targetWindowAlpha is 0.96")

        guard window.cornerRadius == 16.0 else {
            print("  [-] Default cornerRadius != 16.0 (got \(window.cornerRadius))")
            return false
        }
        print("  [✓] Default cornerRadius is 16.0pt")

        guard window.level == .floating else {
            print("  [-] Window level != .floating")
            return false
        }
        print("  [✓] Window level is .floating")

        let requiredBehaviors: [NSWindow.CollectionBehavior] = [
            .canJoinAllSpaces, .ignoresCycle, .transient, .fullScreenAuxiliary
        ]
        for b in requiredBehaviors {
            guard window.collectionBehavior.contains(b) else {
                print("  [-] Missing collectionBehavior: \(b)")
                return false
            }
        }
        print("  [✓] Collection behaviors contain all required flags")

        // 2. Mode Switching
        window.mode = .neon
        guard window.mode == .neon else {
            print("  [-] Mode switch to .neon failed")
            return false
        }
        print("  [✓] Mode switch: .glassHalo -> .neon")

        window.mode = .outline
        guard window.mode == .outline else {
            print("  [-] Mode switch to .outline failed")
            return false
        }
        print("  [✓] Mode switch: .neon -> .outline")

        window.mode = .glassHalo
        guard window.mode == .glassHalo else {
            print("  [-] Mode switch back to .glassHalo failed")
            return false
        }
        print("  [✓] Mode switch: .outline -> .glassHalo")

        // 3. Bounds Calculation for Sample Rects with Padding
        let sampleTarget = NSRect(x: 200, y: 150, width: 800, height: 600)

        // Glass Halo frame calculation
        window.mode = .glassHalo
        window.haloPadding = 12.0
        let haloFrame = window.computeFrame(for: sampleTarget)
        let expectedHaloFrame = NSRect(x: 188, y: 138, width: 824, height: 624)
        guard haloFrame == expectedHaloFrame else {
            print("  [-] Glass halo frame calculation mismatch: got \(haloFrame), expected \(expectedHaloFrame)")
            return false
        }
        print("  [✓] Glass halo bounds calculation with 12pt padding matches expected outset frame")

        window.haloPadding = 20.0
        let haloFrame20 = window.computeFrame(for: sampleTarget)
        let expectedHaloFrame20 = NSRect(x: 180, y: 130, width: 840, height: 640)
        guard haloFrame20 == expectedHaloFrame20 else {
            print("  [-] Glass halo frame calculation mismatch with 20pt padding")
            return false
        }
        print("  [✓] Glass halo bounds calculation with 20pt padding matches expected outset frame")

        // Neon frame calculation
        window.mode = .neon
        window.borderWidth = 3.5
        let neonFrame = window.computeFrame(for: sampleTarget)
        let expectedNeonFrame = NSRect(x: 196.5, y: 146.5, width: 807, height: 607)
        guard neonFrame == expectedNeonFrame else {
            print("  [-] Neon frame calculation mismatch: got \(neonFrame), expected \(expectedNeonFrame)")
            return false
        }
        print("  [✓] Neon bounds calculation with 3.5pt borderWidth matches expected outset frame")

        // Outline frame calculation
        window.mode = .outline
        window.borderWidth = 2.0
        let outlineFrame = window.computeFrame(for: sampleTarget)
        let expectedOutlineFrame = NSRect(x: 198, y: 148, width: 804, height: 604)
        guard outlineFrame == expectedOutlineFrame else {
            print("  [-] Outline frame calculation mismatch: got \(outlineFrame), expected \(expectedOutlineFrame)")
            return false
        }
        print("  [✓] Outline bounds calculation with 2.0pt borderWidth matches expected outset frame")

        // Test update(for target:) with mock FocusedWindowInfo
        window.mode = .glassHalo
        window.haloPadding = 12.0
        let mockTarget = FocusedWindowInfo(
            windowID: 4242,
            processID: 101,
            appName: "Ghostty",
            title: "Terminal",
            bounds: CGRect(x: 200, y: 150, width: 800, height: 600),
            appkitFrame: sampleTarget
        )
        window.update(for: mockTarget)
        guard window.frame == expectedHaloFrame else {
            print("  [-] update(for:) frame mismatch: got \(window.frame), expected \(expectedHaloFrame)")
            return false
        }
        guard window.currentTargetWindowID == 4242 else {
            print("  [-] currentTargetWindowID mismatch: got \(window.currentTargetWindowID), expected 4242")
            return false
        }
        print("  [✓] update(for:) successfully updated window frame and target window ID")

        // 4. Test Hook Active Bypass & Fallback (REQ-SAF-002)
        print("[*] Testing Hook Active Bypass and Fallback (REQ-SAF-002)...")
        NotificationCenter.default.post(name: .hyprServerHookAvailable, object: nil)
        guard window.isHookActive == true else {
            print("  [-] isHookActive != true after .hyprServerHookAvailable notification")
            return false
        }
        guard !window.isVisible else {
            print("  [-] window is still visible when hook is active")
            return false
        }
        print("  [✓] Hook active bypass: BorderWindow overlay deactivated")

        window.update(for: mockTarget)
        guard !window.isVisible else {
            print("  [-] window became visible during update(for:) while hook is active")
            return false
        }
        print("  [✓] update(for:) while hook active preserves hidden state")

        NotificationCenter.default.post(name: .hyprServerHookUnavailable, object: nil)
        guard window.isHookActive == false else {
            print("  [-] isHookActive != false after .hyprServerHookUnavailable notification")
            return false
        }
        guard window.isVisible else {
            print("  [-] window failed to re-enable overlay upon hook unavailable fallback")
            return false
        }
        guard window.frame == expectedHaloFrame else {
            print("  [-] fallback frame mismatch: got \(window.frame), expected \(expectedHaloFrame)")
            return false
        }
        print("  [✓] Hook unavailable fallback: BorderWindow overlay re-enabled immediately")

        // 5. Clean Teardown
        window.hideBorder()
        guard window.currentTargetWindowID == 0 else {
            print("  [-] hideBorder failed to reset currentTargetWindowID")
            return false
        }
        guard !window.isVisible else {
            print("  [-] hideBorder failed to hide window")
            return false
        }
        window.close()
        print("  [✓] Clean teardown and close verified")

        print("=== [Self-Test Result: PASSED] ===")
        return true
    }
}
