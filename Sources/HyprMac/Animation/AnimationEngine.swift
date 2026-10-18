import Foundation
import CoreGraphics
import Cocoa
import os

/// Classification of window transitions supported by the animation subsystem.
public enum AnimationKind: String, Sendable, CaseIterable {
    case windowsMove
    case windowsIn
    case windowsOut
    case fullscreen
    case minimize
    case unminimize
}

/// Active solver type driving the animation progress.
public enum AnimationSolver: Sendable {
    case bezier(CubicBezier)
    case spring(SpringAnimation)
}

/// Represents an in-flight window GPU affine transform animation.
public final class ActiveWindowAnimation: @unchecked Sendable {
    public let windowID: CGWindowID
    public let kind: AnimationKind
    public let startFrame: CGRect
    public let targetFrame: CGRect
    public let physicalBaseFrame: CGRect
    public let duration: Double
    public let solver: AnimationSolver
    public let borderWindowID: CGWindowID?
    public let onComplete: (@MainActor (CGWindowID) -> Void)?

    public var elapsed: Double = 0.0
    public var currentProgress: Double = 0.0
    public var currentFrame: CGRect
    public var currentAlpha: Float
    public var isFinished: Bool = false

    public init(
        windowID: CGWindowID,
        kind: AnimationKind,
        startFrame: CGRect,
        targetFrame: CGRect,
        physicalBaseFrame: CGRect? = nil,
        duration: Double,
        solver: AnimationSolver,
        borderWindowID: CGWindowID? = nil,
        initialAlpha: Float = 1.0,
        onComplete: (@MainActor (CGWindowID) -> Void)? = nil
    ) {
        self.windowID = windowID
        self.kind = kind
        self.startFrame = startFrame
        self.targetFrame = targetFrame
        self.physicalBaseFrame = physicalBaseFrame ?? ((kind == .windowsIn) ? targetFrame : startFrame)
        self.duration = max(duration, 0.01)
        self.solver = solver
        self.borderWindowID = borderWindowID
        self.currentAlpha = initialAlpha
        self.onComplete = onComplete
        self.currentFrame = startFrame
    }
}

/// Represents an in-flight workspace transition animation.
public final class ActiveWorkspaceAnimation: @unchecked Sendable {
    public let oldWorkspace: Int
    public let newWorkspace: Int
    public let outgoingWindowIDs: [CGWindowID]
    public let incomingWindowIDs: [CGWindowID]
    public let duration: Double
    public let solver: AnimationSolver
    public let style: String
    public let slideWidth: CGFloat
    public let onComplete: (@MainActor () -> Void)?

    public var elapsed: Double = 0.0
    public var currentProgress: Double = 0.0
    public var isFinished: Bool = false

    public init(
        oldWorkspace: Int,
        newWorkspace: Int,
        outgoingWindowIDs: [CGWindowID],
        incomingWindowIDs: [CGWindowID],
        duration: Double,
        solver: AnimationSolver,
        style: String,
        slideWidth: CGFloat,
        onComplete: (@MainActor () -> Void)? = nil
    ) {
        self.oldWorkspace = oldWorkspace
        self.newWorkspace = newWorkspace
        self.outgoingWindowIDs = outgoingWindowIDs
        self.incomingWindowIDs = incomingWindowIDs
        self.duration = max(duration, 0.01)
        self.solver = solver
        self.style = style
        self.slideWidth = slideWidth
        self.onComplete = onComplete
    }
}

/// Manages and coordinates Hyprland-identical GPU-accelerated window animations in HyprMac.
/// Transforms windows on the GPU via SkyLight affine transforms during animation,
/// and applies final physical frames atomically via Accessibility upon completion.
@MainActor
public final class AnimationEngine {
    public static let shared = AnimationEngine()

    public var config: HyprConfig = .default
    public let displayLink: DisplayLinkDriver
    public private(set) var activeAnimations: [CGWindowID: ActiveWindowAnimation] = [:]
    public private(set) var activeWorkspaceAnimation: ActiveWorkspaceAnimation?

    private let skyLight: SkyLightBridge
    public var isSimulated: Bool = false
    private let isSteppingLock = OSAllocatedUnfairLock(initialState: false)

    public init(
        config: HyprConfig = .default,
        displayID: CGDirectDisplayID = CGMainDisplayID(),
        skyLight: SkyLightBridge = .shared
    ) {
        self.config = config
        self.skyLight = skyLight
        self.displayLink = DisplayLinkDriver(displayID: displayID)
    }

    /// Checks if a window is currently undergoing an active animation.
    public func isAnimating(windowID: CGWindowID) -> Bool {
        return activeAnimations[windowID] != nil
    }

    /// Retrieves the current visual (interpolated) frame of an animating window.
    public func currentVisualFrame(windowID: CGWindowID) -> CGRect? {
        return activeAnimations[windowID]?.currentFrame
    }

    /// Retrieves the current visual alpha/opacity of an animating window.
    public func currentVisualAlpha(windowID: CGWindowID) -> Float? {
        return activeAnimations[windowID]?.currentAlpha
    }

    // MARK: - Animation Dispatchers

    /// Animates a window move/resize between two tiling frames (windowsMove).
    @discardableResult
    public func animateMove(
        windowID: CGWindowID,
        startFrame: CGRect? = nil,
        targetFrame: CGRect,
        borderWindowID: CGWindowID? = nil,
        physicalBaseFrame: CGRect? = nil,
        onComplete: (@MainActor (CGWindowID) -> Void)? = nil
    ) -> Bool {
        guard config.animationsEnabled else {
            WindowDetector.shared.setWindowFrame(windowID: windowID, frame: targetFrame)
            onComplete?(windowID)
            return false
        }

        let animConfig = config.animationTree.getConfig(for: "windowsMove")
        guard animConfig.enabled else {
            WindowDetector.shared.setWindowFrame(windowID: windowID, frame: targetFrame)
            onComplete?(windowID)
            return false
        }

        // Determine start frame & physical base frame:
        // If already animating, take the current interpolated visual frame as the new startFrame,
        // and preserve the existing physicalBaseFrame so the GPU matrix offset (current - physicalBase)
        // never causes a coordinate jump mid-flight.
        let existingAnim = activeAnimations[windowID]
        let initial = startFrame ?? existingAnim?.currentFrame ?? WindowDetector.shared.getWindowBounds(windowID: windowID) ?? targetFrame
        guard initial != targetFrame else {
            WindowDetector.shared.setWindowFrame(windowID: windowID, frame: targetFrame)
            onComplete?(windowID)
            return false
        }

        let physicalBase = physicalBaseFrame ?? existingAnim?.physicalBaseFrame ?? WindowDetector.shared.getWindowBounds(windowID: windowID) ?? initial

        let solver = makeSolver(for: animConfig)
        let animation = ActiveWindowAnimation(
            windowID: windowID,
            kind: .windowsMove,
            startFrame: initial,
            targetFrame: targetFrame,
            physicalBaseFrame: physicalBase,
            duration: animConfig.duration,
            solver: solver,
            borderWindowID: borderWindowID,
            onComplete: onComplete
        )

        activeAnimations[windowID] = animation
        ensureDisplayLinkRunning()
        return true
    }

    /// Animates window appearance (windowsIn), supporting popin scaling or slide styles.
    @discardableResult
    public func animateIn(
        windowID: CGWindowID,
        targetFrame: CGRect,
        style: String? = nil,
        borderWindowID: CGWindowID? = nil,
        onComplete: (@MainActor (CGWindowID) -> Void)? = nil
    ) -> Bool {
        guard config.animationsEnabled else {
            WindowDetector.shared.setWindowFrame(windowID: windowID, frame: targetFrame)
            onComplete?(windowID)
            return false
        }

        let animConfig = config.animationTree.getConfig(for: "windowsIn")
        guard animConfig.enabled else {
            WindowDetector.shared.setWindowFrame(windowID: windowID, frame: targetFrame)
            onComplete?(windowID)
            return false
        }

        let effectiveStyle = style ?? animConfig.style
        let popinScale = parsePopinPercentage(from: effectiveStyle, defaultPercent: 80.0) / 100.0

        // Compute starting frame for popin (scaled down around target center)
        let w0 = targetFrame.width * popinScale
        let h0 = targetFrame.height * popinScale
        let x0 = targetFrame.midX - (w0 / 2.0)
        let y0 = targetFrame.midY - (h0 / 2.0)
        let startFrame = CGRect(x: x0, y: y0, width: w0, height: h0)

        // Set initial physical frame to targetFrame, and transform window to popin scale
        WindowDetector.shared.setWindowFrame(windowID: windowID, frame: targetFrame)

        let baseFrame = targetFrame
        let sx = w0 / max(baseFrame.width, 1.0)
        let sy = h0 / max(baseFrame.height, 1.0)
        let tx = x0 - baseFrame.origin.x
        let ty = y0 - baseFrame.origin.y
        let initialTransform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
        skyLight.setWindowTransform(windowID: windowID, transform: initialTransform)
        skyLight.setWindowAlpha(windowID: windowID, alpha: 0.0)
        if let bWid = borderWindowID {
            skyLight.setWindowTransform(windowID: bWid, transform: initialTransform)
            skyLight.setWindowAlpha(windowID: bWid, alpha: 0.0)
        }

        let solver = makeSolver(for: animConfig)
        let animation = ActiveWindowAnimation(
            windowID: windowID,
            kind: .windowsIn,
            startFrame: startFrame,
            targetFrame: targetFrame,
            duration: animConfig.duration,
            solver: solver,
            borderWindowID: borderWindowID,
            initialAlpha: 0.0,
            onComplete: onComplete
        )

        activeAnimations[windowID] = animation
        ensureDisplayLinkRunning()
        return true
    }

    /// Animates window disappearance (windowsOut), scaling down or fading out before removal.
    @discardableResult
    public func animateOut(
        windowID: CGWindowID,
        startFrame: CGRect,
        style: String? = nil,
        borderWindowID: CGWindowID? = nil,
        onComplete: (@MainActor (CGWindowID) -> Void)? = nil
    ) -> Bool {
        guard config.animationsEnabled else {
            onComplete?(windowID)
            return false
        }

        let animConfig = config.animationTree.getConfig(for: "windowsOut")
        guard animConfig.enabled else {
            onComplete?(windowID)
            return false
        }

        let effectiveStyle = style ?? animConfig.style
        let popinScale = parsePopinPercentage(from: effectiveStyle, defaultPercent: 80.0) / 100.0

        let w1 = startFrame.width * popinScale
        let h1 = startFrame.height * popinScale
        let x1 = startFrame.midX - (w1 / 2.0)
        let y1 = startFrame.midY - (h1 / 2.0)
        let targetFrame = CGRect(x: x1, y: y1, width: w1, height: h1)

        let solver = makeSolver(for: animConfig)
        let animation = ActiveWindowAnimation(
            windowID: windowID,
            kind: .windowsOut,
            startFrame: startFrame,
            targetFrame: targetFrame,
            duration: animConfig.duration,
            solver: solver,
            borderWindowID: borderWindowID,
            initialAlpha: Float(config.windowOpacity),
            onComplete: onComplete
        )

        activeAnimations[windowID] = animation
        ensureDisplayLinkRunning()
        return true
    }

    /// Animates fullscreen zoom in / zoom out transitions.
    @discardableResult
    public func animateFullscreen(
        windowID: CGWindowID,
        from startFrame: CGRect,
        to targetFrame: CGRect,
        isFullscreen: Bool,
        borderWindowID: CGWindowID? = nil,
        physicalBaseFrame: CGRect? = nil,
        onComplete: (@MainActor (CGWindowID) -> Void)? = nil
    ) -> Bool {
        guard config.animationsEnabled else {
            WindowDetector.shared.setWindowFrame(windowID: windowID, frame: targetFrame)
            onComplete?(windowID)
            return false
        }

        let animConfig = config.animationTree.getConfig(for: "fullscreen")
        let solver = makeSolver(for: animConfig)
        let animation = ActiveWindowAnimation(
            windowID: windowID,
            kind: .fullscreen,
            startFrame: startFrame,
            targetFrame: targetFrame,
            physicalBaseFrame: physicalBaseFrame ?? targetFrame,
            duration: animConfig.duration,
            solver: solver,
            borderWindowID: borderWindowID,
            onComplete: onComplete
        )

        activeAnimations[windowID] = animation
        ensureDisplayLinkRunning()
        return true
    }

    /// Animates minimize transition down towards dock / screen bottom.
    @discardableResult
    public func animateMinimize(
        windowID: CGWindowID,
        currentFrame: CGRect,
        screenBounds: CGRect,
        onComplete: (@MainActor (CGWindowID) -> Void)? = nil
    ) -> Bool {
        guard config.animationsEnabled else {
            _ = WindowDetector.shared.setWindowMinimized(windowID: windowID, minimized: true)
            onComplete?(windowID)
            return false
        }

        let animConfig = config.animationTree.getConfig(for: "windowsOut")
        let targetW = max(currentFrame.width * 0.2, 50.0)
        let targetH = max(currentFrame.height * 0.2, 50.0)
        let targetFrame = CGRect(
            x: currentFrame.midX - (targetW / 2.0),
            y: screenBounds.maxY,
            width: targetW,
            height: targetH
        )

        let solver = makeSolver(for: animConfig)
        let animation = ActiveWindowAnimation(
            windowID: windowID,
            kind: .minimize,
            startFrame: currentFrame,
            targetFrame: targetFrame,
            duration: animConfig.duration,
            solver: solver,
            borderWindowID: nil,
            onComplete: { wid in
                _ = WindowDetector.shared.setWindowMinimized(windowID: wid, minimized: true)
                onComplete?(wid)
            }
        )

        activeAnimations[windowID] = animation
        ensureDisplayLinkRunning()
        return true
    }

    /// Animates unminimize transition up from dock / screen bottom into allocated tiling frame.
    @discardableResult
    public func animateUnminimize(
        windowID: CGWindowID,
        targetFrame: CGRect,
        screenBounds: CGRect,
        onComplete: (@MainActor (CGWindowID) -> Void)? = nil
    ) -> Bool {
        _ = WindowDetector.shared.setWindowMinimized(windowID: windowID, minimized: false)
        guard config.animationsEnabled else {
            WindowDetector.shared.setWindowFrame(windowID: windowID, frame: targetFrame)
            onComplete?(windowID)
            return false
        }

        let animConfig = config.animationTree.getConfig(for: "windowsIn")
        let startW = max(targetFrame.width * 0.2, 50.0)
        let startH = max(targetFrame.height * 0.2, 50.0)
        let startFrame = CGRect(
            x: targetFrame.midX - (startW / 2.0),
            y: screenBounds.maxY,
            width: startW,
            height: startH
        )

        let solver = makeSolver(for: animConfig)
        let animation = ActiveWindowAnimation(
            windowID: windowID,
            kind: .unminimize,
            startFrame: startFrame,
            targetFrame: targetFrame,
            duration: animConfig.duration,
            solver: solver,
            borderWindowID: nil,
            onComplete: onComplete
        )

        activeAnimations[windowID] = animation
        ensureDisplayLinkRunning()
        return true
    }

    /// Animates a GPU workspace transition between oldWorkspace and newWorkspace.
    @discardableResult
    public func animateWorkspaceTransition(
        oldWorkspace: Int,
        newWorkspace: Int,
        outgoingWindowIDs: [CGWindowID],
        incomingWindowIDs: [CGWindowID],
        screenWidth: CGFloat,
        onComplete: (@MainActor () -> Void)? = nil
    ) -> Bool {
        guard config.animationsEnabled else {
            onComplete?()
            return false
        }

        let animConfig = config.animationTree.getConfig(for: "workspaces")
        guard animConfig.enabled, animConfig.duration > 0.01 else {
            onComplete?()
            return false
        }

        // Cancel any pending workspace transition cleanly
        if activeWorkspaceAnimation != nil {
            cancelWorkspaceAnimation()
        }

        let solver = makeSolver(for: animConfig)
        let effectiveStyle = animConfig.style.lowercased()
        let styleName: String
        if effectiveStyle.contains("slidefade") {
            styleName = "slidefade"
        } else if effectiveStyle.contains("fade") {
            styleName = "fade"
        } else {
            styleName = "slide"
        }

        let direction: CGFloat = (newWorkspace > oldWorkspace) ? 1.0 : -1.0
        let targetOpacity = Float(config.windowOpacity)
        var initialEntries: [(windowID: CGWindowID, transform: CGAffineTransform, alpha: Float)] = []

        // Outgoing windows start at identity
        for wid in outgoingWindowIDs {
            initialEntries.append((windowID: wid, transform: .identity, alpha: targetOpacity))
        }

        // Incoming windows start translated or faded
        let initialIncomingTx: CGFloat
        let initialIncomingAlpha: Float

        if styleName == "slidefade" {
            initialIncomingTx = direction * screenWidth
            initialIncomingAlpha = 0.0
        } else if styleName == "fade" {
            initialIncomingTx = 0.0
            initialIncomingAlpha = 0.0
        } else {
            // "slide"
            initialIncomingTx = direction * screenWidth
            initialIncomingAlpha = targetOpacity
        }

        let incomingXf = CGAffineTransform(translationX: initialIncomingTx, y: 0)
        for wid in incomingWindowIDs {
            initialEntries.append((windowID: wid, transform: incomingXf, alpha: initialIncomingAlpha))
        }

        if !initialEntries.isEmpty {
            HyprServerBridge.shared.setWorkspaceTransform(entries: initialEntries)
        }

        let animation = ActiveWorkspaceAnimation(
            oldWorkspace: oldWorkspace,
            newWorkspace: newWorkspace,
            outgoingWindowIDs: outgoingWindowIDs,
            incomingWindowIDs: incomingWindowIDs,
            duration: animConfig.duration,
            solver: solver,
            style: styleName,
            slideWidth: screenWidth,
            onComplete: onComplete
        )

        self.activeWorkspaceAnimation = animation
        ensureDisplayLinkRunning()
        return true
    }

    /// Cancels active workspace transition and resets transforms to identity.
    public func cancelWorkspaceAnimation() {
        guard let wsAnim = activeWorkspaceAnimation else { return }
        if !wsAnim.incomingWindowIDs.isEmpty {
            HyprServerBridge.shared.resetWorkspaceTransforms(windowIDs: wsAnim.incomingWindowIDs)
        }
        activeWorkspaceAnimation = nil
        if activeAnimations.isEmpty && !isSimulated {
            displayLink.stop()
        }
    }

    /// Cancels animation for a specific window, resetting transforms to identity.
    public func cancelAnimation(for windowID: CGWindowID) {
        guard let anim = activeAnimations.removeValue(forKey: windowID) else { return }
        var resetIDs: [CGWindowID] = [windowID]
        if let bWid = anim.borderWindowID {
            resetIDs.append(bWid)
        }
        if HyprServerBridge.shared.isAvailable {
            HyprServerBridge.shared.resetWorkspaceTransforms(windowIDs: resetIDs)
        }
        skyLight.setWindowTransform(windowID: windowID, transform: .identity)
        skyLight.setWindowAlpha(windowID: windowID, alpha: Float(config.windowOpacity))
        if let bWid = anim.borderWindowID {
            skyLight.setWindowTransform(windowID: bWid, transform: .identity)
            skyLight.setWindowAlpha(windowID: bWid, alpha: Float(config.windowOpacity))
        }
        if activeAnimations.isEmpty && activeWorkspaceAnimation == nil && !isSimulated {
            displayLink.stop()
        }
    }

    /// Cancels all active animations and resets transforms to identity.
    public func cancelAll() {
        cancelWorkspaceAnimation()
        var allResetIDs: [CGWindowID] = []
        for (wid, anim) in activeAnimations {
            allResetIDs.append(wid)
            if let bWid = anim.borderWindowID {
                allResetIDs.append(bWid)
            }
            skyLight.setWindowTransform(windowID: wid, transform: .identity)
            skyLight.setWindowAlpha(windowID: wid, alpha: Float(config.windowOpacity))
            if let bWid = anim.borderWindowID {
                skyLight.setWindowTransform(windowID: bWid, transform: .identity)
                skyLight.setWindowAlpha(windowID: bWid, alpha: Float(config.windowOpacity))
            }
        }
        if HyprServerBridge.shared.isAvailable && !allResetIDs.isEmpty {
            HyprServerBridge.shared.resetWorkspaceTransforms(windowIDs: allResetIDs)
        }
        activeAnimations.removeAll()
        isSteppingLock.withLock { isStepping in
            isStepping = false
        }
        if !isSimulated {
            displayLink.stop()
        }
    }

    // MARK: - Animation Stepping & Frame Evaluation

    /// Advances all active animations by elapsed delta-time dt (in seconds).
    /// Can be called directly by tests or triggered by DisplayLinkDriver.
    public func step(dt: Double) {
        guard !activeAnimations.isEmpty || activeWorkspaceAnimation != nil else {
            if !isSimulated && displayLink.isRunning {
                displayLink.stop()
            }
            return
        }

        // Advance active workspace animation
        if let wsAnim = activeWorkspaceAnimation {
            wsAnim.elapsed += dt
            let normalizedTime = min(max(wsAnim.elapsed / wsAnim.duration, 0.0), 1.0)

            let p: Double
            switch wsAnim.solver {
            case .bezier(let bezier):
                p = bezier.evaluate(at: normalizedTime)
            case .spring(let spring):
                p = spring.step(dt: dt)
            }
            wsAnim.currentProgress = p

            let finished: Bool
            switch wsAnim.solver {
            case .bezier:
                finished = (normalizedTime >= 1.0)
            case .spring(let spring):
                finished = spring.isSettled
            }

            if finished {
                wsAnim.isFinished = true
                if !wsAnim.incomingWindowIDs.isEmpty {
                    HyprServerBridge.shared.resetWorkspaceTransforms(windowIDs: wsAnim.incomingWindowIDs)
                }
                let cb = wsAnim.onComplete
                self.activeWorkspaceAnimation = nil
                cb?()
            } else {
                let direction: CGFloat = (wsAnim.newWorkspace > wsAnim.oldWorkspace) ? 1.0 : -1.0
                let targetOpacity = Float(config.windowOpacity)
                let clampedP = Float(min(max(p, 0.0), 1.0))
                var entries: [(windowID: CGWindowID, transform: CGAffineTransform, alpha: Float)] = []

                let outTx: CGFloat
                let inTx: CGFloat
                let outAlpha: Float
                let inAlpha: Float

                if wsAnim.style == "slidefade" {
                    outTx = -direction * wsAnim.slideWidth * CGFloat(p)
                    inTx = direction * wsAnim.slideWidth * (1.0 - CGFloat(p))
                    outAlpha = (1.0 - clampedP) * targetOpacity
                    inAlpha = clampedP * targetOpacity
                } else if wsAnim.style == "fade" {
                    outTx = 0.0
                    inTx = 0.0
                    outAlpha = (1.0 - clampedP) * targetOpacity
                    inAlpha = clampedP * targetOpacity
                } else {
                    // "slide"
                    outTx = -direction * wsAnim.slideWidth * CGFloat(p)
                    inTx = direction * wsAnim.slideWidth * (1.0 - CGFloat(p))
                    outAlpha = targetOpacity
                    inAlpha = targetOpacity
                }

                let outXf = CGAffineTransform(translationX: outTx, y: 0)
                for wid in wsAnim.outgoingWindowIDs {
                    entries.append((windowID: wid, transform: outXf, alpha: outAlpha))
                }

                let inXf = CGAffineTransform(translationX: inTx, y: 0)
                for wid in wsAnim.incomingWindowIDs {
                    entries.append((windowID: wid, transform: inXf, alpha: inAlpha))
                }

                if !entries.isEmpty {
                    HyprServerBridge.shared.setWorkspaceTransform(entries: entries)
                }
            }
        }

        var completedWids: [CGWindowID] = []
        var windowTransformEntries: [(windowID: CGWindowID, transform: CGAffineTransform, alpha: Float)] = []

        for (wid, anim) in activeAnimations {
            anim.elapsed += dt
            let normalizedTime = min(max(anim.elapsed / anim.duration, 0.0), 1.0)

            let p: Double
            switch anim.solver {
            case .bezier(let bezier):
                p = bezier.evaluate(at: normalizedTime)
            case .spring(let spring):
                p = spring.step(dt: dt)
            }

            anim.currentProgress = p

            // Compute interpolated visual frame
            let start = anim.startFrame
            let target = anim.targetFrame
            let curX = start.origin.x + CGFloat(p) * (target.origin.x - start.origin.x)
            let curY = start.origin.y + CGFloat(p) * (target.origin.y - start.origin.y)
            let curW = start.width + CGFloat(p) * (target.width - start.width)
            let curH = start.height + CGFloat(p) * (target.height - start.height)
            let curFrame = CGRect(x: curX, y: curY, width: curW, height: curH)
            anim.currentFrame = curFrame

            // Alpha lerping for windowsIn and windowsOut
            let targetOpacity = Float(config.windowOpacity)
            if anim.kind == .windowsIn {
                let clampedProgress = Float(min(max(p, 0.0), 1.0))
                anim.currentAlpha = clampedProgress * targetOpacity
                skyLight.setWindowAlpha(windowID: wid, alpha: anim.currentAlpha)
                if let bWid = anim.borderWindowID {
                    skyLight.setWindowAlpha(windowID: bWid, alpha: anim.currentAlpha)
                }
            } else if anim.kind == .windowsOut {
                let clampedProgress = Float(min(max(p, 0.0), 1.0))
                anim.currentAlpha = (1.0 - clampedProgress) * targetOpacity
                skyLight.setWindowAlpha(windowID: wid, alpha: anim.currentAlpha)
                if let bWid = anim.borderWindowID {
                    skyLight.setWindowAlpha(windowID: bWid, alpha: anim.currentAlpha)
                }
            }

            // Check completion: exclusively spring.isSettled for springs, normalizedTime >= 1.0 for beziers
            let finished: Bool
            switch anim.solver {
            case .bezier:
                finished = (normalizedTime >= 1.0)
            case .spring(let spring):
                finished = spring.isSettled
            }

            if finished {
                anim.isFinished = true
                completedWids.append(wid)
            } else {
                // Compute affine transform relative to physicalBaseFrame
                let baseFrame = anim.physicalBaseFrame
                let baseW = max(baseFrame.width, 1.0)
                let baseH = max(baseFrame.height, 1.0)
                let sx = curW / baseW
                let sy = curH / baseH
                let tx = curX - baseFrame.origin.x
                let ty = curY - baseFrame.origin.y
                let transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)

                if HyprServerBridge.shared.isAvailable {
                    windowTransformEntries.append((windowID: wid, transform: transform, alpha: anim.currentAlpha))
                    if let bWid = anim.borderWindowID {
                        windowTransformEntries.append((windowID: bWid, transform: transform, alpha: anim.currentAlpha))
                    }
                } else {
                    // Apply transform atomically via SkyLight transaction
                    if let txRef = skyLight.transactionCreate() {
                        skyLight.transactionSetWindowTransform(transaction: txRef, windowID: wid, transform: transform)
                        if let bWid = anim.borderWindowID {
                            skyLight.transactionSetWindowTransform(transaction: txRef, windowID: bWid, transform: transform)
                        }
                        skyLight.transactionCommit(transaction: txRef, sync: false)
                    } else {
                        skyLight.setWindowTransform(windowID: wid, transform: transform)
                        if let bWid = anim.borderWindowID {
                            skyLight.setWindowTransform(windowID: bWid, transform: transform)
                        }
                    }
                }
            }
        }

        if HyprServerBridge.shared.isAvailable && !windowTransformEntries.isEmpty {
            HyprServerBridge.shared.setWorkspaceTransform(entries: windowTransformEntries)
        }

        // Finalize completed animations
        for wid in completedWids {
            guard let anim = activeAnimations.removeValue(forKey: wid) else { continue }

            // 1. Reset transforms to identity and restore target opacity
            let finalAlpha = Float(config.windowOpacity)
            var resetIDs: [CGWindowID] = [wid]
            if let bWid = anim.borderWindowID {
                resetIDs.append(bWid)
            }

            if HyprServerBridge.shared.isAvailable {
                HyprServerBridge.shared.resetWorkspaceTransforms(windowIDs: resetIDs)
            } else {
                if let txRef = skyLight.transactionCreate() {
                    skyLight.transactionSetWindowTransform(transaction: txRef, windowID: wid, transform: .identity)
                    if let bWid = anim.borderWindowID {
                        skyLight.transactionSetWindowTransform(transaction: txRef, windowID: bWid, transform: .identity)
                    }
                    skyLight.transactionCommit(transaction: txRef, sync: true)
                } else {
                    skyLight.setWindowTransform(windowID: wid, transform: .identity)
                    if let bWid = anim.borderWindowID {
                        skyLight.setWindowTransform(windowID: bWid, transform: .identity)
                    }
                }
            }
            skyLight.setWindowAlpha(windowID: wid, alpha: finalAlpha)
            if let bWid = anim.borderWindowID {
                skyLight.setWindowAlpha(windowID: bWid, alpha: finalAlpha)
            }

            // 2. Apply final physical frame atomically via Accessibility
            if anim.kind != .windowsOut && anim.kind != .minimize {
                WindowDetector.shared.setWindowFrame(windowID: wid, frame: anim.targetFrame)
            }

            // 3. Invoke completion callback
            anim.onComplete?(wid)
        }

        if activeAnimations.isEmpty && activeWorkspaceAnimation == nil && !isSimulated {
            displayLink.stop()
        }
    }

    // MARK: - Internal Helpers

    private func ensureDisplayLinkRunning() {
        guard (activeWorkspaceAnimation != nil || !activeAnimations.isEmpty), !displayLink.isRunning, !isSimulated else { return }
        displayLink.start { [weak self] _, dt in
            guard let self = self else { return }
            let shouldStep = self.isSteppingLock.withLock { isStepping -> Bool in
                if isStepping { return false }
                isStepping = true
                return true
            }
            guard shouldStep else { return }

            Task { @MainActor in
                defer {
                    self.isSteppingLock.withLock { isStepping in
                        isStepping = false
                    }
                }
                self.step(dt: dt)
            }
        }
    }

    private func makeSolver(for anim: HyprAnimation) -> AnimationSolver {
        if anim.curveName.lowercased().hasPrefix("spring") {
            // Spring curve specification: e.g. "spring" or "spring, mass, stiffness, damping"
            let tokens = anim.curveName.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if tokens.count >= 4,
               let m = Double(tokens[1]),
               let k = Double(tokens[2]),
               let d = Double(tokens[3]) {
                let spring = SpringAnimation(config: SpringConfig(mass: m, stiffness: k, damping: d), startValue: 0.0, targetValue: 1.0)
                return .spring(spring)
            } else if tokens.count == 2, let zeta = Double(tokens[1]) {
                let spring = SpringAnimation(config: SpringConfig.withDampingRatio(dampingRatio: zeta), startValue: 0.0, targetValue: 1.0)
                return .spring(spring)
            }
            return .spring(SpringAnimation(config: .default, startValue: 0.0, targetValue: 1.0))
        }

        if let bezier = config.animationTree.getBezier(name: anim.curveName) {
            return .bezier(CubicBezier(bezier))
        }

        if let springConfig = config.animationTree.getSpring(name: anim.curveName) {
            return .spring(SpringAnimation(config: springConfig, startValue: 0.0, targetValue: 1.0))
        }

        switch anim.curveName.lowercased() {
        case "linear":
            return .bezier(CubicBezier.linear)
        case "almostlinear":
            return .bezier(CubicBezier.almostLinear)
        case "quick":
            return .bezier(CubicBezier.quick)
        case "easeoutquint":
            return .bezier(CubicBezier.easeOutQuint)
        case "easeinoutcubic":
            return .bezier(CubicBezier.easeInOutCubic)
        case "mybezier":
            return .bezier(CubicBezier.myBezier)
        default:
            return .bezier(CubicBezier.default)
        }
    }

    private func parsePopinPercentage(from style: String, defaultPercent: Double) -> Double {
        let lower = style.lowercased()
        if lower.contains("popin") {
            let tokens = lower.components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",%")))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for token in tokens {
                if let val = Double(token) {
                    return min(max(val, 10.0), 100.0)
                }
            }
        }
        return defaultPercent
    }
}
