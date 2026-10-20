import Cocoa

/// Presentation mode for window borders
public enum BorderMode: String, Sendable, CaseIterable, Equatable {
    case outline = "outline"
    case glassHalo = "glass_halo"
}

extension NSColor {
    public convenience init(rgbaHex: UInt32) {
        let r = CGFloat((rgbaHex >> 24) & 0xFF) / 255.0
        let g = CGFloat((rgbaHex >> 16) & 0xFF) / 255.0
        let b = CGFloat((rgbaHex >> 8) & 0xFF) / 255.0
        let a = CGFloat(rgbaHex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    public convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        if hex > 0xFFFFFF {
            self.init(rgbaHex: hex)
        } else {
            let r = CGFloat((hex >> 16) & 0xFF) / 255.0
            let g = CGFloat((hex >> 8) & 0xFF) / 255.0
            let b = CGFloat(hex & 0xFF) / 255.0
            self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
        }
    }
}
