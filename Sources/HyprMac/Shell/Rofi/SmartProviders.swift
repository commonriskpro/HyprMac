import Cocoa

/// Unified search result item model for Rofi launcher
public enum RofiSearchResult: @unchecked Sendable, Identifiable, Equatable {
    case app(AppItem)
    case calculator(result: String, expression: String)
    case systemCommand(id: String, title: String, subtitle: String, icon: String, action: @Sendable () -> Void)
    case runBinary(name: String, path: String)

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
        case .runBinary:
            if let img = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Terminal") {
                let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
                return img.withSymbolConfiguration(config) ?? img
            }
            return NSImage()
        }
    }

    public var isSystemOrUtility: Bool {
        switch self {
        case .app:
            return false
        case .calculator, .systemCommand, .runBinary:
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
            guard fm.fileExists(atPath: dir),
                  let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }

            for filename in contents {
                if filename.hasPrefix(".") { continue }
                if seenNames.contains(filename) { continue }

                let fullPath = (dir as NSString).appendingPathComponent(filename)
                if fm.isExecutableFile(atPath: fullPath) {
                    seenNames.insert(filename)
                    items.append(BinaryItem(name: filename, path: fullPath))
                }
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
        lastScanTime = 0
        lock.unlock()
    }
}
