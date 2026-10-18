import Foundation
import Cocoa

public struct WlogoutItem: Sendable, Equatable, Codable {
    public var label: String
    public var text: String
    public var keybind: Character
    public var actionCommand: String

    public init(
        label: String,
        text: String,
        keybind: Character,
        actionCommand: String
    ) {
        self.label = label
        self.text = text
        self.keybind = keybind
        self.actionCommand = actionCommand
    }

    enum CodingKeys: String, CodingKey {
        case label
        case text
        case keybind
        case action
        case actionCommand
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try container.decode(String.self, forKey: .label)
        self.text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""

        if let keyStr = try? container.decode(String.self, forKey: .keybind), let first = keyStr.first {
            self.keybind = first
        } else {
            self.keybind = " "
        }

        if let act = try? container.decode(String.self, forKey: .action) {
            self.actionCommand = act
        } else if let actCmd = try? container.decode(String.self, forKey: .actionCommand) {
            self.actionCommand = actCmd
        } else {
            self.actionCommand = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(text, forKey: .text)
        try container.encode(String(keybind), forKey: .keybind)
        try container.encode(actionCommand, forKey: .action)
    }

    public static let defaultItems: [WlogoutItem] = [
        WlogoutItem(
            label: "lock",
            text: "󰌾",
            keybind: "l",
            actionCommand: "/usr/bin/pmset displaysleepnow"
        ),
        WlogoutItem(
            label: "suspend",
            text: "󰤄",
            keybind: "u",
            actionCommand: "/usr/bin/pmset sleepnow"
        ),
        WlogoutItem(
            label: "logout",
            text: "󰍃",
            keybind: "e",
            actionCommand: "hyprmac-logout"
        ),
        WlogoutItem(
            label: "shutdown",
            text: "󰐥",
            keybind: "s",
            actionCommand: "osascript -e 'tell application \"System Events\" to shut down'"
        ),
        WlogoutItem(
            label: "reboot",
            text: "󰜉",
            keybind: "r",
            actionCommand: "osascript -e 'tell application \"System Events\" to restart'"
        ),
        WlogoutItem(
            label: "hibernate",
            text: "󰒲",
            keybind: "h",
            actionCommand: "/usr/bin/pmset sleepnow"
        )
    ]

    public var displayTitle: String {
        switch label.lowercased() {
        case "lock": return "Lock"
        case "suspend": return "Suspend"
        case "logout": return "Logout"
        case "shutdown": return "Shutdown"
        case "reboot": return "Reboot"
        case "hibernate": return "Hibernate"
        default: return label.capitalized
        }
    }

    public var keybindHint: String {
        return "[" + String(keybind).uppercased() + "]"
    }

    public var fallbackSFSymbolName: String {
        switch label.lowercased() {
        case "lock": return "lock.fill"
        case "suspend": return "moon.fill"
        case "logout": return "rectangle.portrait.and.arrow.right"
        case "shutdown": return "power"
        case "reboot": return "arrow.clockwise"
        case "hibernate": return "powersleep"
        default: return "circle.fill"
        }
    }

    public var resolvedMacActionCommand: String {
        let lowerLabel = label.lowercased()
        let cmd = actionCommand.trimmingCharacters(in: .whitespacesAndNewlines)

        if lowerLabel == "logout" || cmd.contains("hyprctl dispatch exit") || cmd.contains("switchTo(mode: .aqua)") || cmd == "hyprmac-logout" {
            return "hyprmac-logout"
        }
        if cmd.contains("hyprlock") {
            return "/usr/bin/pmset displaysleepnow"
        }
        if cmd.contains("systemctl suspend") {
            return "/usr/bin/pmset sleepnow"
        }
        if cmd.contains("systemctl hibernate") {
            return "/usr/bin/pmset sleepnow"
        }
        if cmd.contains("systemctl poweroff") {
            return "osascript -e 'tell application \"System Events\" to shut down'"
        }
        if cmd.contains("systemctl reboot") {
            return "osascript -e 'tell application \"System Events\" to restart'"
        }
        return cmd
    }
}

@MainActor
public protocol WlogoutActionDispatcherProtocol: AnyObject {
    func dispatch(item: WlogoutItem)
}

@MainActor
public final class WlogoutActionDispatcher: WlogoutActionDispatcherProtocol {
    public static let shared = WlogoutActionDispatcher()

    public typealias CommandRunner = @MainActor (String) -> Void
    public typealias LogoutHandler = @MainActor () -> Void

    private let commandRunner: CommandRunner?
    private let logoutHandler: LogoutHandler?

    public init(
        commandRunner: CommandRunner? = nil,
        logoutHandler: LogoutHandler? = nil
    ) {
        self.commandRunner = commandRunner
        self.logoutHandler = logoutHandler
    }

    public func dispatch(item: WlogoutItem) {
        let action = item.resolvedMacActionCommand
        if action == "hyprmac-logout" || item.label.lowercased() == "logout" {
            if let customLogout = logoutHandler {
                customLogout()
            } else {
                _ = SessionManager.shared.switchTo(mode: .aqua)
            }
            return
        }

        if let runner = commandRunner {
            runner(action)
            return
        }

        guard !action.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", action]
        try? process.run()
    }
}

public final class WlogoutLayoutLoader: Sendable {
    public init() {}

    public static func parse(jsonString: String) -> [WlogoutItem] {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let decoder = JSONDecoder()

        // 1. Try parsing as standard JSON array
        if trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
           let items = try? decoder.decode([WlogoutItem].self, from: data), !items.isEmpty {
            return items
        }

        // 2. Parse concatenated JSON objects (e.g. { ... }\n{ ... })
        var extractedObjects: [String] = []
        var currentObject = ""
        var depth = 0
        var inString = false
        var escapeNext = false

        for char in trimmed {
            if inString {
                currentObject.append(char)
                if escapeNext {
                    escapeNext = false
                } else if char == "\\" {
                    escapeNext = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                    currentObject.append(char)
                } else if char == "{" {
                    depth += 1
                    currentObject.append(char)
                } else if char == "}" {
                    depth -= 1
                    currentObject.append(char)
                    if depth == 0 {
                        let cleaned = currentObject.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            extractedObjects.append(cleaned)
                        }
                        currentObject = ""
                    }
                } else if depth > 0 {
                    currentObject.append(char)
                }
            }
        }

        var parsedItems: [WlogoutItem] = []
        for objStr in extractedObjects {
            guard let data = objStr.data(using: .utf8) else { continue }
            if let item = try? decoder.decode(WlogoutItem.self, from: data) {
                parsedItems.append(item)
            }
        }

        return parsedItems
    }

    public func loadItems(fromPath customPath: String? = nil) -> [WlogoutItem] {
        let fm = FileManager.default
        if let custom = customPath {
            if fm.fileExists(atPath: custom),
               let content = try? String(contentsOfFile: custom, encoding: .utf8) {
                let parsed = Self.parse(jsonString: content)
                if !parsed.isEmpty {
                    return parsed
                }
            }
            return WlogoutItem.defaultItems
        }

        let candidatePaths: [String] = [
            NSString(string: "~/.config/wlogout/layout").expandingTildeInPath,
            "/Users/saturno/Developer/REA/reference/mxmrn/config/wlogout/layout"
        ].compactMap { $0 }

        for path in candidatePaths {
            if fm.fileExists(atPath: path),
               let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let parsed = Self.parse(jsonString: content)
                if !parsed.isEmpty {
                    return parsed
                }
            }
        }

        return WlogoutItem.defaultItems
    }
}
