import XCTest
import CoreGraphics
@testable import HyprMac

@MainActor
final class AnimationTests: XCTestCase {

    // MARK: - CubicBezier Tests

    func testCubicBezierLinear() {
        let linear = CubicBezier.linear
        XCTAssertEqual(linear.evaluate(at: 0.0), 0.0, accuracy: 1e-5)
        XCTAssertEqual(linear.evaluate(at: 0.25), 0.25, accuracy: 1e-4)
        XCTAssertEqual(linear.evaluate(at: 0.5), 0.5, accuracy: 1e-4)
        XCTAssertEqual(linear.evaluate(at: 0.75), 0.75, accuracy: 1e-4)
        XCTAssertEqual(linear.evaluate(at: 1.0), 1.0, accuracy: 1e-5)
    }

    func testCubicBezierEndpointsAndClamping() {
        let bezier = CubicBezier.default
        XCTAssertEqual(bezier.evaluate(at: -0.5), 0.0)
        XCTAssertEqual(bezier.evaluate(at: 0.0), 0.0)
        XCTAssertEqual(bezier.evaluate(at: 1.0), 1.0)
        XCTAssertEqual(bezier.evaluate(at: 1.5), 1.0)
    }

    func testCubicBezierPresets() {
        let myBezier = CubicBezier.myBezier
        let val05 = myBezier.evaluate(at: 0.5)
        // myBezier (0.05, 0.9, 0.1, 1.05) is very fast and snaps up
        XCTAssertGreaterThan(val05, 0.8)
        XCTAssertLessThanOrEqual(val05, 1.1)

        let easeOutQuint = CubicBezier.easeOutQuint
        let valQuint05 = easeOutQuint.evaluate(at: 0.5)
        XCTAssertGreaterThan(valQuint05, 0.85)

        let easeInOut = CubicBezier.easeInOut
        let valIO05 = easeInOut.evaluate(at: 0.5)
        XCTAssertEqual(valIO05, 0.5, accuracy: 0.05)
    }

    func testCubicBezierRootFindingExtremeCurves() {
        // Curve with steep inflection testing Newton-Raphson and bisection fallback
        let steep = CubicBezier(x0: 0.0, y0: 1.0, x1: 0.0, y1: 1.0)
        let res05 = steep.evaluate(at: 0.5)
        XCTAssertGreaterThan(res05, 0.0)
        XCTAssertLessThanOrEqual(res05, 1.0)

        let sCurve = CubicBezier(x0: 0.9, y0: 0.0, x1: 0.1, y1: 1.0)
        XCTAssertEqual(sCurve.evaluate(at: 0.0), 0.0, accuracy: 1e-5)
        XCTAssertEqual(sCurve.evaluate(at: 1.0), 1.0, accuracy: 1e-5)
    }

    // MARK: - SpringAnimation Tests

    func testSpringUnderdampedOscillation() {
        // Underdamped with dampingRatio = 0.4 should overshoot 1.0
        let config = SpringConfig.withDampingRatio(mass: 1.0, stiffness: 100.0, dampingRatio: 0.4)
        let spring = SpringAnimation(config: config, startValue: 0.0, targetValue: 1.0)

        var maxVal = 0.0
        var t = 0.0
        while t < 2.0 {
            let (val, _) = spring.evaluate(at: t)
            maxVal = max(maxVal, val)
            t += 0.01
        }
        XCTAssertGreaterThan(maxVal, 1.1, "Underdamped spring must exhibit overshoot beyond target")
    }

    func testSpringCriticallyDampedMonotonic() {
        // Critically damped with dampingRatio = 1.0 must not overshoot
        let config = SpringConfig.withDampingRatio(mass: 1.0, stiffness: 100.0, dampingRatio: 1.0)
        let spring = SpringAnimation(config: config, startValue: 0.0, targetValue: 1.0)

        var maxVal = 0.0
        var t = 0.0
        while t < 2.0 {
            let (val, _) = spring.evaluate(at: t)
            maxVal = max(maxVal, val)
            t += 0.01
        }
        XCTAssertLessThanOrEqual(maxVal, 1.0001, "Critically damped spring must not overshoot target")
    }

    func testSpringOverdampedConvergence() {
        let config = SpringConfig.withDampingRatio(mass: 1.0, stiffness: 80.0, dampingRatio: 1.5)
        let spring = SpringAnimation(config: config, startValue: 0.0, targetValue: 1.0)

        // Step until settled
        for _ in 0..<300 {
            spring.step(dt: 1.0 / 60.0)
            if spring.isSettled { break }
        }
        XCTAssertTrue(spring.isSettled)
        XCTAssertEqual(spring.currentValue, 1.0, accuracy: 1e-4)
        XCTAssertEqual(spring.currentVelocity, 0.0, accuracy: 1e-3)
    }

    func testSpringReset() {
        let spring = SpringAnimation(config: .default, startValue: 0.0, targetValue: 1.0)
        spring.step(dt: 0.5)
        XCTAssertFalse(spring.isSettled)

        spring.reset(startValue: 10.0, targetValue: 20.0, initialVelocity: 0.0)
        XCTAssertEqual(spring.startValue, 10.0)
        XCTAssertEqual(spring.targetValue, 20.0)
        XCTAssertEqual(spring.currentValue, 10.0)
    }

    // MARK: - DisplayLinkDriver Tests

    func testDisplayLinkNominalCalculations() {
        let driver = DisplayLinkDriver()
        XCTAssertGreaterThan(driver.nominalRefreshPeriod, 0.0)
        XCTAssertGreaterThan(driver.nominalRefreshRate, 0.0)
        XCTAssertLessThanOrEqual(driver.nominalRefreshRate, 500.0)
    }

    // MARK: - ConfigParser Animation Tests

    func testConfigParserAnimationDirectives() {
        let conf = """
        animations {
            enabled = yes
            bezier = testBezier, 0.1, 0.8, 0.2, 1.1
            bezier = customEase, 0.25, 0.1, 0.25, 1.0
            animation = windows, 1, 7, testBezier
            animation = windowsMove, 1, 5, customEase
            animation = windowsIn, 1, 6, testBezier, popin 75%
            animation = workspaces, 0, 4, default
        }
        """
        let parsed = ConfigParser.parse(text: conf)
        XCTAssertTrue(parsed.animationsEnabled)

        let b1 = parsed.animationTree.getBezier(name: "testBezier")
        XCTAssertNotNil(b1)
        XCTAssertEqual(b1?.x0, 0.1)
        XCTAssertEqual(b1?.y0, 0.8)
        XCTAssertEqual(b1?.x1, 0.2)
        XCTAssertEqual(b1?.y1, 1.1)

        let b2 = parsed.animationTree.getBezier(name: "customEase")
        XCTAssertNotNil(b2)

        let animWindows = parsed.animationTree.getConfig(for: "windows")
        XCTAssertTrue(animWindows.enabled)
        XCTAssertEqual(animWindows.duration, 0.7, accuracy: 1e-4)
        XCTAssertEqual(animWindows.curveName, "testBezier")

        let animMove = parsed.animationTree.getConfig(for: "windowsMove")
        XCTAssertTrue(animMove.enabled)
        XCTAssertEqual(animMove.duration, 0.5, accuracy: 1e-4)
        XCTAssertEqual(animMove.curveName, "customEase")

        let animIn = parsed.animationTree.getConfig(for: "windowsIn")
        XCTAssertTrue(animIn.enabled)
        XCTAssertEqual(animIn.duration, 0.6, accuracy: 1e-4)
        XCTAssertEqual(animIn.style, "popin 75%")

        let animWorkspaces = parsed.animationTree.getConfig(for: "workspaces")
        XCTAssertFalse(animWorkspaces.enabled)
    }

    func testConfigParserAnimationHierarchyFallback() {
        var tree = HyprAnimationTree.default
        tree.setConfigForNode(node: "global", enabled: true, duration: 0.8, curveName: "linear")
        tree.animations.removeValue(forKey: "windowsMove")
        tree.animations.removeValue(forKey: "windows")

        // windowsMove should fall back to windows -> global
        let fallback = tree.getConfig(for: "windowsMove")
        XCTAssertEqual(fallback.duration, 0.8)
        XCTAssertEqual(fallback.curveName, "linear")
    }

    // MARK: - AnimationEngine Tests

    func testAnimationEngineMoveStateTransitions() {
        let engine = AnimationEngine()
        engine.isSimulated = true

        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = CGRect(x: 500, y: 200, width: 600, height: 450)
        var completed = false

        let started = engine.animateMove(
            windowID: 9991,
            startFrame: start,
            targetFrame: target,
            borderWindowID: 9992
        ) { wid in
            XCTAssertEqual(wid, 9991)
            completed = true
        }
        XCTAssertTrue(started)
        XCTAssertTrue(engine.isAnimating(windowID: 9991))

        // Step halfway (dt = 0.20s for upstream easy spring)
        engine.step(dt: 0.20)
        XCTAssertFalse(completed)
        XCTAssertTrue(engine.isAnimating(windowID: 9991))
        let midFrame = engine.currentVisualFrame(windowID: 9991)
        XCTAssertNotNil(midFrame)
        XCTAssertGreaterThan(midFrame!.origin.x, start.origin.x)
        XCTAssertLessThan(midFrame!.origin.x, target.origin.x)

        // Step remaining time to finish in standard 60Hz ticks
        for _ in 0..<60 {
            engine.step(dt: 0.02)
            if completed { break }
        }
        XCTAssertTrue(completed)
        XCTAssertFalse(engine.isAnimating(windowID: 9991))
    }

    func testAnimationEnginePopinInAndOut() {
        let engine = AnimationEngine()
        engine.isSimulated = true

        let target = CGRect(x: 200, y: 200, width: 800, height: 600)
        var inCompleted = false
        engine.animateIn(
            windowID: 8881,
            targetFrame: target,
            style: "popin 70%"
        ) { _ in
            inCompleted = true
        }
        XCTAssertTrue(engine.isAnimating(windowID: 8881))

        // Step to completion with 60Hz ticks
        for _ in 0..<60 {
            engine.step(dt: 0.02)
            if inCompleted { break }
        }
        XCTAssertTrue(inCompleted)
        XCTAssertFalse(engine.isAnimating(windowID: 8881))

        // Test animateOut
        var outCompleted = false
        engine.animateOut(
            windowID: 8882,
            startFrame: target,
            style: "popin 60%"
        ) { _ in
            outCompleted = true
        }
        XCTAssertTrue(engine.isAnimating(windowID: 8882))
        for _ in 0..<60 {
            engine.step(dt: 0.02)
            if outCompleted { break }
        }
        XCTAssertTrue(outCompleted)
        XCTAssertFalse(engine.isAnimating(windowID: 8882))
    }

    func testAnimationEngineCancellation() {
        let engine = AnimationEngine()
        engine.isSimulated = true

        engine.animateMove(
            windowID: 7771,
            startFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
            targetFrame: CGRect(x: 100, y: 100, width: 300, height: 300)
        )
        XCTAssertTrue(engine.isAnimating(windowID: 7771))

        engine.cancelAnimation(for: 7771)
        XCTAssertFalse(engine.isAnimating(windowID: 7771))
    }

    func testAnimationEngineSpringSolverIntegration() {
        var config = HyprConfig.default
        config.animationTree.setConfigForNode(
            node: "windowsMove",
            enabled: true,
            duration: 1.0,
            curveName: "spring, 1.0, 150.0, 15.0"
        )
        let engine = AnimationEngine(config: config)
        engine.isSimulated = true

        var completed = false
        engine.animateMove(
            windowID: 6661,
            startFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetFrame: CGRect(x: 500, y: 500, width: 600, height: 600)
        ) { _ in
            completed = true
        }
        XCTAssertTrue(engine.isAnimating(windowID: 6661))

        // Step forward with spring simulation
        for _ in 0..<120 {
            engine.step(dt: 1.0 / 60.0)
            if completed { break }
        }
        XCTAssertTrue(completed)
        XCTAssertFalse(engine.isAnimating(windowID: 6661))
    }

    func testAnimationEngineMidFlightRetargeting() {
        let engine = AnimationEngine()
        engine.isSimulated = true

        let f0 = CGRect(x: 0, y: 0, width: 400, height: 300)
        let f1 = CGRect(x: 200, y: 200, width: 400, height: 300)
        let f2 = CGRect(x: 500, y: 100, width: 600, height: 400)

        // 1. Initial move to f1
        engine.animateMove(windowID: 5551, startFrame: f0, targetFrame: f1)
        XCTAssertEqual(engine.activeAnimations[5551]?.physicalBaseFrame, f0)

        // Step halfway (dt = 0.20s before spring overshoot)
        engine.step(dt: 0.20)
        let midFrame = engine.currentVisualFrame(windowID: 5551)!
        XCTAssertGreaterThan(midFrame.origin.x, f0.origin.x)
        XCTAssertLessThan(midFrame.origin.x, f1.origin.x)

        // 2. Retarget mid-flight to f2
        var completed = false
        engine.animateMove(windowID: 5551, targetFrame: f2) { wid in
            completed = true
        }

        let retargetedAnim = engine.activeAnimations[5551]!
        // startFrame must be the mid-flight visual frame
        XCTAssertEqual(retargetedAnim.startFrame.origin.x, midFrame.origin.x, accuracy: 1e-4)
        XCTAssertEqual(retargetedAnim.startFrame.origin.y, midFrame.origin.y, accuracy: 1e-4)
        // physicalBaseFrame must remain f0 so the GPU transform matrix offset does not jump
        XCTAssertEqual(retargetedAnim.physicalBaseFrame, f0)

        // Step to completion of the retargeted move
        for _ in 0..<100 {
            engine.step(dt: 0.02)
            if completed { break }
        }
        XCTAssertTrue(completed)
        XCTAssertFalse(engine.isAnimating(windowID: 5551))
    }

    func testSpringSolverTerminationExclusivelyOnSettled() {
        var config = HyprConfig.default
        // Low stiffness spring takes ~0.5s to settle, but duration is configured nominally to 0.1s
        config.animationTree.setConfigForNode(
            node: "windowsMove",
            enabled: true,
            duration: 0.1,
            curveName: "spring, 1.0, 50.0, 5.0"
        )
        let engine = AnimationEngine(config: config)
        engine.isSimulated = true

        var completed = false
        engine.animateMove(
            windowID: 4441,
            startFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
            targetFrame: CGRect(x: 100, y: 100, width: 400, height: 400)
        ) { _ in
            completed = true
        }

        // Step past nominal duration (0.15s > 0.10s)
        engine.step(dt: 0.15)
        // Spring must NOT have terminated prematurely simply because elapsed >= duration
        XCTAssertFalse(completed, "Spring animation must not terminate prematurely on duration cutoff")
        XCTAssertTrue(engine.isAnimating(windowID: 4441))

        // Step forward until spring naturally settles
        for _ in 0..<200 {
            engine.step(dt: 0.02)
            if completed { break }
        }
        XCTAssertTrue(completed, "Spring animation must terminate when settled")
        XCTAssertFalse(engine.isAnimating(windowID: 4441))
    }

    func testAlphaLerpWindowsInAndWindowsOut() {
        let engine = AnimationEngine()
        engine.isSimulated = true

        let target = CGRect(x: 100, y: 100, width: 500, height: 400)
        var inCompleted = false
        engine.animateIn(
            windowID: 3331,
            targetFrame: target,
            style: "popin 80%"
        ) { _ in
            inCompleted = true
        }

        let inAnim = engine.activeAnimations[3331]!
        XCTAssertEqual(inAnim.currentAlpha, 0.0, "animateIn must start with visual alpha 0.0")

        // Step halfway (dt = 0.20s for duration ~0.41s)
        engine.step(dt: 0.20)
        XCTAssertGreaterThan(inAnim.currentAlpha, 0.1)
        XCTAssertLessThanOrEqual(inAnim.currentAlpha, Float(engine.config.windowOpacity))

        // Complete animateIn via 60Hz ticks
        for _ in 0..<60 {
            engine.step(dt: 0.02)
            if inCompleted { break }
        }
        XCTAssertTrue(inCompleted)

        // Test animateOut alpha lerp
        var outCompleted = false
        engine.animateOut(
            windowID: 3332,
            startFrame: target,
            style: "popin 80%"
        ) { _ in
            outCompleted = true
        }
        let outAnim = engine.activeAnimations[3332]!
        XCTAssertEqual(outAnim.currentAlpha, Float(engine.config.windowOpacity))

        // Step partially
        engine.step(dt: 0.07)
        XCTAssertLessThan(outAnim.currentAlpha, Float(engine.config.windowOpacity))
        XCTAssertGreaterThan(outAnim.currentAlpha, 0.0)

        // Complete animateOut via 60Hz ticks
        for _ in 0..<30 {
            engine.step(dt: 0.02)
            if outCompleted { break }
        }
        XCTAssertTrue(outCompleted)
    }

    func testMakeSolverResolvesSpringsFromTree() {
        // Default Hyprland config maps windowsMove to spring "easy"
        let engine = AnimationEngine(config: .default)
        engine.isSimulated = true

        engine.animateMove(
            windowID: 2221,
            startFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetFrame: CGRect(x: 200, y: 200, width: 300, height: 300)
        )

        guard let anim = engine.activeAnimations[2221] else {
            XCTFail("Animation not found")
            return
        }

        switch anim.solver {
        case .spring(let spring):
            XCTAssertEqual(spring.config.mass, SpringConfig.easy.mass)
            XCTAssertEqual(spring.config.stiffness, SpringConfig.easy.stiffness, accuracy: 1e-3)
            XCTAssertEqual(spring.config.damping, SpringConfig.easy.damping, accuracy: 1e-3)
        case .bezier:
            XCTFail("windowsMove with curve 'easy' must resolve to a Spring solver")
        }
        engine.cancelAll()
    }

    func testConfigParserSpringDirective() {
        let conf = """
        animations {
            enabled = yes
            spring = customSpring, 1.0, 260.0, 26.0
            animation = windows, 1, 4.5, customSpring
        }
        """
        let parsed = ConfigParser.parse(text: conf)
        let spring = parsed.animationTree.getSpring(name: "customSpring")
        XCTAssertNotNil(spring)
        XCTAssertEqual(spring?.mass, 1.0)
        XCTAssertEqual(spring?.stiffness, 260.0)
        XCTAssertEqual(spring?.damping, 26.0)

        let anim = parsed.animationTree.getConfig(for: "windows")
        XCTAssertEqual(anim.curveName, "customSpring")
    }

    func testDwindleEngineApplyToSystemNewlyAddedWindows() {
        let dwindle = DwindleEngine()
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frames = dwindle.addWindow(windowID: 1111, in: bounds)

        let animEngine = AnimationEngine.shared
        animEngine.isSimulated = true

        dwindle.applyToSystem(windowFrames: frames, newlyAddedWindows: [1111])

        XCTAssertTrue(animEngine.isAnimating(windowID: 1111))
        XCTAssertEqual(animEngine.activeAnimations[1111]?.kind, .windowsIn)
        animEngine.cancelAll()
    }

    func testDwindleEngineReconcileSkipsActiveAnimations() {
        let dwindle = DwindleEngine()
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        _ = dwindle.addWindow(windowID: 1212, in: bounds)

        let animEngine = AnimationEngine.shared
        animEngine.isSimulated = true

        // Start animation
        animEngine.animateMove(
            windowID: 1212,
            startFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetFrame: CGRect(x: 500, y: 500, width: 400, height: 400)
        )

        var snappedWid: CGWindowID? = nil
        let snapped = dwindle.reconcileFrames(
            threshold: 1.0,
            boundsProvider: { _ in CGRect(x: 50, y: 50, width: 100, height: 100) },
            frameSetter: { wid, _ in snappedWid = wid }
        )

        // Because 1212 is actively animating, reconcileFrames must skip it and not snap back
        XCTAssertTrue(snapped.isEmpty)
        XCTAssertNil(snappedWid)
        animEngine.cancelAll()
    }

    // MARK: - Workspace Transition Animation Tests

    func testWorkspaceTransitionSlideProgressionAndCompletion() {
        let engine = AnimationEngine()
        engine.isSimulated = true
        engine.config.animationTree.setConfigForNode(
            node: "workspaces",
            enabled: true,
            duration: 0.2,
            curveName: "linear",
            style: "slide"
        )

        var completed = false
        let started = engine.animateWorkspaceTransition(
            oldWorkspace: 1,
            newWorkspace: 2,
            outgoingWindowIDs: [1001, 1002],
            incomingWindowIDs: [2001],
            screenWidth: 1920
        ) {
            completed = true
        }

        XCTAssertTrue(started)
        XCTAssertNotNil(engine.activeWorkspaceAnimation)
        XCTAssertEqual(engine.activeWorkspaceAnimation?.style, "slide")
        XCTAssertEqual(engine.activeWorkspaceAnimation?.slideWidth, 1920)
        XCTAssertEqual(engine.activeWorkspaceAnimation?.outgoingWindowIDs, [1001, 1002])
        XCTAssertEqual(engine.activeWorkspaceAnimation?.incomingWindowIDs, [2001])

        // Step halfway (0.10s of 0.20s linear curve)
        engine.step(dt: 0.10)
        XCTAssertFalse(completed)
        XCTAssertNotNil(engine.activeWorkspaceAnimation)
        XCTAssertEqual(engine.activeWorkspaceAnimation!.currentProgress, 0.5, accuracy: 1e-3)

        // Step remaining to completion
        engine.step(dt: 0.15)
        XCTAssertTrue(completed)
        XCTAssertNil(engine.activeWorkspaceAnimation)
    }

    func testWorkspaceTransitionFadeProgressionAndCompletion() {
        let engine = AnimationEngine()
        engine.isSimulated = true
        engine.config.animationTree.setConfigForNode(
            node: "workspaces",
            enabled: true,
            duration: 0.2,
            curveName: "linear",
            style: "fade"
        )

        var completed = false
        let started = engine.animateWorkspaceTransition(
            oldWorkspace: 2,
            newWorkspace: 1,
            outgoingWindowIDs: [2001],
            incomingWindowIDs: [1001],
            screenWidth: 1920
        ) {
            completed = true
        }

        XCTAssertTrue(started)
        XCTAssertNotNil(engine.activeWorkspaceAnimation)
        XCTAssertEqual(engine.activeWorkspaceAnimation?.style, "fade")

        // Step to completion
        engine.step(dt: 0.25)
        XCTAssertTrue(completed)
        XCTAssertNil(engine.activeWorkspaceAnimation)
    }

    func testWorkspaceTransitionSlideFadeProgression() {
        let engine = AnimationEngine()
        engine.isSimulated = true
        engine.config.animationTree.setConfigForNode(
            node: "workspaces",
            enabled: true,
            duration: 0.2,
            curveName: "linear",
            style: "slidefade"
        )

        var completed = false
        let started = engine.animateWorkspaceTransition(
            oldWorkspace: 1,
            newWorkspace: 3,
            outgoingWindowIDs: [1001],
            incomingWindowIDs: [3001],
            screenWidth: 2560
        ) {
            completed = true
        }

        XCTAssertTrue(started)
        XCTAssertEqual(engine.activeWorkspaceAnimation?.style, "slidefade")

        engine.step(dt: 0.10)
        XCTAssertEqual(engine.activeWorkspaceAnimation!.currentProgress, 0.5, accuracy: 1e-3)

        engine.step(dt: 0.15)
        XCTAssertTrue(completed)
        XCTAssertNil(engine.activeWorkspaceAnimation)
    }

    func testWorkspaceTransitionDisabledImmediatelyCompletes() {
        let engine = AnimationEngine()
        engine.isSimulated = true
        engine.config.animationTree.setConfigForNode(
            node: "workspaces",
            enabled: false,
            duration: 0.2,
            curveName: "linear"
        )

        var completed = false
        let started = engine.animateWorkspaceTransition(
            oldWorkspace: 1,
            newWorkspace: 2,
            outgoingWindowIDs: [1001],
            incomingWindowIDs: [2001],
            screenWidth: 1920
        ) {
            completed = true
        }

        XCTAssertFalse(started)
        XCTAssertTrue(completed)
        XCTAssertNil(engine.activeWorkspaceAnimation)
    }

    func testWorkspaceTransitionCancelAllResetsState() {
        let engine = AnimationEngine()
        engine.isSimulated = true
        engine.config.animationTree.setConfigForNode(
            node: "workspaces",
            enabled: true,
            duration: 0.5,
            curveName: "linear"
        )

        var completed = false
        engine.animateWorkspaceTransition(
            oldWorkspace: 1,
            newWorkspace: 2,
            outgoingWindowIDs: [1001],
            incomingWindowIDs: [2001],
            screenWidth: 1920
        ) {
            completed = true
        }

        XCTAssertNotNil(engine.activeWorkspaceAnimation)
        engine.cancelAll()
        XCTAssertNil(engine.activeWorkspaceAnimation)
        XCTAssertFalse(completed)
    }

    func testAnimateFullscreenStepAndCompletion() {
        let engine = AnimationEngine()
        engine.isSimulated = true
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = CGRect(x: 0, y: 37, width: 1920, height: 1043)
        var completed = false

        let started = engine.animateFullscreen(
            windowID: 1005,
            from: start,
            to: target,
            isFullscreen: true
        ) { _ in
            completed = true
        }

        XCTAssertTrue(started)
        XCTAssertTrue(engine.isAnimating(windowID: 1005))

        // Step through to finish (duration is 0.18s)
        engine.step(dt: 0.10)
        XCTAssertFalse(completed)
        XCTAssertTrue(engine.isAnimating(windowID: 1005))

        engine.step(dt: 0.10)
        XCTAssertTrue(completed)
        XCTAssertFalse(engine.isAnimating(windowID: 1005))
    }
}
