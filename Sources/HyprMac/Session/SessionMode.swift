import Foundation

/// Represents the active desktop operating session mode of HyprMac on macOS.
public enum SessionMode: String, Codable, Sendable, CaseIterable, CustomStringConvertible {
    /// Active Hyprland mode (custom bar/shell, automatic tiling layout, active gradient borders, custom hotkeys).
    case hyprMac = "hyprMac"
    /// Traditional macOS Aqua mode (native visible menu bar, standard floating window manager, default Dock).
    case aqua = "aqua"

    public var description: String {
        return rawValue
    }

    /// Human-readable label for user interfaces, diagnostics, and notifications.
    public var displayName: String {
        switch self {
        case .hyprMac:
            return "Hyprland Mode (Tiling, Custom Shell & Borders)"
        case .aqua:
            return "macOS Aqua Mode (Native Menubar & Floating Windows)"
        }
    }

    /// Returns true if current mode is hyprMac.
    public var isHyprMac: Bool {
        return self == .hyprMac
    }

    /// Returns true if current mode is aqua.
    public var isAqua: Bool {
        return self == .aqua
    }

    /// Returns the opposite mode (useful for toggling between Hyprland and Aqua).
    public var toggled: SessionMode {
        switch self {
        case .hyprMac:
            return .aqua
        case .aqua:
            return .hyprMac
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw.lowercased() {
        case "hyprmac", "hypr", "tiling":
            self = .hyprMac
        case "aqua", "native", "macos", "floating":
            self = .aqua
        default:
            if let mode = SessionMode(rawValue: raw) {
                self = mode
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid SessionMode value: \(raw)"
                )
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
