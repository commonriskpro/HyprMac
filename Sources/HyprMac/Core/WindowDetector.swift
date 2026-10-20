import Cocoa
import ApplicationServices
import CoreGraphics

public struct FocusedWindowInfo: Sendable, Equatable {
    public let windowID: CGWindowID
    public let processID: pid_t
    public let appName: String
    public let title: String
    public let bounds: CGRect
    public let appkitFrame: NSRect

    public init(
        windowID: CGWindowID,
        processID: pid_t,
        appName: String,
        title: String,
        bounds: CGRect,
        appkitFrame: NSRect
    ) {
        self.windowID = windowID
        self.processID = processID
        self.appName = appName
        self.title = title
        self.bounds = bounds
        self.appkitFrame = appkitFrame
    }
}

public final class WindowDetector: @unchecked Sendable {
    public static let shared = WindowDetector()

    private typealias AXUIElementGetWindowFunc = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private let _axGetWindow: AXUIElementGetWindowFunc?
    private let lock = NSLock()
    private var pidCache: [CGWindowID: pid_t] = [:]
    private var axElementCache: [CGWindowID: AXUIElement] = [:]
    private var _cachedFocusedWindow: FocusedWindowInfo?

    private init() {
        if let sym = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow") {
            self._axGetWindow = unsafeBitCast(sym, to: AXUIElementGetWindowFunc.self)
        } else {
            self._axGetWindow = nil
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notif in
            guard let self = self else { return }
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self.invalidateApplication(pid: app.processIdentifier)
            }
        }
    }

    /// Verifies if the current process has Accessibility privileges
    public static func isProcessTrusted(prompt: Bool = false) -> Bool {
        // "AXTrustedCheckOptionPrompt" is the constant string value of kAXTrustedCheckOptionPrompt.
        // Spelled out directly to satisfy Swift 6 strict concurrency (the global is mutable shared state).
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public var cachedFocusedWindow: FocusedWindowInfo? {
        lock.lock()
        defer { lock.unlock() }
        return _cachedFocusedWindow
    }

    public func setCachedFocusedWindow(_ info: FocusedWindowInfo?) {
        lock.lock()
        _cachedFocusedWindow = info
        lock.unlock()
    }

    /// Fast accessor returning the cached focused window from recent queries, falling back to full detection
    public func fastFocusedWindow() -> FocusedWindowInfo? {
        lock.lock()
        let cached = _cachedFocusedWindow
        lock.unlock()
        return cached ?? getFocusedWindow()
    }

    /// Detects the current focused active window across the entire macOS workspace
    public func getFocusedWindow() -> FocusedWindowInfo? {
        let result: FocusedWindowInfo?
        if let ax = getFocusedWindowAX(), ax.windowID > 0 {
            result = ax
        } else {
            result = getFrontmostWindowFromCGList()
        }
        lock.lock()
        _cachedFocusedWindow = result
        lock.unlock()
        return result
    }

    private func getFocusedWindowAX() -> FocusedWindowInfo? {
        var appElement: AXUIElement?
        var pid: pid_t = 0

        // Strategy 1: Try system-wide focused application
        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppVal: AnyObject?
        let sysErr = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppVal)

        if sysErr == .success, let val = focusedAppVal {
            let elem = val as! AXUIElement
            appElement = elem
            AXUIElementGetPid(elem, &pid)
        }

        // Strategy 2: Fallback to NSWorkspace frontmostApplication
        if appElement == nil || pid == 0 {
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                return nil
            }
            pid = frontApp.processIdentifier
            appElement = AXUIElementCreateApplication(pid)
        }

        guard let targetApp = appElement else { return nil }

        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown"

        // Query focused window attribute from the application element
        var windowVal: AnyObject?
        let winErr = AXUIElementCopyAttributeValue(targetApp, kAXFocusedWindowAttribute as CFString, &windowVal)
        guard winErr == .success, let winVal = windowVal else {
            return getFrontmostWindowFromCGList()
        }
        let winElement = winVal as! AXUIElement

        // Resolve CGWindowID
        var windowID: CGWindowID = 0
        if let fn = _axGetWindow {
            var wid: CGWindowID = 0
            if fn(winElement, &wid) == .success && wid > 0 {
                windowID = wid
            }
        }

        var activeWinElement = winElement
        var activeWindowID = windowID

        // If not standard window (e.g. popup, dropdown, tooltip, auxiliary dialog)
        if windowID > 0 && !isStandardWindow(windowID: windowID, pid: pid) {
            var resolvedStandard = false

            // 1. Check parent window attribute
            var parentVal: AnyObject?
            if AXUIElementCopyAttributeValue(winElement, kAXParentAttribute as CFString, &parentVal) == .success,
               let parentElem = parentVal {
                let pElem = parentElem as! AXUIElement
                if let fn = _axGetWindow {
                    var pWid: CGWindowID = 0
                    if fn(pElem, &pWid) == .success && pWid > 0 && isStandardWindow(windowID: pWid, pid: pid) {
                        activeWinElement = pElem
                        activeWindowID = pWid
                        resolvedStandard = true
                    }
                }
            }

            // 2. If parent was not a standard window, check application's main window
            if !resolvedStandard {
                var mainVal: AnyObject?
                if AXUIElementCopyAttributeValue(targetApp, kAXMainWindowAttribute as CFString, &mainVal) == .success,
                   let mainElem = mainVal {
                    let mElem = mainElem as! AXUIElement
                    if let fn = _axGetWindow {
                        var mWid: CGWindowID = 0
                        if fn(mElem, &mWid) == .success && mWid > 0 && isStandardWindow(windowID: mWid, pid: pid) {
                            activeWinElement = mElem
                            activeWindowID = mWid
                            resolvedStandard = true
                        }
                    }
                }
            }

            // 3. If neither parent nor main window is standard, do not return non-standard element
            if !resolvedStandard {
                return nil
            }
        }

        // Query window title
        var titleVal: AnyObject?
        AXUIElementCopyAttributeValue(activeWinElement, kAXTitleAttribute as CFString, &titleVal)
        let title = (titleVal as? String) ?? ""

        // Query window position and size
        var pt = CGPoint.zero
        var sz = CGSize.zero

        var posVal: AnyObject?
        if AXUIElementCopyAttributeValue(activeWinElement, kAXPositionAttribute as CFString, &posVal) == .success, let pv = posVal {
            AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
        }

        var sizeVal: AnyObject?
        if AXUIElementCopyAttributeValue(activeWinElement, kAXSizeAttribute as CFString, &sizeVal) == .success, let sv = sizeVal {
            AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        }

        var cgBounds = CGRect(origin: pt, size: sz)

        // Fallback: match via CGWindowListCopyWindowInfo
        if activeWindowID == 0 {
            activeWindowID = resolveWindowIDFromCGWindowList(pid: pid, bounds: cgBounds)
            if activeWindowID > 0 && !isStandardWindow(windowID: activeWindowID, pid: pid) {
                return nil
            }
        }

        // If AX bounds was empty or zero, try querying WindowServer bounds directly
        if (cgBounds.width <= 0 || cgBounds.height <= 0) && activeWindowID > 0 {
            if let slsBounds = SkyLightBridge.shared.getWindowBounds(windowID: activeWindowID) {
                cgBounds = slsBounds
            }
        }

        // Discard invisible or zero-sized windows
        guard cgBounds.width > 0 && cgBounds.height > 0 else {
            return nil
        }

        // Discard parked or hidden windows belonging to inactive workspaces
        guard !HiddenWindowPlacement.isParkedOrHidden(cgBounds) else {
            return nil
        }

        // Calculate AppKit screen coordinate frame
        let appkitFrame = convertToAppKitFrame(cgRect: cgBounds)

        return FocusedWindowInfo(
            windowID: activeWindowID,
            processID: pid,
            appName: appName,
            title: title,
            bounds: cgBounds,
            appkitFrame: appkitFrame
        )
    }

    private func resolveWindowIDFromCGWindowList(pid: pid_t, bounds: CGRect) -> CGWindowID {
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return 0
        }

        var bestWid: CGWindowID = 0
        var minDiff: CGFloat = .infinity

        for item in windowList {
            guard let itemPID = item[kCGWindowOwnerPID as String] as? pid_t, itemPID == pid else {
                continue
            }
            guard let itemWid = item[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            guard let boundsDict = item[kCGWindowBounds as String] as? [String: Any],
                  let itemRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }

            let diff = abs(itemRect.origin.x - bounds.origin.x) +
                       abs(itemRect.origin.y - bounds.origin.y) +
                       abs(itemRect.width - bounds.width) +
                       abs(itemRect.height - bounds.height)

            if diff < minDiff {
                minDiff = diff
                bestWid = itemWid
            }
        }

        return bestWid
    }

    /// Converts CoreGraphics display coordinates (top-left origin) to AppKit coordinates (bottom-left origin)
    public func convertToAppKitFrame(cgRect: CGRect) -> NSRect {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? cgRect.height
        let appkitY = primaryScreenHeight - (cgRect.origin.y + cgRect.height)
        return NSRect(x: cgRect.origin.x, y: appkitY, width: cgRect.width, height: cgRect.height)
    }

    public func getWindowID(for element: AXUIElement) -> CGWindowID? {
        if let fn = _axGetWindow {
            var wid: CGWindowID = 0
            if fn(element, &wid) == .success && wid > 0 {
                return wid
            }
        }
        return nil
    }

    /// Looks up or caches the owning PID for a given window ID.
    public func getPID(for windowID: CGWindowID) -> pid_t? {
        lock.lock()
        if let cached = pidCache[windowID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        lock.lock()
        for item in windowList {
            if let wid = item[kCGWindowNumber as String] as? CGWindowID,
               let pid = item[kCGWindowOwnerPID as String] as? pid_t, pid > 0 {
                pidCache[wid] = pid
            }
        }
        let result = pidCache[windowID]
        lock.unlock()
        return result
    }

    /// Resolves the AXUIElement window handle corresponding to the CGWindowID.
    public func getWindowAXElement(windowID: CGWindowID, pid: pid_t? = nil) -> AXUIElement? {
        lock.lock()
        if let cached = axElementCache[windowID] {
            var roleVal: AnyObject?
            if AXUIElementCopyAttributeValue(cached, kAXRoleAttribute as CFString, &roleVal) == .success,
               let role = roleVal as? String, role == (kAXWindowRole as String) {
                if let cachedWid = getWindowID(for: cached) {
                    if cachedWid == windowID {
                        lock.unlock()
                        return cached
                    } else {
                        axElementCache.removeValue(forKey: windowID)
                    }
                } else {
                    lock.unlock()
                    return cached
                }
            } else {
                axElementCache.removeValue(forKey: windowID)
            }
        }
        lock.unlock()

        var appPID = pid
        if appPID == nil || appPID == 0 {
            appPID = getPID(for: windowID)
        }
        guard let validPID = appPID, validPID > 0 else { return nil }

        let appElement = AXUIElementCreateApplication(validPID)
        var windowsVal: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsVal) == .success,
              let axWindows = windowsVal as? [AXUIElement] else {
            return nil
        }

        // Filter elements to strictly valid AXWindows (excluding non-window elements like Finder Desktop AXScrollArea)
        var windowElements: [AXUIElement] = []
        for elem in axWindows {
            var roleVal: AnyObject?
            if AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleVal) == .success,
               let role = roleVal as? String, role == (kAXWindowRole as String) {
                windowElements.append(elem)
            }
        }

        // Match exact window ID
        for winElem in windowElements {
            if let wid = getWindowID(for: winElem), wid == windowID {
                lock.lock()
                axElementCache[windowID] = winElem
                lock.unlock()
                return winElem
            }
        }

        // Single window fallback only if exactly one genuine AXWindow exists AND its window ID is unknown or matches
        if windowElements.count == 1, let singleWin = windowElements.first {
            let singleWid = getWindowID(for: singleWin)
            if singleWid == nil || singleWid == windowID {
                lock.lock()
                axElementCache[windowID] = singleWin
                lock.unlock()
                return singleWin
            }
        }
        return nil
    }

    /// Invalidates cached AXUIElement handle and PID for a destroyed window.
    public func invalidateWindow(windowID: CGWindowID) {
        lock.lock()
        axElementCache.removeValue(forKey: windowID)
        pidCache.removeValue(forKey: windowID)
        lock.unlock()
    }

    /// Invalidates all cached AXUIElements and PIDs for an application PID upon termination.
    public func invalidateApplication(pid: pid_t) {
        lock.lock()
        let toRemove = pidCache.filter { $0.value == pid }.map { $0.key }
        for wid in toRemove {
            axElementCache.removeValue(forKey: wid)
            pidCache.removeValue(forKey: wid)
        }
        lock.unlock()
    }

    /// Clears the entire AXUIElement and PID caches.
    public func clearCache() {
        lock.lock()
        axElementCache.removeAll()
        pidCache.removeAll()
        _cachedFocusedWindow = nil
        lock.unlock()
    }

    /// Queries the window title for a given window ID using Accessibility or CoreGraphics.
    public func getWindowTitle(windowID: CGWindowID, pid: pid_t? = nil) -> String? {
        if let elem = getWindowAXElement(windowID: windowID, pid: pid) {
            var titleVal: AnyObject?
            if AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &titleVal) == .success,
               let title = titleVal as? String, !title.isEmpty {
                return title
            }
        }
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for item in list {
            if let wid = item[kCGWindowNumber as String] as? CGWindowID, wid == windowID {
                return item[kCGWindowName as String] as? String
            }
        }
        return nil
    }

    /// Moves a window to a target coordinate point via Accessibility.
    @discardableResult
    public func setWindowPosition(windowID: CGWindowID, point: CGPoint, pid: pid_t? = nil) -> Bool {
        guard let winElem = getWindowAXElement(windowID: windowID, pid: pid) else {
            return false
        }
        var pt = point
        if let posVal = AXValueCreate(.cgPoint, &pt) {
            let err = AXUIElementSetAttributeValue(winElem, kAXPositionAttribute as CFString, posVal)
            return err == .success
        }
        return false
    }

    /// Sets both the position and size of a window via Accessibility.
    /// Follows Rift / WorkspaceManager 1:1 invariant:
    /// - If size is unchanged: writes only position (position_only: true).
    /// - If size grows: sets Position first, then Size.
    /// - If size shrinks: sets Size first, then Position (prevents macOS AX clamping/rejection when x + width > display width).
    /// - Synchronous readback barrier to ensure WindowServer commits the frame before continuing.
    @discardableResult
    public func setWindowFrame(windowID: CGWindowID, frame: CGRect, pid: pid_t? = nil) -> Bool {
        guard let winElem = getWindowAXElement(windowID: windowID, pid: pid) else {
            return false
        }
        var curSz = CGSize.zero
        if let bounds = SkyLightBridge.shared.getWindowBounds(windowID: windowID) {
            curSz = bounds.size
        } else {
            var sizeVal: AnyObject?
            if AXUIElementCopyAttributeValue(winElem, kAXSizeAttribute as CFString, &sizeVal) == .success, let sv = sizeVal {
                AXValueGetValue(sv as! AXValue, .cgSize, &curSz)
            }
        }

        var pt = frame.origin
        let posVal = AXValueCreate(.cgPoint, &pt)
        let sizeChanged = abs(curSz.width - frame.size.width) > 0.5 || abs(curSz.height - frame.size.height) > 0.5

        if !sizeChanged {
            // If size is unchanged: set ONLY Position. Do not write kAXSizeAttribute.
            if let pv = posVal {
                AXUIElementSetAttributeValue(winElem, kAXPositionAttribute as CFString, pv)
            }
        } else {
            var sz = frame.size
            let newSizeVal = AXValueCreate(.cgSize, &sz)
            let grows = frame.size.width > curSz.width + 0.5 || frame.size.height > curSz.height + 0.5

            if grows {
                // If size grows: set Position first, then Size.
                if let pv = posVal {
                    AXUIElementSetAttributeValue(winElem, kAXPositionAttribute as CFString, pv)
                }
                if let sv = newSizeVal {
                    AXUIElementSetAttributeValue(winElem, kAXSizeAttribute as CFString, sv)
                }
            } else {
                // If size shrinks: set Size first, then Position.
                if let sv = newSizeVal {
                    AXUIElementSetAttributeValue(winElem, kAXSizeAttribute as CFString, sv)
                }
                if let pv = posVal {
                    AXUIElementSetAttributeValue(winElem, kAXPositionAttribute as CFString, pv)
                }
                // Two-pass safeguard: re-apply size after position in case offscreen clamping occurred
                if let sv = newSizeVal {
                    AXUIElementSetAttributeValue(winElem, kAXSizeAttribute as CFString, sv)
                }
            }
        }

        return true
    }

    /// Checks whether a window is minimized via Accessibility.
    public func isWindowMinimized(windowID: CGWindowID, pid: pid_t? = nil) -> Bool {
        guard let winElem = getWindowAXElement(windowID: windowID, pid: pid) else {
            return false
        }
        var minVal: AnyObject?
        let err = AXUIElementCopyAttributeValue(winElem, kAXMinimizedAttribute as CFString, &minVal)
        if err == .success, let val = minVal {
            if let boolVal = val as? Bool {
                return boolVal
            }
            if CFGetTypeID(val) == CFBooleanGetTypeID() {
                return CFEqual(val, kCFBooleanTrue)
            }
        }
        return false
    }

    /// Sets whether a window is minimized via Accessibility.
    @discardableResult
    public func setWindowMinimized(windowID: CGWindowID, minimized: Bool, pid: pid_t? = nil) -> Bool {
        guard let winElem = getWindowAXElement(windowID: windowID, pid: pid) else {
            return false
        }
        let val = minimized ? kCFBooleanTrue : kCFBooleanFalse
        let err = AXUIElementSetAttributeValue(winElem, kAXMinimizedAttribute as CFString, val!)
        return err == .success
    }

    /// Verifies if a window is a standard application window (excluding popups, dropdowns, dialogs, tooltips).
    public func isStandardWindow(windowID: CGWindowID, pid: pid_t? = nil) -> Bool {
        guard let winElem = getWindowAXElement(windowID: windowID, pid: pid) else {
            return false
        }

        // Query AXRole: must be AXWindow (kAXWindowRole)
        var roleVal: AnyObject?
        let roleErr = AXUIElementCopyAttributeValue(winElem, kAXRoleAttribute as CFString, &roleVal)
        guard roleErr == .success, let role = roleVal as? String,
              role == (kAXWindowRole as String) || role == "AXWindow" else {
            return false
        }

        // Query AXSubrole: must be AXStandardWindow (kAXStandardWindowSubrole)
        var subroleVal: AnyObject?
        let subroleErr = AXUIElementCopyAttributeValue(winElem, kAXSubroleAttribute as CFString, &subroleVal)
        guard subroleErr == .success, let subrole = subroleVal as? String else {
            return false
        }

        let nonStandardSubroles: Set<String> = [
            "AXFloatingWindow", "AXDialog", "AXSystemDialog", "AXUnknown"
        ]
        if nonStandardSubroles.contains(subrole) {
            return false
        }

        return subrole == (kAXStandardWindowSubrole as String) || subrole == "AXStandardWindow"
    }

    /// Retrieves the current bounding rect for a window ID via AX, SkyLight, or WindowServer list fallback.
    /// Operates reliably whether the window is placed on screen or parked at a hidden anchor.
    public func getWindowBounds(windowID: CGWindowID, pid: pid_t? = nil) -> CGRect? {
        if let winElem = getWindowAXElement(windowID: windowID, pid: pid) {
            var pt = CGPoint.zero
            var sz = CGSize.zero
            var posVal: AnyObject?
            if AXUIElementCopyAttributeValue(winElem, kAXPositionAttribute as CFString, &posVal) == .success, let pv = posVal {
                AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
            }
            var sizeVal: AnyObject?
            if AXUIElementCopyAttributeValue(winElem, kAXSizeAttribute as CFString, &sizeVal) == .success, let sv = sizeVal {
                AXValueGetValue(sv as! AXValue, .cgSize, &sz)
            }
            if sz.width > 0 && sz.height > 0 {
                return CGRect(origin: pt, size: sz)
            }
        }
        if let slsBounds = SkyLightBridge.shared.getWindowBounds(windowID: windowID) {
            return slsBounds
        }
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for item in windowList {
            if let wid = item[kCGWindowNumber as String] as? CGWindowID, wid == windowID,
               let boundsDict = item[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                return rect
            }
        }
        return nil
    }

    /// Checks whether a window ID physically exists in the macOS WindowServer.
    public func isWindowAlive(windowID: CGWindowID) -> Bool {
        guard windowID > 0 else { return false }
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windowList.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }
    }

    /// Returns the set of all window IDs currently existing in the macOS WindowServer.
    public func getAllAliveWindowIDs() -> Set<CGWindowID> {
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return Set(windowList.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    /// Fallback: returns the frontmost visible normal window using CGWindowListCopyWindowInfo (requires no AX permissions)
    public func getFrontmostWindowFromCGList() -> FocusedWindowInfo? {
        return getVisibleWindowsFromCGList().first
    }

    /// Returns all visible on-screen application windows from CGWindowListCopyWindowInfo
    public func getVisibleWindowsFromCGList() -> [FocusedWindowInfo] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [FocusedWindowInfo] = []
        for item in windowList {
            let layer = item[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }
            guard let wid = item[kCGWindowNumber as String] as? CGWindowID, wid > 0 else { continue }
            guard let pid = item[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let appName = item[kCGWindowOwnerName as String] as? String ?? "Unknown"
            let title = item[kCGWindowName as String] as? String ?? ""
            guard let boundsDict = item[kCGWindowBounds as String] as? [String: Any],
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  cgBounds.width > 100 && cgBounds.height > 100,
                  !HiddenWindowPlacement.isParkedOrHidden(cgBounds) else {
                continue
            }
            guard isStandardWindow(windowID: wid, pid: pid) else { continue }
            let appkitFrame = convertToAppKitFrame(cgRect: cgBounds)
            result.append(FocusedWindowInfo(
                windowID: wid,
                processID: pid,
                appName: appName,
                title: title,
                bounds: cgBounds,
                appkitFrame: appkitFrame
            ))
        }
        return result
    }

    /// Returns all eligible application windows for tiling, navigation, and focus management.
    public func getEligibleWindows(
        in screenBounds: CGRect? = nil,
        excludingPIDs: Set<pid_t> = [getpid()]
    ) -> [FocusedWindowInfo] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let excludedApps: Set<String> = [
            "Dock", "Window Server", "ControlCenter", "NotificationCenter",
            "SystemUIServer", "Spotlight", "HyprMac", "Wallpaper", "screencapture",
            "Simulator Trampoline"
        ]

        var userWindows: [FocusedWindowInfo] = []

        for item in windowList {
            guard let wid = item[kCGWindowNumber as String] as? CGWindowID, wid > 0 else { continue }
            guard let layer = item[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = item[kCGWindowOwnerPID as String] as? pid_t, !excludingPIDs.contains(pid) else { continue }
            guard let appName = item[kCGWindowOwnerName as String] as? String, !excludedApps.contains(appName) else { continue }
            let title = (item[kCGWindowName as String] as? String) ?? ""
            let alpha = (item[kCGWindowAlpha as String] as? Double) ?? 1.0
            guard alpha > 0.01 else { continue }

            guard let boundsDict = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }

            guard rect.width >= 100 && rect.height >= 100 else { continue }
            guard !HiddenWindowPlacement.isParkedOrHidden(rect) else { continue }
            guard !isWindowMinimized(windowID: wid, pid: pid) else { continue }
            guard isStandardWindow(windowID: wid, pid: pid) else { continue }

            if let screen = screenBounds {
                guard rect.intersects(screen) else { continue }
            }

            let appkitFrame = convertToAppKitFrame(cgRect: rect)
            userWindows.append(FocusedWindowInfo(
                windowID: wid,
                processID: pid,
                appName: appName,
                title: title,
                bounds: rect,
                appkitFrame: appkitFrame
            ))
        }
        return userWindows
    }

}
