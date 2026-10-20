import Foundation
import SQLite3

/// Monitors Apple's native notification database in ~/Library/Group Containers/group.com.apple.usernoted/db2
/// and emits parsed HyprNotification events via DispatchSource file system monitoring.
public final class NotificationDatabaseWatcher: @unchecked Sendable {
    public static let defaultDatabaseDirectory: String = NSString(
        string: "~/Library/Group Containers/group.com.apple.usernoted/db2"
    ).expandingTildeInPath

    public let databaseDirectory: String
    public let databasePath: String

    private let queue = DispatchQueue(label: "org.hyprland.hyprmac.notificationwatcher", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    public private(set) var lastRecID: Int64 = 0
    public private(set) var isRunning: Bool = false

    public var onNewNotification: (@MainActor @Sendable (HyprNotification) -> Void)?

    public init(databaseDirectory: String = NotificationDatabaseWatcher.defaultDatabaseDirectory) {
        self.databaseDirectory = databaseDirectory
        self.databasePath = (databaseDirectory as NSString).appendingPathComponent("db")
    }

    deinit {
        stop()
    }

    /// Starts file system observation and initializes baseline lastRecID.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // Initialize baseline lastRecID so we only emit new notifications
        initializeLastRecID()

        // Attempt to open directory or file for VNODE monitoring
        var targetPath = databaseDirectory
        var fd = open(targetPath, O_EVTONLY)
        if fd < 0 {
            targetPath = databasePath
            fd = open(targetPath, O_EVTONLY)
        }

        guard fd >= 0 else {
            // Still running in polling / manual mode even if file descriptor cannot be opened
            return
        }

        self.fileDescriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            _ = self?.pollDatabase()
        }

        src.setCancelHandler { [fd] in
            close(fd)
        }

        self.source = src
        src.resume()
    }

    /// Halts file system observation and releases open file descriptors.
    public func stop() {
        guard isRunning else { return }
        isRunning = false

        if let src = source {
            src.cancel()
            self.source = nil
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
        fileDescriptor = -1
    }

    /// Initializes the baseline record ID to MAX(rec_id) from the SQLite database.
    private func initializeLastRecID() {
        guard FileManager.default.fileExists(atPath: databasePath) else { return }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK else {
            if let db = db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let query = "SELECT MAX(rec_id) FROM record;"
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let maxID = sqlite3_column_int64(stmt, 0)
                self.lastRecID = maxID
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Queries SQLite table 'record' in read-only mode for newly inserted notifications.
    /// Returns any newly parsed HyprNotification items and triggers the main-actor callback.
    @discardableResult
    public func pollDatabase() -> [HyprNotification] {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return []
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK else {
            if let db = db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        let query = "SELECT rec_id, app_id, data, delivered_date FROM record WHERE rec_id > ? ORDER BY rec_id ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, lastRecID)

        var newNotifications: [HyprNotification] = []
        var highestRecID = lastRecID

        while sqlite3_step(stmt) == SQLITE_ROW {
            let recID = sqlite3_column_int64(stmt, 0)
            highestRecID = max(highestRecID, recID)

            guard let blobBytes = sqlite3_column_blob(stmt, 2) else {
                continue
            }
            let blobSize = sqlite3_column_bytes(stmt, 2)
            guard blobSize > 0 else { continue }

            let data = Data(bytes: blobBytes, count: Int(blobSize))
            if let notification = HyprNotification.decode(from: data) {
                newNotifications.append(notification)
            }
        }

        self.lastRecID = highestRecID

        if !newNotifications.isEmpty {
            let itemsToEmit = newNotifications
            DispatchQueue.main.async { [weak self] in
                for item in itemsToEmit {
                    self?.onNewNotification?(item)
                }
            }
        }

        return newNotifications
    }

    /// Manually sets the last processed record ID (used in tests or replay scenarios).
    public func setLastRecID(_ id: Int64) {
        self.lastRecID = id
    }
}
