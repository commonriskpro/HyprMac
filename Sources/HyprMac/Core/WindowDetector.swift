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

    private init() {
        if let sym = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow") {
            self._axGetWindow = unsafeBitCast(sym, to: AXUIElementGetWindowFunc.self)
        } else {
            self._axGetWindow = nil
        }
    }

    /// Verifies if the current process has Accessibility privileges
    public static func isProcessTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Detects the current focused active window across the entire macOS workspace
    public func getFocusedWindow() -> FocusedWindowInfo? {
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
            return nil
        }
        let winElement = winVal as! AXUIElement

        // Query window title
        var titleVal: AnyObject?
        AXUIElementCopyAttributeValue(winElement, kAXTitleAttribute as CFString, &titleVal)
        let title = (titleVal as? String) ?? ""

        // Query window position and size
        var pt = CGPoint.zero
        var sz = CGSize.zero

        var posVal: AnyObject?
        if AXUIElementCopyAttributeValue(winElement, kAXPositionAttribute as CFString, &posVal) == .success, let pv = posVal {
            AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
        }

        var sizeVal: AnyObject?
        if AXUIElementCopyAttributeValue(winElement, kAXSizeAttribute as CFString, &sizeVal) == .success, let sv = sizeVal {
            AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        }

        var cgBounds = CGRect(origin: pt, size: sz)

        // Resolve CGWindowID
        var windowID: CGWindowID = 0
        if let fn = _axGetWindow {
            var wid: CGWindowID = 0
            if fn(winElement, &wid) == .success && wid > 0 {
                windowID = wid
            }
        }

        // Fallback: match via CGWindowListCopyWindowInfo
        if windowID == 0 {
            windowID = resolveWindowIDFromCGWindowList(pid: pid, bounds: cgBounds)
        }

        // If AX bounds was empty or zero, try querying WindowServer bounds directly
        if (cgBounds.width <= 0 || cgBounds.height <= 0) && windowID > 0 {
            if let slsBounds = SkyLightBridge.shared.getWindowBounds(windowID: windowID) {
                cgBounds = slsBounds
            }
        }

        // Discard invisible or zero-sized windows
        guard cgBounds.width > 0 && cgBounds.height > 0 else {
            return nil
        }

        // Calculate AppKit screen coordinate frame
        let appkitFrame = convertToAppKitFrame(cgRect: cgBounds)

        return FocusedWindowInfo(
            windowID: windowID,
            processID: pid,
            appName: appName,
            title: title,
            bounds: cgBounds,
            appkitFrame: appkitFrame
        )
    }

    private func resolveWindowIDFromCGWindowList(pid: pid_t, bounds: CGRect) -> CGWindowID {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
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
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080.0
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

    @discardableResult
    public func setWindowFrame(windowID: CGWindowID, frame: CGRect) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        guard let info = windowList.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }),
              let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsVal: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsVal) == .success,
              let axWindows = windowsVal as? [AXUIElement] else {
            return false
        }

        for winElem in axWindows {
            let wid = getWindowID(for: winElem)
            if wid == windowID || (axWindows.count == 1 && wid == nil) {
                var pt = frame.origin
                var sz = frame.size
                if let posVal = AXValueCreate(.cgPoint, &pt) {
                    AXUIElementSetAttributeValue(winElem, kAXPositionAttribute as CFString, posVal)
                }
                if let sizeVal = AXValueCreate(.cgSize, &sz) {
                    AXUIElementSetAttributeValue(winElem, kAXSizeAttribute as CFString, sizeVal)
                }
                if let posVal = AXValueCreate(.cgPoint, &pt) {
                    AXUIElementSetAttributeValue(winElem, kAXPositionAttribute as CFString, posVal)
                }
                return true
            }
        }
        return false
    }
}
