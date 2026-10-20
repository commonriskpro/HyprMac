import Cocoa

/// Unified search result item model for Rofi launcher
public enum RofiSearchResult: @unchecked Sendable, Identifiable, Equatable {
    case app(AppItem)
    case calculator(result: String, expression: String)
    case systemCommand(id: String, title: String, subtitle: String, icon: String, action: @Sendable () -> Void)
    case runBinary(name: String, path: String)
    case wallpaper(path: String, name: String, category: String)
    case window(windowID: CGWindowID, title: String, appName: String, workspace: Int, icon: NSImage)
    case clipboard(text: String, date: Date)

    public var id: String {
        switch self {
        case .app(let item):
            return "app:" + item.bundleURL.path
        case .calculator(let result, let expr):
            return "calc:\(expr)=\(result)"
        case .systemCommand(let id, _, _, _, _):
            return "sys:\(id)"
        case .runBinary(let name, let path):
            return "bin:\(path):\(name)"
        case .wallpaper(let path, _, _):
            return "wall:" + path
        case .window(let wid, _, _, _, _):
            return "win:\(wid)"
        case .clipboard(let text, let date):
            return "clip:\(date.timeIntervalSince1970):\(text.prefix(32))"
        }
    }

    public var title: String {
        switch self {
        case .app(let item):
            return item.name
        case .calculator(let result, _):
            return "= \(result)"
        case .systemCommand(_, let title, _, _, _):
            return title
        case .runBinary(let name, _):
            return name
        case .wallpaper(_, let name, _):
            return name
        case .window(_, let title, let appName, _, _):
            return title.isEmpty ? appName : title
        case .clipboard(let text, _):
            let s = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? "[Empty Clipboard]" : s
        }
    }

    public var subtitle: String? {
        switch self {
        case .app:
            return nil
        case .calculator(_, let expr):
            return expr
        case .systemCommand(_, _, let subtitle, _, _):
            return subtitle
        case .runBinary(_, let path):
            return path
        case .wallpaper(let path, _, let category):
            return category.isEmpty ? path : "\(category) • \(path)"
        case .window(_, _, let appName, let ws, _):
            return "Workspace \(ws) • \(appName)"
        case .clipboard(let text, let date):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let timeAgo = formatter.localizedString(for: date, relativeTo: Date())
            return "Clipboard • \(text.count) chars • \(timeAgo)"
        }
    }

    public var icon: NSImage {
        switch self {
        case .app(let item):
            return item.icon
        case .calculator:
            if let img = NSImage(systemSymbolName: "equal.circle.fill", accessibilityDescription: "Calculator") {
                let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
                return img.withSymbolConfiguration(config) ?? img
            }
            return NSImage()
        case .systemCommand(_, _, _, let iconName, _):
            if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: title) {
                let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
                return img.withSymbolConfiguration(config) ?? img
            }
            return NSImage()
        case .runBinary(let name, _):
            let lower = name.lowercased()
            let sfSymbol: String
            switch lower {
            case "git", "gh":
                sfSymbol = "arrow.triangle.branch"
            case "nvim", "vim", "vi", "nano", "emacs", "hx", "helix":
                sfSymbol = "character.cursor.ibeam"
            case "python", "python3", "ipython", "py":
                sfSymbol = "curlybraces"
            case "cargo", "rustc", "rustup":
                sfSymbol = "shippingbox.fill"
            case "docker", "podman", "docker-compose":
                sfSymbol = "shippingbox.circle.fill"
            case "node", "npm", "yarn", "pnpm", "bun", "deno":
                sfSymbol = "cube.transparent.fill"
            case "brew":
                sfSymbol = "mug.fill"
            case "ssh", "curl", "wget", "ping", "netstat":
                sfSymbol = "network"
            case "htop", "btop", "top", "glances":
                sfSymbol = "chart.bar.xaxis"
            case "tmux", "zellij", "screen":
                sfSymbol = "square.split.2x2.fill"
            case "zsh", "bash", "fish", "sh":
                sfSymbol = "chevron.left.forwardslash.chevron.right"
            case "make", "cmake", "ninja", "clang", "gcc", "swift", "swiftc":
                sfSymbol = "hammer.fill"
            default:
                sfSymbol = "terminal.fill"
            }
            if let img = NSImage(systemSymbolName: sfSymbol, accessibilityDescription: name) {
                let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
                return img.withSymbolConfiguration(config) ?? img
            }
            return NSImage()
        case .wallpaper:
            if let img = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: "Wallpaper") {
                let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
                return img.withSymbolConfiguration(config) ?? img
            }
            return NSImage()
        case .window(_, _, _, _, let winIcon):
            return winIcon
        case .clipboard:
            if let img = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: "Clipboard") {
                let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
                return img.withSymbolConfiguration(config) ?? img
            }
            return NSImage()
        }
    }

    public var isSystemOrUtility: Bool {
        switch self {
        case .app, .window:
            return false
        case .calculator, .systemCommand, .runBinary, .wallpaper, .clipboard:
            return true
        }
    }

    public static func == (lhs: RofiSearchResult, rhs: RofiSearchResult) -> Bool {
        lhs.id == rhs.id
    }
}

/// Robust mathematical expression parser and evaluator using NSExpression
public enum MathEvaluator {
    public static func evaluate(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Must contain at least one math operator (+, -, *, /, ^, %, x)
        let operatorSet = CharacterSet(charactersIn: "+-*/^%xX")
        guard trimmed.rangeOfCharacter(from: operatorSet) != nil else { return nil }

        // Must contain at least one digit
        guard trimmed.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }

        // Character whitelist
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/^%xX() ")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

        // Preprocess x, X, ^, %
        var prepared = ""
        var prevChar: Character? = nil
        for ch in trimmed {
            if ch == "x" || ch == "X" {
                prepared.append("*")
            } else if ch == "^" {
                prepared.append("**")
            } else if ch == "%" {
                if let p = prevChar, p.isNumber || p == ")" {
                    prepared.append(" * 0.01")
                } else {
                    return nil
                }
            } else {
                prepared.append(ch)
            }
            prevChar = ch
        }

        // Tokenize into numbers, operators, parens
        var tokens: [String] = []
        var i = prepared.startIndex
        while i < prepared.endIndex {
            let c = prepared[i]
            if c.isWhitespace {
                i = prepared.index(after: i)
                continue
            }
            if c.isNumber || c == "." {
                var num = ""
                var dotCount = 0
                while i < prepared.endIndex && (prepared[i].isNumber || prepared[i] == ".") {
                    if prepared[i] == "." {
                        dotCount += 1
                        if dotCount > 1 { return nil }
                    }
                    num.append(prepared[i])
                    i = prepared.index(after: i)
                }
                if !num.contains(".") {
                    num.append(".0")
                }
                tokens.append(num)
            } else if c == "*" && prepared.index(after: i) < prepared.endIndex && prepared[prepared.index(after: i)] == "*" {
                tokens.append("**")
                i = prepared.index(i, offsetBy: 2)
            } else if "+-*/()".contains(c) {
                tokens.append(String(c))
                i = prepared.index(after: i)
            } else {
                return nil
            }
        }

        guard !tokens.isEmpty else { return nil }

        // Grammar verification: recursive descent
        var idx = 0
        func parseExpr() -> Bool {
            if idx >= tokens.count { return false }
            if tokens[idx] == "+" || tokens[idx] == "-" {
                idx += 1
            }
            guard parseFactor() else { return false }
            while idx < tokens.count && ["+", "-", "*", "/", "**"].contains(tokens[idx]) {
                idx += 1
                if idx < tokens.count && (tokens[idx] == "+" || tokens[idx] == "-") {
                    idx += 1
                }
                guard parseFactor() else { return false }
            }
            return true
        }

        func parseFactor() -> Bool {
            if idx >= tokens.count { return false }
            let t = tokens[idx]
            if t == "(" {
                idx += 1
                guard parseExpr() else { return false }
                guard idx < tokens.count && tokens[idx] == ")" else { return false }
                idx += 1
                return true
            } else if let _ = Double(t) {
                idx += 1
                return true
            }
            return false
        }

        guard parseExpr() && idx == tokens.count else { return nil }

        let formula = tokens.joined(separator: " ")
        let exp = NSExpression(format: formula)
        guard let numVal = exp.expressionValue(with: nil, context: nil) as? NSNumber else {
            return nil
        }

        let val = numVal.doubleValue
        if val.isNaN || val.isInfinite {
            return nil
        }

        if val.rounded() == val && abs(val) < 1e15 {
            return String(Int64(val))
        } else {
            let formatted = String(format: "%.6f", val)
            var trimmedResult = formatted
            while trimmedResult.hasSuffix("0") && trimmedResult.contains(".") {
                trimmedResult.removeLast()
            }
            if trimmedResult.hasSuffix(".") {
                trimmedResult.removeLast()
            }
            return trimmedResult
        }
    }
}

/// Built-in macOS system command definition
public struct SystemCommandDef: @unchecked Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let icon: String
    public let keywords: [String]
    public let action: @Sendable () -> Void

    public init(id: String, title: String, subtitle: String, icon: String, keywords: [String], action: @escaping @Sendable () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.keywords = keywords
        self.action = action
    }
}

/// Built-in macOS system commands provider
public enum SystemCommandProvider {
    public static let commands: [SystemCommandDef] = [
        SystemCommandDef(
            id: "lock_screen",
            title: "Lock Screen",
            subtitle: "Lock macOS screen immediately",
            icon: "lock.fill",
            keywords: ["lock", "bloquear", "pantalla", "screen"],
            action: {
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["displaysleepnow"])
            }
        ),
        SystemCommandDef(
            id: "sleep",
            title: "Sleep / Suspend",
            subtitle: "Put computer to sleep",
            icon: "moon.zzz.fill",
            keywords: ["sleep", "suspender", "dormir"],
            action: {
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["sleepnow"])
            }
        ),
        SystemCommandDef(
            id: "restart",
            title: "Restart System",
            subtitle: "Reboot computer",
            icon: "arrow.clockwise.circle.fill",
            keywords: ["restart", "reboot", "reiniciar"],
            action: {
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", "tell application \"System Events\" to restart"])
            }
        ),
        SystemCommandDef(
            id: "shutdown",
            title: "Shut Down System",
            subtitle: "Power off computer",
            icon: "power",
            keywords: ["shutdown", "poweroff", "apagar"],
            action: {
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", "tell application \"System Events\" to shut down"])
            }
        ),
        SystemCommandDef(
            id: "empty_trash",
            title: "Empty Trash",
            subtitle: "Permanently erase deleted files in Trash",
            icon: "trash.fill",
            keywords: ["trash", "papelera", "vaciar"],
            action: {
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", "tell application \"Finder\" to empty trash"])
            }
        ),
        SystemCommandDef(
            id: "toggle_dark_mode",
            title: "Toggle Dark Mode",
            subtitle: "Switch between Light and Dark appearance",
            icon: "circle.lefthalf.filled",
            keywords: ["dark mode", "tema oscuro", "apariencia"],
            action: {
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"])
            }
        ),
        SystemCommandDef(
            id: "exit_hyprmac",
            title: "Exit HyprMac (Aqua Mode)",
            subtitle: "Switch to native macOS Aqua mode",
            icon: "rectangle.portrait.and.arrow.right",
            keywords: ["exit", "logout", "aqua", "hyprmac"],
            action: {
                _ = SessionManager.shared.switchTo(mode: .aqua)
            }
        ),
        SystemCommandDef(
            id: "reload_config",
            title: "Reload HyprMac Config",
            subtitle: "Hot-reload Hyprland configuration, bar styles, and keybindings",
            icon: "arrow.triangle.2.circlepath",
            keywords: ["reload", "recargar", "config", "hypr", "rice"],
            action: {
                KeybindManager.shared.reloadConfig()
            }
        ),
        SystemCommandDef(
            id: "toggle_floating",
            title: "Toggle Window Floating",
            subtitle: "Switch focused window between tiled and floating",
            icon: "macwindow.on.rectangle",
            keywords: ["float", "flotar", "flotante", "floating", "tile"],
            action: {
                KeybindManager.shared.togglefloating()
            }
        ),
        SystemCommandDef(
            id: "toggle_split",
            title: "Toggle Dwindle Split",
            subtitle: "Toggle split orientation (horizontal / vertical)",
            icon: "square.split.2x1",
            keywords: ["split", "togglesplit", "division"],
            action: {
                KeybindManager.shared.togglesplit()
            }
        ),
        SystemCommandDef(
            id: "clear_clipboard",
            title: "Clear Clipboard History",
            subtitle: "Empty stored clipboard items and system pasteboard",
            icon: "trash.circle.fill",
            keywords: ["clear", "clipboard", "portapapeles", "limpiar", "borrar"],
            action: {
                ClipboardTracker.shared.clearHistory()
                NSPasteboard.general.clearContents()
            }
        )
    ]

    public static func match(query: String) -> [RofiSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        var results: [(cmd: SystemCommandDef, score: Int)] = []
        for cmd in commands {
            var bestScore: Int? = nil
            if let titleScore = FuzzyMatcher.score(query: q, target: cmd.title) {
                bestScore = titleScore
            }
            for kw in cmd.keywords {
                let kwLower = kw.lowercased()
                if kwLower == q {
                    bestScore = max(bestScore ?? 0, 95_000)
                } else if kwLower.hasPrefix(q) {
                    bestScore = max(bestScore ?? 0, 48_000)
                } else if let s = FuzzyMatcher.score(query: q, target: kwLower) {
                    bestScore = max(bestScore ?? 0, s)
                }
            }
            if let score = bestScore {
                results.append((cmd, score))
            }
        }

        results.sort { $0.score > $1.score }
        return results.map {
            .systemCommand(
                id: $0.cmd.id,
                title: $0.cmd.title,
                subtitle: $0.cmd.subtitle,
                icon: $0.cmd.icon,
                action: $0.cmd.action
            )
        }
    }
}

/// Item representation of an executable found in $PATH
public struct BinaryItem: @unchecked Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Scans and caches executable binaries in $PATH
public final class PathBinaryScanner: @unchecked Sendable {
    public static let shared = PathBinaryScanner()

    private let lock = NSLock()
    private var cachedBinaries: [BinaryItem] = []
    private var lastScanTime: TimeInterval = 0
    private var dirMtimeCache: [String: (mtime: time_t, items: [BinaryItem])] = [:]

    public init() {}

    public func scan(forceRefresh: Bool = false) -> [BinaryItem] {
        lock.lock()
        defer { lock.unlock() }

        let now = ProcessInfo.processInfo.systemUptime
        if !forceRefresh && !cachedBinaries.isEmpty && (now - lastScanTime < 60.0) {
            return cachedBinaries
        }

        let directoriesToScan: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            NSString(string: "~/.cargo/bin").expandingTildeInPath,
            NSString(string: "~/.local/bin").expandingTildeInPath
        ]

        let fm = FileManager.default
        var items: [BinaryItem] = []
        var seenNames = Set<String>()

        for dir in directoriesToScan {
            var statBuf = stat()
            let statRes = stat(dir, &statBuf)
            if !forceRefresh && statRes == 0 {
                let mtime = statBuf.st_mtimespec.tv_sec
                if let cached = dirMtimeCache[dir], cached.mtime == mtime {
                    for item in cached.items {
                        if !seenNames.contains(item.name) {
                            seenNames.insert(item.name)
                            items.append(item)
                        }
                    }
                    continue
                }
            }

            guard fm.fileExists(atPath: dir),
                  let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }

            var dirItems: [BinaryItem] = []
            for filename in contents {
                if filename.hasPrefix(".") { continue }

                let fullPath = (dir as NSString).appendingPathComponent(filename)
                if access(fullPath, X_OK) == 0 {
                    let item = BinaryItem(name: filename, path: fullPath)
                    dirItems.append(item)
                    if !seenNames.contains(filename) {
                        seenNames.insert(filename)
                        items.append(item)
                    }
                }
            }

            if statRes == 0 {
                dirMtimeCache[dir] = (mtime: statBuf.st_mtimespec.tv_sec, items: dirItems)
            }
        }

        items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedBinaries = items
        lastScanTime = now
        return items
    }

    public func clearCache() {
        lock.lock()
        cachedBinaries.removeAll()
        dirMtimeCache.removeAll()
        lastScanTime = 0
        lock.unlock()
    }
}

/// Item representation of a discovered desktop wallpaper
public struct WallpaperItem: @unchecked Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let name: String
    public let category: String
    public let path: String

    public init(name: String, category: String, path: String) {
        self.name = name
        self.category = category
        self.path = path
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
            (home as NSString).appendingPathComponent("Downloads/mxmrn-dotfiles-wallpapers"),
            (home as NSString).appendingPathComponent(".config/hypr/wallpapers"),
            (home as NSString).appendingPathComponent("Developer/REA/assets"),
            (home as NSString).appendingPathComponent("Developer/REA/assets/rices"),
            (home as NSString).appendingPathComponent("Developer/REA/reference/mxmrn/wallpapers"),
            (home as NSString).appendingPathComponent("Developer/REA/reference/noro18/wallpapers"),
            (home as NSString).appendingPathComponent("Pictures")
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

/// Provides searchable wallpaper items for Rofi
public enum WallpaperProvider {
    public static func match(query: String) -> [RofiSearchResult] {
        let wallpapers = WallpaperScanner.shared.scan()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            return wallpapers.prefix(50).map {
                .wallpaper(path: $0.path, name: $0.name, category: $0.category)
            }
        }

        var scoredItems: [(item: WallpaperItem, score: Int)] = []
        for wall in wallpapers {
            var bestScore: Int? = nil
            if let nameScore = FuzzyMatcher.score(query: q, target: wall.name) {
                bestScore = nameScore
            }
            if let catScore = FuzzyMatcher.score(query: q, target: wall.category) {
                bestScore = max(bestScore ?? 0, catScore - 5_000)
            }
            if let s = bestScore {
                scoredItems.append((wall, s))
            }
        }
        scoredItems.sort { $0.score > $1.score }
        return scoredItems.map {
            .wallpaper(path: $0.item.path, name: $0.item.name, category: $0.item.category)
        }
    }
}

/// Provides open application windows across workspaces for Rofi
@MainActor
public enum WindowProvider {
    private static var cachedWindows: [RofiSearchResult] = []
    private static var lastFetchTime: TimeInterval = 0

    public static func match(query: String) -> [RofiSearchResult] {
        let now = ProcessInfo.processInfo.systemUptime
        let rawItems: [RofiSearchResult]

        if !cachedWindows.isEmpty && (now - lastFetchTime < 2.0) {
            rawItems = cachedWindows
        } else {
            let windows = WindowDetector.shared.getEligibleWindows()
            var items: [(wid: CGWindowID, title: String, appName: String, workspace: Int, icon: NSImage)] = []

            for win in windows {
                let wid = win.windowID
                let title = win.title
                let appName = win.appName
                let ws = WorkspaceManager.shared.workspace(for: wid) ?? WorkspaceManager.shared.activeWorkspace
                let icon: NSImage
                if let runningApp = NSRunningApplication(processIdentifier: win.processID),
                   let appIcon = runningApp.icon {
                    icon = appIcon
                } else {
                    icon = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Window") ?? NSImage()
                }
                items.append((wid, title, appName, ws, icon))
            }

            rawItems = items.map {
                .window(windowID: $0.wid, title: $0.title, appName: $0.appName, workspace: $0.workspace, icon: $0.icon)
            }
            cachedWindows = rawItems
            lastFetchTime = now
        }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            return rawItems
        }

        var scoredItems: [(item: RofiSearchResult, score: Int)] = []
        for winItem in rawItems {
            if case .window(_, let title, let appName, _, _) = winItem {
                var bestScore: Int? = nil
                if let s = FuzzyMatcher.score(query: q, target: appName) {
                    bestScore = s + 10_000
                }
                if !title.isEmpty, let s = FuzzyMatcher.score(query: q, target: title) {
                    bestScore = max(bestScore ?? 0, s)
                }
                if let score = bestScore {
                    scoredItems.append((winItem, score))
                }
            }
        }
        scoredItems.sort { $0.score > $1.score }
        return scoredItems.map { $0.item }
    }

    public static func clearCache() {
        cachedWindows.removeAll()
        lastFetchTime = 0
    }
}

/// Tracks recent text copied to the macOS clipboard with persistent disk caching
public final class ClipboardTracker: @unchecked Sendable {
    public static let shared = ClipboardTracker()

    private let lock = NSLock()
    private var history: [(text: String, date: Date)] = []
    private var lastChangeCount: Int = -1
    private let cacheFile: String

    public init(cachePath: String? = nil) {
        let path = cachePath ?? NSString(string: "~/.cache/hyprmac/clipboard.json").expandingTildeInPath
        self.cacheFile = path
        loadFromDisk()
        checkPasteboard()
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        var loaded: [(text: String, date: Date)] = []
        for item in json {
            if let text = item["text"] as? String, let ts = item["timestamp"] as? TimeInterval {
                loaded.append((text: text, date: Date(timeIntervalSince1970: ts)))
            }
        }
        self.history = loaded
    }

    private func saveToDisk() {
        let items = history.map { ["text": $0.text, "timestamp": $0.date.timeIntervalSince1970] }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: []) else { return }
        let dir = (cacheFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: cacheFile), options: .atomic)
    }

    public func checkPasteboard() {
        lock.lock()
        defer { lock.unlock() }

        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        guard let str = pb.string(forType: .string), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        if let first = history.first, first.text == str {
            return
        }

        history.removeAll { $0.text == str }
        history.insert((text: str, date: Date()), at: 0)

        if history.count > 50 {
            history.removeLast()
        }
        saveToDisk()
    }

    public func getHistory() -> [(text: String, date: Date)] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    public func clearHistory() {
        lock.lock()
        history.removeAll()
        lastChangeCount = -1
        try? FileManager.default.removeItem(atPath: cacheFile)
        lock.unlock()
    }

    public func addEntry(text: String) {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.removeAll { $0.text == trimmed }
        history.insert((text: trimmed, date: Date()), at: 0)
        if history.count > 50 {
            history.removeLast()
        }
        saveToDisk()
    }
}

/// Provides searchable clipboard history items for Rofi
public enum ClipboardProvider {
    public static func match(query: String) -> [RofiSearchResult] {
        ClipboardTracker.shared.checkPasteboard()
        let history = ClipboardTracker.shared.getHistory()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if q.isEmpty {
            return history.map { .clipboard(text: $0.text, date: $0.date) }
        }

        var results: [(item: (text: String, date: Date), score: Int)] = []
        for entry in history {
            if let s = FuzzyMatcher.score(query: q, target: entry.text) {
                results.append((entry, s))
            } else if entry.text.localizedCaseInsensitiveContains(q) {
                results.append((entry, 25_000))
            }
        }
        results.sort { $0.score > $1.score }
        return results.map { .clipboard(text: $0.item.text, date: $0.item.date) }
    }
}

/// Asynchronously loads and caches wallpaper preview images for 60fps UI navigation
@MainActor
public final class WallpaperPreviewLoader {
    public static let shared = WallpaperPreviewLoader()

    private let cache = NSCache<NSString, NSImage>()
    private var currentTaskID: UUID = UUID()

    public init() {
        cache.countLimit = 100
    }

    public func load(path: String, completion: @escaping @MainActor (NSImage?) -> Void) {
        if let cached = cache.object(forKey: path as NSString) {
            completion(cached)
            return
        }

        let taskID = UUID()
        currentTaskID = taskID

        Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: path) else {
                await MainActor.run {
                    guard Self.shared.currentTaskID == taskID else { return }
                    completion(nil)
                }
                return
            }

            let fileURL = URL(fileURLWithPath: path)
            var loadedImage: NSImage? = nil

            if let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1000
                ]
                if let cgThumb = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                    loadedImage = NSImage(cgImage: cgThumb, size: NSSize(width: 410, height: 416))
                }
            }

            if loadedImage == nil {
                loadedImage = NSImage(contentsOfFile: path)
            }

            let finalImage = loadedImage
            await MainActor.run {
                if let img = finalImage {
                    Self.shared.cache.setObject(img, forKey: path as NSString)
                }
                guard Self.shared.currentTaskID == taskID else { return }
                completion(finalImage)
            }
        }
    }

    public func clearCache() {
        cache.removeAllObjects()
    }
}
