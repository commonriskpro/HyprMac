import Cocoa

extension NSColor {
    public static func parseColorString(_ raw: String) -> NSColor? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased().hasPrefix("rgba(") && clean.hasSuffix(")") {
            let inner = clean.dropFirst(5).dropLast()
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 4,
                  let r = Double(parts[0]),
                  let g = Double(parts[1]),
                  let b = Double(parts[2]),
                  let a = Double(parts[3]) else { return nil }
            let alpha = a > 1.0 ? a / 255.0 : a
            return NSColor(srgbRed: CGFloat(r / 255.0), green: CGFloat(g / 255.0), blue: CGFloat(b / 255.0), alpha: CGFloat(alpha))
        } else if clean.lowercased().hasPrefix("rgb(") && clean.hasSuffix(")") {
            let inner = clean.dropFirst(4).dropLast()
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3,
                  let r = Double(parts[0]),
                  let g = Double(parts[1]),
                  let b = Double(parts[2]) else { return nil }
            return NSColor(srgbRed: CGFloat(r / 255.0), green: CGFloat(g / 255.0), blue: CGFloat(b / 255.0), alpha: 1.0)
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
        NSString(string: "~/.config/waybar/colors.css").expandingTildeInPath,
        NSString(string: "~/.config/waybar/colors-waybar.css").expandingTildeInPath,
        NSString(string: "~/.cache/wal/colors-waybar.css").expandingTildeInPath,
        NSString(string: "~/.cache/colors-waybar.css").expandingTildeInPath,
        NSString(string: "~/.config/hyprmac/colors.json").expandingTildeInPath,
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

        self.primary = extractColor(keys: ["primary", "color4"], fallbackHex: Self.fallbackPrimaryHex)
        self.surface = extractColor(keys: ["surface", "surface_dim", "background", "background_matugen", "color0"], fallbackHex: Self.fallbackSurfaceHex)
        self.onPrimary = extractColor(keys: ["on_primary", "onprimary", "background", "color0"], fallbackHex: Self.fallbackOnPrimaryHex)
        self.onSurface = extractColor(keys: ["on_surface", "onsurface", "on_background", "onbackground", "foreground", "color7"], fallbackHex: Self.fallbackOnSurfaceHex)
        self.secondary = extractColor(keys: ["secondary", "color2"], fallbackHex: Self.fallbackSecondaryHex)
        self.tertiary = extractColor(keys: ["tertiary", "accent", "color5"], fallbackHex: Self.fallbackTertiaryHex)
        self.outline = extractColor(keys: ["outline", "outline_variant", "color8"], fallbackHex: Self.fallbackOutlineHex)
        self.error = extractColor(keys: ["error", "color1"], fallbackHex: Self.fallbackErrorHex)
    }

    private func parseJSONTheme(content: String) {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            applyFallbacks()
            return
        }

        let colorsDict = json["colors"] as? [String: Any]

        func extractColor(keys: [String], fallbackHex: String) -> NSColor {
            for k in keys {
                if let str = json[k] as? String, !str.isEmpty, let c = NSColor.parseColorString(str) {
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

        self.primary = extractColor(keys: ["primary"], fallbackHex: Self.fallbackPrimaryHex)
        self.surface = extractColor(keys: ["surface", "surface_dim", "background"], fallbackHex: Self.fallbackSurfaceHex)
        self.onPrimary = extractColor(keys: ["on_primary", "onPrimary"], fallbackHex: Self.fallbackOnPrimaryHex)
        self.onSurface = extractColor(keys: ["on_surface", "onSurface", "on_background"], fallbackHex: Self.fallbackOnSurfaceHex)
        self.secondary = extractColor(keys: ["secondary"], fallbackHex: Self.fallbackSecondaryHex)
        self.tertiary = extractColor(keys: ["tertiary", "accent"], fallbackHex: Self.fallbackTertiaryHex)
        self.outline = extractColor(keys: ["outline", "outline_variant"], fallbackHex: Self.fallbackOutlineHex)
        self.error = extractColor(keys: ["error"], fallbackHex: Self.fallbackErrorHex)
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
