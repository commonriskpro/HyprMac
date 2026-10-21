import Cocoa
import Foundation

/// Item representation of a discovered desktop wallpaper
public struct WallpaperItem: @unchecked Sendable, Identifiable, Equatable, Hashable {
    public var id: String { path }
    public let name: String
    public let category: String
    public let path: String

    public init(name: String, category: String, path: String) {
        self.name = name
        self.category = category
        self.path = path
    }

    public static func == (lhs: WallpaperItem, rhs: WallpaperItem) -> Bool {
        lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

/// Discovers, caches, and indexes wallpapers across system and rice repositories
public final class WallpaperScanner: @unchecked Sendable {
    public static let shared = WallpaperScanner()

    private let lock = NSLock()
    private var cachedWallpapers: [WallpaperItem] = []
    private var lastScanTime: TimeInterval = 0

    public init() {}

    public func scan(forceRefresh: Bool = false) -> [WallpaperItem] {
        lock.lock()
        defer { lock.unlock() }

        let now = ProcessInfo.processInfo.systemUptime
        if !forceRefresh && !cachedWallpapers.isEmpty && (now - lastScanTime < 60.0) {
            return cachedWallpapers
        }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let directories: [String] = [
            (home as NSString).appendingPathComponent("Pictures/Wallpapers"),
            (home as NSString).appendingPathComponent("Pictures"),
            (home as NSString).appendingPathComponent(".config/hypr/wallpapers"),
            (home as NSString).appendingPathComponent("Downloads/wallpapers"),
            FileManager.default.currentDirectoryPath + "/assets/showcase"
        ]

        let allowedExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic"]
        var items: [WallpaperItem] = []
        var seenPaths = Set<String>()

        func scanDir(_ dirPath: String, rootName: String, maxDepth: Int) {
            guard maxDepth > 0, fm.fileExists(atPath: dirPath) else { return }
            if dirPath.hasSuffix(".photoslibrary") || dirPath.hasSuffix(".app") || dirPath.hasSuffix(".framework") { return }
            guard let contents = try? fm.contentsOfDirectory(atPath: dirPath) else { return }

            for file in contents {
                if file.hasPrefix(".") { continue }
                let fullPath = (dirPath as NSString).appendingPathComponent(file)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir) {
                    if isDir.boolValue {
                        let subCategory = rootName.isEmpty ? file : "\(rootName)/\(file)"
                        scanDir(fullPath, rootName: subCategory, maxDepth: maxDepth - 1)
                    } else {
                        let ext = (file as NSString).pathExtension.lowercased()
                        if allowedExtensions.contains(ext) {
                            let realPath = URL(fileURLWithPath: fullPath).resolvingSymlinksInPath().path
                            if !seenPaths.contains(realPath) {
                                seenPaths.insert(realPath)
                                let baseName = (file as NSString).deletingPathExtension
                                let displayName = formatWallpaperName(baseName)
                                items.append(WallpaperItem(name: displayName, category: rootName, path: realPath))
                            }
                        }
                    }
                }
            }
        }

        for baseDir in directories {
            let catName = (baseDir as NSString).lastPathComponent
            let depth = (catName == "Pictures") ? 1 : 4
            scanDir(baseDir, rootName: catName, maxDepth: depth)
        }

        items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedWallpapers = items
        lastScanTime = now
        return items
    }

    private func formatWallpaperName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
           .replacingOccurrences(of: "-", with: " ")
           .trimmingCharacters(in: .whitespaces)
    }

    public func clearCache() {
        lock.lock()
        cachedWallpapers.removeAll()
        lastScanTime = 0
        lock.unlock()
    }
}
