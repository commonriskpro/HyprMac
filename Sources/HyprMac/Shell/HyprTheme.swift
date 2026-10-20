import Cocoa

extension NSColor {
    public static func parseColorString(_ raw: String) -> NSColor? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased().hasPrefix("rgba(") && clean.hasSuffix(")") {
            let inner = clean.dropFirst(5).dropLast().trimmingCharacters(in: .whitespaces)
            if inner.contains(",") {
                let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 4,
                      let r = Double(parts[0]),
                      let g = Double(parts[1]),
                      let b = Double(parts[2]),
                      let a = Double(parts[3]) else { return nil }
                let alpha = a > 1.0 ? a / 255.0 : a
                return NSColor(srgbRed: CGFloat(r / 255.0), green: CGFloat(g / 255.0), blue: CGFloat(b / 255.0), alpha: CGFloat(alpha))
            } else {
                return parseColorString(inner)
            }
        } else if clean.lowercased().hasPrefix("rgb(") && clean.hasSuffix(")") {
            let inner = clean.dropFirst(4).dropLast().trimmingCharacters(in: .whitespaces)
            if inner.contains(",") {
                let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 3,
                      let r = Double(parts[0]),
                      let g = Double(parts[1]),
                      let b = Double(parts[2]) else { return nil }
                return NSColor(srgbRed: CGFloat(r / 255.0), green: CGFloat(g / 255.0), blue: CGFloat(b / 255.0), alpha: 1.0)
            } else {
                return parseColorString(inner)
            }
        } else {
            var hex = clean
            if hex.hasPrefix("#") {
                hex = String(hex.dropFirst())
            } else if hex.lowercased().hasPrefix("0x") {
                hex = String(hex.dropFirst(2))
            }
            if hex.count == 3 {
                let chars = Array(hex)
                hex = String([chars[0], chars[0], chars[1], chars[1], chars[2], chars[2]])
            }
            guard let val = UInt64(hex, radix: 16) else { return nil }
            if hex.count == 6 {
                let r = CGFloat((val >> 16) & 0xFF) / 255.0
                let g = CGFloat((val >> 8) & 0xFF) / 255.0
                let b = CGFloat(val & 0xFF) / 255.0
                return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
            } else if hex.count == 8 {
                let r = CGFloat((val >> 24) & 0xFF) / 255.0
                let g = CGFloat((val >> 16) & 0xFF) / 255.0
                let b = CGFloat((val >> 8) & 0xFF) / 255.0
                let a = CGFloat(val & 0xFF) / 255.0
                return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
            }
        }
        return nil
    }

    public convenience init(hexString: String, fallback: NSColor = .black) {
        if let parsed = NSColor.parseColorString(hexString) {
            self.init(srgbRed: parsed.redComponent, green: parsed.greenComponent, blue: parsed.blueComponent, alpha: parsed.alphaComponent)
        } else {
            self.init(srgbRed: fallback.redComponent, green: fallback.greenComponent, blue: fallback.blueComponent, alpha: fallback.alphaComponent)
        }
    }

    public var hexString: String {
        guard let srgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((srgb.redComponent * 255.0).rounded())
        let g = Int((srgb.greenComponent * 255.0).rounded())
        let b = Int((srgb.blueComponent * 255.0).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

public final class HyprTheme: @unchecked Sendable {
    public static let shared = HyprTheme()

    public static let fallbackSurfaceHex = "#191614"
    public static let fallbackPrimaryHex = "#e0a96d"
    public static let fallbackOnPrimaryHex = "#191614"
    public static let fallbackSecondaryHex = "#c5c6d0"
    public static let fallbackTertiaryHex = "#b0c7de"
    public static let fallbackErrorHex = "#ffb4ab"
    public static let fallbackOnSurfaceHex = "#e3e1e9"
    public static let fallbackOutlineHex = "#8e919a"

    public static let defaultThemePaths: [String] = [
        NSString(string: "~/.config/hyprmac/colors.json").expandingTildeInPath,
        NSString(string: "~/.cache/wal/colors-hyprmac.json").expandingTildeInPath,
        NSString(string: "~/.cache/wal/colors.json").expandingTildeInPath,
        NSString(string: "~/.cache/wal/colors-rofi-dark.rasi").expandingTildeInPath,
        NSString(string: "~/.config/waybar/colors.css").expandingTildeInPath,
        NSString(string: "~/.config/waybar/colors-waybar.css").expandingTildeInPath,
        NSString(string: "~/.cache/wal/colors-waybar.css").expandingTildeInPath,
        NSString(string: "~/.cache/colors-waybar.css").expandingTildeInPath,
        NSString(string: "~/.config/rofi/colors/colors-matugen.rasi").expandingTildeInPath,
        NSString(string: "~/.config/rofi/colors/colors-wallust.rasi").expandingTildeInPath,
        NSString(string: "~/.cache/colors-rofi.rasi").expandingTildeInPath
    ]

    public private(set) var surface: NSColor
    public private(set) var primary: NSColor
    public private(set) var onPrimary: NSColor
    public private(set) var secondary: NSColor
    public private(set) var tertiary: NSColor
    public private(set) var error: NSColor
    public private(set) var onSurface: NSColor
    public private(set) var outline: NSColor

    private var currentConfigPath: String?

    public init(configPath: String? = nil) {
        self.currentConfigPath = configPath
        self.surface = NSColor(hexString: Self.fallbackSurfaceHex)
        self.primary = NSColor(hexString: Self.fallbackPrimaryHex)
        self.onPrimary = NSColor(hexString: Self.fallbackOnPrimaryHex)
        self.secondary = NSColor(hexString: Self.fallbackSecondaryHex)
        self.tertiary = NSColor(hexString: Self.fallbackTertiaryHex)
        self.error = NSColor(hexString: Self.fallbackErrorHex)
        self.onSurface = NSColor(hexString: Self.fallbackOnSurfaceHex)
        self.outline = NSColor(hexString: Self.fallbackOutlineHex)
        reload(fromPath: configPath)
    }

    public func reload(fromPath customPath: String? = nil) {
        let path: String?
        if let custom = customPath {
            let exp = NSString(string: custom).expandingTildeInPath
            path = FileManager.default.fileExists(atPath: exp) ? exp : nil
        } else if let curr = currentConfigPath, FileManager.default.fileExists(atPath: curr) {
            path = curr
        } else {
            path = Self.defaultThemePaths.first(where: { FileManager.default.fileExists(atPath: $0) })
        }

        self.currentConfigPath = path

        guard let validPath = path,
              let content = try? String(contentsOfFile: validPath, encoding: .utf8) else {
            applyFallbacks()
            return
        }

        if validPath.hasSuffix(".json") {
            parseJSONTheme(content: content)
        } else {
            parseCSSOrRasiTheme(content: content)
        }
    }

    private func parseCSSOrRasiTheme(content: String) {
        var dict: [String: String] = [:]
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start = trimmed.range(of: "/*"), let end = trimmed.range(of: "*/") {
                trimmed.removeSubrange(start.lowerBound..<end.upperBound)
                trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if trimmed.hasPrefix("@define-color") {
                let rest = trimmed.dropFirst(13).trimmingCharacters(in: .whitespaces)
                let parts = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                if let defPart = parts.first {
                    let tokens = defPart.split(whereSeparator: { $0.isWhitespace })
                    if tokens.count >= 2 {
                        let key = String(tokens[0]).lowercased().replacingOccurrences(of: "-", with: "_")
                        let val = tokens.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
                        dict[key] = val
                    }
                }
            } else if trimmed.contains(":") && trimmed.hasSuffix(";") {
                let cleaned = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
                let parts = cleaned.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                if parts.count == 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "_")
                    let val = parts[1].trimmingCharacters(in: .whitespaces)
                    dict[key] = val
                }
            }
        }

        func extractColor(keys: [String], fallbackHex: String) -> NSColor {
            for k in keys {
                if let valStr = dict[k], let color = NSColor.parseColorString(valStr) {
                    return color
                }
            }
            return NSColor(hexString: fallbackHex)
        }

        self.primary = extractColor(keys: ["primary", "accent", "selected_normal_background", "active_background", "color10", "color4"], fallbackHex: Self.fallbackPrimaryHex)
        self.surface = extractColor(keys: ["surface", "surface_dim", "background", "background_matugen", "normal_background", "background_color", "color0"], fallbackHex: Self.fallbackSurfaceHex)
        self.onPrimary = extractColor(keys: ["on_primary", "onprimary", "selected_normal_foreground", "background", "color0"], fallbackHex: Self.fallbackOnPrimaryHex)
        self.onSurface = extractColor(keys: ["on_surface", "onsurface", "foreground", "normal_foreground", "on_background", "onbackground", "color15", "color7"], fallbackHex: Self.fallbackOnSurfaceHex)
        self.secondary = extractColor(keys: ["secondary", "accent_secondary", "selected_active_background", "color2"], fallbackHex: Self.fallbackSecondaryHex)
        self.tertiary = extractColor(keys: ["tertiary", "accent", "color5", "color3", "color11"], fallbackHex: Self.fallbackTertiaryHex)
        self.outline = extractColor(keys: ["outline", "outline_variant", "border_color", "color8"], fallbackHex: Self.fallbackOutlineHex)
        self.error = extractColor(keys: ["error", "urgent_background", "color1"], fallbackHex: Self.fallbackErrorHex)
    }

    private func parseJSONTheme(content: String) {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            applyFallbacks()
            return
        }

        let colorsDict = json["colors"] as? [String: Any]
        let specialDict = json["special"] as? [String: Any]

        func extractColor(keys: [String], fallbackHex: String) -> NSColor {
            for k in keys {
                if let str = json[k] as? String, !str.isEmpty, let c = NSColor.parseColorString(str) {
                    return c
                }
                if let str = specialDict?[k] as? String, !str.isEmpty, let c = NSColor.parseColorString(str) {
                    return c
                }
                if let str = colorsDict?[k] as? String, !str.isEmpty, let c = NSColor.parseColorString(str) {
                    return c
                }
                if let nested = colorsDict?[k] as? [String: Any] {
                    if let def = nested["default"] as? [String: Any], let cStr = def["color"] as? String, !cStr.isEmpty, let c = NSColor.parseColorString(cStr) {
                        return c
                    }
                    if let cStr = nested["color"] as? String, !cStr.isEmpty, let c = NSColor.parseColorString(cStr) {
                        return c
                    }
                }
            }
            return NSColor(hexString: fallbackHex)
        }

        self.primary = extractColor(keys: ["primary", "accent", "color10", "color4"], fallbackHex: Self.fallbackPrimaryHex)
        self.surface = extractColor(keys: ["surface", "surface_dim", "background", "color0"], fallbackHex: Self.fallbackSurfaceHex)
        self.onPrimary = extractColor(keys: ["on_primary", "onPrimary", "background", "color0"], fallbackHex: Self.fallbackOnPrimaryHex)
        self.onSurface = extractColor(keys: ["on_surface", "onSurface", "foreground", "on_background", "color15", "color7"], fallbackHex: Self.fallbackOnSurfaceHex)
        self.secondary = extractColor(keys: ["secondary", "accent_secondary", "color2"], fallbackHex: Self.fallbackSecondaryHex)
        self.tertiary = extractColor(keys: ["tertiary", "accent", "color3", "color5", "color11"], fallbackHex: Self.fallbackTertiaryHex)
        self.outline = extractColor(keys: ["outline", "outline_variant", "color8"], fallbackHex: Self.fallbackOutlineHex)
        self.error = extractColor(keys: ["error", "color1"], fallbackHex: Self.fallbackErrorHex)
    }


    public func resolveColor(_ spec: String?, fallback: NSColor) -> NSColor {
        guard let spec = spec?.trimmingCharacters(in: .whitespacesAndNewlines), !spec.isEmpty else {
            return fallback
        }
        switch spec.lowercased() {
        case "primary": return self.primary
        case "on_primary", "onprimary": return self.onPrimary
        case "secondary": return self.secondary
        case "tertiary": return self.tertiary
        case "on_surface", "onsurface", "foreground": return self.onSurface
        case "surface", "background": return self.surface
        case "outline": return self.outline
        case "error": return self.error
        default:
            if let parsed = NSColor.parseColorString(spec) {
                return parsed
            }
            return fallback
        }
    }

    private func applyFallbacks() {
        self.surface = NSColor(hexString: Self.fallbackSurfaceHex)
        self.primary = NSColor(hexString: Self.fallbackPrimaryHex)
        self.onPrimary = NSColor(hexString: Self.fallbackOnPrimaryHex)
        self.secondary = NSColor(hexString: Self.fallbackSecondaryHex)
        self.tertiary = NSColor(hexString: Self.fallbackTertiaryHex)
        self.error = NSColor(hexString: Self.fallbackErrorHex)
        self.onSurface = NSColor(hexString: Self.fallbackOnSurfaceHex)
        self.outline = NSColor(hexString: Self.fallbackOutlineHex)
    }
}

@MainActor
public enum HyprFont {
    private static let candidateNerdFonts = [
        "JetBrainsMonoNF-Regular",
        "JetBrainsMono Nerd Font",
        "HackNF-Regular",
        "Hack Nerd Font",
        "IosevkaNF",
        "Iosevka Nerd Font",
        "FiraCodeNF-Reg",
        "FiraCode Nerd Font",
        "SymbolsNerdFontMono-Regular",
        "Symbols Nerd Font Mono"
    ]

    private static var cachedNerdFontDescriptors: [NSFontDescriptor]?

    public static func nerdFontDescriptors() -> [NSFontDescriptor] {
        if let cached = cachedNerdFontDescriptors {
            return cached
        }
        var descriptors: [NSFontDescriptor] = []
        for name in candidateNerdFonts {
            if let font = NSFont(name: name, size: 12) {
                descriptors.append(font.fontDescriptor)
            }
        }
        cachedNerdFontDescriptors = descriptors
        return descriptors
    }

    public static func barFont(ofSize size: CGFloat, weight: NSFont.Weight = .medium, italic: Bool = false, monospacedDigits: Bool = false) -> NSFont {
        var baseFont: NSFont = monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)

        if italic {
            baseFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        }

        let nerdDescriptors = nerdFontDescriptors()
        guard !nerdDescriptors.isEmpty else {
            return baseFont
        }

        let cascadeDesc = baseFont.fontDescriptor.addingAttributes([
            .cascadeList: nerdDescriptors
        ])

        return NSFont(descriptor: cascadeDesc, size: size) ?? baseFont
    }
}

@MainActor
extension NSFont {
    public static func barFont(ofSize size: CGFloat, weight: NSFont.Weight = .medium, italic: Bool = false, monospacedDigits: Bool = false) -> NSFont {
        HyprFont.barFont(ofSize: size, weight: weight, italic: italic, monospacedDigits: monospacedDigits)
    }
}
