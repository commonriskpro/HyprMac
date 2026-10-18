import XCTest
@testable import HyprMac

final class WallpaperWatcherTests: XCTestCase {
    func testCanonicalizePathSingleAndMultipleSlashes() {
        let u1 = URL(fileURLWithPath: "/Users/test/wallpaper.jpg")
        XCTAssertEqual(WallpaperWatcher.canonicalizePath(from: u1), "/Users/test/wallpaper.jpg")

        let rawMultiple = "///Users/test/another.png"
        XCTAssertEqual(WallpaperWatcher.cleanLeadingSlashes(rawMultiple), "/Users/test/another.png")

        let rawQuad = "////Users/test/img.png"
        XCTAssertEqual(WallpaperWatcher.cleanLeadingSlashes(rawQuad), "/Users/test/img.png")
    }

    func testComputeFileSHA256() {
        let pkgSwift = "/Users/saturno/Developer/REA/Package.swift"
        let hash = WallpaperWatcher.computeFileSHA256(atPath: pkgSwift)
        XCTAssertNotNil(hash)
        XCTAssertEqual(hash?.count, 64)
    }

    func testStartStopLifecycle() {
        let watcher = WallpaperWatcher()
        watcher.start()
        // Verify stopping is completely safe and symmetric
        watcher.stop()
    }

    func testWatcherSelfTest() {
        XCTAssertTrue(WallpaperWatcher.runSelfTest())
    }
}
