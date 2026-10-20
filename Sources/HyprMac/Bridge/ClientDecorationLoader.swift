import Cocoa
import Foundation

public final class ClientDecorationLoader: @unchecked Sendable {
    public static let shared = ClientDecorationLoader()

    public var ignoredApps: [String] = ["zen", "ghostty", "kitty"]

    private let lock = NSLock()
    private var attachedPIDs: Set<pid_t> = []
    private var launchObserverToken: (any NSObjectProtocol)?
    private var activateObserverToken: (any NSObjectProtocol)?
    private var termObserverToken: (any NSObjectProtocol)?
    private var isRunning: Bool = false
    private let queue = DispatchQueue(label: "org.hyprmac.decoration-loader", qos: .userInitiated)

    private init() {}

    public func start(stripDecorations: Bool) {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        guard stripDecorations else { return }

        // Symmetrically prune terminated PIDs
        termObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self else { return }
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self.lock.lock()
                self.attachedPIDs.remove(app.processIdentifier)
                self.lock.unlock()
            }
        }

        // Intercept newly launched applications
        launchObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self else { return }
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.attachIfNeeded(app: app, delay: 0.15)
        }

        // Intercept activated applications (dock, cmd-tab, launcher)
        activateObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self else { return }
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.attachIfNeeded(app: app, delay: 0.05)
        }

        // Attach to currently running regular GUI applications
        let running = NSWorkspace.shared.runningApplications
        for app in running {
            attachIfNeeded(app: app, delay: 0.05)
        }
    }

    public func reloadOpacity() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("org.hyprmac.reload_opacity"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = false

        if let token = launchObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            launchObserverToken = nil
        }
        if let token = activateObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            activateObserverToken = nil
        }
        if let token = termObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            termObserverToken = nil
        }
        attachedPIDs.removeAll()
    }

    public func attachIfNeeded(pid: pid_t) {
        guard pid > 0 && pid != getpid() else { return }
        lock.lock()
        if attachedPIDs.contains(pid) {
            lock.unlock()
            return
        }
        lock.unlock()

        let app = NSRunningApplication(processIdentifier: pid)
        if let a = app {
            attachIfNeeded(app: a, delay: 0.05)
        } else {
            lock.lock()
            if attachedPIDs.contains(pid) {
                lock.unlock()
                return
            }
            attachedPIDs.insert(pid)
            lock.unlock()

            queue.async { [weak self] in
                guard let self = self else { return }
                self.performAttachment(pid: pid, appName: "PID \(pid)", bundleId: "")
            }
        }
    }

    public func attachIfNeeded(app: NSRunningApplication, delay: TimeInterval = 0.05) {
        guard app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        guard pid > 0 && pid != getpid() else { return }

        lock.lock()
        if attachedPIDs.contains(pid) {
            lock.unlock()
            return
        }
        attachedPIDs.insert(pid)
        lock.unlock()

        let appName = app.localizedName ?? "App"
        let bundleId = app.bundleIdentifier ?? ""
        let appLower = appName.lowercased()
        let bundleLower = bundleId.lowercased()

        lock.lock()
        for ignored in ignoredApps {
            let ig = ignored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !ig.isEmpty && (appLower.contains(ig) || bundleLower.contains(ig)) {
                lock.unlock()
                print("[HyprMac] Skipping client attachment for self-theming app: \(appName) (\(bundleId))")
                fflush(stdout)
                return
            }
        }
        lock.unlock()

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.performAttachment(pid: pid, appName: appName, bundleId: bundleId)
        }
    }

    private func performAttachment(pid: pid_t, appName: String, bundleId: String) {
        guard kill(pid, 0) == 0 else {
            lock.lock()
            attachedPIDs.remove(pid)
            lock.unlock()
            return
        }

        guard let injectBin = resolveBinary(name: "hypr-inject") else {
            print("[HyprMac] hypr-inject binary not found. Skipping client attachment.")
            fflush(stdout)
            return
        }

        guard let baseDylib = resolveBinary(name: "libhyprclient.dylib") else {
            print("[HyprMac] libhyprclient.dylib not found. Skipping client attachment.")
            fflush(stdout)
            return
        }

        var targetDylib = baseDylib
        let home = NSHomeDirectory()
        let containerPath = home + "/Library/Containers/" + bundleId

        if !bundleId.isEmpty && FileManager.default.fileExists(atPath: containerPath) {
            let containerTmp = containerPath + "/Data/tmp"
            let containerDylib = containerTmp + "/libhyprclient.dylib"
            do {
                try FileManager.default.createDirectory(atPath: containerTmp, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: containerDylib) {
                    try FileManager.default.copyItem(atPath: baseDylib, toPath: containerDylib)
                }
                targetDylib = containerDylib
            } catch {
            }
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: injectBin)
        task.arguments = [String(pid), targetDylib, "--suspend"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                print("[HyprMac] Successfully attached client decoration stripper to " + appName + " (PID: " + String(pid) + ")")
                fflush(stdout)
            } else {
                print("[HyprMac] Failed to attach client decoration stripper to " + appName + " (PID: " + String(pid) + ", exit " + String(task.terminationStatus) + ")")
                fflush(stdout)
            }
        } catch {
            print("[HyprMac] Error invoking hypr-inject for " + appName + " (PID: " + String(pid) + "): " + error.localizedDescription)
            fflush(stdout)
        }
    }

    private func resolveBinary(name: String) -> String? {
        let home = NSHomeDirectory()
        let searchPaths = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(name).path,
            home + "/Developer/REA/build/" + name,
            home + "/.config/hypr/" + name,
            "/usr/local/bin/" + name,
            "/usr/local/lib/" + name
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
}
