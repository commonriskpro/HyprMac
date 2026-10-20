import Foundation
import CoreGraphics

/// Robust parser for Hyprland configuration files (`hyprland.conf`).
/// Supports variable definition and expansion, nested block sections,
/// keybinding directives (`bind`, `bindm`, etc.), include directives (`source`),
/// and style/dimension mappings to `HyprConfig`.
public final class ConfigParser {
    /// Parse raw configuration text into a `HyprConfig` instance.
    public static func parse(text: String) -> HyprConfig {
        var config = HyprConfig()
        var visited = Set<String>()
        parseInternal(text: text, config: &config, visited: &visited)
        return config
    }

    /// Parse a configuration file from the filesystem.
    /// Returns default `HyprConfig` if the file does not exist or cannot be read.
    public static func parseFile(atPath path: String) -> HyprConfig {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded),
              let content = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            return HyprConfig()
        }
        var config = HyprConfig()
        var visited = Set<String>([expanded])
        parseInternal(text: content, config: &config, visited: &visited)
        return config
    }

    /// Validates parser behavior against a realistic Hyprland configuration snippet.
    /// Returns `true` on success, or logs failures and returns `false`.
    @discardableResult
    public static func runSelfTest() -> Bool {
        let sample = """
        # Real-world Hyprland configuration sample
        $mainMod = SUPER
        $terminal = kitty
        $fileManager = dolphin
        $menu = wofi --show drun
        $extraMod = $mainMod SHIFT

        # General window layout & borders
        general {
            gaps_in = 6
            gaps_out = 14
            border_size = 3
            border_mode = glass_halo
            halo_padding = 12
            col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
            col.inactive_border = rgba(595959aa)
            layout = dwindle
        }

        # Decoration & Visuals
        decoration {
            rounding = 12
            active_opacity = 0.96
            strip_decorations = yes
            drop_shadow = yes
            shadow_range = 4
            blur {
                enabled = true
                size = 4
                passes = 2
            }
        }

        dwindle {
            pseudotile = yes
            preserve_split = yes
        }

        animations {
            enabled = yes
            bezier = myBezier, 0.05, 0.9, 0.1, 1.05
            animation = windows, 1, 7, myBezier
            animation = windowsOut, 1, 7, default, popin 80%
            animation = windowsMove, 1, 5, easeOutQuint
        }

        # Keybindings
        bind = $mainMod, Q, exec, $terminal # launch terminal
        bind = $mainMod, C, killactive
        bind = $mainMod, M, exit,
        bind = $mainMod, E, exec, $fileManager
        bind = $mainMod, V, togglefloating,
        bind = $mainMod, R, exec, $menu
        bind = $mainMod, 1, workspace, 1
        bind = $extraMod, 1, movetoworkspace, 1
        bind = , XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+

        source = ~/.config/hypr/mac-extras.conf
        """

        let config = parse(text: sample)

        guard config.gapsIn == 6.0 else {
            print("[-] runSelfTest failed: gapsIn != 6.0 (got \(config.gapsIn))")
            return false
        }
        guard config.gapsOut == 14.0 else {
            print("[-] runSelfTest failed: gapsOut != 14.0 (got \(config.gapsOut))")
            return false
        }
        guard config.borderSize == 3 else {
            print("[-] runSelfTest failed: borderSize != 3 (got \(config.borderSize))")
            return false
        }
        guard config.rounding == 12.0 else {
            print("[-] runSelfTest failed: rounding != 12.0 (got \(config.rounding))")
            return false
        }
        guard config.borderMode == .glassHalo else {
            print("[-] runSelfTest failed: borderMode != .glassHalo (got \(config.borderMode))")
            return false
        }
        guard config.haloPadding == 12.0 else {
            print("[-] runSelfTest failed: haloPadding != 12.0 (got \(config.haloPadding))")
            return false
        }
        guard config.windowOpacity == 0.96 else {
            print("[-] runSelfTest failed: windowOpacity != 0.96 (got \(config.windowOpacity))")
            return false
        }
        guard config.stripDecorations == true else {
            print("[-] runSelfTest failed: stripDecorations != true")
            return false
        }
        guard config.activeBorderGradient == [0x33CCFFEE, 0x00FF99EE] else {
            print("[-] runSelfTest failed: activeBorderGradient mismatch")
            return false
        }
        guard config.inactiveBorderColor == 0x595959AA else {
            print("[-] runSelfTest failed: inactiveBorderColor mismatch")
            return false
        }
        guard config.variables["$mainMod"] == "SUPER", config.variables["terminal"] == "kitty" else {
            print("[-] runSelfTest failed: variables mismatch")
            return false
        }
        guard config.variables["$extraMod"] == "SUPER SHIFT" else {
            print("[-] runSelfTest failed: extraMod variable expansion mismatch")
            return false
        }
        guard config.bindings.count == 9 else {
            print("[-] runSelfTest failed: bindings count != 9 (got \(config.bindings.count))")
            return false
        }

        let qBind = config.bindings[0]
        guard qBind.mod == "SUPER", qBind.key == "Q", qBind.dispatcher == "exec", qBind.args == "kitty" else {
            print("[-] runSelfTest failed: binding 0 mismatch: \(qBind)")
            return false
        }

        let cBind = config.bindings[1]
        guard cBind.mod == "SUPER", cBind.key == "C", cBind.dispatcher == "killactive", cBind.args == "" else {
            print("[-] runSelfTest failed: binding 1 mismatch: \(cBind)")
            return false
        }

        let extraBind = config.bindings[7]
        guard extraBind.mod == "SUPER SHIFT", extraBind.key == "1", extraBind.dispatcher == "movetoworkspace", extraBind.args == "1" else {
            print("[-] runSelfTest failed: binding 7 mismatch: \(extraBind)")
            return false
        }

        let volBind = config.bindings[8]
        guard volBind.mod == "", volBind.key == "XF86AudioRaiseVolume", volBind.dispatcher == "exec", volBind.args.contains("wpctl") else {
            print("[-] runSelfTest failed: binding 8 mismatch: \(volBind)")
            return false
        }

        guard config.sourceFiles.contains("~/.config/hypr/mac-extras.conf") else {
            print("[-] runSelfTest failed: sourceFiles missing expected path")
            return false
        }

        guard config.sections["decoration.blur"]?["enabled"] == "true" else {
            print("[-] runSelfTest failed: nested section decoration.blur missing enabled=true")
            return false
        }

        guard config.animationsEnabled == true else {
            print("[-] runSelfTest failed: animationsEnabled != true")
            return false
        }

        guard let b = config.animationTree.getBezier(name: "myBezier"), b.x0 == 0.05, b.y1 == 1.05 else {
            print("[-] runSelfTest failed: myBezier curve was not parsed correctly")
            return false
        }

        guard let aWin = config.animationTree.animations["windows"], aWin.curveName == "myBezier", abs(aWin.duration - 0.7) < 1e-4 else {
            print("[-] runSelfTest failed: animation windows was not parsed correctly")
            return false
        }

        guard let aMove = config.animationTree.animations["windowsMove"], aMove.curveName == "easeOutQuint", abs(aMove.duration - 0.5) < 1e-4 else {
            print("[-] runSelfTest failed: animation windowsMove was not parsed correctly")
            return false
        }

        // Verify alternate key syntax (colon prefix, hide_window_decorations, outline mode)
        let altSample = """
        general:border_mode = outline
        halo_padding = 16.5
        decoration:active_opacity = 0.88
        hide_window_decorations = 0
        """
        let altConfig = parse(text: altSample)
        guard altConfig.borderMode == .outline else {
            print("[-] runSelfTest failed: altConfig borderMode != .outline (got \(altConfig.borderMode))")
            return false
        }
        guard altConfig.haloPadding == 16.5 else {
            print("[-] runSelfTest failed: altConfig haloPadding != 16.5 (got \(altConfig.haloPadding))")
            return false
        }
        guard altConfig.windowOpacity == 0.88 else {
            print("[-] runSelfTest failed: altConfig windowOpacity != 0.88 (got \(altConfig.windowOpacity))")
            return false
        }
        guard altConfig.stripDecorations == false else {
            print("[-] runSelfTest failed: altConfig stripDecorations != false")
            return false
        }

        print("[+] ConfigParser.runSelfTest() PASSED successfully!")
        return true
    }

    // MARK: - Internal Parsing Engine

    private static func parseInternal(text: String, config: inout HyprConfig, visited: inout Set<String>) {
        let lines = text.components(separatedBy: .newlines)
        var sectionStack: [String] = []
        var pendingSection: String? = nil

        for rawLine in lines {
            let stripped = stripComment(from: rawLine)
            if stripped.isEmpty { continue }

            // Handle pending section header where opening brace is on a subsequent line
            if stripped == "{" {
                if let sec = pendingSection {
                    sectionStack.append(sec)
                    pendingSection = nil
                }
                continue
            }

            // Expand variables across the line before further processing
            let line = expandVariables(in: stripped, variables: config.variables)

            // Closing section brace
            if line == "}" {
                if !sectionStack.isEmpty { sectionStack.removeLast() }
                pendingSection = nil
                continue
            }

            // Standard section opening: "section_name {"
            if line.hasSuffix("{") {
                let sectionName = line.dropLast().trimmingCharacters(in: .whitespaces)
                if !sectionName.isEmpty {
                    sectionStack.append(sectionName)
                }
                pendingSection = nil
                continue
            }

            // Inline block on single line: "section_name { key = value; ... }"
            if let openIdx = line.firstIndex(of: "{"), let closeIdx = line.lastIndex(of: "}"), openIdx < closeIdx {
                let secName = line[..<openIdx].trimmingCharacters(in: .whitespaces)
                if !secName.contains("=") && !secName.isEmpty {
                    let inner = line[line.index(after: openIdx)..<closeIdx].trimmingCharacters(in: .whitespaces)
                    sectionStack.append(secName)
                    if !inner.isEmpty {
                        for stmt in inner.components(separatedBy: ";") {
                            let trimmedStmt = stmt.trimmingCharacters(in: .whitespaces)
                            if !trimmedStmt.isEmpty {
                                processStatement(trimmedStmt, sectionStack: sectionStack, config: &config, visited: &visited)
                            }
                        }
                    }
                    if !sectionStack.isEmpty { sectionStack.removeLast() }
                    pendingSection = nil
                    continue
                }
            }

            // Possible section name without brace on this line
            if !line.contains("=") && !line.contains(",") && !line.hasPrefix("$") {
                pendingSection = line
                continue
            } else {
                pendingSection = nil
            }

            // Handle statements that end with closing brace: "key = val }"
            var statement = line
            var popAtEnd = false
            if statement.hasSuffix("}") && !statement.contains("{") {
                statement = String(statement.dropLast()).trimmingCharacters(in: .whitespaces)
                popAtEnd = true
            }

            if !statement.isEmpty {
                processStatement(statement, sectionStack: sectionStack, config: &config, visited: &visited)
            }

            if popAtEnd && !sectionStack.isEmpty {
                sectionStack.removeLast()
            }
        }
    }

    private static func processStatement(
        _ line: String,
        sectionStack: [String],
        config: inout HyprConfig,
        visited: inout Set<String>
    ) {
        guard let eqIndex = line.firstIndex(of: "=") else { return }

        let rawKey = String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces)
        let rawVal = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

        // 1. Variable definition ($var = val)
        if rawKey.hasPrefix("$") {
            let varVal = expandVariables(in: rawVal, variables: config.variables)
            config.variables[rawKey] = varVal
            let noDollar = String(rawKey.dropFirst())
            config.variables[noDollar] = varVal
            return
        }

        let lowerKey = rawKey.lowercased()

        // 2. Keybinding directives: bind, bindm, binde, bindl, bindr
        if lowerKey == "bind" || lowerKey.hasPrefix("bind") {
            let flags = lowerKey == "bind" ? "" : String(rawKey.dropFirst(4))
            let binding = parseBindingTokens(rawVal, flags: flags)
            config.bindings.append(binding)
            return
        }

        // 3. Include directive: source = path
        if lowerKey == "source" {
            let path = rawVal
            config.sourceFiles.append(path)
            let expanded = (path as NSString).expandingTildeInPath
            if !visited.contains(expanded) && FileManager.default.fileExists(atPath: expanded) {
                visited.insert(expanded)
                if let content = try? String(contentsOfFile: expanded, encoding: .utf8) {
                    parseInternal(text: content, config: &config, visited: &visited)
                }
            }
            return
        }

        // 3b. Bezier curve directive: bezier = name, x0, y0, x1, y1
        if lowerKey == "bezier" {
            let tokens = rawVal.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if tokens.count >= 5,
               let x0 = Double(tokens[1]),
               let y0 = Double(tokens[2]),
               let x1 = Double(tokens[3]),
               let y1 = Double(tokens[4]) {
                let bezier = HyprBezier(name: tokens[0], x0: x0, y0: y0, x1: x1, y1: y1)
                config.animationTree.addBezier(bezier)
            }
            return
        }

        // 3b-2. Spring curve directive: spring = name, mass, stiffness, damping
        if lowerKey == "spring" {
            let tokens = rawVal.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if tokens.count >= 4,
               let m = Double(tokens[1]),
               let k = Double(tokens[2]),
               let d = Double(tokens[3]) {
                let spring = SpringConfig(mass: m, stiffness: k, damping: d)
                config.animationTree.addSpring(name: tokens[0], spring: spring)
            } else if tokens.count == 3,
                      let m = Double(tokens[1]),
                      let zeta = Double(tokens[2]) {
                let spring = SpringConfig.withDampingRatio(mass: m, stiffness: 100.0, dampingRatio: zeta)
                config.animationTree.addSpring(name: tokens[0], spring: spring)
            }
            return
        }

        // 3c. Animation directive: animation = node, enabled, duration, curve [, style]
        if lowerKey == "animation" {
            let tokens = rawVal.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if tokens.count >= 4 {
                let node = tokens[0]
                let enabled = parseBool(tokens[1]) ?? true
                let rawDuration = Double(tokens[2]) ?? 7.0
                // In Hyprland, speed is strictly measured in deciseconds (ds): speed 7 = 0.7s, 4.79 = 0.479s, 1.49 = 0.149s
                let duration = rawDuration / 10.0
                let curve = tokens[3]
                let style = tokens.count > 4 ? tokens[4...].joined(separator: ", ") : ""
                config.animationTree.setConfigForNode(
                    node: node,
                    enabled: enabled,
                    duration: duration,
                    curveName: curve,
                    style: style
                )
            }
            return
        }

        // 4. Regular settings & Hyprland variables
        let currentSection = sectionStack.joined(separator: ".")
        if (currentSection == "animations" && lowerKey == "enabled") ||
           rawKey.lowercased() == "animations:enabled" ||
           rawKey.lowercased() == "animations.enabled" {
            if let b = parseBool(rawVal) {
                config.animationsEnabled = b
            }
            return
        }
        let fullKey = currentSection.isEmpty ? rawKey : "\(currentSection).\(rawKey)"
        config.rawSettings[fullKey] = rawVal
        config.rawSettings[rawKey] = rawVal

        if !currentSection.isEmpty {
            var secDict = config.sections[currentSection] ?? [:]
            secDict[rawKey] = rawVal
            config.sections[currentSection] = secDict
        }

        // Normalized key for mapping
        let normalizedKey = rawKey.components(separatedBy: CharacterSet(charactersIn: ":.")).last ?? rawKey

        // 3d. Declarative Bar module color tokens (bar { ... } or bar:key)
        if currentSection == "bar" || rawKey.lowercased().hasPrefix("bar.") || rawKey.lowercased().hasPrefix("bar:") {
            let barProp = normalizedKey.lowercased()
            var cleanVal = rawVal.trimmingCharacters(in: .whitespaces)
            let q = String(Character(UnicodeScalar(34)))
            let sq = String(Character(UnicodeScalar(39)))
            if (cleanVal.hasPrefix(q) && cleanVal.hasSuffix(q)) || (cleanVal.hasPrefix(sq) && cleanVal.hasSuffix(sq)) {
                cleanVal = String(cleanVal.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            switch barProp {
            case "col.window_title", "col.windowtitle", "window_title", "windowtitle":
                config.barColors.windowTitle = cleanVal
            case "col.workspaces_inactive", "col.workspacesinactive", "workspaces_inactive", "workspacesinactive",
                 "col.workspaces_text", "workspaces_text":
                config.barColors.workspacesInactive = cleanVal
            case "col.workspaces_active_bg", "col.workspacesactivebg", "workspaces_active_bg", "workspacesactivebg",
                 "col.workspaces_active", "workspaces_active":
                config.barColors.workspacesActiveBg = cleanVal
            case "col.workspaces_active_fg", "col.workspacesactivefg", "workspaces_active_fg", "workspacesactivefg",
                 "col.workspaces_active_text", "workspaces_active_text":
                config.barColors.workspacesActiveFg = cleanVal
            case "col.battery", "battery":
                config.barColors.battery = cleanVal
            case "col.clock", "col.time":
                config.barColors.clock = cleanVal
            case "clock", "time":
                if cleanVal.lowercased() == "12h" || cleanVal.lowercased() == "12" || cleanVal.lowercased() == "12-hour" {
                    config.clockFormat = "h:mm a  EEE"
                } else if cleanVal.lowercased() == "24h" || cleanVal.lowercased() == "24" || cleanVal.lowercased() == "24-hour" {
                    config.clockFormat = "HH:mm  EEE"
                } else {
                    config.barColors.clock = cleanVal
                }
            case "clock_format", "clockformat", "time_format", "timeformat", "format_clock", "format_time":
                if cleanVal.lowercased() == "12h" || cleanVal.lowercased() == "12" || cleanVal.lowercased() == "12-hour" {
                    config.clockFormat = "h:mm a  EEE"
                } else if cleanVal.lowercased() == "24h" || cleanVal.lowercased() == "24" || cleanVal.lowercased() == "24-hour" {
                    config.clockFormat = "HH:mm  EEE"
                } else {
                    var fmt = cleanVal
                    if fmt.hasPrefix("{:") && fmt.hasSuffix("}") {
                        fmt = String(fmt.dropFirst(2).dropLast(1)).trimmingCharacters(in: .whitespaces)
                    }
                    config.clockFormat = convertStrftimeToDateFormat(fmt)
                }
            case "clock_12h", "clock12h", "time_12h", "time12h":
                if parseBool(cleanVal) == true {
                    config.clockFormat = "h:mm a  EEE"
                } else if parseBool(cleanVal) == false {
                    config.clockFormat = "HH:mm  EEE"
                }
            case "col.volume", "volume":
                config.barColors.volume = cleanVal
            case "col.network", "network", "col.wifi", "wifi":
                config.barColors.network = cleanVal
            case "col.cpu", "cpu":
                config.barColors.cpu = cleanVal
            case "col.memory", "memory", "col.mem", "mem":
                config.barColors.memory = cleanVal
            case "col.notification", "notification":
                config.barColors.notification = cleanVal
            case "col.power", "power":
                config.barColors.power = cleanVal
            case "col.surface", "surface", "col.background", "background":
                config.barColors.surface = cleanVal
            case "opacity", "alpha", "capsule_alpha", "capsulealpha", "bar_opacity", "baropacity":
                if let d = Double(cleanVal) { config.barOpacity = d }
            default:
                break
            }
        }


        switch normalizedKey.lowercased() {
        case "gaps_in", "gapsin":
            if let d = Double(rawVal) { config.gapsIn = CGFloat(d) }
        case "gaps_out", "gapsout":
            if let d = Double(rawVal) { config.gapsOut = CGFloat(d) }
        case "border_size", "bordersize":
            if let i = Int(rawVal) { config.borderSize = i }
        case "border_mode", "bordermode":
            let lower = rawVal.trimmingCharacters(in: .whitespaces).lowercased()
            if let m = BorderMode(rawValue: lower) {
                config.borderMode = m
            } else if lower == "halo" || lower == "glass" || lower == "glasshalo" {
                config.borderMode = .glassHalo
            } else if lower == "neon" || lower == "outline" {
                config.borderMode = .outline
            }
        case "halo_padding", "halopadding":
            if let d = Double(rawVal) { config.haloPadding = CGFloat(d) }
        case "active_opacity", "activeopacity", "window_opacity", "windowopacity":
            if let d = Double(rawVal) { config.windowOpacity = d }
        case "inactive_opacity", "inactiveopacity":
            if let d = Double(rawVal) { config.inactiveOpacity = d }
        case "strip_decorations", "stripdecorations", "hide_window_decorations", "hidewindowdecorations":
            if let b = parseBool(rawVal) { config.stripDecorations = b }
        case "ignore_client", "ignoreclient", "ignore_opacity", "ignoreopacity":
            let items = rawVal.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if !items.isEmpty { config.ignoredClientApps = items }
        case "rounding":
            if let d = Double(rawVal) { config.rounding = CGFloat(d) }
        case "active_border", "col.active_border":
            let colors = parseColors(rawVal)
            if !colors.isEmpty { config.activeBorderGradient = colors }
        case "inactive_border", "col.inactive_border":
            let colors = parseColors(rawVal)
            if let first = colors.first { config.inactiveBorderColor = first }
        default:
            let lowerNormalized = normalizedKey.lowercased()
            if lowerNormalized.contains("border_mode") || lowerNormalized.contains("bordermode") {
                let lower = rawVal.trimmingCharacters(in: .whitespaces).lowercased()
                if let m = BorderMode(rawValue: lower) {
                    config.borderMode = m
                } else if lower == "halo" || lower == "glass" || lower == "glasshalo" {
                    config.borderMode = .glassHalo
                } else if lower == "neon" || lower == "outline" {
                    config.borderMode = .outline
                }
            } else if lowerNormalized.contains("halo_padding") || lowerNormalized.contains("halopadding") {
                if let d = Double(rawVal) { config.haloPadding = CGFloat(d) }
            } else if lowerNormalized.contains("active_opacity") || lowerNormalized.contains("window_opacity") {
                if let d = Double(rawVal) { config.windowOpacity = d }
            } else if lowerNormalized.contains("inactive_opacity") || lowerNormalized.contains("inactiveopacity") {
                if let d = Double(rawVal) { config.inactiveOpacity = d }
            } else if lowerNormalized.contains("strip_decorations") || lowerNormalized.contains("hide_window_decorations") {
                if let b = parseBool(rawVal) { config.stripDecorations = b }
            } else if lowerNormalized.contains("ignore_client") || lowerNormalized.contains("ignore_opacity") {
                let items = rawVal.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                if !items.isEmpty { config.ignoredClientApps = items }
            } else if rawKey.lowercased().contains("active_border") {
                let colors = parseColors(rawVal)
                if !colors.isEmpty { config.activeBorderGradient = colors }
            } else if rawKey.lowercased().contains("inactive_border") {
                let colors = parseColors(rawVal)
                if let first = colors.first { config.inactiveBorderColor = first }
            }
        }
    }

    // MARK: - Helper Parsers

    private static func parseBool(_ raw: String) -> Bool? {
        let val = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch val {
        case "yes", "true", "1", "on":
            return true
        case "no", "false", "0", "off":
            return false
        default:
            return nil
        }
    }

    private static func stripComment(from line: String) -> String {
        var result = ""
        var insideQuotes = false
        var quoteChar: Character? = nil

        for char in line {
            if char == "\"" || char == "'" {
                if insideQuotes && quoteChar == char {
                    insideQuotes = false
                    quoteChar = nil
                } else if !insideQuotes {
                    insideQuotes = true
                    quoteChar = char
                }
                result.append(char)
            } else if char == "#" && !insideQuotes {
                break
            } else {
                result.append(char)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func expandVariables(in string: String, variables: [String: String]) -> String {
        guard string.contains("$") else { return string }

        var result = string
        // Match both ${var} and $var
        let pattern = "\\$(\\{([a-zA-Z0-9_]+)\\}|([a-zA-Z0-9_]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }

        let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = regex.matches(in: result, range: nsRange)

        for match in matches.reversed() {
            guard let varRange = Range(match.range, in: result) else { continue }
            let fullMatch = String(result[varRange])

            var varName = ""
            if match.numberOfRanges > 2, let r1 = Range(match.range(at: 2), in: result) {
                varName = String(result[r1])
            } else if match.numberOfRanges > 3, let r2 = Range(match.range(at: 3), in: result) {
                varName = String(result[r2])
            }

            if let val = variables[fullMatch] ?? variables["$" + varName] ?? variables[varName] {
                result.replaceSubrange(varRange, with: val)
            }
        }
        return result
    }

    private static func parseBindingTokens(_ raw: String, flags: String = "") -> HyprBinding {
        var tokens: [String] = []
        var current = ""
        var insideQuotes = false
        var quoteChar: Character? = nil

        for char in raw {
            if char == "\"" || char == "'" {
                if insideQuotes && quoteChar == char {
                    insideQuotes = false
                    quoteChar = nil
                } else if !insideQuotes {
                    insideQuotes = true
                    quoteChar = char
                }
                current.append(char)
            } else if char == "," && !insideQuotes && tokens.count < 3 {
                tokens.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        tokens.append(current.trimmingCharacters(in: .whitespaces))

        let mod = tokens.count > 0 ? tokens[0] : ""
        let key = tokens.count > 1 ? tokens[1] : ""
        let dispatcher = tokens.count > 2 ? tokens[2] : ""
        let args = tokens.count > 3 ? tokens[3] : ""

        return HyprBinding(flags: flags, mod: mod, key: key, dispatcher: dispatcher, args: args)
    }

    private static func parseColors(_ input: String) -> [UInt32] {
        var results: [UInt32] = []
        let tokens = input.components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;")))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for token in tokens {
            if token.hasSuffix("deg") { continue }
            if let c = parseSingleColor(token) {
                results.append(c)
            }
        }
        return results
    }

    private static func parseSingleColor(_ rawToken: String) -> UInt32? {
        let token = rawToken.trimmingCharacters(in: .whitespaces)
        if token.hasSuffix("deg") { return nil }

        // rgba(hex) e.g. rgba(33ccffee)
        if token.lowercased().hasPrefix("rgba(") && token.hasSuffix(")") {
            var inner = String(token.dropFirst(5).dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.lowercased().hasPrefix("0x") { inner = String(inner.dropFirst(2)) }
            if inner.contains(",") {
                let parts = inner.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 4,
                   let r = UInt32(parts[0]),
                   let g = UInt32(parts[1]),
                   let b = UInt32(parts[2]) {
                    let a: UInt32
                    if let aDouble = Double(parts[3]) {
                        a = UInt32(min(max(aDouble <= 1.0 ? aDouble * 255.0 : aDouble, 0), 255))
                    } else if let aInt = UInt32(parts[3]) {
                        a = min(aInt, 255)
                    } else {
                        a = 255
                    }
                    return ((r & 0xFF) << 24) | ((g & 0xFF) << 16) | ((b & 0xFF) << 8) | (a & 0xFF)
                }
            }
            if inner.count == 8, let hex = UInt32(inner, radix: 16) {
                return hex
            } else if inner.count == 6, let hex = UInt32(inner, radix: 16) {
                return (hex << 8) | 0xFF
            }
        }

        // rgb(hex) e.g. rgb(33ccff)
        if token.lowercased().hasPrefix("rgb(") && token.hasSuffix(")") {
            var inner = String(token.dropFirst(4).dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.lowercased().hasPrefix("0x") { inner = String(inner.dropFirst(2)) }
            if inner.contains(",") {
                let parts = inner.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count >= 3,
                   let r = UInt32(parts[0]),
                   let g = UInt32(parts[1]),
                   let b = UInt32(parts[2]) {
                    return ((r & 0xFF) << 24) | ((g & 0xFF) << 16) | ((b & 0xFF) << 8) | 0xFF
                }
            }
            if inner.count == 6, let hex = UInt32(inner, radix: 16) {
                return (hex << 8) | 0xFF
            } else if inner.count == 8, let hex = UInt32(inner, radix: 16) {
                return hex
            }
        }

        // 0x... hex
        if token.lowercased().hasPrefix("0x") {
            let inner = String(token.dropFirst(2))
            if inner.count == 8, let hex = UInt32(inner, radix: 16) {
                return hex
            } else if inner.count == 6, let hex = UInt32(inner, radix: 16) {
                return (hex << 8) | 0xFF
            }
        }

        // #... hex
        if token.hasPrefix("#") {
            let inner = String(token.dropFirst(1))
            if inner.count == 8, let hex = UInt32(inner, radix: 16) {
                return hex
            } else if inner.count == 6, let hex = UInt32(inner, radix: 16) {
                return (hex << 8) | 0xFF
            }
        }

        // Raw hex string
        if token.count == 8, let hex = UInt32(token, radix: 16) {
            return hex
        } else if token.count == 6, let hex = UInt32(token, radix: 16) {
            return (hex << 8) | 0xFF
        }

        return nil
    }

    /// Converts strftime-style format specifiers to DateFormatter format specifiers.
    public static func convertStrftimeToDateFormat(_ format: String) -> String {
        guard format.contains("%") else { return format }
        var result = format
        let map: [(String, String)] = [
            ("%Y", "yyyy"),
            ("%y", "yy"),
            ("%B", "MMMM"),
            ("%b", "MMM"),
            ("%h", "MMM"),
            ("%m", "MM"),
            ("%d", "dd"),
            ("%e", "d"),
            ("%A", "EEEE"),
            ("%a", "EEE"),
            ("%H", "HH"),
            ("%I", "hh"),
            ("%l", "h"),
            ("%k", "H"),
            ("%M", "mm"),
            ("%S", "ss"),
            ("%p", "a"),
            ("%P", "a"),
            ("%R", "HH:mm"),
            ("%T", "HH:mm:ss")
        ]
        for (src, dst) in map {
            result = result.replacingOccurrences(of: src, with: dst)
        }
        return result
    }
}
