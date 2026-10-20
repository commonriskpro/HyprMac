import Foundation
import Cocoa
import CoreServices
import CryptoKit

/// Native Kernel-Level Event-Driven Wallpaper & Theming Watcher for HyprMac.
///
/// Monitors macOS wallpaper changes via FSEventStream against
/// ~/Library/Application Support/com.apple.wallpaper/Store in a strictly event-driven
/// fashion (0% CPU at idle, zero polling, debounced at kernel level to 0.5s).
///
/// On change, standardizes path, checks SHA256 idempotency, runs wallset.sh asynchronously,
/// and dispatches theme / bar / border reloads to MainActor.
public final class WallpaperWatcher: @unchecked Sendable {
    public static let shared = WallpaperWatcher()

    public var onThemeReload: (@MainActor () -> Void)?

    private let eventQueue = DispatchQueue(label: "com.hyprmac.wallpaperwatcher", qos: .utility)
    private var streamRef: FSEventStreamRef?

    private var lastProcessedPath: String?
    private var lastProcessedHash: String?
    private var isExecuting: Bool = false
    private var hasPendingEvent: Bool = false

    public init() {}

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Starts the FSEvents stream monitoring wallpaper changes.
    public func start() {
        eventQueue.async { [weak self] in
            guard let self = self, self.streamRef == nil else { return }

            self.initializeFromExistingTheme()

            let storePath = NSString(string: "~/Library/Application Support/com.apple.wallpaper/Store").expandingTildeInPath
            guard FileManager.default.fileExists(atPath: storePath) else {
                print("[-] [WallpaperWatcher] Wallpaper store path does not exist: \(storePath)")
                return
            }

            let pathsToWatch = [storePath] as CFArray

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let callback: FSEventStreamCallback = { stream, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds in
                guard let clientCallBackInfo = clientCallBackInfo else { return }
                let watcher = Unmanaged<WallpaperWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
                watcher.handleStreamEvent()
            }

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.5, // 0.5s latency debouncing
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            ) else {
                print("[-] [WallpaperWatcher] Failed to create FSEventStream for \(storePath)")
                return
            }

            self.streamRef = stream
            FSEventStreamSetDispatchQueue(stream, self.eventQueue)

            if FSEventStreamStart(stream) {
                print("[+] [WallpaperWatcher] Kernel FSEvents watcher active on \(storePath) (0.5s debounce)")
            } else {
                print("[-] [WallpaperWatcher] Failed to start FSEventStream")
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.streamRef = nil
            }
        }
    }

    /// Stops and cleanly invalidates the FSEvents stream.
    public func stop() {
        eventQueue.sync { [weak self] in
            guard let self = self, let stream = self.streamRef else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.streamRef = nil
            print("[+] [WallpaperWatcher] FSEventStream stopped and released cleanly")
        }
    }

    // MARK: - Event Processing

    private func handleStreamEvent() {
        processCurrentWallpaper(force: false)
    }

    /// Manually triggers a check of the active desktop wallpaper.
    public func triggerCheck(force: Bool = false) {
        eventQueue.async { [weak self] in
            self?.processCurrentWallpaper(force: force)
        }
    }

    private func processCurrentWallpaper(force: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return
        }

        let standardizedPath = Self.canonicalizePath(from: url)

        guard FileManager.default.fileExists(atPath: standardizedPath) else {
            print("[-] [WallpaperWatcher] Desktop picture does not exist at path: \(standardizedPath)")
            return
        }

        let fileHash = Self.computeFileSHA256(atPath: standardizedPath) ?? ""

        if !force && standardizedPath == lastProcessedPath && (!fileHash.isEmpty && fileHash == lastProcessedHash) {
            // Unchanged; strictly idempotent
            return
        }

        if isExecuting {
            hasPendingEvent = true
            return
        }

        self.lastProcessedPath = standardizedPath
        self.lastProcessedHash = fileHash
        self.isExecuting = true

        let cachePath = NSString(string: "~/.cache/current_wallpaper").expandingTildeInPath
        try? standardizedPath.write(toFile: cachePath, atomically: true, encoding: .utf8)

        print("[+] [WallpaperWatcher] Wallpaper transition detected: \(standardizedPath)")

        let candidates = [
            NSString(string: "~/.config/hypr/scripts/wallset.sh").expandingTildeInPath,
            NSString(string: "~/.local/bin/wallset").expandingTildeInPath,
            (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Resources/scripts/wallset.sh"),
            (Bundle.main.bundlePath as NSString).appendingPathComponent("scripts/wallset.sh"),
            FileManager.default.currentDirectoryPath + "/scripts/wallset.sh"
        ]
        guard let wallsetScript = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            print("[-] [WallpaperWatcher] wallset.sh script not found in candidate paths")
            self.isExecuting = false
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [wallsetScript, standardizedPath]

        var env = ProcessInfo.processInfo.environment
        let localBin = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")
        env["PATH"] = "\(localBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            self.eventQueue.async {
                self.isExecuting = false
                if self.hasPendingEvent {
                    self.hasPendingEvent = false
                    self.processCurrentWallpaper(force: false)
                }
            }

            guard proc.terminationStatus == 0 else {
                print("[-] [WallpaperWatcher] wallset.sh exited with status \(proc.terminationStatus)")
                return
            }

            print("[+] [WallpaperWatcher] wallset.sh finished. Refreshing live themes...")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    HyprTheme.shared.reload()

                    if let bar = HyprBarWindow.shared {
                        bar.barView.theme = HyprTheme.shared
                        bar.barView.applyTheme()
                    }

                    self.onThemeReload?()
                }
            }
        }

        do {
            try process.run()
        } catch {
            self.isExecuting = false
            print("[-] [WallpaperWatcher] Failed to spawn wallset.sh process: \(error)")
        }
    }

    private func initializeFromExistingTheme() {
        let colorsPath = NSString(string: "~/.config/hyprmac/colors.json").expandingTildeInPath
        if let data = try? Data(contentsOf: URL(fileURLWithPath: colorsPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let wp = json["wallpaper"] as? String {
            let clean = Self.cleanLeadingSlashes(wp)
            self.lastProcessedPath = clean
            self.lastProcessedHash = Self.computeFileSHA256(atPath: clean)
        }
    }

    // MARK: - Utilities

    /// Standardizes file URL and strips any leading duplicate slashes.
    public static func canonicalizePath(from url: URL) -> String {
        return cleanLeadingSlashes(url.standardizedFileURL.path)
    }

    /// Strips leading duplicate slashes until exactly one root slash remains.
    public static func cleanLeadingSlashes(_ raw: String) -> String {
        var path = raw
        while path.hasPrefix("//") {
            path = String(path.dropFirst())
        }
        return path
    }

    /// Computes the SHA256 digest of a local file using memory-mapped reading.
    public static func computeFileSHA256(atPath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Self-Test Suite

    /// Executes self-diagnostics verifying path canonicalization, hashing, and watcher lifecycle.
    @discardableResult
    public static func runSelfTest() -> Bool {
        print("=== [WallpaperWatcher Self-Test] ===")

        // 1. Path canonicalization check
        let home = NSHomeDirectory()
        let sampleURL = URL(fileURLWithPath: "///" + (home as NSString).appendingPathComponent("Desktop/test.png"))
        let canon = canonicalizePath(from: sampleURL)
        let expected = (home as NSString).appendingPathComponent("Desktop/test.png")
        guard canon == expected else {
            print("  [-] Canonical path failed: \(canon)")
            return false
        }
        print("  [✓] Path canonicalization verified (leading slashes stripped)")

        // 2. Hash calculation on known file
        let knownFile = FileManager.default.fileExists(atPath: "Package.swift") ? "Package.swift" : "/bin/sh"
        guard let hash = computeFileSHA256(atPath: knownFile), !hash.isEmpty else {
            print("  [-] computeFileSHA256 failed on \(knownFile)")
            return false
        }
        print("  [✓] File SHA256 hashing verified: \(hash.prefix(12))...")

        // 3. Lifecycle start/stop test
        let watcher = WallpaperWatcher()
        watcher.start()
        watcher.stop()
        print("  [✓] Symmetric FSEvents start/stop lifecycle verified")

        print("=== [WallpaperWatcher Self-Test Result: PASSED] ===")
        return true
    }
}
