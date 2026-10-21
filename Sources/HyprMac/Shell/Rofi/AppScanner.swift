import Cocoa

/// Representation of an installed macOS application
public struct AppItem: @unchecked Sendable, Identifiable, Equatable, Hashable {
    public var id: URL { bundleURL }
    public let name: String
    public let bundleURL: URL
    public let bundleIdentifier: String?
    private let _icon: NSImage?

    public var icon: NSImage {
        if let i = _icon {
            return i
        }
        return AppScanner.cachedIcon(for: bundleURL.path)
    }

    public init(name: String, bundleURL: URL, bundleIdentifier: String?, icon: NSImage? = nil) {
        self.name = name
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self._icon = icon
    }

    public static func == (lhs: AppItem, rhs: AppItem) -> Bool {
        lhs.bundleURL == rhs.bundleURL
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundleURL)
    }
}

/// Scans and caches macOS applications across standard application directories
public final class AppScanner: @unchecked Sendable {
    public static let shared = AppScanner()

    nonisolated(unsafe) private static let iconCache = NSCache<NSString, NSImage>()

    public static func cachedIcon(for path: String) -> NSImage {
        if let img = iconCache.object(forKey: path as NSString) {
            return img
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 36, height: 36)
        iconCache.setObject(icon, forKey: path as NSString)
        return icon
    }

    private let lock = NSLock()
    private var cachedApps: [AppItem] = []
    private var lastScanTime: TimeInterval = 0
    private var recordedModificationDates: [String: Date] = [:]

    public init() {}

    /// Asynchronously warms the application cache and icons on a background queue
    public func preloadAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.scan(forceRefresh: false)
        }
    }

    /// Scans applications from standard system and user directories.
    /// Returns cached results if available and within cache TTL (60s), unless forceRefresh is true.
    public func scan(forceRefresh: Bool = false) -> [AppItem] {
        lock.lock()
        defer { lock.unlock() }

        let directoriesToScan: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications")
        ]

        let fileManager = FileManager.default
        let now = ProcessInfo.processInfo.systemUptime
        if !forceRefresh && !cachedApps.isEmpty {
            if now - lastScanTime < 60.0 {
                return cachedApps
            }
            var directoriesUnchanged = true
            for root in directoriesToScan {
                guard fileManager.fileExists(atPath: root.path) else { continue }
                let currentMod = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let recorded = recordedModificationDates[root.path] {
                    if currentMod != recorded {
                        directoriesUnchanged = false
                        break
                    }
                } else {
                    directoriesUnchanged = false
                    break
                }
            }
            if directoriesUnchanged {
                lastScanTime = now
                return cachedApps
            }
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        var discovered: [URL] = []
        var seenPaths = Set<String>()

        for root in directoriesToScan {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            scanDirectory(root, fileManager: fileManager, keys: keys, discovered: &discovered, seenPaths: &seenPaths, depth: 0)
        }

        var appItems: [AppItem] = []
        var seenIdentifiers = Set<String>()
        var seenNames = Set<String>()

        for url in discovered {
            let bundle = Bundle(url: url)
            let bundleId = bundle?.bundleIdentifier

            if let bId = bundleId {
                if seenIdentifiers.contains(bId) {
                    continue
                }
                seenIdentifiers.insert(bId)
            }

            var displayName: String
            if let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !bundleName.isEmpty {
                displayName = bundleName
            } else if let bundleName = bundle?.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String, !bundleName.isEmpty {
                displayName = bundleName
            } else {
                let fmName = fileManager.displayName(atPath: url.path)
                displayName = fmName.hasSuffix(".app") ? String(fmName.dropLast(4)) : fmName
            }

            if displayName.hasSuffix(".app") {
                displayName = String(displayName.dropLast(4))
            }

            displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty else { continue }

            let nameKey = displayName.lowercased()
            if seenNames.contains(nameKey) {
                continue
            }
            seenNames.insert(nameKey)

            let item = AppItem(
                name: displayName,
                bundleURL: url,
                bundleIdentifier: bundleId,
                icon: nil
            )
            appItems.append(item)
        }

        appItems.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var newDates: [String: Date] = [:]
        for root in directoriesToScan {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            if let modDate = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                newDates[root.path] = modDate
            }
        }
        recordedModificationDates = newDates
        cachedApps = appItems
        lastScanTime = now
        return appItems
    }

    private func scanDirectory(
        _ dir: URL,
        fileManager: FileManager,
        keys: [URLResourceKey],
        discovered: inout [URL],
        seenPaths: inout Set<String>,
        depth: Int
    ) {
        guard depth <= 3 else { return }
        guard let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return
        }

        for url in contents {
            let path = url.path
            if seenPaths.contains(path) { continue }
            seenPaths.insert(path)

            if url.pathExtension == "app" {
                discovered.append(url)
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                scanDirectory(url, fileManager: fileManager, keys: keys, discovered: &discovered, seenPaths: &seenPaths, depth: depth + 1)
            }
        }
    }

    public func clearCache() {
        lock.lock()
        cachedApps.removeAll()
        recordedModificationDates.removeAll()
        lastScanTime = 0
        lock.unlock()
    }
}
