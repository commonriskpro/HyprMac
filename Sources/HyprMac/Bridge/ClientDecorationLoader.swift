import Cocoa
import Foundation
import Darwin

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
            var pathBuf = [CChar](repeating: 0, count: 4096)
            let ret = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let procPath = ret > 0 ? String(cString: pathBuf) : ""
            let procName = URL(fileURLWithPath: procPath).lastPathComponent.lowercased()
            if !procName.isEmpty && isIgnored(appName: procName, bundleId: "") {
                print("[HyprMac] Skipping client attachment for ignored PID \(pid): \(procName)")
                fflush(stdout)
                return
            }

            lock.lock()
            if attachedPIDs.contains(pid) {
                lock.unlock()
                return
            }
            attachedPIDs.insert(pid)
            lock.unlock()

            queue.async { [weak self] in
                guard let self = self else { return }
                self.performAttachment(pid: pid, appName: procName.isEmpty ? "PID \(pid)" : procName, bundleId: "")
            }
        }
    }

    public func isIgnored(appName: String, bundleId: String) -> Bool {
        let appLower = appName.lowercased()
        let bundleLower = bundleId.lowercased()
        lock.lock()
        defer { lock.unlock() }
        for ignored in ignoredApps {
            let ig = ignored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !ig.isEmpty && (appLower.contains(ig) || bundleLower.contains(ig)) {
                return true
            }
        }
        return false
    }

    public func attachIfNeeded(app: NSRunningApplication, delay: TimeInterval = 0.05) {
        guard app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        guard pid > 0 && pid != getpid() else { return }

        let appName = app.localizedName ?? "App"
        let bundleId = app.bundleIdentifier ?? ""

        if isIgnored(appName: appName, bundleId: bundleId) {
            print("[HyprMac] Skipping client attachment for self-theming app: \(appName) (\(bundleId))")
            fflush(stdout)
            return
        }

        lock.lock()
        if attachedPIDs.contains(pid) {
            lock.unlock()
            return
        }
        attachedPIDs.insert(pid)
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

        // 1. Try instantaneous privileged helper socket (zero fork/exec subprocesses)
        if injectViaHelperSocket(pid: pid, dylibPath: targetDylib) {
            print("[HyprMac] Successfully attached client decoration stripper via helper daemon to " + appName + " (PID: " + String(pid) + ")")
            fflush(stdout)
            return
        }

        // 2. Fallback to CLI process execution if helper socket is unavailable
        guard let injectBin = resolveBinary(name: "hypr-inject") else {
            print("[HyprMac] hypr-inject binary not found. Skipping client attachment.")
            fflush(stdout)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: injectBin)
        task.arguments = [String(pid), targetDylib]
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

    private func injectViaHelperSocket(pid: pid_t, dylibPath: String) -> Bool {
        let sockPath = "/tmp/hyprmac-inject.sock"
        guard FileManager.default.fileExists(atPath: sockPath) else { return false }

        let sfd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sfd >= 0 else { return false }
        defer { close(sfd) }

        var timeout = timeval(tv_sec: 0, tv_usec: 200_000) // 200ms timeout
        setsockopt(sfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sfd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = sockPath.withCString { cstr in
                strncpy(ptr, cstr, maxLen - 1)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(sfd, saPtr, addrLen)
            }
        }

        guard connectRes == 0 else { return false }

        let cmdStr = "INJECT \(pid) \(dylibPath) 0\n"
        guard let data = cmdStr.data(using: .utf8) else { return false }

        let writeRes = data.withUnsafeBytes { raw in
            write(sfd, raw.baseAddress!, data.count)
        }
        guard writeRes == data.count else { return false }

        var respBuf = [UInt8](repeating: 0, count: 64)
        let n = read(sfd, &respBuf, 63)
        guard n > 0 else { return false }

        let resp = String(decoding: respBuf.prefix(n), as: UTF8.self)
        return resp.hasPrefix("OK")
    }

    private func resolveBinary(name: String) -> String? {
        let home = NSHomeDirectory()
        let searchPaths = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(name).path,
            FileManager.default.currentDirectoryPath + "/build/" + name,
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
