import XCTest
import Cocoa
@testable import HyprMac

@MainActor
final class HyprBarTests: XCTestCase {

    func testBatteryStatusFormatted() {
        let status = BatteryStatus(isPresent: true, isCharging: true, percentage: 85, powerSource: "AC")
        XCTAssertFalse(status.formattedText.isEmpty)
        XCTAssertEqual(status.formattedText, "85% ")
    }

    func testBatteryStatusNotPresent() {
        let status = BatteryStatus(isPresent: false, isCharging: false, percentage: 0, powerSource: "None")
        XCTAssertFalse(status.formattedText.isEmpty)
        XCTAssertEqual(status.formattedText, "100% ")
    }

    func testBarStyleEquality() {
        let docked1: HyprBarStyle = .docked
        let docked2: HyprBarStyle = .docked
        XCTAssertEqual(docked1, docked2)

        let pill1: HyprBarStyle = .floatingPill(horizontalMargin: 8.0, topMargin: 5.0)
        let pill2: HyprBarStyle = .floatingPill(horizontalMargin: 8.0, topMargin: 5.0)
        XCTAssertEqual(pill1, pill2)
    }

    func testBarStyleInequality() {
        let docked: HyprBarStyle = .docked
        let pill: HyprBarStyle = .floatingPill(horizontalMargin: 8.0, topMargin: 5.0)
        XCTAssertNotEqual(docked, pill)
    }

    func testHyprBarWindowInit() {
        let window = HyprBarWindow()
        defer {
            window.hideBar()
            window.close()
        }
        XCTAssertEqual(window.barHeight, 32.0)
        XCTAssertEqual(window.level, .statusBar)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
    }

    func testBarViewDefaultWorkspace() {
        let barView = BarView(frame: .zero, workspaceCount: 5)
        defer { barView.stopTimers() }
        XCTAssertEqual(barView.activeWorkspaceID, 1)
    }

    func testBarViewUpdateWorkspace() {
        let barView = BarView(frame: .zero, workspaceCount: 5)
        defer { barView.stopTimers() }
        barView.updateActiveWorkspace(3)
        XCTAssertEqual(barView.activeWorkspaceID, 3)
    }

    func testBarViewUpdateActiveWindow() {
        let barView = BarView(frame: .zero, workspaceCount: 5)
        defer { barView.stopTimers() }
        barView.updateActiveWindow(title: "README.md", app: "Code")
        XCTAssertEqual(barView.currentAppName, "Code")
        XCTAssertEqual(barView.currentWindowTitle, "README.md")
    }

    func testBarViewDirtyRectInvalidationOnTitleShrink() {
        let barView = BarView(frame: NSRect(x: 0, y: 0, width: 1904, height: 32), workspaceCount: 6)
        defer { barView.stopTimers() }

        // 1. Expand with a long title
        barView.updateActiveWindow(title: "Hermano, podes revisar el repo de github de los temas que uso", app: "ChatGPT")
        barView.layoutSubtreeIfNeeded()
        let longWidth = barView.leftCapsule.frame.width
        XCTAssertGreaterThan(longWidth, 200.0)

        // 2. Contract with a short title
        barView.updateActiveWindow(title: "~", app: "")
        barView.layoutSubtreeIfNeeded()
        let shortWidth = barView.leftCapsule.frame.width
        XCTAssertLessThan(shortWidth, longWidth)

        // 3. Verify transparent layer clearing invariants
        XCTAssertFalse(barView.isOpaque)
        XCTAssertEqual(barView.layerContentsRedrawPolicy, .onSetNeedsDisplay)
    }

    func testBarViewCornerRadius() {
        let barView = BarView(frame: .zero, workspaceCount: 5)
        defer { barView.stopTimers() }
        XCTAssertEqual(barView.cornerRadius, 5.0)
    }

    func testBarViewHasThreeCapsules() {
        let barView = BarView(frame: .zero, workspaceCount: 5)
        defer { barView.stopTimers() }
        XCTAssertNotNil(barView.leftCapsule)
        XCTAssertNotNil(barView.centerCapsule)
        XCTAssertNotNil(barView.rightCapsule)
    }

    func testKanjiWorkspaces() {
        let barView = BarView(frame: .zero, workspaceCount: 6)
        defer { barView.stopTimers() }
        XCTAssertEqual(WorkspacePill.kanjiList.prefix(6), ["一", "二", "三", "四", "五", "六"])
        XCTAssertEqual(barView.activeWorkspaceID, 1)
        barView.updateActiveWorkspace(2)
        XCTAssertEqual(barView.activeWorkspaceID, 2)
    }

    func testHardwareMonitor() {
        let cpu = HardwareMonitor.currentCPULoad()
        XCTAssertGreaterThanOrEqual(cpu, 1)
        XCTAssertLessThanOrEqual(cpu, 100)
        let mem = HardwareMonitor.currentMemoryLoad()
        XCTAssertGreaterThanOrEqual(mem, 1)
        XCTAssertLessThanOrEqual(mem, 100)
    }

    func testHyprThemeFallbacks() {
        let theme = HyprTheme.fallbackSurfaceHex
        XCTAssertEqual(theme, "#191614")
        XCTAssertEqual(HyprTheme.fallbackPrimaryHex, "#e0a96d")
        XCTAssertEqual(HyprTheme.fallbackOnPrimaryHex, "#191614")
        XCTAssertEqual(HyprTheme.fallbackSecondaryHex, "#c5c6d0")
        XCTAssertEqual(HyprTheme.fallbackTertiaryHex, "#b0c7de")
        XCTAssertEqual(HyprTheme.fallbackErrorHex, "#ffb4ab")
        XCTAssertEqual(HyprTheme.fallbackOnSurfaceHex, "#e3e1e9")
    }

    func testHyprBarWindowSharedLifecycle() {
        let window = HyprBarWindow()
        XCTAssertNotNil(HyprBarWindow.shared)
        XCTAssertTrue(HyprBarWindow.shared === window)
        window.hideBar()
        window.close()
    }

    func testHyprThemeWaybarCSSParsing() {
        let tempDir = FileManager.default.temporaryDirectory
        let tempCSS = tempDir.appendingPathComponent("test_colors_waybar.css")

        let lines = [
            "/* Waybar color scheme generated by pywal16 */",
            "@define-color foreground #f2e9e4;",
            "@define-color background #1a1514;",
            "@define-color primary #a37567;",
            "@define-color on_primary #1a1514;",
            "@define-color secondary #4a5659;",
            "@define-color tertiary #84b8ad;",
            "@define-color surface #1a1514;",
            "@define-color error #5e4841;",
            "@define-color outline #a09692;"
        ]
        let cssContent = lines.joined(separator: "\n")

        try? cssContent.write(to: tempCSS, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempCSS) }

        let theme = HyprTheme(configPath: tempCSS.path)
        XCTAssertEqual(theme.primary.hexString.lowercased(), "#a37567")
        XCTAssertEqual(theme.surface.hexString.lowercased(), "#1a1514")
        XCTAssertEqual(theme.secondary.hexString.lowercased(), "#4a5659")
        XCTAssertEqual(theme.tertiary.hexString.lowercased(), "#84b8ad")
        XCTAssertEqual(theme.error.hexString.lowercased(), "#5e4841")
    }

    func testHyprThemePywalTokenFallback() {
        let tempDir = FileManager.default.temporaryDirectory
        let tempCSS = tempDir.appendingPathComponent("test_raw_pywal.css")

        let lines = [
            "@define-color foreground #c3c4c8;",
            "@define-color background #0f1323;",
            "@define-color color0 #0f1323;",
            "@define-color color1 #5062a1;",
            "@define-color color2 #4e67b1;",
            "@define-color color3 #5071cf;",
            "@define-color color4 #6b89b5;",
            "@define-color color5 #6291d3;",
            "@define-color color8 #5e6274;"
        ]
        let rawPywalCSS = lines.joined(separator: "\n")

        try? rawPywalCSS.write(to: tempCSS, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempCSS) }

        let theme = HyprTheme(configPath: tempCSS.path)
        XCTAssertEqual(theme.primary.hexString.lowercased(), "#6b89b5")
        XCTAssertEqual(theme.secondary.hexString.lowercased(), "#4e67b1")
        XCTAssertEqual(theme.tertiary.hexString.lowercased(), "#6291d3")
        XCTAssertEqual(theme.surface.hexString.lowercased(), "#0f1323")
        XCTAssertEqual(theme.error.hexString.lowercased(), "#5062a1")
    }

    func testBarFontNerdFontGlyphResolution() {
        let font = NSFont.barFont(ofSize: 11, weight: .medium)
        XCTAssertNotNil(font)

        // Verify telemetry glyphs render without tofu via CoreText line creation
        let telemetryString = "100%   01:27 Sun   59%"
        let attrStr = NSAttributedString(string: telemetryString, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attrStr)
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        XCTAssertGreaterThan(runs.count, 0)
    }

    func testRightIslandModularHardwareLayout() {
        let barView = BarView(frame: NSRect(x: 0, y: 0, width: 1200, height: 32))
        barView.updateHardware()
        barView.updateNetwork()
        barView.updateVolume()

        XCTAssertTrue(barView.networkLabel.stringValue.contains("  "))
        XCTAssertTrue(barView.cpuLabel.stringValue.contains("󰍛  "))
        XCTAssertTrue(barView.memLabel.stringValue.contains("  "))
        XCTAssertTrue(barView.volumeLabel.stringValue.contains("  "))
    }

    func testCapsuleTransparencyAndBehindWindowBlur() {
        let barView = BarView(frame: NSRect(x: 0, y: 0, width: 1200, height: 32))
        XCTAssertEqual(barView.capsuleAlpha, 0.65, accuracy: 0.01)
        XCTAssertEqual(barView.leftCapsule.surfaceAlpha, 0.65, accuracy: 0.01)

        barView.capsuleAlpha = 0.45
        XCTAssertEqual(barView.leftCapsule.surfaceAlpha, 0.45, accuracy: 0.01)
        XCTAssertEqual(barView.centerCapsule.surfaceAlpha, 0.45, accuracy: 0.01)
        XCTAssertEqual(barView.rightCapsule.surfaceAlpha, 0.45, accuracy: 0.01)
    }

    func testDeclarativeBarColorsApplication() {
        let barView = BarView(frame: .zero, workspaceCount: 6)
        defer { barView.stopTimers() }
        var barColors = HyprBarColors()
        barColors.windowTitle = "#E4A136"
        barColors.workspacesInactive = "#8C9071"
        barColors.workspacesActiveBg = "#E4A136"
        barColors.workspacesActiveFg = "#131514"
        barView.barColors = barColors

        XCTAssertEqual(barView.windowTitleLabel.textColor?.hexString.lowercased(), "#e4a136")
        XCTAssertEqual(barView.batteryLabel.textColor?.hexString.lowercased(), barView.theme.secondary.hexString.lowercased())
    }

    func testHyprThemeResolveColorAndRgbaHexParsing() {
        let theme = HyprTheme.shared
        let parsed = NSColor.parseColorString("rgba(E4A136ee)")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.hexString.lowercased(), "#e4a136")

        let resolvedToken = theme.resolveColor("primary", fallback: .black)
        XCTAssertEqual(resolvedToken.hexString.lowercased(), theme.primary.hexString.lowercased())

        let resolvedHex = theme.resolveColor("#E4A136", fallback: .black)
        XCTAssertEqual(resolvedHex.hexString.lowercased(), "#e4a136")

        let resolvedRgbaHex = theme.resolveColor("rgba(E4A136ee)", fallback: .black)
        XCTAssertEqual(resolvedRgbaHex.hexString.lowercased(), "#e4a136")
    }

    func testHyprBarWindowFloatingPillLayout() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let window = HyprBarWindow(
            screen: screen,
            height: 32.0,
            style: .floatingPill(horizontalMargin: 8.0, topMargin: 5.0),
            workspaceCount: 6
        )
        defer {
            window.hideBar()
            window.close()
        }

        window.reposition()
        let screenFrame = screen.frame
        XCTAssertEqual(window.frame.width, screenFrame.width - 16.0)
        XCTAssertEqual(window.frame.origin.x, screenFrame.origin.x + 8.0)
        XCTAssertEqual(window.frame.origin.y, screenFrame.origin.y + screenFrame.height - 32.0 - 5.0)
        XCTAssertEqual(window.frame.height, 32.0)
        XCTAssertEqual(window.barBottomY, 37.0)
    }

    func testBarViewClockFormat12h() {
        let barView = BarView(frame: NSRect(x: 0, y: 0, width: 1440, height: 32), workspaceCount: 6)
        barView.clockFormat = "h:mm a  EEE"
        barView.updateClock()
        let text = barView.clockLabel.stringValue
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("AM") || text.contains("PM") || text.contains("am") || text.contains("pm") || text.contains("m."), "Clock string '\(text)' must contain 12-hour AM/PM period indicator")
    }

    func testFullscreenAutoHideAndHoverReveal() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let window = HyprBarWindow(
            screen: screen,
            height: 32.0,
            style: .floatingPill(horizontalMargin: 8.0, topMargin: 5.0),
            workspaceCount: 6
        )
        defer {
            window.setFullscreenAutoHide(false, animated: false)
            window.hideBar()
            window.close()
        }

        let screenFrame = screen.frame
        let resting = window.restingFrame(for: screenFrame)
        let hidden = window.hiddenFullscreenFrame(for: screenFrame)

        // 1. setFullscreenAutoHide(true, animated: false) moves HyprBarWindow to hiddenFullscreenFrame, alphaValue == 0.0, ignoresMouseEvents == true
        window.setFullscreenAutoHide(true, animated: false)
        XCTAssertTrue(window.isFullscreenAutoHide)
        XCTAssertFalse(window.isRevealedInFullscreen)
        XCTAssertEqual(window.frame, hidden)
        XCTAssertEqual(window.alphaValue, 0.0)
        XCTAssertTrue(window.ignoresMouseEvents)

        // 2. handleCursorLocation at top edge (y = screenFrame.maxY - 1.0) reveals the bar
        let topEdgeLocation = NSPoint(x: screenFrame.midX, y: screenFrame.maxY - 1.0)
        window.handleCursorLocation(topEdgeLocation, animated: false)
        XCTAssertTrue(window.isRevealedInFullscreen)
        XCTAssertEqual(window.frame, resting)
        XCTAssertEqual(window.alphaValue, 1.0)
        XCTAssertFalse(window.ignoresMouseEvents)

        // 3. handleCursorLocation while inside the bar (y = screenFrame.maxY - 20.0) keeps isRevealedInFullscreen == true
        let insideBarLocation = NSPoint(x: screenFrame.midX, y: screenFrame.maxY - 20.0)
        window.handleCursorLocation(insideBarLocation, animated: false)
        XCTAssertTrue(window.isRevealedInFullscreen)
        XCTAssertEqual(window.frame, resting)
        XCTAssertEqual(window.alphaValue, 1.0)
        XCTAssertFalse(window.ignoresMouseEvents)

        // 4. handleCursorLocation below the bar (y = screenFrame.maxY - 80.0, immediateHide: true) conceals the bar back to hiddenFullscreenFrame
        let belowBarLocation = NSPoint(x: screenFrame.midX, y: screenFrame.maxY - 80.0)
        window.handleCursorLocation(belowBarLocation, animated: false, immediateHide: true)
        XCTAssertFalse(window.isRevealedInFullscreen)
        XCTAssertEqual(window.frame, hidden)
        XCTAssertEqual(window.alphaValue, 0.0)
        XCTAssertTrue(window.ignoresMouseEvents)

        // 5. setFullscreenAutoHide(false, animated: false) restores the bar to restingFrame
        window.setFullscreenAutoHide(false, animated: false)
        XCTAssertFalse(window.isFullscreenAutoHide)
        XCTAssertFalse(window.isRevealedInFullscreen)
        XCTAssertEqual(window.frame, resting)
        XCTAssertEqual(window.alphaValue, 1.0)
        XCTAssertFalse(window.ignoresMouseEvents)
    }

    func testNotificationCenterDrawerWindowLevel() {
        XCTAssertEqual(NotificationCenterDrawer.shared.level, .popUpMenu)
    }
}
