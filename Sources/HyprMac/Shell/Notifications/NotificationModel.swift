import Cocoa
import Foundation

/// Native notification model matching SwayNC / mxmrn representation.
public struct HyprNotification: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let appIdentifier: String
    public let appName: String
    public let title: String
    public let body: String
    public let date: Date
    public let urgency: Int
    public let icon: NSImage?

    public init(
        id: UUID = UUID(),
        appIdentifier: String,
        appName: String? = nil,
        title: String,
        body: String,
        date: Date = Date(),
        urgency: Int = 1,
        icon: NSImage? = nil
    ) {
        self.id = id
        self.appIdentifier = appIdentifier
        self.title = title
        self.body = body
        self.date = date
        self.urgency = urgency

        let resolvedName: String
        if let explicitName = appName, !explicitName.isEmpty {
            resolvedName = explicitName
        } else if !appIdentifier.isEmpty {
            resolvedName = Self.resolveAppName(for: appIdentifier)
        } else {
            resolvedName = "Notification"
        }
        self.appName = resolvedName

        if let explicitIcon = icon {
            self.icon = explicitIcon
        } else if !appIdentifier.isEmpty {
            self.icon = Self.resolveAppIcon(for: appIdentifier)
        } else {
            self.icon = nil
        }
    }

    public static func == (lhs: HyprNotification, rhs: HyprNotification) -> Bool {
        lhs.id == rhs.id
    }

    /// Resolves human-friendly display name from a macOS bundle identifier.
    public static func resolveAppName(for bundleIdentifier: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            if let localizedName = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) {
                return localizedName
            }
            return url.deletingPathExtension().lastPathComponent
        }
        let components = bundleIdentifier.split(separator: ".")
        if let last = components.last, !last.isEmpty {
            let s = String(last)
            return s.prefix(1).uppercased() + s.dropFirst()
        }
        return bundleIdentifier
    }

    /// Resolves 48x48 app icon from a macOS bundle identifier.
    public static func resolveAppIcon(for bundleIdentifier: String) -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let img = NSWorkspace.shared.icon(forFile: url.path)
            img.size = NSSize(width: 48, height: 48)
            return img
        }
        return nil
    }

    /// Parses a notification dictionary from Apple's binary property list format.
    /// Supports keys `app`, `req.titl`, `req.body`, `req.date`, `uuid`, and nested `req` dictionary.
    public init?(propertyListDictionary dict: [String: Any]) {
        // 1. Bundle identifier
        let appIdentifier: String
        if let app = dict["app"] as? String {
            appIdentifier = app
        } else if let app = dict["appIdentifier"] as? String {
            appIdentifier = app
        } else {
            appIdentifier = ""
        }

        // 2. UUID
        let id: UUID
        if let uuidData = dict["uuid"] as? Data, uuidData.count == 16 {
            let rawUUID: uuid_t = uuidData.withUnsafeBytes { $0.load(as: uuid_t.self) }
            id = UUID(uuid: rawUUID)
        } else if let uuidData = dict["uuid"] as? NSData, uuidData.length == 16 {
            var raw: uuid_t = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
            uuidData.getBytes(&raw, length: 16)
            id = UUID(uuid: raw)
        } else if let uuidStr = dict["uuid"] as? String, let parsed = UUID(uuidString: uuidStr) {
            id = parsed
        } else {
            id = UUID()
        }

        // 3. Request sub-dictionary (if present)
        let reqDict = dict["req"] as? [String: Any]

        // 4. Title
        let title: String
        if let t = dict["req.titl"] as? String {
            title = t
        } else if let t = reqDict?["titl"] as? String {
            title = t
        } else if let t = dict["title"] as? String {
            title = t
        } else {
            title = ""
        }

        // 5. Body
        let body: String
        if let b = dict["req.body"] as? String {
            body = b
        } else if let b = reqDict?["body"] as? String {
            body = b
        } else if let b = dict["body"] as? String {
            body = b
        } else {
            body = ""
        }

        // 6. Date
        let dateVal = dict["req.date"] ?? reqDict?["date"] ?? dict["date"]
        let date: Date
        if let d = dateVal as? Date {
            date = d
        } else if let dbl = dateVal as? Double {
            // Apple reference date (seconds since 2001-01-01) vs UNIX epoch
            if dbl > 500_000_000 && dbl < 2_000_000_000 {
                date = Date(timeIntervalSinceReferenceDate: dbl)
            } else {
                date = Date(timeIntervalSince1970: dbl)
            }
        } else {
            date = Date()
        }

        // 7. Urgency / Style
        let urgency = dict["urgency"] as? Int ?? (dict["styl"] as? Int ?? 1)

        self.init(
            id: id,
            appIdentifier: appIdentifier,
            appName: dict["appName"] as? String,
            title: title,
            body: body,
            date: date,
            urgency: urgency,
            icon: nil
        )
    }

    /// Deserializes binary parameter block data via PropertyListSerialization and parses a HyprNotification.
    public static func decode(from data: Data) -> HyprNotification? {
        do {
            var format = PropertyListSerialization.PropertyListFormat.binary
            let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
            if let dict = obj as? [String: Any] {
                return HyprNotification(propertyListDictionary: dict)
            }
        } catch {
            return nil
        }
        return nil
    }
}

extension HyprNotification {
    /// Human readable relative or formatted timestamp
    public var formattedTimestamp: String {
        let now = Date()
        let diff = now.timeIntervalSince(date)
        if diff < 0 {
            return "now"
        } else if diff < 60 {
            return "now"
        } else if diff < 3600 {
            return "\(Int(diff / 60))m ago"
        } else if diff < 86400 {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}
