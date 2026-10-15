import Foundation
import CoreGraphics
import Carbon.HIToolbox
import AppKit

/// Provides bidirectional mapping between Hyprland key/modifier identifiers and macOS CGKeyCode/CGEventFlags.
public enum KeyCodeMapping {

    // MARK: - Modifiers

    /// Maps a single Hyprland modifier string to its corresponding CGEventFlags bitmask.
    public static func modifier(for name: String) -> CGEventFlags? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch normalized {
        case "SUPER", "CMD", "COMMAND", "WIN", "MOD4", "SUPER_L", "SUPER_R":
            return .maskCommand
        case "SHIFT", "SHIFT_L", "SHIFT_R":
            return .maskShift
        case "CTRL", "CONTROL", "CTRL_L", "CTRL_R", "CONTROL_L", "CONTROL_R":
            return .maskControl
        case "ALT", "MOD1", "OPTION", "OPT", "ALT_L", "ALT_R", "OPTION_L", "OPTION_R":
            return .maskAlternate
        case "FN", "FUNCTION":
            return .maskSecondaryFn
        case "CAPS", "CAPSLOCK", "CAPS_LOCK":
            return .maskAlphaShift
        default:
            return nil
        }
    }

    /// Maps a single Hyprland modifier string to its corresponding NSEvent.ModifierFlags.
    public static func eventModifierFlags(for name: String) -> NSEvent.ModifierFlags? {
        guard let cgFlag = modifier(for: name) else { return nil }
        return toNSEventModifierFlags(flags: cgFlag)
    }

    /// Parses a combined modifier string (e.g., "SUPER_SHIFT", "SUPER,SHIFT", "CMD+SHIFT", "SUPER SHIFT", "ALT|CTRL")
    /// into a composite CGEventFlags set.
    public static func parseModifiers(_ raw: String) -> CGEventFlags {
        let separators = CharacterSet(charactersIn: ",+_| \t")
        let tokens = raw.components(separatedBy: separators).filter { !$0.isEmpty }
        var flags = CGEventFlags()
        for token in tokens {
            if let flag = modifier(for: token) {
                flags.insert(flag)
            }
        }
        return flags
    }

    /// Parses a combined modifier string into NSEvent.ModifierFlags.
    public static func parseNSEventModifiers(_ raw: String) -> NSEvent.ModifierFlags {
        let cgFlags = parseModifiers(raw)
        return toNSEventModifierFlags(flags: cgFlags)
    }

    /// Converts CGEventFlags to equivalent NSEvent.ModifierFlags.
    public static func toNSEventModifierFlags(flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var nsFlags: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { nsFlags.insert(.command) }
        if flags.contains(.maskShift) { nsFlags.insert(.shift) }
        if flags.contains(.maskControl) { nsFlags.insert(.control) }
        if flags.contains(.maskAlternate) { nsFlags.insert(.option) }
        if flags.contains(.maskSecondaryFn) { nsFlags.insert(.function) }
        if flags.contains(.maskAlphaShift) { nsFlags.insert(.capsLock) }
        return nsFlags
    }

    /// Converts NSEvent.ModifierFlags to equivalent CGEventFlags.
    public static func toCGEventFlags(flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var cgFlags = CGEventFlags()
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.function) { cgFlags.insert(.maskSecondaryFn) }
        if flags.contains(.capsLock) { cgFlags.insert(.maskAlphaShift) }
        return cgFlags
    }

    /// Returns canonical Hyprland names for active modifier flags.
    public static func modifierNames(for flags: CGEventFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.maskCommand) { names.append("SUPER") }
        if flags.contains(.maskShift) { names.append("SHIFT") }
        if flags.contains(.maskControl) { names.append("CTRL") }
        if flags.contains(.maskAlternate) { names.append("ALT") }
        if flags.contains(.maskSecondaryFn) { names.append("FN") }
        return names
    }

    // MARK: - Key Codes Mapping

    /// Canonical mapping from primary key names to macOS virtual key codes.
    private static let canonicalMapping: [(String, CGKeyCode)] = [
        // Letters
        ("A", CGKeyCode(kVK_ANSI_A)),
        ("B", CGKeyCode(kVK_ANSI_B)),
        ("C", CGKeyCode(kVK_ANSI_C)),
        ("D", CGKeyCode(kVK_ANSI_D)),
        ("E", CGKeyCode(kVK_ANSI_E)),
        ("F", CGKeyCode(kVK_ANSI_F)),
        ("G", CGKeyCode(kVK_ANSI_G)),
        ("H", CGKeyCode(kVK_ANSI_H)),
        ("I", CGKeyCode(kVK_ANSI_I)),
        ("J", CGKeyCode(kVK_ANSI_J)),
        ("K", CGKeyCode(kVK_ANSI_K)),
        ("L", CGKeyCode(kVK_ANSI_L)),
        ("M", CGKeyCode(kVK_ANSI_M)),
        ("N", CGKeyCode(kVK_ANSI_N)),
        ("O", CGKeyCode(kVK_ANSI_O)),
        ("P", CGKeyCode(kVK_ANSI_P)),
        ("Q", CGKeyCode(kVK_ANSI_Q)),
        ("R", CGKeyCode(kVK_ANSI_R)),
        ("S", CGKeyCode(kVK_ANSI_S)),
        ("T", CGKeyCode(kVK_ANSI_T)),
        ("U", CGKeyCode(kVK_ANSI_U)),
        ("V", CGKeyCode(kVK_ANSI_V)),
        ("W", CGKeyCode(kVK_ANSI_W)),
        ("X", CGKeyCode(kVK_ANSI_X)),
        ("Y", CGKeyCode(kVK_ANSI_Y)),
        ("Z", CGKeyCode(kVK_ANSI_Z)),

        // Digits
        ("0", CGKeyCode(kVK_ANSI_0)),
        ("1", CGKeyCode(kVK_ANSI_1)),
        ("2", CGKeyCode(kVK_ANSI_2)),
        ("3", CGKeyCode(kVK_ANSI_3)),
        ("4", CGKeyCode(kVK_ANSI_4)),
        ("5", CGKeyCode(kVK_ANSI_5)),
        ("6", CGKeyCode(kVK_ANSI_6)),
        ("7", CGKeyCode(kVK_ANSI_7)),
        ("8", CGKeyCode(kVK_ANSI_8)),
        ("9", CGKeyCode(kVK_ANSI_9)),

        // Control & Whitespace
        ("RETURN", CGKeyCode(kVK_Return)),
        ("TAB", CGKeyCode(kVK_Tab)),
        ("SPACE", CGKeyCode(kVK_Space)),
        ("BACKSPACE", CGKeyCode(kVK_Delete)),
        ("ESCAPE", CGKeyCode(kVK_Escape)),
        ("FORWARDDELETE", CGKeyCode(kVK_ForwardDelete)),

        // Navigation & Arrow Keys
        ("LEFT", CGKeyCode(kVK_LeftArrow)),
        ("RIGHT", CGKeyCode(kVK_RightArrow)),
        ("DOWN", CGKeyCode(kVK_DownArrow)),
        ("UP", CGKeyCode(kVK_UpArrow)),
        ("HOME", CGKeyCode(kVK_Home)),
        ("END", CGKeyCode(kVK_End)),
        ("PAGEUP", CGKeyCode(kVK_PageUp)),
        ("PAGEDOWN", CGKeyCode(kVK_PageDown)),

        // Function Keys
        ("F1", CGKeyCode(kVK_F1)),
        ("F2", CGKeyCode(kVK_F2)),
        ("F3", CGKeyCode(kVK_F3)),
        ("F4", CGKeyCode(kVK_F4)),
        ("F5", CGKeyCode(kVK_F5)),
        ("F6", CGKeyCode(kVK_F6)),
        ("F7", CGKeyCode(kVK_F7)),
        ("F8", CGKeyCode(kVK_F8)),
        ("F9", CGKeyCode(kVK_F9)),
        ("F10", CGKeyCode(kVK_F10)),
        ("F11", CGKeyCode(kVK_F11)),
        ("F12", CGKeyCode(kVK_F12)),
        ("F13", CGKeyCode(kVK_F13)),
        ("F14", CGKeyCode(kVK_F14)),
        ("F15", CGKeyCode(kVK_F15)),
        ("F16", CGKeyCode(kVK_F16)),
        ("F17", CGKeyCode(kVK_F17)),
        ("F18", CGKeyCode(kVK_F18)),
        ("F19", CGKeyCode(kVK_F19)),
        ("F20", CGKeyCode(kVK_F20)),

        // Symbols / Punctuation
        ("MINUS", CGKeyCode(kVK_ANSI_Minus)),
        ("EQUAL", CGKeyCode(kVK_ANSI_Equal)),
        ("LEFTBRACKET", CGKeyCode(kVK_ANSI_LeftBracket)),
        ("RIGHTBRACKET", CGKeyCode(kVK_ANSI_RightBracket)),
        ("BACKSLASH", CGKeyCode(kVK_ANSI_Backslash)),
        ("SEMICOLON", CGKeyCode(kVK_ANSI_Semicolon)),
        ("APOSTROPHE", CGKeyCode(kVK_ANSI_Quote)),
        ("COMMA", CGKeyCode(kVK_ANSI_Comma)),
        ("PERIOD", CGKeyCode(kVK_ANSI_Period)),
        ("SLASH", CGKeyCode(kVK_ANSI_Slash)),
        ("GRAVE", CGKeyCode(kVK_ANSI_Grave)),

        // Modifiers as individual keys
        ("COMMAND", CGKeyCode(kVK_Command)),
        ("SHIFT", CGKeyCode(kVK_Shift)),
        ("CAPSLOCK", CGKeyCode(kVK_CapsLock)),
        ("OPTION", CGKeyCode(kVK_Option)),
        ("CONTROL", CGKeyCode(kVK_Control)),
        ("RIGHTSHIFT", CGKeyCode(kVK_RightShift)),
        ("RIGHTOPTION", CGKeyCode(kVK_RightOption)),
        ("RIGHTCONTROL", CGKeyCode(kVK_RightControl)),
        ("FUNCTION", CGKeyCode(kVK_Function)),

        // Keypad
        ("KP_0", CGKeyCode(kVK_ANSI_Keypad0)),
        ("KP_1", CGKeyCode(kVK_ANSI_Keypad1)),
        ("KP_2", CGKeyCode(kVK_ANSI_Keypad2)),
        ("KP_3", CGKeyCode(kVK_ANSI_Keypad3)),
        ("KP_4", CGKeyCode(kVK_ANSI_Keypad4)),
        ("KP_5", CGKeyCode(kVK_ANSI_Keypad5)),
        ("KP_6", CGKeyCode(kVK_ANSI_Keypad6)),
        ("KP_7", CGKeyCode(kVK_ANSI_Keypad7)),
        ("KP_8", CGKeyCode(kVK_ANSI_Keypad8)),
        ("KP_9", CGKeyCode(kVK_ANSI_Keypad9)),
        ("KP_DECIMAL", CGKeyCode(kVK_ANSI_KeypadDecimal)),
        ("KP_MULTIPLY", CGKeyCode(kVK_ANSI_KeypadMultiply)),
        ("KP_ADD", CGKeyCode(kVK_ANSI_KeypadPlus)),
        ("KP_CLEAR", CGKeyCode(kVK_ANSI_KeypadClear)),
        ("KP_DIVIDE", CGKeyCode(kVK_ANSI_KeypadDivide)),
        ("KP_ENTER", CGKeyCode(kVK_ANSI_KeypadEnter)),
        ("KP_SUBTRACT", CGKeyCode(kVK_ANSI_KeypadMinus)),
        ("KP_EQUALS", CGKeyCode(kVK_ANSI_KeypadEquals))
    ]

    /// Secondary aliases for common alternate names.
    private static let aliases: [(String, CGKeyCode)] = [
        // Whitespace & control aliases
        ("ENTER", CGKeyCode(kVK_Return)),
        ("RET", CGKeyCode(kVK_Return)),
        ("SPC", CGKeyCode(kVK_Space)),
        ("ESC", CGKeyCode(kVK_Escape)),
        ("BACK", CGKeyCode(kVK_Delete)),
        ("BS", CGKeyCode(kVK_Delete)),
        ("DEL", CGKeyCode(kVK_ForwardDelete)),
        ("DELETE", CGKeyCode(kVK_ForwardDelete)),

        // Arrows & Navigation aliases
        ("LEFTARROW", CGKeyCode(kVK_LeftArrow)),
        ("RIGHTARROW", CGKeyCode(kVK_RightArrow)),
        ("DOWNARROW", CGKeyCode(kVK_DownArrow)),
        ("UPARROW", CGKeyCode(kVK_UpArrow)),
        ("PAGE_UP", CGKeyCode(kVK_PageUp)),
        ("PAGE_DOWN", CGKeyCode(kVK_PageDown)),
        ("PGUP", CGKeyCode(kVK_PageUp)),
        ("PGDN", CGKeyCode(kVK_PageDown)),
        ("PRIOR", CGKeyCode(kVK_PageUp)),
        ("NEXT", CGKeyCode(kVK_PageDown)),

        // Symbols aliases
        ("-", CGKeyCode(kVK_ANSI_Minus)),
        ("EQUALS", CGKeyCode(kVK_ANSI_Equal)),
        ("=", CGKeyCode(kVK_ANSI_Equal)),
        ("[", CGKeyCode(kVK_ANSI_LeftBracket)),
        ("BRACKETLEFT", CGKeyCode(kVK_ANSI_LeftBracket)),
        ("BRACELEFT", CGKeyCode(kVK_ANSI_LeftBracket)),
        ("{", CGKeyCode(kVK_ANSI_LeftBracket)),
        ("]", CGKeyCode(kVK_ANSI_RightBracket)),
        ("BRACKETRIGHT", CGKeyCode(kVK_ANSI_RightBracket)),
        ("BRACERIGHT", CGKeyCode(kVK_ANSI_RightBracket)),
        ("}", CGKeyCode(kVK_ANSI_RightBracket)),
        ("\\", CGKeyCode(kVK_ANSI_Backslash)),
        (";", CGKeyCode(kVK_ANSI_Semicolon)),
        (":", CGKeyCode(kVK_ANSI_Semicolon)),
        ("COLON", CGKeyCode(kVK_ANSI_Semicolon)),
        ("'", CGKeyCode(kVK_ANSI_Quote)),
        ("\"", CGKeyCode(kVK_ANSI_Quote)),
        ("QUOTE", CGKeyCode(kVK_ANSI_Quote)),
        (",", CGKeyCode(kVK_ANSI_Comma)),
        ("<", CGKeyCode(kVK_ANSI_Comma)),
        ("LESS", CGKeyCode(kVK_ANSI_Comma)),
        (".", CGKeyCode(kVK_ANSI_Period)),
        ("DOT", CGKeyCode(kVK_ANSI_Period)),
        (">", CGKeyCode(kVK_ANSI_Period)),
        ("GREATER", CGKeyCode(kVK_ANSI_Period)),
        ("/", CGKeyCode(kVK_ANSI_Slash)),
        ("?", CGKeyCode(kVK_ANSI_Slash)),
        ("QUESTION", CGKeyCode(kVK_ANSI_Slash)),
        ("`", CGKeyCode(kVK_ANSI_Grave)),
        ("BACKTICK", CGKeyCode(kVK_ANSI_Grave)),
        ("~", CGKeyCode(kVK_ANSI_Grave)),
        ("TILDE", CGKeyCode(kVK_ANSI_Grave)),

        // Modifiers aliases
        ("CMD", CGKeyCode(kVK_Command)),
        ("SUPER", CGKeyCode(kVK_Command)),
        ("CTRL", CGKeyCode(kVK_Control)),
        ("ALT", CGKeyCode(kVK_Option)),
        ("OPT", CGKeyCode(kVK_Option)),
        ("FN", CGKeyCode(kVK_Function)),
        ("CAPS_LOCK", CGKeyCode(kVK_CapsLock)),
        ("CAPS", CGKeyCode(kVK_CapsLock)),

        // Keypad aliases
        ("KP0", CGKeyCode(kVK_ANSI_Keypad0)),
        ("KP1", CGKeyCode(kVK_ANSI_Keypad1)),
        ("KP2", CGKeyCode(kVK_ANSI_Keypad2)),
        ("KP3", CGKeyCode(kVK_ANSI_Keypad3)),
        ("KP4", CGKeyCode(kVK_ANSI_Keypad4)),
        ("KP5", CGKeyCode(kVK_ANSI_Keypad5)),
        ("KP6", CGKeyCode(kVK_ANSI_Keypad6)),
        ("KP7", CGKeyCode(kVK_ANSI_Keypad7)),
        ("KP8", CGKeyCode(kVK_ANSI_Keypad8)),
        ("KP9", CGKeyCode(kVK_ANSI_Keypad9)),
        ("KP_PLUS", CGKeyCode(kVK_ANSI_KeypadPlus)),
        ("KPPLUS", CGKeyCode(kVK_ANSI_KeypadPlus)),
        ("KP_MINUS", CGKeyCode(kVK_ANSI_KeypadMinus)),
        ("KPMINUS", CGKeyCode(kVK_ANSI_KeypadMinus)),
        ("KP_DOT", CGKeyCode(kVK_ANSI_KeypadDecimal)),
        ("KPDOT", CGKeyCode(kVK_ANSI_KeypadDecimal)),
        ("KPENTER", CGKeyCode(kVK_ANSI_KeypadEnter))
    ]

    /// Lookup table from normalized name to CGKeyCode.
    private static let nameToCodeMap: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [:]
        for (name, code) in canonicalMapping {
            map[name.uppercased()] = code
        }
        for (alias, code) in aliases {
            map[alias.uppercased()] = code
        }
        return map
    }()

    /// Reverse lookup table from CGKeyCode to canonical Hyprland name.
    private static let codeToNameMap: [CGKeyCode: String] = {
        var map: [CGKeyCode: String] = [:]
        for (name, code) in canonicalMapping {
            // Set once to preserve canonical primary name
            if map[code] == nil {
                map[code] = name
            }
        }
        return map
    }()

    /// Resolves a Hyprland key string (case-insensitive) to a macOS CGKeyCode.
    /// Also supports numeric keycode formats like "code:12" or "0x0C" or "12".
    public static func keyCode(for name: String) -> CGKeyCode? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.isEmpty { return nil }

        // Direct table match
        if let code = nameToCodeMap[trimmed] {
            return code
        }

        // Handle "code:<num>" syntax commonly used in Hyprland
        if trimmed.hasPrefix("CODE:") {
            let rawNum = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return parseNumericKeyCode(rawNum)
        }

        // Handle direct hex or decimal keycode numbers
        return parseNumericKeyCode(trimmed)
    }

    /// Resolves a macOS CGKeyCode to its canonical Hyprland key name.
    public static func keyName(for keyCode: CGKeyCode) -> String? {
        return codeToNameMap[keyCode]
    }

    private static func parseNumericKeyCode(_ raw: String) -> CGKeyCode? {
        if raw.hasPrefix("0X") {
            if let val = UInt16(raw.dropFirst(2), radix: 16) {
                return CGKeyCode(val)
            }
        } else if let val = UInt16(raw) {
            return CGKeyCode(val)
        }
        return nil
    }
}
