import XCTest
import CoreGraphics
@testable import HyprMac

@MainActor
final class SpecialWorkspaceAndAnimationTests: XCTestCase {

    // MARK: - Normalization Tests

    func testNormalizeSpecialName() {
        XCTAssertEqual(WorkspaceManager.normalizeSpecialName(""), "scratchpad")
        XCTAssertEqual(WorkspaceManager.normalizeSpecialName("   "), "scratchpad")
        XCTAssertEqual(WorkspaceManager.normalizeSpecialName("special"), "scratchpad")
        XCTAssertEqual(WorkspaceManager.normalizeSpecialName("special:"), "scratchpad")
        XCTAssertEqual(WorkspaceManager.normalizeSpecialName("special:scratchpad"), "scratchpad")
        XCTAssertEqual(WorkspaceManager.normalizeSpecialName("special:discord"), "discord")
        XCTAssertEqual(WorkspaceManager.normalizeSpecialName("terminal"), "terminal")
        XCTAssertEqual(WorkspaceManager.normalizeSpecialName("  special:notes  "), "notes")
    }

    // MARK: - Special Workspace Lifecycle & Toggle Tests

    func testToggleSpecialWorkspaceShowingAndHiding() {
        let manager = WorkspaceManager()
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var simulatedFrames: [CGWindowID: CGRect] = [:]

        let getFrame: (CGWindowID) -> CGRect? = { simulatedFrames[$0] }
        let setFrame: (CGWindowID, CGRect) -> Void = { simulatedFrames[$0] = $1 }

        // Setup regular windows on workspace 1
        manager.assignWindow(wid: 101, to: 1)
        manager.assignWindow(wid: 102, to: 1)
        simulatedFrames[101] = CGRect(x: 0, y: 0, width: 960, height: 1080)
        simulatedFrames[102] = CGRect(x: 960, y: 0, width: 960, height: 1080)

        // Add window 301 to special workspace "scratchpad" (silent = false, but scratchpad is currently closed)
        manager.moveWindowToSpecialWorkspace(
            301,
            name: "scratchpad",
            silent: false,
            screenBounds: screen,
            getFrame: getFrame,
            setFrame: setFrame
        )

        // 1. Initial State: Window 301 is in special workspace, parked offscreen
        XCTAssertTrue(manager.isInSpecialWorkspace(301))
        XCTAssertEqual(manager.specialWorkspaceName(for: 301), "scratchpad")
        XCTAssertNil(manager.workspace(for: 301), "Special windows must not belong to numbered workspaces 1...9")
        XCTAssertFalse(manager.activeSpecialWorkspaces.contains("scratchpad"))
        XCTAssertFalse(manager.activeWindowIDs().contains(301), "Inactive scratchpad window must not be in activeWindowIDs")
        XCTAssertEqual(manager.activeWindowIDs(), [101, 102], "Regular workspace 1 windows must remain unchanged")

        let frameBeforeToggle = simulatedFrames[301]
        XCTAssertNotNil(frameBeforeToggle)
        XCTAssertTrue(HiddenWindowPlacement.isHidden(screen: screen, window: frameBeforeToggle!), "Window 301 must initially be parked offscreen")

        // 2. Toggle scratchpad OPEN
        manager.toggleSpecialWorkspace(
            name: "scratchpad",
            screenBounds: screen,
            getFrame: getFrame,
            setFrame: setFrame
        )

        XCTAssertTrue(manager.activeSpecialWorkspaces.contains("scratchpad"))
        XCTAssertTrue(manager.activeWindowIDs().contains(301), "Open scratchpad window must now be included in activeWindowIDs")
        XCTAssertEqual(Set(manager.activeWindowIDs()), Set([101, 102, 301]))

        let revealedFrame = simulatedFrames[301]
        XCTAssertNotNil(revealedFrame)
        XCTAssertFalse(HiddenWindowPlacement.isHidden(screen: screen, window: revealedFrame!), "Revealed window 301 must be on screen")
        XCTAssertEqual(revealedFrame?.width, 1920 * 0.75)
        XCTAssertEqual(revealedFrame?.height, 1080 * 0.75)

        // Verify regular windows 101 and 102 were NOT disturbed
        XCTAssertEqual(simulatedFrames[101], CGRect(x: 0, y: 0, width: 960, height: 1080))
        XCTAssertEqual(simulatedFrames[102], CGRect(x: 960, y: 0, width: 960, height: 1080))

        // 3. Toggle scratchpad CLOSED
        manager.toggleSpecialWorkspace(
            name: "scratchpad",
            screenBounds: screen,
            getFrame: getFrame,
            setFrame: setFrame
        )

        XCTAssertFalse(manager.activeSpecialWorkspaces.contains("scratchpad"))
        XCTAssertFalse(manager.activeWindowIDs().contains(301))
        XCTAssertEqual(manager.activeWindowIDs(), [101, 102])

        let hiddenAgain = simulatedFrames[301]
        XCTAssertNotNil(hiddenAgain)
        XCTAssertTrue(HiddenWindowPlacement.isHidden(screen: screen, window: hiddenAgain!), "Window 301 must be parked offscreen again")
    }

    // MARK: - Move Window to Special Workspace and Back Tests

    func testMoveWindowToSpecialWorkspaceAndRestoreToRegular() {
        let manager = WorkspaceManager()
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var simulatedFrames: [CGWindowID: CGRect] = [:]

        let getFrame: (CGWindowID) -> CGRect? = { simulatedFrames[$0] }
        let setFrame: (CGWindowID, CGRect) -> Void = { simulatedFrames[$0] = $1 }

        // Start with window 501 on workspace 2
        manager.assignWindow(wid: 501, to: 2)
        simulatedFrames[501] = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(manager.workspace(for: 501), 2)
        XCTAssertFalse(manager.isInSpecialWorkspace(501))

        // Move 501 to special:scratchpad silently
        manager.moveWindowToSpecialWorkspace(
            501,
            name: "special:scratchpad",
            silent: true,
            screenBounds: screen,
            getFrame: getFrame,
            setFrame: setFrame
        )

        XCTAssertNil(manager.workspace(for: 501), "Window 501 must be stripped from workspace 2")
        XCTAssertTrue(manager.isInSpecialWorkspace(501))
        XCTAssertEqual(manager.specialWorkspaceName(for: 501), "scratchpad")
        XCTAssertEqual(manager.specialWindows(for: "scratchpad"), [501])

        // Verify window was parked offscreen and original frame saved
        XCTAssertTrue(HiddenWindowPlacement.isHidden(screen: screen, window: simulatedFrames[501]!))
        XCTAssertEqual(manager.savedSpecialFrames[501], CGRect(x: 100, y: 100, width: 800, height: 600))

        // Open scratchpad: window should restore to its saved frame (100, 100, 800, 600)
        manager.toggleSpecialWorkspace(
            name: "scratchpad",
            screenBounds: screen,
            getFrame: getFrame,
            setFrame: setFrame
        )
        XCTAssertEqual(simulatedFrames[501], CGRect(x: 100, y: 100, width: 800, height: 600))

        // Move window 501 from special:scratchpad back to regular workspace 1
        manager.assignWindow(wid: 501, to: 1)
        XCTAssertEqual(manager.workspace(for: 501), 1)
        XCTAssertFalse(manager.isInSpecialWorkspace(501), "Assigning to regular workspace must remove window from special workspace")
        XCTAssertNil(manager.specialWorkspaceName(for: 501))
        XCTAssertTrue(manager.specialWindows(for: "scratchpad").isEmpty)
    }

    // MARK: - AnimationEngine SkyLight Pipeline Tests

    func testAnimationEngineStepAppliesSkyLightTransformsEvenWhenServerUnavailable() {
        let skyLight = SkyLightBridge.shared
        skyLight.clearTracking()

        let engine = AnimationEngine(skyLight: skyLight)
        engine.isSimulated = true
        engine.config.windowOpacity = 0.95
        engine.config.animationTree.setConfigForNode(
            node: "workspaces",
            enabled: true,
            duration: 0.20,
            curveName: "linear",
            style: "slide"
        )

        let outgoingWID: CGWindowID = 9101
        let incomingWID: CGWindowID = 9201

        let started = engine.animateWorkspaceSwitch(
            oldWorkspace: 1,
            newWorkspace: 2,
            outgoingWindowIDs: [outgoingWID],
            incomingWindowIDs: [incomingWID],
            screenWidth: 1920
        )

        XCTAssertTrue(started)
        XCTAssertNotNil(engine.activeWorkspaceAnimation)

        // Step halfway (0.10s of 0.20s linear curve -> progress = 0.5)
        engine.step(dt: 0.10)

        // Verify SkyLight received the expected transforms
        // Outgoing window (moving left): tx = -direction * width * p = -1 * 1920 * 0.5 = -960
        // Incoming window (moving left towards 0): tx = direction * width * (1 - p) = 1 * 1920 * 0.5 = 960
        let incomingXf = skyLight.getTrackedTransform(windowID: incomingWID)
        let outgoingXf = skyLight.getTrackedTransform(windowID: outgoingWID)

        XCTAssertNotNil(incomingXf, "SkyLightBridge must have received a transform for incoming window")
        XCTAssertNotNil(outgoingXf, "SkyLightBridge must have received a transform for outgoing window")
        XCTAssertEqual(incomingXf?.tx ?? 0, 960.0, accuracy: 1.0)
        XCTAssertEqual(outgoingXf?.tx ?? 0, -960.0, accuracy: 1.0)

        let incomingAlpha = skyLight.getTrackedAlpha(windowID: incomingWID)
        XCTAssertNotNil(incomingAlpha)
        XCTAssertEqual(incomingAlpha ?? 0, Float(0.95), accuracy: 1e-3)

        // Step to completion (remaining 0.15s)
        engine.step(dt: 0.15)
        XCTAssertNil(engine.activeWorkspaceAnimation, "Workspace animation must be finished and cleared")

        // Upon completion, transforms must be reset to .identity
        let finalIncomingXf = skyLight.getTrackedTransform(windowID: incomingWID)
        let finalOutgoingXf = skyLight.getTrackedTransform(windowID: outgoingWID)
        XCTAssertEqual(finalIncomingXf, CGAffineTransform.identity, "Incoming window transform must reset to identity")
        XCTAssertEqual(finalOutgoingXf, CGAffineTransform.identity, "Outgoing window transform must reset to identity")
    }

    // MARK: - ConfigParser Special Workspace Directive Tests

    func testConfigParserSpecialWorkspaceDirectives() {
        let input = """
        windowrule = workspace special:scratchpad, class:^(spotify)$
        windowrule = workspace special:discord silent, class:Discord
        windowrulev2 = workspace special:terminal, class:^(kitty)$
        bind = $mainMod, S, togglespecialworkspace, scratchpad
        bind = $mainMod SHIFT, S, movetoworkspacesilent, special:scratchpad
        """

        let config = ConfigParser.parse(text: input)

        XCTAssertEqual(config.windowRules.count, 3)
        XCTAssertEqual(config.windowRules[0].action, .specialWorkspace(name: "scratchpad", silent: false))
        XCTAssertEqual(config.windowRules[0].criteria, [.class(pattern: "^(spotify)$")])

        XCTAssertEqual(config.windowRules[1].action, .specialWorkspace(name: "discord", silent: true))
        XCTAssertEqual(config.windowRules[1].criteria, [.class(pattern: "Discord")])

        XCTAssertEqual(config.windowRules[2].action, .specialWorkspace(name: "terminal", silent: false))
        XCTAssertEqual(config.windowRules[2].criteria, [.class(pattern: "^(kitty)$")])

        XCTAssertEqual(config.bindings.count, 2)
        XCTAssertEqual(config.bindings[0].dispatcher, "togglespecialworkspace")
        XCTAssertEqual(config.bindings[0].args, "scratchpad")

        XCTAssertEqual(config.bindings[1].dispatcher, "movetoworkspacesilent")
        XCTAssertEqual(config.bindings[1].args, "special:scratchpad")
    }
}

