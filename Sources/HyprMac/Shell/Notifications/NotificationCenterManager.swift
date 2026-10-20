import Cocoa
import Foundation

/// Primary coordinator for the native HyprMac notification subsystem.
/// Manages database watcher, notification history, DND state, toast stacking, and drawer presentation.
@MainActor
public final class NotificationCenterManager {
    public static let shared = NotificationCenterManager()
    public static let stateDidChangeNotification = Notification.Name("HyprMac.NotificationCenterStateDidChange")

    public private(set) var watcher: NotificationDatabaseWatcher?
    public private(set) var history: [HyprNotification] = []
    public var isDoNotDisturb: Bool = false {
        didSet {
            notifyStateChanged()
        }
    }

    public private(set) var drawer: NotificationCenterDrawer?
    public private(set) var toastManager: NotificationToastManager = .shared
    public var onStateChange: (@MainActor () -> Void)?

    public static let maxHistoryCount = 100

    public init() {}

    /// Starts native usernoted database monitoring and initializes components.
    public func start() {
        guard watcher == nil else { return }
        let w = NotificationDatabaseWatcher()
        w.onNewNotification = { [weak self] item in
            self?.handleIncomingNotification(item)
        }
        self.watcher = w
        w.start()
    }

    /// Stops native usernoted database monitoring.
    public func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Ingests a new notification. If DND is inactive, presents toast; always appends to history.
    public func handleIncomingNotification(_ notification: HyprNotification) {
        // Insert newest notification at top of history
        history.insert(notification, at: 0)
        if history.count > Self.maxHistoryCount {
            history.removeLast()
        }

        // Toast presentation (suppressed if Do Not Disturb is active)
        if !isDoNotDisturb {
            toastManager.present(notification: notification)
        }

        // Refresh active drawer if open
        drawer?.reloadHistory()
        notifyStateChanged()
    }

    /// Posts an internal / programmatic notification.
    public func postNotification(
        title: String,
        body: String,
        appName: String? = nil,
        bundleId: String? = nil,
        icon: NSImage? = nil,
        urgency: Int = 1
    ) {
        let notif = HyprNotification(
            id: UUID(),
            appIdentifier: bundleId ?? "",
            appName: appName,
            title: title,
            body: body,
            date: Date(),
            urgency: urgency,
            icon: icon
        )
        handleIncomingNotification(notif)
    }

    /// Toggles the notification center slide-in drawer.
    public func toggleDrawer() {
        if drawer == nil {
            drawer = NotificationCenterDrawer()
        }
        drawer?.toggleDrawer()
    }

    /// Opens the notification center slide-in drawer.
    public func openDrawer() {
        if drawer == nil {
            drawer = NotificationCenterDrawer()
        }
        drawer?.openDrawer()
    }

    /// Closes the notification center slide-in drawer.
    public func closeDrawer() {
        drawer?.closeDrawer()
    }

    /// Removes a notification from history by its UUID.
    public func removeNotification(id: UUID) {
        history.removeAll(where: { $0.id == id })
        drawer?.reloadHistory()
        notifyStateChanged()
    }

    /// Clears all notifications from history.
    public func clearAll() {
        history.removeAll()
        drawer?.reloadHistory()
        notifyStateChanged()
    }

    private func notifyStateChanged() {
        onStateChange?()
        NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: self)
    }
}
