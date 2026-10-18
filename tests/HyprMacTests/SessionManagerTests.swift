import XCTest
@testable import HyprMac

final class SessionManagerTests: XCTestCase {

    private final class CommandCallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(executable: String, arguments: [String])] = []

        func record(executable: String, arguments: [String]) {
            lock.lock()
            defer { lock.unlock() }
            calls.append((executable, arguments))
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls.count
        }

        var recordedCalls: [(executable: String, arguments: [String])] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    func testSessionModeRawValues() {
        XCTAssertEqual(SessionMode.hyprMac.rawValue, "hyprMac")
        XCTAssertEqual(SessionMode.aqua.rawValue, "aqua")
    }

    func testSessionModeToggled() {
        XCTAssertEqual(SessionMode.aqua.toggled, .hyprMac)
        XCTAssertEqual(SessionMode.hyprMac.toggled, .aqua)
    }

    func testSessionModeIsHyprMac() {
        XCTAssertTrue(SessionMode.hyprMac.isHyprMac)
        XCTAssertFalse(SessionMode.aqua.isHyprMac)
    }

    func testSessionModeIsAqua() {
        XCTAssertTrue(SessionMode.aqua.isAqua)
        XCTAssertFalse(SessionMode.hyprMac.isAqua)
    }

    func testSessionModeDisplayName() {
        XCTAssertFalse(SessionMode.hyprMac.displayName.isEmpty)
        XCTAssertFalse(SessionMode.aqua.displayName.isEmpty)
    }

    func testSessionModeCaseIterable() {
        XCTAssertEqual(SessionMode.allCases.count, 2)
        XCTAssertTrue(SessionMode.allCases.contains(.hyprMac))
        XCTAssertTrue(SessionMode.allCases.contains(.aqua))
    }

    func testSessionStateDefaults() {
        let state = SessionState()
        XCTAssertEqual(state.mode, .aqua)
        XCTAssertFalse(state.autoHideMenuBar)
        XCTAssertFalse(state.autoHideDock)
    }

    func testSessionStateEncoding() throws {
        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        let state = SessionState(
            mode: .hyprMac,
            updatedAt: fixedDate,
            autoHideMenuBar: true,
            autoHideDock: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionState.self, from: data)

        XCTAssertEqual(decoded, state)
    }

    func testSessionManagerInit() {
        let tmpPath = NSTemporaryDirectory() + "hyprtest-\(UUID().uuidString).json"
        let tmpKey = "org.hypr.test.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tmpPath)
            UserDefaults.standard.removeObject(forKey: tmpKey)
        }

        let manager = SessionManager(
            stateFilePath: tmpPath,
            userDefaultsKey: tmpKey,
            autoHideDockOnHyprMac: false,
            commandRunner: { _, _ in true }
        )

        XCTAssertEqual(manager.stateFilePath, tmpPath)
        XCTAssertEqual(manager.userDefaultsKey, tmpKey)
        XCTAssertFalse(manager.autoHideDockOnHyprMac)
        XCTAssertNotNil(manager.commandRunner)
    }

    func testSwitchToHyprMac() {
        let tmpPath = NSTemporaryDirectory() + "hyprtest-\(UUID().uuidString).json"
        let tmpKey = "org.hypr.test.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tmpPath)
            UserDefaults.standard.removeObject(forKey: tmpKey)
        }

        let manager = SessionManager(
            stateFilePath: tmpPath,
            userDefaultsKey: tmpKey,
            autoHideDockOnHyprMac: true,
            commandRunner: { _, _ in true }
        )

        let switched = manager.switchTo(mode: .hyprMac)
        XCTAssertTrue(switched)
        XCTAssertEqual(manager.getCurrentMode(), .hyprMac)
    }

    func testSwitchToAqua() {
        let tmpPath = NSTemporaryDirectory() + "hyprtest-\(UUID().uuidString).json"
        let tmpKey = "org.hypr.test.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tmpPath)
            UserDefaults.standard.removeObject(forKey: tmpKey)
        }

        let manager = SessionManager(
            stateFilePath: tmpPath,
            userDefaultsKey: tmpKey,
            autoHideDockOnHyprMac: true,
            commandRunner: { _, _ in true }
        )

        manager.switchTo(mode: .hyprMac)
        XCTAssertEqual(manager.getCurrentMode(), .hyprMac)

        let switchedBack = manager.switchTo(mode: .aqua)
        XCTAssertTrue(switchedBack)
        XCTAssertEqual(manager.getCurrentMode(), .aqua)
    }

    func testToggleSession() {
        let tmpPath = NSTemporaryDirectory() + "hyprtest-\(UUID().uuidString).json"
        let tmpKey = "org.hypr.test.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tmpPath)
            UserDefaults.standard.removeObject(forKey: tmpKey)
        }

        let manager = SessionManager(
            stateFilePath: tmpPath,
            userDefaultsKey: tmpKey,
            autoHideDockOnHyprMac: true,
            commandRunner: { _, _ in true }
        )

        XCTAssertEqual(manager.getCurrentMode(), .aqua)
        let mode1 = manager.toggleSession()
        XCTAssertEqual(mode1, .hyprMac)
        XCTAssertEqual(manager.getCurrentMode(), .hyprMac)

        let mode2 = manager.toggleSession()
        XCTAssertEqual(mode2, .aqua)
        XCTAssertEqual(manager.getCurrentMode(), .aqua)
    }

    func testStateFilePersistence() {
        let tmpPath = NSTemporaryDirectory() + "hyprtest-\(UUID().uuidString).json"
        let tmpKey = "org.hypr.test.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tmpPath)
            UserDefaults.standard.removeObject(forKey: tmpKey)
        }

        let manager1 = SessionManager(
            stateFilePath: tmpPath,
            userDefaultsKey: tmpKey,
            autoHideDockOnHyprMac: true,
            commandRunner: { _, _ in true }
        )
        manager1.switchTo(mode: .hyprMac)
        XCTAssertEqual(manager1.getCurrentMode(), .hyprMac)

        let dummyKey = "org.hypr.test.dummy.\(UUID().uuidString)"
        let manager2 = SessionManager(
            stateFilePath: tmpPath,
            userDefaultsKey: dummyKey,
            autoHideDockOnHyprMac: true,
            commandRunner: { _, _ in true }
        )
        XCTAssertEqual(manager2.getCurrentMode(), .hyprMac)
    }

    func testCommandRunnerCalled() {
        let tmpPath = NSTemporaryDirectory() + "hyprtest-\(UUID().uuidString).json"
        let tmpKey = "org.hypr.test.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tmpPath)
            UserDefaults.standard.removeObject(forKey: tmpKey)
        }

        let recorder = CommandCallRecorder()
        let manager = SessionManager(
            stateFilePath: tmpPath,
            userDefaultsKey: tmpKey,
            autoHideDockOnHyprMac: true,
            commandRunner: { executable, arguments in
                recorder.record(executable: executable, arguments: arguments)
                return true
            }
        )

        manager.switchTo(mode: .hyprMac)
        XCTAssertGreaterThan(recorder.callCount, 0)
        let calls = recorder.recordedCalls
        XCTAssertTrue(calls.contains { $0.executable.contains("defaults") })
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(atPath: SessionManager.menubarSuppressionFlag)
    }

    func testMenuBarSuppressionFlagLifecycle() {
        let flag = SessionManager.menubarSuppressionFlag
        try? FileManager.default.removeItem(atPath: flag)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag))

        SessionManager.apply(mode: .hyprMac)
        XCTAssertTrue(FileManager.default.fileExists(atPath: flag))

        SessionManager.apply(mode: .aqua)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag))
    }
}
