import Foundation

/// Data structure representing the persisted session state of HyprMac.
public struct SessionState: Codable, Equatable, Sendable {
    /// Current active desktop session mode.
    public var mode: SessionMode
    /// Timestamp of when the session state was last modified.
    public var updatedAt: Date
    /// Whether macOS native menu bar autohide is enabled.
    public var autoHideMenuBar: Bool
    /// Whether macOS Dock autohide is enabled.
    public var autoHideDock: Bool

    public init(
        mode: SessionMode = .aqua,
        updatedAt: Date = Date(),
        autoHideMenuBar: Bool = false,
        autoHideDock: Bool = false
    ) {
        self.mode = mode
        self.updatedAt = updatedAt
        self.autoHideMenuBar = autoHideMenuBar
        self.autoHideDock = autoHideDock
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case currentMode
        case updatedAt
        case autoHideMenuBar
        case autoHideDock
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let m = try? container.decode(SessionMode.self, forKey: .mode) {
            self.mode = m
        } else if let m = try? container.decode(SessionMode.self, forKey: .currentMode) {
            self.mode = m
        } else {
            self.mode = .aqua
        }

        if let date = try? container.decode(Date.self, forKey: .updatedAt) {
            self.updatedAt = date
        } else if let dateStr = try? container.decode(String.self, forKey: .updatedAt),
                  let date = ISO8601DateFormatter().date(from: dateStr) {
            self.updatedAt = date
        } else {
            self.updatedAt = Date()
        }

        self.autoHideMenuBar = (try? container.decode(Bool.self, forKey: .autoHideMenuBar)) ?? (self.mode == .hyprMac)
        self.autoHideDock = (try? container.decode(Bool.self, forKey: .autoHideDock)) ?? (self.mode == .hyprMac)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(autoHideMenuBar, forKey: .autoHideMenuBar)
        try container.encode(autoHideDock, forKey: .autoHideDock)
    }
}

/// Core session manager for toggling and persisting between HyprMac and traditional macOS Aqua desktop modes.
public final class SessionManager: @unchecked Sendable {
    /// Shared global singleton instance.
    public static let shared = SessionManager()

    /// Path to the interposer suppression flag file in /tmp.
    public static let menubarSuppressionFlag = "/tmp/hyprmac-menubar-suppressed"

    /// Signature for shell/process execution (abstracted for deterministic unit testing).
    public typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) -> Bool

    /// File path where JSON session state is persisted (~/.config/hypr/session.json by default).
    public let stateFilePath: String
    /// UserDefaults key used for fallback state mirroring.
    public let userDefaultsKey: String
    /// Whether to configure macOS Dock autohide when entering HyprMac mode.
    public var autoHideDockOnHyprMac: Bool
    /// Optional custom command executor closure.
    public var commandRunner: CommandRunner?

    private let lock = NSLock()

    public init(
        stateFilePath: String = "~/.config/hypr/session.json",
        userDefaultsKey: String = "org.hypr.sessionMode",
        autoHideDockOnHyprMac: Bool = true,
        commandRunner: CommandRunner? = nil
    ) {
        self.stateFilePath = stateFilePath
        self.userDefaultsKey = userDefaultsKey
        self.autoHideDockOnHyprMac = autoHideDockOnHyprMac
        self.commandRunner = commandRunner
    }

    // MARK: - State Inspection

    /// Returns the currently active session mode.
    public func getCurrentMode() -> SessionMode {
        return getCurrentState().mode
    }

    /// Reads and returns the complete persisted session state from JSON or UserDefaults fallback.
    public func getCurrentState() -> SessionState {
        lock.lock()
        defer { lock.unlock() }

        let expanded = (stateFilePath as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expanded)

        if FileManager.default.fileExists(atPath: expanded),
           let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let state = try? decoder.decode(SessionState.self, from: data) {
                return state
            }
        }

        // Fallback to UserDefaults
        if let rawMode = UserDefaults.standard.string(forKey: userDefaultsKey),
           let mode = SessionMode(rawValue: rawMode) {
            return SessionState(
                mode: mode,
                updatedAt: Date(),
                autoHideMenuBar: mode == .hyprMac,
                autoHideDock: mode == .hyprMac
            )
        }

        // Default state when neither file nor UserDefaults key exists
        return SessionState(mode: .aqua, updatedAt: Date(), autoHideMenuBar: false, autoHideDock: false)
    }

    // MARK: - Mode Switching

    /// Applies compositor-level and system integrations for the given session mode.
    public func apply(mode: SessionMode) {
        switch mode {
        case .hyprMac:
            setMenuBarAgentSuppressed(true)
            FileManager.default.createFile(atPath: SessionManager.menubarSuppressionFlag, contents: nil)
            _ = try? HyprServerBridge.shared.setMenuBarSuppression(suppress: true)
        case .aqua:
            setMenuBarAgentSuppressed(false)
            try? FileManager.default.removeItem(atPath: SessionManager.menubarSuppressionFlag)
            _ = try? HyprServerBridge.shared.setMenuBarSuppression(suppress: false)
        }
    }

    // MARK: - MenuBarAgent Lifecycle Management

    /// Controls whether the native macOS MenuBarAgent service is active.
    /// In HyprMac mode, unloads MenuBarAgent from the GUI session via launchctl so WindowServer
    /// never displays the native Apple menu bar upon window activation.
    /// In Aqua mode, reloads MenuBarAgent so the native menu bar is completely restored.
    public func setMenuBarAgentSuppressed(_ suppress: Bool) {
        let plist = "/System/Library/LaunchAgents/com.apple.MenuBarAgent.plist"
        let args = suppress ? ["unload", "-w", plist] : ["load", "-w", plist]
        _ = runCommand(executable: "/bin/launchctl", arguments: args)
    }

    /// Legacy compatibility hook.
    public func ensureMenuBarInterposerActive() {
        setMenuBarAgentSuppressed(true)
    }

    /// Transitions the system into the requested mode, applying system defaults and persisting state.
    @discardableResult
    public func switchTo(mode: SessionMode) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var commandSuccess = true

        switch mode {
        case .hyprMac:
            // 1. Hide native macOS menu bar: defaults write NSGlobalDomain _HIHideMenuBar -bool true
            let menuBarOk = runCommand(
                executable: "/usr/bin/defaults",
                arguments: ["write", "NSGlobalDomain", "_HIHideMenuBar", "-bool", "true"]
            )
            if !menuBarOk { commandSuccess = false }

            // 2. Hide Dock if configured: defaults write com.apple.dock autohide -bool true
            if autoHideDockOnHyprMac {
                let dockOk = runCommand(
                    executable: "/usr/bin/defaults",
                    arguments: ["write", "com.apple.dock", "autohide", "-bool", "true"]
                )
                if !dockOk { commandSuccess = false }

                // Restart Dock to apply autohide changes immediately
                _ = runCommand(
                    executable: "/usr/bin/killall",
                    arguments: ["Dock"]
                )
            }

        case .aqua:
            // 1. Restore native macOS menu bar: defaults write NSGlobalDomain _HIHideMenuBar -bool false
            let menuBarOk = runCommand(
                executable: "/usr/bin/defaults",
                arguments: ["write", "NSGlobalDomain", "_HIHideMenuBar", "-bool", "false"]
            )
            if !menuBarOk { commandSuccess = false }

            // 2. Restore traditional Dock: defaults write com.apple.dock autohide -bool false
            let dockOk = runCommand(
                executable: "/usr/bin/defaults",
                arguments: ["write", "com.apple.dock", "autohide", "-bool", "false"]
            )
            if !dockOk { commandSuccess = false }

            // Restart Dock to apply autohide changes immediately
            _ = runCommand(
                executable: "/usr/bin/killall",
                arguments: ["Dock"]
            )
        }

        // 3. Apply compositor-level hooks (menu bar suppression)
        apply(mode: mode)

        // 4. Persist new state to JSON and UserDefaults
        let newState = SessionState(
            mode: mode,
            updatedAt: Date(),
            autoHideMenuBar: mode == .hyprMac,
            autoHideDock: mode == .hyprMac && autoHideDockOnHyprMac
        )
        let saveSuccess = persistState(newState)

        return commandSuccess && saveSuccess
    }

    /// Toggles between Aqua and HyprMac modes.
    @discardableResult
    public func toggleSession() -> SessionMode {
        let current = getCurrentMode()
        let target: SessionMode = (current == .aqua) ? .hyprMac : .aqua
        _ = switchTo(mode: target)
        return getCurrentMode()
    }

    // MARK: - Static Convenience Accessors

    /// Global convenience to retrieve current session mode.
    public static func getCurrentMode() -> SessionMode {
        return shared.getCurrentMode()
    }

    /// Global convenience to apply compositor integrations for a given mode.
    public static func apply(mode: SessionMode) {
        shared.apply(mode: mode)
    }

    /// Global convenience to ensure MenuBarAgent interposer is installed and active.
    public static func ensureMenuBarInterposerActive() {
        shared.ensureMenuBarInterposerActive()
    }

    /// Global convenience to switch session mode.
    @discardableResult
    public static func switchTo(mode: SessionMode) -> Bool {
        return shared.switchTo(mode: mode)
    }

    /// Global convenience to toggle session mode.
    @discardableResult
    public static func toggleSession() -> SessionMode {
        return shared.toggleSession()
    }

    // MARK: - Internal Helpers

    private func runCommand(executable: String, arguments: [String]) -> Bool {
        if let customRunner = self.commandRunner {
            return customRunner(executable, arguments)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func persistState(_ state: SessionState) -> Bool {
        var fileSaved = true

        // 1. Save to JSON file
        let expanded = (stateFilePath as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expanded)
        let dirURL = fileURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("[-] SessionManager: Failed to write session state to \(expanded): \(error)")
            fileSaved = false
        }

        // 2. Mirror to UserDefaults for instant availability
        UserDefaults.standard.set(state.mode.rawValue, forKey: userDefaultsKey)
        UserDefaults.standard.synchronize()

        return fileSaved
    }

    // MARK: - Self-Test Suite

    /// Validates session serialization, mode switching, command dispatching, and configuration consistency.
    @discardableResult
    public static func runSelfTest() -> Bool {
        print("=== [SessionManager Self-Test] ===")
        var allPassed = true

        func assertCond(_ condition: Bool, _ message: String) {
            if condition {
                print("  [✓] \(message)")
            } else {
                print("  [✗] FAILED: \(message)")
                allPassed = false
            }
        }

        // 1. Test SessionMode enum representation and conversions
        assertCond(SessionMode.hyprMac.rawValue == "hyprMac", "SessionMode.hyprMac raw value is 'hyprMac'")
        assertCond(SessionMode.aqua.rawValue == "aqua", "SessionMode.aqua raw value is 'aqua'")
        assertCond(SessionMode.hyprMac.isHyprMac && !SessionMode.hyprMac.isAqua, "SessionMode.hyprMac flags are correct")
        assertCond(SessionMode.aqua.isAqua && !SessionMode.aqua.isHyprMac, "SessionMode.aqua flags are correct")
        assertCond(SessionMode.hyprMac.toggled == .aqua, "SessionMode.hyprMac toggles to .aqua")
        assertCond(SessionMode.aqua.toggled == .hyprMac, "SessionMode.aqua toggles to .hyprMac")

        // 2. Test JSON Encoding and Decoding of SessionState
        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        let testState = SessionState(mode: .hyprMac, updatedAt: fixedDate, autoHideMenuBar: true, autoHideDock: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encodedData = try? encoder.encode(testState) else {
            assertCond(false, "Failed to encode SessionState to JSON")
            return false
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decodedState = try? decoder.decode(SessionState.self, from: encodedData) else {
            assertCond(false, "Failed to decode SessionState from JSON")
            return false
        }
        assertCond(decodedState.mode == .hyprMac, "Decoded SessionState mode matches .hyprMac")
        assertCond(decodedState.autoHideMenuBar == true, "Decoded SessionState autoHideMenuBar is true")
        assertCond(decodedState.autoHideDock == true, "Decoded SessionState autoHideDock is true")

        // 3. Test Backward-compatibility / Alternative decoding formats
        let legacyJSON = """
        {
            "currentMode": "hyprmac",
            "updatedAt": "2024-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        if let legacyState = try? decoder.decode(SessionState.self, from: legacyJSON) {
            assertCond(legacyState.mode == .hyprMac, "Alternative 'currentMode' key and lowercase 'hyprmac' decode to .hyprMac")
        } else {
            assertCond(false, "Failed to decode legacy JSON format")
        }

        // 4. Test Isolated SessionManager with Mock Command Runner
        final class CommandRecorder: @unchecked Sendable {
            private let recLock = NSLock()
            private var commands: [(executable: String, arguments: [String])] = []

            func record(executable: String, arguments: [String]) {
                recLock.lock()
                defer { recLock.unlock() }
                commands.append((executable, arguments))
            }

            func getCommands() -> [(executable: String, arguments: [String])] {
                recLock.lock()
                defer { recLock.unlock() }
                return commands
            }

            func clear() {
                recLock.lock()
                defer { recLock.unlock() }
                commands.removeAll()
            }
        }

        let recorder = CommandRecorder()
        let tempDir = NSTemporaryDirectory()
        let tempFile = (tempDir as NSString).appendingPathComponent("hyprmac-session-test-\(UUID().uuidString).json")
        let tempKey = "org.hypr.test.\(UUID().uuidString)"

        let manager = SessionManager(
            stateFilePath: tempFile,
            userDefaultsKey: tempKey,
            autoHideDockOnHyprMac: true,
            commandRunner: { exe, args in
                recorder.record(executable: exe, arguments: args)
                return true
            }
        )

        // Initial mode should default to .aqua when file doesn't exist
        assertCond(manager.getCurrentMode() == .aqua, "Initial mode defaults to .aqua when no session file exists")

        // Test switchTo(.hyprMac)
        recorder.clear()
        let switchedToHypr = manager.switchTo(mode: .hyprMac)
        assertCond(switchedToHypr, "switchTo(.hyprMac) returned true")
        assertCond(manager.getCurrentMode() == .hyprMac, "getCurrentMode() reports .hyprMac")

        let hyprCmds = recorder.getCommands()
        let hasHideMenuBar = hyprCmds.contains { $0.executable.contains("defaults") && $0.arguments.contains("_HIHideMenuBar") && $0.arguments.contains("true") }
        let hasHideDock = hyprCmds.contains { $0.executable.contains("defaults") && $0.arguments.contains("com.apple.dock") && $0.arguments.contains("true") }
        let hasKillDock = hyprCmds.contains { $0.executable.contains("killall") && $0.arguments.contains("Dock") }
        assertCond(hasHideMenuBar, "Dispatched defaults write NSGlobalDomain _HIHideMenuBar -bool true")
        assertCond(hasHideDock, "Dispatched defaults write com.apple.dock autohide -bool true")
        assertCond(hasKillDock, "Dispatched killall Dock")

        // Verify file was written to disk and can be read independently
        assertCond(FileManager.default.fileExists(atPath: tempFile), "Session JSON file was written to disk")
        if let fileData = try? Data(contentsOf: URL(fileURLWithPath: tempFile)),
           let onDiskState = try? decoder.decode(SessionState.self, from: fileData) {
            assertCond(onDiskState.mode == .hyprMac, "On-disk session JSON contains mode .hyprMac")
        } else {
            assertCond(false, "Failed to read or parse on-disk session file")
        }

        // Test switchTo(.aqua)
        recorder.clear()
        let switchedToAqua = manager.switchTo(mode: .aqua)
        assertCond(switchedToAqua, "switchTo(.aqua) returned true")
        assertCond(manager.getCurrentMode() == .aqua, "getCurrentMode() reports .aqua")

        let aquaCmds = recorder.getCommands()
        let hasShowMenuBar = aquaCmds.contains { $0.executable.contains("defaults") && $0.arguments.contains("_HIHideMenuBar") && $0.arguments.contains("false") }
        let hasRestoreDock = aquaCmds.contains { $0.executable.contains("defaults") && $0.arguments.contains("com.apple.dock") && $0.arguments.contains("false") }
        assertCond(hasShowMenuBar, "Dispatched defaults write NSGlobalDomain _HIHideMenuBar -bool false")
        assertCond(hasRestoreDock, "Dispatched defaults write com.apple.dock autohide -bool false")

        // Test toggleSession()
        recorder.clear()
        let toggled1 = manager.toggleSession()
        assertCond(toggled1 == .hyprMac, "toggleSession() from .aqua transitions to .hyprMac")
        assertCond(manager.getCurrentMode() == .hyprMac, "State is .hyprMac after toggle")

        let toggled2 = manager.toggleSession()
        assertCond(toggled2 == .aqua, "toggleSession() from .hyprMac transitions to .aqua")
        assertCond(manager.getCurrentMode() == .aqua, "State is .aqua after toggle")

        // Test Corrupt Configuration Fallback
        try? "corrupt-json-non-parseable".write(toFile: tempFile, atomically: true, encoding: .utf8)
        let fallbackMode = manager.getCurrentMode()
        // Should fall back cleanly without fatal crash
        assertCond(fallbackMode == .aqua || fallbackMode == .hyprMac, "Corrupt session JSON handled gracefully without crashing")

        // Cleanup temporary test files
        try? FileManager.default.removeItem(atPath: tempFile)
        UserDefaults.standard.removeObject(forKey: tempKey)

        if allPassed {
            print("[+] SessionManager.runSelfTest() PASSED successfully!")
        } else {
            print("[-] SessionManager.runSelfTest() FAILED one or more checks.")
        }

        return allPassed
    }
}
