import XCTest
import Cocoa
@testable import HyprMac

@MainActor
final class RofiTests: XCTestCase {

    func testAppScannerDiscoversApps() {
        let scanner = AppScanner.shared
        let apps = scanner.scan(forceRefresh: true)

        XCTAssertFalse(apps.isEmpty, "AppScanner should discover installed applications on macOS")

        // Verify standard macOS applications exist in the scanned list
        let appNames = Set(apps.map { $0.name.lowercased() })
        let hasCommonApp = appNames.contains("safari") ||
                           appNames.contains("calculator") ||
                           appNames.contains("terminal") ||
                           appNames.contains("system settings")
        XCTAssertTrue(hasCommonApp, "Discovered apps should include at least one core macOS application")

        // Verify data structure invariants
        for app in apps.prefix(10) {
            XCTAssertFalse(app.name.isEmpty, "App item display name must not be empty")
            XCTAssertTrue(FileManager.default.fileExists(atPath: app.bundleURL.path), "App bundle URL must physically exist")
            XCTAssertNotNil(app.icon, "App item should have an icon")
            XCTAssertEqual(app.icon.size.width, 36.0, accuracy: 0.1, "App icon should be sized to 36x36")
            XCTAssertEqual(app.icon.size.height, 36.0, accuracy: 0.1, "App icon should be sized to 36x36")
        }
    }

    func testAppScannerCaching() {
        let scanner = AppScanner()
        scanner.clearCache()

        let firstScan = scanner.scan(forceRefresh: true)
        XCTAssertFalse(firstScan.isEmpty)

        let cachedScan = scanner.scan(forceRefresh: false)
        XCTAssertEqual(firstScan.count, cachedScan.count)

        scanner.clearCache()
    }

    func testFuzzyMatcherRankingPriority() {
        let dummyURL = URL(fileURLWithPath: "/Applications/Test.app")
        let dummyIcon = NSImage()

        let candidates: [AppItem] = [
            AppItem(name: "iTerm", bundleURL: dummyURL, bundleIdentifier: "com.googlecode.iterm2", icon: dummyIcon),
            AppItem(name: "Terminal", bundleURL: dummyURL, bundleIdentifier: "com.apple.Terminal", icon: dummyIcon),
            AppItem(name: "Visual Studio Code", bundleURL: dummyURL, bundleIdentifier: "com.microsoft.VSCode", icon: dummyIcon),
            AppItem(name: "Safari", bundleURL: dummyURL, bundleIdentifier: "com.apple.Safari", icon: dummyIcon),
            AppItem(name: "Google Chrome", bundleURL: dummyURL, bundleIdentifier: "com.google.Chrome", icon: dummyIcon)
        ]

        // 1. Exact prefix match beats substring match
        let termResults = FuzzyMatcher.match(query: "term", candidates: candidates, extractTarget: { $0.name })
        XCTAssertFalse(termResults.isEmpty)
        XCTAssertEqual(termResults.first?.name, "Terminal", "'Terminal' should rank above 'iTerm' for prefix 'term'")

        // 2. Exact match gets highest score
        let exactResults = FuzzyMatcher.match(query: "safari", candidates: candidates, extractTarget: { $0.name })
        XCTAssertEqual(exactResults.first?.name, "Safari")

        // 3. Word boundary match works (e.g. 'code' in 'Visual Studio Code')
        let codeResults = FuzzyMatcher.match(query: "code", candidates: candidates, extractTarget: { $0.name })
        XCTAssertEqual(codeResults.first?.name, "Visual Studio Code")

        // 4. Acronym initials match (e.g. 'gc' for 'Google Chrome')
        let gcResults = FuzzyMatcher.match(query: "gc", candidates: candidates, extractTarget: { $0.name })
        XCTAssertEqual(gcResults.first?.name, "Google Chrome")
    }

    func testFuzzyMatcherCaseInsensitivity() {
        let dummyURL = URL(fileURLWithPath: "/Applications/Safari.app")
        let candidates = [AppItem(name: "Safari", bundleURL: dummyURL, bundleIdentifier: "com.apple.Safari", icon: NSImage())]

        let lower = FuzzyMatcher.match(query: "safari", candidates: candidates, extractTarget: { $0.name })
        let upper = FuzzyMatcher.match(query: "SAFARI", candidates: candidates, extractTarget: { $0.name })
        let mixed = FuzzyMatcher.match(query: "sAfArI", candidates: candidates, extractTarget: { $0.name })

        XCTAssertEqual(lower.count, 1)
        XCTAssertEqual(upper.count, 1)
        XCTAssertEqual(mixed.count, 1)
        XCTAssertEqual(lower.first?.name, "Safari")
        XCTAssertEqual(upper.first?.name, "Safari")
        XCTAssertEqual(mixed.first?.name, "Safari")
    }

    func testFuzzyMatcherEmptyQueryReturnsAll() {
        let dummyURL = URL(fileURLWithPath: "/Applications/Test.app")
        let candidates = [
            AppItem(name: "AppA", bundleURL: dummyURL, bundleIdentifier: nil, icon: NSImage()),
            AppItem(name: "AppB", bundleURL: dummyURL, bundleIdentifier: nil, icon: NSImage())
        ]
        let results = FuzzyMatcher.match(query: "   ", candidates: candidates, extractTarget: { $0.name })
        XCTAssertEqual(results.count, 2)
    }

    func testFuzzyMatcherNoMatchReturnsEmpty() {
        let dummyURL = URL(fileURLWithPath: "/Applications/Test.app")
        let candidates = [
            AppItem(name: "Safari", bundleURL: dummyURL, bundleIdentifier: nil, icon: NSImage())
        ]
        let results = FuzzyMatcher.match(query: "zzqqxx999", candidates: candidates, extractTarget: { $0.name })
        XCTAssertTrue(results.isEmpty)
    }

    func testRofiWindowInitialization() {
        let window = RofiWindow(initialQuery: "test")
        defer {
            window.dismiss()
            window.close()
        }

        XCTAssertTrue(window.canBecomeKey, "RofiWindow must be capable of becoming key window for search input")
        XCTAssertTrue(window.canBecomeMain, "RofiWindow must be capable of becoming main window")
        XCTAssertEqual(window.level, .popUpMenu, "RofiWindow should have .popUpMenu level to float above other windows")
        XCTAssertEqual(window.frame.width, 900.0, accuracy: 0.1, "RofiWindow width must be 900px matching specification")
        XCTAssertEqual(window.frame.height, 440.0, accuracy: 0.1, "RofiWindow height must be 440px matching specification")
        XCTAssertFalse(window.isOpaque, "RofiWindow must be non-opaque for rounded blur aesthetics")
    }

    func testRofiTwoColumnLayoutAndModeSwitcher() {
        let window = RofiWindow(initialQuery: "")
        defer {
            window.dismiss()
            window.close()
        }

        // Verify 2-column split dimensions
        XCTAssertEqual(window.imageBoxView.frame.width, 410.0, accuracy: 0.1, "imagebox width must be 410px")
        XCTAssertEqual(window.imageBoxView.frame.height, 416.0, accuracy: 0.1, "imagebox height must be 416px")
        XCTAssertEqual(window.listBoxView.frame.width, 452.0, accuracy: 0.1, "listbox width must be 452px")
        XCTAssertEqual(window.listBoxView.frame.height, 416.0, accuracy: 0.1, "listbox height must be 416px")

        // Verify default mode is APPS
        XCTAssertEqual(window.currentMode, .apps, "Default mode must be APPS")

        // Mode switching
        window.setMode(.run)
        XCTAssertEqual(window.currentMode, .run, "Mode should update to RUN")
        window.setMode(.apps)
        XCTAssertEqual(window.currentMode, .apps, "Mode should update back to APPS")
    }

    func testRofiCyclicNavigation() {
        let window = RofiWindow(initialQuery: "")
        defer {
            window.dismiss()
            window.close()
        }

        let rowCount = window.listBoxView.rowViews.count
        if rowCount > 1 {
            XCTAssertEqual(window.selectedIndex, 0)
            window.setSelectedIndex(1)
            XCTAssertEqual(window.selectedIndex, 1)
            // Underflow should wrap to last index
            window.setSelectedIndex(-1)
            XCTAssertEqual(window.selectedIndex, rowCount - 1)
            // Overflow should wrap to 0
            window.setSelectedIndex(rowCount)
            XCTAssertEqual(window.selectedIndex, 0)
        }
    }

    func testMatugenCSSAndRasiThemeParsing() {
        let tempCSS = NSTemporaryDirectory() + "test_colors.css"
        let cssContent = """
        @define-color primary rgba(255, 182, 145, 1);
        @define-color surface rgba(26, 18, 14, 1);
        @define-color on_primary rgba(84, 33, 3, 1);
        @define-color on_surface rgba(240, 223, 216, 1);
        @define-color secondary rgba(230, 190, 172, 1);
        @define-color tertiary rgba(207, 200, 144, 1);
        @define-color outline rgba(160, 141, 133, 1);
        @define-color error rgba(255, 180, 171, 1);
        """
        try? cssContent.write(toFile: tempCSS, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempCSS) }

        let theme = HyprTheme(configPath: tempCSS)
        XCTAssertNotNil(theme.primary)
        XCTAssertNotNil(theme.surface)
        XCTAssertNotNil(theme.onPrimary)
        XCTAssertNotNil(theme.onSurface)
        XCTAssertNotNil(theme.secondary)
        XCTAssertNotNil(theme.tertiary)
        XCTAssertNotNil(theme.outline)
        XCTAssertNotNil(theme.error)

        // Verify color components parsed from rgba(255, 182, 145, 1)
        if let srgb = theme.primary.usingColorSpace(.sRGB) {
            XCTAssertEqual(Double(srgb.redComponent), 255.0 / 255.0, accuracy: 0.02)
            XCTAssertEqual(Double(srgb.greenComponent), 182.0 / 255.0, accuracy: 0.02)
            XCTAssertEqual(Double(srgb.blueComponent), 145.0 / 255.0, accuracy: 0.02)
        }
    }

    func testNSColorCustomParsing() {
        let cRGBA = NSColor.parseColorString("rgba(26, 18, 14, 0.8)")
        XCTAssertNotNil(cRGBA)
        XCTAssertEqual(Double(cRGBA!.alphaComponent), 0.8, accuracy: 0.02)

        let cRGB = NSColor.parseColorString("rgb(207, 224, 183)")
        XCTAssertNotNil(cRGB)
        XCTAssertEqual(Double(cRGB!.alphaComponent), 1.0, accuracy: 0.01)

        let cHex3 = NSColor.parseColorString("#fff")
        XCTAssertNotNil(cHex3)

        let cHex6 = NSColor.parseColorString("#e0a96d")
        XCTAssertNotNil(cHex6)

        let cHex8 = NSColor.parseColorString("#e0a96dff")
        XCTAssertNotNil(cHex8)
    }

    func testMathEvaluatorCalculations() {
        XCTAssertEqual(MathEvaluator.evaluate("2+2"), "4")
        XCTAssertEqual(MathEvaluator.evaluate("10/4"), "2.5")
        XCTAssertEqual(MathEvaluator.evaluate("2^8"), "256")
        XCTAssertEqual(MathEvaluator.evaluate("3x5"), "15")
        XCTAssertEqual(MathEvaluator.evaluate("50%"), "0.5")
        XCTAssertEqual(MathEvaluator.evaluate("(100 - 20) * 0.5"), "40")

        // Incomplete / invalid inputs must fail-safe without throwing
        XCTAssertNil(MathEvaluator.evaluate("2+"))
        XCTAssertNil(MathEvaluator.evaluate("safari"))
        XCTAssertNil(MathEvaluator.evaluate("1/0"))
        XCTAssertNil(MathEvaluator.evaluate("2..3"))
        XCTAssertNil(MathEvaluator.evaluate(""))
    }

    func testSystemCommandProviderMatches() {
        let lockMatches = SystemCommandProvider.match(query: "lock")
        XCTAssertFalse(lockMatches.isEmpty)
        XCTAssertEqual(lockMatches.first?.title, "Lock Screen")

        let spanishLock = SystemCommandProvider.match(query: "bloquear")
        XCTAssertFalse(spanishLock.isEmpty)
        XCTAssertEqual(spanishLock.first?.title, "Lock Screen")

        let sleepMatches = SystemCommandProvider.match(query: "sleep")
        XCTAssertFalse(sleepMatches.isEmpty)
        XCTAssertEqual(sleepMatches.first?.title, "Sleep / Suspend")

        let darkMatches = SystemCommandProvider.match(query: "dark mode")
        XCTAssertFalse(darkMatches.isEmpty)
        XCTAssertEqual(darkMatches.first?.title, "Toggle Dark Mode")

        let restartMatches = SystemCommandProvider.match(query: "reboot")
        XCTAssertFalse(restartMatches.isEmpty)
        XCTAssertEqual(restartMatches.first?.title, "Restart System")

        let trashMatches = SystemCommandProvider.match(query: "papelera")
        XCTAssertFalse(trashMatches.isEmpty)
        XCTAssertEqual(trashMatches.first?.title, "Empty Trash")

        let exitMatches = SystemCommandProvider.match(query: "aqua")
        XCTAssertFalse(exitMatches.isEmpty)
        XCTAssertEqual(exitMatches.first?.title, "Exit HyprMac (Aqua Mode)")
    }

    func testPathBinaryScannerDiscoversBinaries() {
        let binaries = PathBinaryScanner.shared.scan(forceRefresh: true)
        XCTAssertFalse(binaries.isEmpty, "PathBinaryScanner should discover binaries in $PATH")
        let names = Set(binaries.map { $0.name })
        XCTAssertTrue(names.contains("ls") || names.contains("sh") || names.contains("cat"))
    }

    func testRofiSmartSearchBlending() {
        let window = RofiWindow(initialQuery: "2+2")
        defer {
            window.dismiss()
            window.close()
        }

        // In APPS mode with "2+2", top result must be calculator
        XCTAssertFalse(window.filteredResults.isEmpty, "Initial query was '2+2', searchField: '(window.searchField.stringValue)', filteredResults count: (window.filteredResults.count), mode: (window.currentMode)")
        if case .calculator(let res, let expr) = window.filteredResults.first! {
            XCTAssertEqual(res, "4")
            XCTAssertEqual(expr, "2+2")
        } else {
            XCTFail("Top result for '2+2' must be .calculator")
        }

        // Switch to RUN mode
        window.setMode(.run)
        XCTAssertEqual(window.currentMode, .run)

        // Filter for a common system binary like "sh"
        window.searchField.stringValue = "sh"
        window.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertFalse(window.filteredResults.isEmpty)
        if case .runBinary = window.filteredResults.first! {
            // OK
        } else {
            XCTFail("In RUN mode, results must be .runBinary")
        }
    }

    func testWallpaperResolutionOrder() {
        let window = RofiWindow(initialQuery: "")
        defer {
            window.dismiss()
            window.close()
        }

        let cachePath = NSString(string: "~/.cache/current_wallpaper").expandingTildeInPath
        let originalContent = try? String(contentsOfFile: cachePath, encoding: .utf8)
        defer {
            if let orig = originalContent {
                try? orig.write(toFile: cachePath, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(atPath: cachePath)
            }
        }

        // 1. Create a dummy test image and point ~/.cache/current_wallpaper to it
        let tempImgPath = NSTemporaryDirectory() + "test_wall.png"
        let testImage = NSImage(size: NSSize(width: 10, height: 10))
        testImage.lockFocus()
        NSColor.red.set()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        testImage.unlockFocus()
        if let tiff = testImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: tempImgPath))
        }
        defer { try? FileManager.default.removeItem(atPath: tempImgPath) }

        try? (tempImgPath + "   ").write(toFile: cachePath, atomically: true, encoding: .utf8)
        let cachedImg = window.loadWallpaperImage()
        XCTAssertNotNil(cachedImg, "Wallpaper should load from ~/.cache/current_wallpaper when valid")

        // 2. Remove ~/.cache/current_wallpaper -> should resolve to macOS desktop image or nil (no crash, no mxmrn fallback)
        try? FileManager.default.removeItem(atPath: cachePath)
        let systemWallpaper = window.loadWallpaperImage()
        if let screen = NSScreen.main ?? NSScreen.screens.first,
           let url = NSWorkspace.shared.desktopImageURL(for: screen),
           FileManager.default.fileExists(atPath: url.path) {
            XCTAssertNotNil(systemWallpaper, "Should resolve to active macOS desktop image")
        }
    }
}
