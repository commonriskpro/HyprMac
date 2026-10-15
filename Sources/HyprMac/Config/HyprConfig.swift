import Foundation
import CoreGraphics

/// Represents a keybinding directive from `hyprland.conf`.
/// Example: `bind = $mainMod, Q, exec, $terminal`
public struct HyprBinding: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// Optional binding flags from directives like `bindm`, `binde`, `bindl`, `bindr`.
    public var flags: String
    /// Modifier string (e.g. "SUPER", "SUPER SHIFT", "CTRL ALT", or "").
    public var mod: String
    /// Trigger key (e.g. "Q", "1", "Return", "Space", "mouse:272").
    public var key: String
    /// Dispatcher command (e.g. "exec", "killactive", "workspace", "movetoworkspace").
    public var dispatcher: String
    /// Arguments passed to the dispatcher (e.g. "kitty", "1", "wpctl set-volume ...").
    public var args: String

    public init(
        flags: String = "",
        mod: String,
        key: String,
        dispatcher: String,
        args: String = ""
    ) {
        self.flags = flags.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mod = mod.trimmingCharacters(in: .whitespacesAndNewlines)
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dispatcher = dispatcher.trimmingCharacters(in: .whitespacesAndNewlines)
        self.args = args.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(
        mod: String,
        key: String,
        dispatcher: String,
        args: String = ""
    ) {
        self.init(flags: "", mod: mod, key: key, dispatcher: dispatcher, args: args)
    }

    public var description: String {
        let prefix = flags.isEmpty ? "bind" : "bind\(flags)"
        if args.isEmpty {
            return "\(prefix) = \(mod), \(key), \(dispatcher)"
        } else {
            return "\(prefix) = \(mod), \(key), \(dispatcher), \(args)"
        }
    }

    /// Normalized individual modifiers (e.g. ["SUPER", "SHIFT"]).
    public var modifierTokens: [String] {
        let separators = CharacterSet(charactersIn: " _+")
        return mod.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
    }

    public var hasSuper: Bool {
        modifierTokens.contains("SUPER") || modifierTokens.contains("MOD4") ||
        modifierTokens.contains("CMD") || modifierTokens.contains("COMMAND")
    }

    public var hasShift: Bool {
        modifierTokens.contains("SHIFT")
    }

    public var hasControl: Bool {
        modifierTokens.contains("CTRL") || modifierTokens.contains("CONTROL")
    }

    public var hasAlt: Bool {
        modifierTokens.contains("ALT") || modifierTokens.contains("MOD1") ||
        modifierTokens.contains("OPTION")
    }
}

/// Data model representing Hyprland configuration variables, styles, and bindings.
public struct HyprConfig: Equatable, Sendable, CustomStringConvertible {
    /// Inner gap between adjacent windows in points (default: 5.0).
    public var gapsIn: CGFloat = 5.0
    /// Outer gap between windows and monitor screen edges in points (default: 10.0).
    public var gapsOut: CGFloat = 10.0
    /// Window border thickness in points (default: 2).
    public var borderSize: Int = 2
    /// Gradient color palette for active window borders as RGBA UInt32 values (default: Hyprland Cyan to Neon Green).
    public var activeBorderGradient: [UInt32] = [0x33CCFFEE, 0x00FF99EE]
    /// Border color for inactive windows as an RGBA UInt32 value (default: semi-transparent grey).
    public var inactiveBorderColor: UInt32 = 0x595959AA
    /// Corner rounding radius for windows and borders in points (default: 10.0).
    public var rounding: CGFloat = 10.0
    /// Border presentation mode for the active window shell (default: .glassHalo).
    public var borderMode: BorderMode = .glassHalo
    /// Padding distance in points for the floating glass halo casing (default: 12.0).
    public var haloPadding: CGFloat = 12.0
    /// Window alpha/opacity for active windows when under the compositor (default: 0.96).
    public var windowOpacity: Double = 0.96
    /// Whether to dynamically strip window titlebars/decorations via SkyLight (default: true).
    public var stripDecorations: Bool = true
    /// Active layout engine name (default: "dwindle").
    public var layout: String { rawSettings["general:layout"] ?? rawSettings["general.layout"] ?? "dwindle" }
    /// Ordered list of keybindings parsed from `bind` directives.
    public var bindings: [HyprBinding] = []
    /// Map of user-defined and resolved configuration variables (e.g. `$mainMod: "SUPER"`).
    public var variables: [String: String] = [:]

    /// Included configuration file paths from `source` directives.
    public var sourceFiles: [String] = []
    /// Flattened key-value configuration dictionary (e.g. `"general.layout": "dwindle"`).
    public var rawSettings: [String: String] = [:]
    /// Section-grouped settings dictionary (e.g. `sections["decoration.blur"]?["enabled"]`).
    public var sections: [String: [String: String]] = [:]

    public init(
        gapsIn: CGFloat = 5.0,
        gapsOut: CGFloat = 10.0,
        borderSize: Int = 2,
        activeBorderGradient: [UInt32] = [0x33CCFFEE, 0x00FF99EE],
        inactiveBorderColor: UInt32 = 0x595959AA,
        rounding: CGFloat = 10.0,
        borderMode: BorderMode = .glassHalo,
        haloPadding: CGFloat = 12.0,
        windowOpacity: Double = 0.96,
        stripDecorations: Bool = true,
        bindings: [HyprBinding] = [],
        variables: [String: String] = [:],
        sourceFiles: [String] = [],
        rawSettings: [String: String] = [:],
        sections: [String: [String: String]] = [:]
    ) {
        self.gapsIn = gapsIn
        self.gapsOut = gapsOut
        self.borderSize = borderSize
        self.activeBorderGradient = activeBorderGradient
        self.inactiveBorderColor = inactiveBorderColor
        self.rounding = rounding
        self.borderMode = borderMode
        self.haloPadding = haloPadding
        self.windowOpacity = windowOpacity
        self.stripDecorations = stripDecorations
        self.bindings = bindings
        self.variables = variables
        self.sourceFiles = sourceFiles
        self.rawSettings = rawSettings
        self.sections = sections
    }

    /// Default HyprMac configuration matching standard Hyprland defaults.
    public static let `default` = HyprConfig()

    /// Retrieve a variable value, accepting names with or without the leading `$` prefix.
    public func variable(_ name: String) -> String? {
        let withDollar = name.hasPrefix("$") ? name : "$" + name
        let withoutDollar = name.hasPrefix("$") ? String(name.dropFirst()) : name
        return variables[withDollar] ?? variables[withoutDollar]
    }

    /// Retrieve a setting from raw settings, optionally qualifying by section name.
    public func setting(for key: String, section: String? = nil) -> String? {
        if let section = section {
            return rawSettings["\(section).\(key)"] ?? rawSettings["\(section):\(key)"] ?? sections[section]?[key]
        }
        return rawSettings[key]
    }

    public var description: String {
        let gradientStr = activeBorderGradient.map { String(format: "0x%08X", $0) }.joined(separator: ", ")
        let inactiveStr = String(format: "0x%08X", inactiveBorderColor)
        return """
        HyprConfig(
            gapsIn: \(gapsIn),
            gapsOut: \(gapsOut),
            borderSize: \(borderSize),
            activeBorderGradient: [\(gradientStr)],
            inactiveBorderColor: \(inactiveStr),
            rounding: \(rounding),
            borderMode: \(borderMode.rawValue),
            haloPadding: \(haloPadding),
            windowOpacity: \(windowOpacity),
            stripDecorations: \(stripDecorations),
            bindingsCount: \(bindings.count),
            variablesCount: \(variables.count)
        )
        """
    }
}
