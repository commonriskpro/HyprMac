import XCTest
import SQLite3
@testable import HyprMac

final class NotificationTests: XCTestCase {

    // MARK: - 1. Notification Model Tests

    func testNotificationModelDefaultInitialization() {
        let notif = HyprNotification(
            appIdentifier: "com.apple.finder",
            appName: "Finder",
            title: "File Downloaded",
            body: "Document.pdf saved to Downloads",
            urgency: 2
        )

        XCTAssertFalse(notif.id.uuidString.isEmpty)
        XCTAssertEqual(notif.appIdentifier, "com.apple.finder")
        XCTAssertEqual(notif.appName, "Finder")
        XCTAssertEqual(notif.title, "File Downloaded")
        XCTAssertEqual(notif.body, "Document.pdf saved to Downloads")
        XCTAssertEqual(notif.urgency, 2)
        XCTAssertEqual(notif.formattedTimestamp, "now")
    }

    func testNotificationModelPropertyListDictionaryDecoding() {
        let testUUID = UUID()
        var uuidRaw = testUUID.uuid
        let uuidData = withUnsafeBytes(of: &uuidRaw) { Data($0) }
        let testDate = Date()

        // Test nested req dictionary
        let nestedDict: [String: Any] = [
            "app": "com.hnc.Discord",
            "uuid": uuidData,
            "req": [
                "titl": "New Mention",
                "body": "Hello world from HyprMac",
                "date": testDate
            ] as [String: Any],
            "styl": 2
        ]

        guard let decoded = HyprNotification(propertyListDictionary: nestedDict) else {
            XCTFail("Failed to decode nested plist dictionary")
            return
        }

        XCTAssertEqual(decoded.id, testUUID)
        XCTAssertEqual(decoded.appIdentifier, "com.hnc.Discord")
        XCTAssertEqual(decoded.title, "New Mention")
        XCTAssertEqual(decoded.body, "Hello world from HyprMac")
        XCTAssertEqual(decoded.urgency, 2)

        // Test flat keys (req.titl, req.body, req.date)
        let flatDict: [String: Any] = [
            "app": "com.apple.MobileSMS",
            "uuid": testUUID.uuidString,
            "req.titl": "Messages",
            "req.body": "Verification Code: 482910",
            "req.date": testDate.timeIntervalSinceReferenceDate
        ]

        guard let decodedFlat = HyprNotification(propertyListDictionary: flatDict) else {
            XCTFail("Failed to decode flat plist dictionary")
            return
        }

        XCTAssertEqual(decodedFlat.id, testUUID)
        XCTAssertEqual(decodedFlat.appIdentifier, "com.apple.MobileSMS")
        XCTAssertEqual(decodedFlat.title, "Messages")
        XCTAssertEqual(decodedFlat.body, "Verification Code: 482910")
    }

    func testNotificationModelBinaryDataDecoding() throws {
        let plistDict: [String: Any] = [
            "app": "com.apple.Terminal",
            "uuid": UUID().uuidString,
            "req": [
                "titl": "Build Succeeded",
                "body": "Compilation completed with 0 errors"
            ] as [String: Any]
        ]

        let binaryData = try PropertyListSerialization.data(
            fromPropertyList: plistDict,
            format: .binary,
            options: 0
        )

        let notif = HyprNotification.decode(from: binaryData)
        XCTAssertNotNil(notif)
        XCTAssertEqual(notif?.appIdentifier, "com.apple.Terminal")
        XCTAssertEqual(notif?.title, "Build Succeeded")
        XCTAssertEqual(notif?.body, "Compilation completed with 0 errors")
    }

    // MARK: - 2. Notification Center Manager & DND Tests

    @MainActor
    func testNotificationCenterManagerDNDSuppression() {
        let manager = NotificationCenterManager.shared
        manager.clearAll()
        manager.toastManager.dismissAll()

        // Phase 1: DND = false -> Toast should be presented and added to history
        manager.isDoNotDisturb = false
        manager.postNotification(
            title: "Task Alert",
            body: "Meeting starting in 5 minutes",
            appName: "Calendar",
            bundleId: "com.apple.iCal"
        )

        XCTAssertEqual(manager.history.count, 1)
        XCTAssertEqual(manager.history.first?.title, "Task Alert")
        XCTAssertEqual(manager.toastManager.activeToasts.count, 1)

        // Phase 2: DND = true -> Toast suppressed, but history recorded
        manager.toastManager.dismissAll()
        manager.isDoNotDisturb = true

        manager.postNotification(
            title: "Suppressed Notification",
            body: "This should not show a toast banner",
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap"
        )

        XCTAssertEqual(manager.history.count, 2)
        XCTAssertEqual(manager.history.first?.title, "Suppressed Notification")
        XCTAssertEqual(manager.toastManager.activeToasts.count, 0, "Toast banner must be suppressed when DND is active")

        // Reset DND for subsequent tests
        manager.isDoNotDisturb = false
        manager.clearAll()
    }

    @MainActor
    func testNotificationCenterManagerHistoryManagement() {
        let manager = NotificationCenterManager.shared
        manager.clearAll()

        manager.postNotification(title: "First", body: "1")
        manager.postNotification(title: "Second", body: "2")
        manager.postNotification(title: "Third", body: "3")

        XCTAssertEqual(manager.history.count, 3)
        XCTAssertEqual(manager.history[0].title, "Third", "History must store newest notifications at index 0")
        XCTAssertEqual(manager.history[1].title, "Second")
        XCTAssertEqual(manager.history[2].title, "First")

        // Remove specific notification
        let targetID = manager.history[1].id
        manager.removeNotification(id: targetID)

        XCTAssertEqual(manager.history.count, 2)
        XCTAssertFalse(manager.history.contains(where: { $0.id == targetID }))

        // Clear all
        manager.clearAll()
        XCTAssertTrue(manager.history.isEmpty)
    }

    // MARK: - 3. Toast Window Geometry & Stacking Tests

    @MainActor
    func testToastWindowGeometryAndStacking() {
        let manager = NotificationToastManager.shared
        manager.dismissAll()

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let expectedX = screenFrame.maxX - NotificationToastManager.toastWidth - NotificationToastManager.toastMarginRight

        // Present 3 toasts
        for idx in 1...3 {
            let notif = HyprNotification(
                appIdentifier: "app.\(idx)",
                appName: "App \(idx)",
                title: "Toast \(idx)",
                body: "Body \(idx)"
            )
            manager.present(notification: notif, animate: false)
        }

        XCTAssertEqual(manager.activeToasts.count, 3)

        // Check geometry and stacking
        for (idx, toast) in manager.activeToasts.enumerated() {
            XCTAssertEqual(toast.frame.width, NotificationToastManager.toastWidth, accuracy: 0.1)
            XCTAssertEqual(toast.frame.origin.x, expectedX, accuracy: 0.1)

            if idx > 0 {
                let prevToast = manager.activeToasts[idx - 1]
                let expectedTop = prevToast.frame.minY - NotificationToastManager.toastSpacing
                XCTAssertEqual(toast.frame.maxY, expectedTop, accuracy: 1.0)
            }
        }

        // Present beyond cap (max 5 concurrent toasts)
        for idx in 4...7 {
            let notif = HyprNotification(
                appIdentifier: "app.\(idx)",
                appName: "App \(idx)",
                title: "Toast \(idx)",
                body: "Body \(idx)"
            )
            manager.present(notification: notif, animate: false)
        }

        XCTAssertLessThanOrEqual(manager.activeToasts.count, NotificationToastManager.maxToasts)
        XCTAssertEqual(manager.activeToasts.count, 5, "Toast manager must cap at 5 concurrent toasts")

        manager.dismissAll()
    }

    // MARK: - 4. Drawer Geometry Tests

    @MainActor
    func testDrawerGeometry() {
        let drawer = NotificationCenterDrawer()
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let expectedX = screenFrame.maxX - NotificationCenterDrawer.drawerWidth - NotificationCenterDrawer.drawerMarginRight

        let (openFrame, closedFrame) = drawer.calculateFrames()
        XCTAssertEqual(openFrame.width, NotificationCenterDrawer.drawerWidth, accuracy: 0.1)
        XCTAssertEqual(openFrame.origin.x, expectedX, accuracy: 0.1)
        XCTAssertEqual(closedFrame.origin.x, screenFrame.maxX, accuracy: 0.1)

        drawer.openDrawer(animate: false)
        XCTAssertEqual(drawer.frame.width, NotificationCenterDrawer.drawerWidth, accuracy: 0.1)
        XCTAssertEqual(drawer.frame.origin.x, expectedX, accuracy: 0.1)
        XCTAssertTrue(drawer.isOpen)

        drawer.closeDrawer(animate: false)
        XCTAssertFalse(drawer.isOpen)
    }

    // MARK: - 5. Database Watcher SQLite Polling Test

    func testDatabaseWatcherSQLitePolling() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("hyprmac_test_(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let dbFile = tempDir.appendingPathComponent("db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbFile, &db), SQLITE_OK)

        let createTableSQL = """
        CREATE TABLE record (
            rec_id INTEGER PRIMARY KEY,
            app_id INTEGER,
            uuid BLOB,
            data BLOB,
            delivered_date REAL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, createTableSQL, nil, nil, nil), SQLITE_OK)

        // Insert sample record
        let samplePlist: [String: Any] = [
            "app": "com.apple.Notes",
            "uuid": UUID().uuidString,
            "req": [
                "titl": "Shared Note",
                "body": "Note updated by team"
            ] as [String: Any]
        ]
        let sampleData = try PropertyListSerialization.data(fromPropertyList: samplePlist, format: .binary, options: 0)

        let insertSQL = "INSERT INTO record (rec_id, app_id, data, delivered_date) VALUES (101, 1, ?, 814000000.0);"
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil), SQLITE_OK)
        _ = sampleData.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(sampleData.count), nil)
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
        sqlite3_close(db)

        // Instantiate watcher pointing to temporary database
        let watcher = NotificationDatabaseWatcher(databaseDirectory: tempDir.path)
        XCTAssertEqual(watcher.databasePath, dbFile)

        // Poll starting from lastRecID = 0
        let parsed = watcher.pollDatabase()
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.appIdentifier, "com.apple.Notes")
        XCTAssertEqual(parsed.first?.title, "Shared Note")
        XCTAssertEqual(parsed.first?.body, "Note updated by team")
        XCTAssertEqual(watcher.lastRecID, 101)

        // Second poll should return empty since no new records exist
        let secondPoll = watcher.pollDatabase()
        XCTAssertTrue(secondPoll.isEmpty)
    }
}
