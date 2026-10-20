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

    func testThumbnailLoaderDeduplicationAndPersistentDiskCache() async {
        let loader = WallpaperThumbnailLoader.shared
        loader.clearCache(clearDisk: true)

        let tempImgPath = NSTemporaryDirectory() + "test_thumb_target.png"
        let testImage = NSImage(size: NSSize(width: 400, height: 300))
        testImage.lockFocus()
        NSColor.blue.set()
        NSRect(x: 0, y: 0, width: 400, height: 300).fill()
        testImage.unlockFocus()

        if let tiff = testImage.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: tempImgPath))
        }
        defer { try? FileManager.default.removeItem(atPath: tempImgPath) }

        // Multiple subscribers test (in-flight deduplication)
        let exp1 = expectation(description: "Sub 1 received")
        let exp2 = expectation(description: "Sub 2 received")

        loader.loadThumbnail(for: tempImgPath) { img in
            XCTAssertNotNil(img)
            exp1.fulfill()
        }

        loader.loadThumbnail(for: tempImgPath) { img in
            XCTAssertNotNil(img)
            exp2.fulfill()
        }

        await fulfillment(of: [exp1, exp2], timeout: 5.0)

        // Verify persistent disk cache file exists
        let diskPath = loader.persistentDiskCachePath(for: tempImgPath, targetSize: NSSize(width: 250, height: 145))
        XCTAssertTrue(FileManager.default.fileExists(atPath: diskPath), "Persistent thumbnail cache file must exist on disk")

        // Clear memory cache only, leaving disk cache
        loader.clearCache(clearDisk: false)
        let exp3 = expectation(description: "Sub 3 loaded from disk cache")
        loader.loadThumbnail(for: tempImgPath) { img in
            XCTAssertNotNil(img)
            exp3.fulfill()
        }
        await fulfillment(of: [exp3], timeout: 5.0)
    }

    func testThumbnailLoaderCancellation() {
        let loader = WallpaperThumbnailLoader.shared
        let token = loader.loadThumbnail(for: "/non/existent/path/for/cancel.png") { _ in }
        XCTAssertNotNil(token)
        XCTAssertFalse(token!.isCanceled)
        token?.cancel()
        XCTAssertTrue(token!.isCanceled)
    }
}
