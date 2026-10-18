import Foundation
import CoreGraphics

/// Represents a cubic bezier curve definition: `bezier = name, x0, y0, x1, y1`
public struct HyprBezier: Equatable, Hashable, Sendable {
    public var name: String
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public init(name: String, x0: Double, y0: Double, x1: Double, y1: Double) {
        self.name = name
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }
}

/// Represents an animation rule: `animation = node, enabled, duration, curve, style`
public struct HyprAnimation: Equatable, Hashable, Sendable {
    public var node: String
    public var enabled: Bool
    public var duration: Double // In seconds
    public var curveName: String
    public var style: String

    public init(
        node: String,
        enabled: Bool,
        duration: Double,
        curveName: String,
        style: String = ""
    ) {
        self.node = node
        self.enabled = enabled
        self.duration = duration
        self.curveName = curveName
        self.style = style
    }
}

/// Hierarchical animation configuration tree matching Hyprland's animation node hierarchy
public struct HyprAnimationTree: Equatable, Sendable {
    public var animations: [String: HyprAnimation]
    public var beziers: [String: HyprBezier]
    public var springs: [String: SpringConfig]

    // Tree hierarchy relationships: child -> parent
    public static let parentMapping: [String: String] = [
        "windows": "global",
        "windowsIn": "windows",
        "windowsOut": "windows",
        "windowsMove": "windows",
        "layers": "global",
        "layersIn": "layers",
        "layersOut": "layers",
        "fade": "global",
        "fadeIn": "fade",
        "fadeOut": "fade",
        "fadeSwitch": "fade",
        "fadeShadow": "fade",
        "fadeDim": "fade",
        "border": "global",
        "borderangle": "global",
        "workspaces": "global",
        "workspacesIn": "workspaces",
        "workspacesOut": "workspaces",
        "specialWorkspace": "workspaces",
        "specialWorkspaceIn": "specialWorkspace",
        "specialWorkspaceOut": "specialWorkspace",
        "zoomFactor": "global",
        "fullscreen": "windows"
    ]

    public init(
        animations: [String: HyprAnimation] = [:],
        beziers: [String: HyprBezier] = [:],
        springs: [String: SpringConfig] = [:]
    ) {
        self.animations = animations
        self.beziers = beziers
        self.springs = springs
    }

    public static let `default`: HyprAnimationTree = {
        var tree = HyprAnimationTree()

        // Upstream Hyprland default beziers
        let defaultBeziers: [HyprBezier] = [
            HyprBezier(name: "default", x0: 0.0, y0: 0.75, x1: 0.15, y1: 1.0),
            HyprBezier(name: "linear", x0: 0.0, y0: 0.0, x1: 1.0, y1: 1.0),
            HyprBezier(name: "almostLinear", x0: 0.5, y0: 0.5, x1: 0.75, y1: 1.0),
            HyprBezier(name: "quick", x0: 0.15, y0: 0.0, x1: 0.1, y1: 1.0),
            HyprBezier(name: "easeOutQuint", x0: 0.23, y0: 1.0, x1: 0.32, y1: 1.0),
            HyprBezier(name: "easeInOutCubic", x0: 0.65, y0: 0.05, x1: 0.36, y1: 1.0),
            HyprBezier(name: "myBezier", x0: 0.05, y0: 0.9, x1: 0.1, y1: 1.05)
        ]
        for b in defaultBeziers {
            tree.beziers[b.name] = b
        }

        // Upstream Hyprland default springs
        tree.springs["easy"] = SpringConfig.easy
        tree.springs["default"] = SpringConfig.defaultSpring

        // Upstream Hyprland default node animations (speed in deciseconds / 10 = seconds)
        tree.animations["global"] = HyprAnimation(node: "global", enabled: true, duration: 1.0, curveName: "default")
        tree.animations["windows"] = HyprAnimation(node: "windows", enabled: true, duration: 0.479, curveName: "easy")
        tree.animations["windowsIn"] = HyprAnimation(node: "windowsIn", enabled: true, duration: 0.41, curveName: "easy", style: "popin 87%")
        tree.animations["windowsOut"] = HyprAnimation(node: "windowsOut", enabled: true, duration: 0.149, curveName: "linear", style: "popin 87%")
        tree.animations["windowsMove"] = HyprAnimation(node: "windowsMove", enabled: true, duration: 0.479, curveName: "easy")
        tree.animations["fadeIn"] = HyprAnimation(node: "fadeIn", enabled: true, duration: 0.173, curveName: "almostLinear")
        tree.animations["fadeOut"] = HyprAnimation(node: "fadeOut", enabled: true, duration: 0.146, curveName: "almostLinear")
        tree.animations["fade"] = HyprAnimation(node: "fade", enabled: true, duration: 0.303, curveName: "quick")
        tree.animations["border"] = HyprAnimation(node: "border", enabled: true, duration: 0.539, curveName: "easeOutQuint")
        tree.animations["workspaces"] = HyprAnimation(node: "workspaces", enabled: true, duration: 0.25, curveName: "easeOutQuint", style: "slide")

        return tree
    }()

    public mutating func addBezier(_ bezier: HyprBezier) {
        beziers[bezier.name] = bezier
    }

    public func getBezier(name: String) -> HyprBezier? {
        return beziers[name]
    }

    public mutating func addSpring(name: String, spring: SpringConfig) {
        springs[name] = spring
    }

    public func getSpring(name: String) -> SpringConfig? {
        return springs[name]
    }

    public mutating func setConfigForNode(
        node: String,
        enabled: Bool,
        duration: Double,
        curveName: String,
        style: String = ""
    ) {
        animations[node] = HyprAnimation(
            node: node,
            enabled: enabled,
            duration: duration,
            curveName: curveName,
            style: style
        )
    }

    /// Resolves effective animation config by traversing up the tree fallback chain if not explicitly set.
    public func getConfig(for node: String) -> HyprAnimation {
        var current: String? = node
        while let curr = current {
            if let anim = animations[curr] {
                return anim
            }
            current = Self.parentMapping[curr]
        }
        return animations["global"] ?? HyprAnimation(node: "global", enabled: true, duration: 0.7, curveName: "default")
    }
}

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
    public var borderMode: BorderMode = .neon
    /// Padding distance in points for the floating glass halo casing (default: 12.0).
    public var haloPadding: CGFloat = 12.0
    /// Window alpha/opacity for active windows when under the compositor (default: 0.96).
    public var windowOpacity: Double = 0.96
    /// Window alpha/opacity for inactive windows when under the compositor (default: 0.98).
    public var inactiveOpacity: Double = 0.98
    /// Whether to dynamically strip window titlebars/decorations via SkyLight (default: true).
    public var stripDecorations: Bool = false
    /// Master switch for window and shell animations (default: true).
    public var animationsEnabled: Bool = true
    /// Animation hierarchy and bezier curves configuration.
    public var animationTree: HyprAnimationTree = .default
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

    /// Whether window background blur is enabled (default: false).
    public var blurEnabled: Bool {
        let val = sections["decoration.blur"]?["enabled"]
            ?? sections["decoration:blur"]?["enabled"]
            ?? sections["blur"]?["enabled"]
            ?? rawSettings["decoration.blur.enabled"]
            ?? rawSettings["decoration:blur:enabled"]
            ?? rawSettings["blur.enabled"]
        guard let v = val?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return v == "true" || v == "yes" || v == "1" || v == "on"
    }

    /// Background blur radius in points (computed from size * passes or default 15).
    public var blurRadius: UInt32 {
        let sizeStr = sections["decoration.blur"]?["size"]
            ?? sections["decoration:blur"]?["size"]
            ?? sections["blur"]?["size"]
            ?? rawSettings["decoration.blur.size"]
        let passesStr = sections["decoration.blur"]?["passes"]
            ?? sections["decoration:blur"]?["passes"]
            ?? sections["blur"]?["passes"]
            ?? rawSettings["decoration.blur.passes"]
        let size = UInt32(sizeStr?.trimmingCharacters(in: .whitespaces) ?? "") ?? 5
        let passes = UInt32(passesStr?.trimmingCharacters(in: .whitespaces) ?? "") ?? 3
        return max(1, size * passes)
    }

    public init(
        gapsIn: CGFloat = 5.0,
        gapsOut: CGFloat = 10.0,
        borderSize: Int = 2,
        activeBorderGradient: [UInt32] = [0x33CCFFEE, 0x00FF99EE],
        inactiveBorderColor: UInt32 = 0x595959AA,
        rounding: CGFloat = 10.0,
        borderMode: BorderMode = .neon,
        haloPadding: CGFloat = 12.0,
        windowOpacity: Double = 0.96,
        inactiveOpacity: Double = 0.98,
        stripDecorations: Bool = false,
        animationsEnabled: Bool = true,
        animationTree: HyprAnimationTree = .default,
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
        self.inactiveOpacity = inactiveOpacity
        self.stripDecorations = stripDecorations
        self.animationsEnabled = animationsEnabled
        self.animationTree = animationTree
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
            inactiveOpacity: \(inactiveOpacity),
            stripDecorations: \(stripDecorations),
            bindingsCount: \(bindings.count),
            variablesCount: \(variables.count)
        )
        """
    }
}
