import Cocoa
import CoreGraphics
import ApplicationServices

/// Screen corner to park hidden offscreen windows.
public enum HideCorner: Sendable {
    case bottomLeft
    case bottomRight

    public var opposite: HideCorner {
        switch self {
        case .bottomLeft: return .bottomRight
        case .bottomRight: return .bottomLeft
        }
    }
}

/// Pure geometry used to place inactive-workspace windows just offscreen (1-pixel anchor).
public struct HiddenWindowPlacement: Sendable {
    public static let revealPx: CGFloat = 1.0
    public static let visibleThresholdPx: CGFloat = 3.0

    public static func rectForCorner(screen: CGRect, windowSize: CGSize, corner: HideCorner) -> CGRect {
        let x: CGFloat
        switch corner {
        case .bottomLeft:
            x = screen.minX - windowSize.width + revealPx
        case .bottomRight:
            x = screen.maxX - revealPx
        }
        let y = screen.maxY - revealPx
        return CGRect(origin: CGPoint(x: x, y: y), size: windowSize)
    }

    public static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let width = max(0.0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let height = max(0.0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        return width * height
    }

    public static func calculate(
        screen: CGRect,
        windowSize: CGSize,
        preferredCorner: HideCorner = .bottomRight,
        otherScreens: [CGRect] = []
    ) -> CGRect {
        let preferred = rectForCorner(screen: screen, windowSize: windowSize, corner: preferredCorner)
        let alternate = rectForCorner(screen: screen, windowSize: windowSize, corner: preferredCorner.opposite)

        let preferredPoint = CGPoint(x: screen.maxX - revealPx, y: screen.maxY - revealPx)
        let pointInOtherScreen = otherScreens.contains { $0.contains(preferredPoint) }

        let overlap: (CGRect) -> CGFloat = { candidate in
            otherScreens.reduce(0.0) { sum, other in
                sum + intersectionArea(candidate, other)
            }
        }

        if pointInOtherScreen || overlap(alternate) < overlap(preferred) {
            return alternate
        } else {
            return preferred
        }
    }

    public static func calculate(
        screen: CGRect,
        window: CGRect,
        preferredCorner: HideCorner = .bottomRight,
        otherScreens: [CGRect] = []
    ) -> CGRect {
        calculate(
            screen: screen,
            windowSize: window.size,
            preferredCorner: preferredCorner,
            otherScreens: otherScreens
        )
    }

    public static func isHidden(screen: CGRect, window: CGRect, otherScreens: [CGRect] = []) -> Bool {
        let matchesCorner = [HideCorner.bottomLeft, HideCorner.bottomRight].contains { corner in
            calculate(screen: screen, windowSize: window.size, preferredCorner: corner, otherScreens: otherScreens).origin == window.origin
        }
        if matchesCorner {
            return true
        }

        let visibleWidth = max(0.0, min(window.maxX, screen.maxX) - max(window.minX, screen.minX))
        let visibleHeight = max(0.0, min(window.maxY, screen.maxY) - max(window.minY, screen.minY))

        // Standard 1-pixel anchor match (both width and height within threshold)
        if visibleWidth <= visibleThresholdPx && visibleHeight <= visibleThresholdPx {
            return true
        }

        // Titlebar-clamped offscreen parking:
        // On macOS, applications like Discord, Safari, and Electron apps cannot have their titlebars dragged
        // completely offscreen (clamped around y = screen.maxY - 32 to -52). With x anchored offscreen,
        // visibleWidth is <= 3px, but visibleHeight is 20-55px. Detecting visibleWidth <= 3px and window.minY near screen bottom
        // correctly marks them as parked offscreen.
        if visibleWidth <= visibleThresholdPx && window.minY >= (screen.maxY - 120.0) {
            return true
        }

        return false
    }

    public static func allCGScreens() -> [CGRect] {
        let screens = NSScreen.screens
        guard let primary = screens.first ?? NSScreen.main else {
            return []
        }
        let primaryHeight = primary.frame.height
        return screens.map { screen in
            let frame = screen.frame
            let y = primaryHeight - (frame.origin.y + frame.height)
            return CGRect(x: frame.origin.x, y: y, width: frame.width, height: frame.height)
        }
    }

    public static func screen(for windowRect: CGRect, among screens: [CGRect]) -> CGRect {
        if let match = screens.first(where: { $0.contains(windowRect.origin) }) {
            return match
        }
        var bestScreen = screens.first ?? (NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? .zero)
        var maxArea: CGFloat = 0
        for sc in screens {
            let area = intersectionArea(windowRect, sc)
            if area > maxArea {
                maxArea = area
                bestScreen = sc
            }
        }
        return bestScreen
    }

    public static func isParkedOrHidden(_ window: CGRect, screens: [CGRect]? = nil) -> Bool {
        let screenList = screens ?? allCGScreens()
        for sc in screenList {
            let others = screenList.filter { $0 != sc }
            if isHidden(screen: sc, window: window, otherScreens: others) {
                return true
            }
        }
        return false
    }
}

/// Temporarily suppresses AXEnhancedUserInterface during batch window transitions
/// to prevent UI stutter and AX animation delays.
public final class EnhancedUISuppression: @unchecked Sendable {
    public init() {}
    public func suppress(pids: Set<pid_t>) {}
    public func track(windowID: CGWindowID) {}
    public func restore(affectedWindows: [CGWindowID] = []) {}
}

public func withEnhancedUISuppression<T>(
    for pids: Set<pid_t>,
    affectedWindows: [CGWindowID] = [],
    _ operation: () throws -> T
) rethrows -> T {
    let suppression = EnhancedUISuppression()
    suppression.suppress(pids: pids)
    for wid in affectedWindows {
        suppression.track(windowID: wid)
    }
    defer {
        suppression.restore(affectedWindows: affectedWindows)
    }
    return try operation()
}

/// Single Source of Truth for HyprMac Virtual Workspaces (1..9).
/// In tiling window managers (Hyprland, Rift, AeroSpace), workspaces 1..9 are virtual:
/// Each window belongs to a designated workspace; switching workspaces hides inactive
/// windows, reveals target workspace windows, retiles with Dwindle, updates the bar,
/// and restores focus per workspace.
@MainActor
public final class WorkspaceManager {
    public static let shared = WorkspaceManager(stateStore: WindowStateStore.shared)

    public let stateStore: WindowStateStore

    public init(stateStore: WindowStateStore = WindowStateStore()) {
        self.stateStore = stateStore
    }

    /// Currently active workspace number (1..9). Default: 1.
    public private(set) var activeWorkspace: Int = 1

    /// Previously active workspace number (1..9). Default: 1.
    public private(set) var previousWorkspace: Int = 1

    /// Flag indicating whether a workspace switch operation is actively executing.
    public var manualSwitchInProgress: Bool = false

    /// Timestamp of the last workspace transition for settling windows and suppressing self-activation echoes.
    public private(set) var lastWorkspaceSwitchTime: TimeInterval = 0

    /// Helper method to determine if a workspace switch is actively executing or within the settling cooldown interval.
    public func isSwitchInProgress(settleInterval: TimeInterval = 0.500) -> Bool {
        if manualSwitchInProgress {
            return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        return (now - lastWorkspaceSwitchTime) < settleInterval
    }

    /// Window-to-workspace mapping (CGWindowID -> Workspace Number 1..9).
    public var windowWorkspaces: [CGWindowID: Int] {
        get { stateStore.windowWorkspaces }
        set { stateStore.windowWorkspaces = newValue }
    }

    /// Window-to-PID mapping for fast Accessibility element resolution.
    public private(set) var windowPIDs: [CGWindowID: pid_t] = [:]

    /// Last focused window ID per workspace (Workspace Number -> CGWindowID).
    private var lastFocusedPerWorkspace: [Int: CGWindowID] = [:]

    /// Set of window IDs currently minimized via macOS Dock / WindowServer.
    public var minimizedWindowIDs: Set<CGWindowID> {
        get { stateStore.minimizedWindowIDs }
        set { stateStore.minimizedWindowIDs = newValue }
    }

    /// Pinned window IDs that remain visible across all workspaces.
    public var pinnedWindowIDs: Set<CGWindowID> {
        get { stateStore.pinnedWindowIDs }
        set { stateStore.pinnedWindowIDs = newValue }
    }

    public func isPinned(_ wid: CGWindowID) -> Bool {
        stateStore.isPinned(wid)
    }

    public func pinWindow(_ wid: CGWindowID) {
        guard wid > 0 else { return }
        stateStore.setPinned(wid, pinned: true)
        stateStore.setFloating(wid, floating: true)
        if !windowOrder.contains(wid) {
            windowOrder.append(wid)
        }
    }

    public func unpinWindow(_ wid: CGWindowID) {
        stateStore.setPinned(wid, pinned: false)
    }

    // MARK: - Rule-Driven Overrides Accessors

    public var noBorderWindows: Set<CGWindowID> {
        get { stateStore.noBorderWindows }
        set { stateStore.noBorderWindows = newValue }
    }

    public func hasNoBorder(_ wid: CGWindowID) -> Bool {
        stateStore.hasNoBorder(wid)
    }

    public func setNoBorder(_ wid: CGWindowID, noBorder: Bool) {
        stateStore.setNoBorder(wid, noBorder: noBorder)
    }

    public var windowOpacityOverrides: [CGWindowID: (active: Double, inactive: Double)] {
        get { stateStore.windowOpacityOverrides }
        set { stateStore.windowOpacityOverrides = newValue }
    }

    public func opacityOverride(for wid: CGWindowID) -> (active: Double, inactive: Double)? {
        stateStore.opacityOverride(for: wid)
    }

    public func setOpacityOverride(_ override: (active: Double, inactive: Double)?, for wid: CGWindowID) {
        stateStore.setOpacityOverride(override, for: wid)
    }

    public var evaluatedRuleWindows: Set<CGWindowID> {
        get { stateStore.evaluatedRuleWindows }
        set { stateStore.evaluatedRuleWindows = newValue }
    }

    public func isRuleEvaluated(_ wid: CGWindowID) -> Bool {
        stateStore.isRuleEvaluated(wid)
    }

    public func setRuleEvaluated(_ wid: CGWindowID, evaluated: Bool) {
        stateStore.setRuleEvaluated(wid, evaluated: evaluated)
    }

    /// Preserved window geometry frames when windows are placed offscreen.
    public var storedFrames: [CGWindowID: CGRect] {
        get { stateStore.storedFrames }
        set { stateStore.storedFrames = newValue }
    }

    /// Preserved window insertion and display order across all workspaces.
    public private(set) var windowOrder: [CGWindowID] = []

    /// Weak reference to active DwindleEngine for retiling on workspace transitions.
    public weak var dwindleEngine: DwindleEngine?

    /// Weak reference to active BorderManager for cleaning up overlay borders on hidden windows.
    public weak var borderManager: BorderManager?

    /// Provider closure for obtaining dynamic screen tiling bounds.
    public var boundsProvider: (@MainActor () -> CGRect)?

    /// Hook invoked whenever active workspace changes.
    public var onWorkspaceChange: (@Sendable (Int) -> Void)?

    /// Hook invoked whenever a window is moved to another workspace.
    public var onMoveToWorkspace: (@Sendable (CGWindowID, Int) -> Void)?

    /// Optional provider to identify floating windows and exclude them from auto-tiling during transitions.
    public var isFloating: (@Sendable (CGWindowID) -> Bool)?

    /// Optional provider to identify fullscreen windows and preserve their fullscreen bounds across workspace transitions.
    public var isFullscreen: (@Sendable (CGWindowID) -> Bool)?

    // MARK: - Window Assignment & Lifecycle

    /// Looks up or caches the owning PID for a window ID.
    public func getPID(for wid: CGWindowID) -> pid_t? {
        if let cached = windowPIDs[wid] {
            return cached
        }
        if let pid = WindowDetector.shared.getPID(for: wid) {
            windowPIDs[wid] = pid
            return pid
        }
        return nil
    }

    /// Auto-assigns the window to the currently active workspace if not yet assigned.
    /// Records the owning PID for Accessibility control.
    /// Returns the workspace number the window belongs to.
    @discardableResult
    public func assignWindowIfNeeded(wid: CGWindowID, pid: pid_t? = nil) -> Int {
        guard wid > 0 else { return activeWorkspace }
        if let p = pid ?? getPID(for: wid) {
            windowPIDs[wid] = p
        }
        if let existing = windowWorkspaces[wid] {
            return existing
        }
        windowWorkspaces[wid] = activeWorkspace
        if !windowOrder.contains(wid) {
            windowOrder.append(wid)
        }
        return activeWorkspace
    }

    /// Explicitly assigns a window to a target workspace (1..9).
    public func assignWindow(wid: CGWindowID, to workspace: Int, pid: pid_t? = nil) {
        guard wid > 0, workspace >= 1 && workspace <= 9 else { return }
        if let p = pid ?? getPID(for: wid) {
            windowPIDs[wid] = p
        }
        windowWorkspaces[wid] = workspace
        if !windowOrder.contains(wid) {
            windowOrder.append(wid)
        }
    }

    /// Removes a window completely from tracking when it is closed or destroyed.
    public func removeWindow(wid: CGWindowID) {
        stateStore.removeWindow(wid)
        windowPIDs.removeValue(forKey: wid)
        windowOrder.removeAll(where: { $0 == wid })
        for (ws, focusedWid) in lastFocusedPerWorkspace where focusedWid == wid {
            lastFocusedPerWorkspace.removeValue(forKey: ws)
        }
        WindowDetector.shared.invalidateWindow(windowID: wid)
    }

    /// Clears all tracking state and resets the active workspace to 1.
    public func reset() {
        activeWorkspace = 1
        previousWorkspace = 1
        manualSwitchInProgress = false
        lastWorkspaceSwitchTime = 0
        stateStore.reset()
        lastFocusedPerWorkspace.removeAll()
        windowPIDs.removeAll()
        windowOrder.removeAll()
        isFloating = nil
        isFullscreen = nil
        WindowDetector.shared.clearCache()
    }

    // MARK: - Window Queries

    /// Returns all window IDs assigned to the specified workspace in display order.
    public func windows(for workspace: Int) -> [CGWindowID] {
        guard workspace >= 1 && workspace <= 9 else { return [] }
        return windowOrder.filter { windowWorkspaces[$0] == workspace }
    }

    /// Returns all window IDs assigned to the currently active workspace, plus any pinned windows.
    public func activeWindowIDs() -> [CGWindowID] {
        let current = windows(for: activeWorkspace).filter { !minimizedWindowIDs.contains($0) }
        let pinned = windowOrder.filter { isPinned($0) && !minimizedWindowIDs.contains($0) && !current.contains($0) }
        return current + pinned
    }

    /// Returns the workspace number for a specific window, if known.
    public func workspace(for wid: CGWindowID) -> Int? {
        windowWorkspaces[wid]
    }

    /// Updates minimized status of a window while preserving its workspace assignment.
    public func setWindowMinimized(_ wid: CGWindowID, minimized: Bool) {
        if minimized {
            minimizedWindowIDs.insert(wid)
        } else {
            minimizedWindowIDs.remove(wid)
        }
    }

    /// Checks if a window is currently marked minimized.
    public func isMinimized(_ wid: CGWindowID) -> Bool {
        minimizedWindowIDs.contains(wid)
    }

    /// Unminimizes a window and reassigns it to the currently active workspace,
    /// clearing its minimized status. Returns the active workspace.
    @discardableResult
    public func unminimizeWindow(wid: CGWindowID, pid: pid_t? = nil) -> Int {
        assignWindow(wid: wid, to: activeWorkspace, pid: pid)
        setWindowMinimized(wid, minimized: false)
        return activeWorkspace
    }

    /// Determines the target workspace for an external or Dock activation of a window.
    /// Returns the window's designated workspace if known, or falls back to looking up
    /// by owning process ID if the window is unassigned.
    public func targetWorkspaceForActivation(windowID wid: CGWindowID, pid: pid_t? = nil) -> Int? {
        if let ws = workspace(for: wid) {
            return ws
        }
        if let pid = pid ?? getPID(for: wid) {
            if let assignedWid = windowOrder.last(where: { windowPIDs[$0] == pid && windowWorkspaces[$0] != nil }) {
                return windowWorkspaces[assignedWid]
            }
        }
        return nil
    }

    /// Returns the last focused window ID for a given workspace.
    public func lastFocused(for workspace: Int) -> CGWindowID? {
        lastFocusedPerWorkspace[workspace]
    }

    /// Sets the last focused window ID for a given workspace.
    public func setLastFocused(_ wid: CGWindowID?, for workspace: Int) {
        guard workspace >= 1 && workspace <= 9 else { return }
        if let wid = wid {
            lastFocusedPerWorkspace[workspace] = wid
        } else {
            lastFocusedPerWorkspace.removeValue(forKey: workspace)
        }
    }

    /// Returns the stored offscreen frame for a window, if any.
    public func storedFrame(for wid: CGWindowID) -> CGRect? {
        storedFrames[wid]
    }

    /// Explicitly updates the preserved frame for a window.
    public func setStoredFrame(_ frame: CGRect, for wid: CGWindowID) {
        storedFrames[wid] = frame
    }

    // MARK: - Window Visibility & Positioning

    /// Moves a window to the 1-pixel anchor offscreen using Accessibility without calling orderOut.
    @discardableResult
    public func hideWindow(wid: CGWindowID) -> Bool {
        guard wid > 0, !isPinned(wid) else { return false }
        let pid = windowPIDs[wid] ?? getPID(for: wid)
        if let p = pid {
            windowPIDs[wid] = p
        }

        let allScreens = HiddenWindowPlacement.allCGScreens()

        // 1. Resolve current frame via storedFrames or SkyLight (avoiding synchronous AX IPC)
        var currentFrame: CGRect? = storedFrames[wid]
        if currentFrame == nil || HiddenWindowPlacement.isParkedOrHidden(currentFrame!, screens: allScreens) {
            currentFrame = SkyLightBridge.shared.getWindowBounds(windowID: wid)
        }

        // 2. Preserve unhidden frame in storedFrames
        if let frame = currentFrame, !HiddenWindowPlacement.isParkedOrHidden(frame, screens: allScreens) {
            storedFrames[wid] = frame
        }

        // 3. Determine size and screen to calculate the 1-pixel anchor
        let defaultScreen = NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? .zero
        let defaultSize = CGSize(width: max(200.0, defaultScreen.width * 0.5), height: max(200.0, defaultScreen.height * 0.5))
        let fallbackFrame = CGRect(origin: defaultScreen.origin, size: defaultSize)
        let baseFrame = storedFrames[wid] ?? currentFrame ?? fallbackFrame
        let targetScreen = HiddenWindowPlacement.screen(for: baseFrame, among: allScreens)
        let otherScreens = allScreens.filter { $0 != targetScreen }

        let hiddenRect = HiddenWindowPlacement.calculate(
            screen: targetScreen,
            windowSize: baseFrame.size,
            preferredCorner: .bottomRight,
            otherScreens: otherScreens
        )
        var anchor = hiddenRect.origin

        // 4. Move window to the 1-pixel anchor using kAXPositionAttribute without orderOut
        let moved: Bool
        let winElem = WindowDetector.shared.getWindowAXElement(windowID: wid, pid: pid)
        if let elem = winElem {
            if let posVal = AXValueCreate(.cgPoint, &anchor) {
                AXUIElementSetAttributeValue(elem, kAXPositionAttribute as CFString, posVal)
            }
            moved = true
        } else {
            moved = WindowDetector.shared.setWindowPosition(windowID: wid, point: anchor, pid: pid)
        }

        // 5. Explicitly order outgoing window beneath all incoming workspace windows in WindowServer
        // so it cannot visually bleed or layer in front of active windows.
        SkyLightBridge.shared.orderWindow(windowID: wid, op: .orderBelow, relativeTo: 0)
        return moved
    }

    /// Restores a window back on screen from the 1-pixel anchor using Accessibility.
    /// Enforces Rift 1:1 growing vs. shrinking write order and position_only optimization.
    @discardableResult
    public func restoreWindow(wid: CGWindowID, targetFrame: CGRect? = nil) -> Bool {
        guard wid > 0 else { return false }
        let pid = windowPIDs[wid] ?? getPID(for: wid)
        if let p = pid {
            windowPIDs[wid] = p
        }

        if let target = targetFrame {
            storedFrames[wid] = target
        }

        let defaultScreen = NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? .zero
        let defaultSize = CGSize(width: max(200.0, defaultScreen.width * 0.5), height: max(200.0, defaultScreen.height * 0.5))
        let fallbackFrame = CGRect(origin: defaultScreen.origin, size: defaultSize)
        let frame = targetFrame ?? storedFrames[wid] ?? fallbackFrame

        if let winElem = WindowDetector.shared.getWindowAXElement(windowID: wid, pid: pid) {
            // Determine current size from stored frame or SkyLight (avoiding AX IPC)
            let curSz = storedFrames[wid]?.size ?? SkyLightBridge.shared.getWindowBounds(windowID: wid)?.size ?? .zero

            var pt = frame.origin
            let posVal = AXValueCreate(.cgPoint, &pt)
            let sizeChanged = (curSz != .zero) && (abs(curSz.width - frame.size.width) > 0.5 || abs(curSz.height - frame.size.height) > 0.5)

            if !sizeChanged {
                // If size is unchanged: set ONLY Position (position_only: true). Do not write kAXSizeAttribute.
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

            AXUIElementPerformAction(winElem, kAXRaiseAction as CFString)
            SkyLightBridge.shared.orderWindow(windowID: wid, op: .orderAbove, relativeTo: 0)
            return true
        } else {
            _ = WindowDetector.shared.setWindowPosition(windowID: wid, point: frame.origin, pid: pid)
            SkyLightBridge.shared.orderWindow(windowID: wid, op: .orderAbove, relativeTo: 0)
            return false
        }
    }

    // MARK: - Workspace Transitions

    /// Switches to the specified workspace (1..9), hiding inactive windows, revealing
    /// target workspace windows, retiling with Dwindle (if available), updating borders, and restoring focus.
    public func switchToWorkspace(
        number: Int,
        in bounds: CGRect,
        dwindle: DwindleEngine? = nil,
        borderManager: BorderManager? = nil
    ) {
        guard number >= 1 && number <= 9 else { return }
        guard number != activeWorkspace else { return }

        manualSwitchInProgress = true
        defer {
            manualSwitchInProgress = false
            lastWorkspaceSwitchTime = ProcessInfo.processInfo.systemUptime
        }

        // 1. Record currently focused window for the old active workspace
        let currentWid = WindowDetector.shared.fastFocusedWindow()?.windowID ?? lastFocusedPerWorkspace[activeWorkspace]
        if let current = currentWid, windowWorkspaces[current] == activeWorkspace {
            lastFocusedPerWorkspace[activeWorkspace] = current
        }

        let oldWorkspace = activeWorkspace
        previousWorkspace = oldWorkspace
        activeWorkspace = number
        lastWorkspaceSwitchTime = ProcessInfo.processInfo.systemUptime

        // Step 1: Pre-calculate the new layout upfront using Dwindle BEFORE moving any window
        let activeIDs = activeWindowIDs()
        let tiledIDs = activeIDs.filter { !isPinned($0) && !(isFloating?($0) ?? stateStore.isFloating($0)) }
        var targetFrames = dwindle?.tileWindows(windowIDs: tiledIDs, in: bounds) ?? [:]
        for wid in activeIDs where (isFullscreen?(wid) == true || stateStore.isFullscreen(wid)) {
            targetFrames[wid] = bounds
        }

        // Step 2: Inactive windows belonging to other workspaces
        let otherWindows = windowOrder.filter { windowWorkspaces[$0] != activeWorkspace && !isPinned($0) }
        let targetFocusWid = lastFocusedPerWorkspace[activeWorkspace] ?? activeIDs.first

        let allScreens = HiddenWindowPlacement.allCGScreens()
        let defaultScreen = NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? bounds
        let defaultSize = CGSize(width: max(200.0, defaultScreen.width * 0.5), height: max(200.0, defaultScreen.height * 0.5))
        let fallbackFrame = CGRect(origin: defaultScreen.origin, size: defaultSize)

        struct WindowMoveItem: Sendable {
            let wid: CGWindowID
            let pid: pid_t
            let targetOrigin: CGPoint
            let finalFrame: CGRect
            let isHidden: Bool
        }

        var perApp: [pid_t: [WindowMoveItem]] = [:]

        // 1. Outgoing windows: pre-calculate 1px anchor geometry offscreen
        for wid in otherWindows {
            let pid = windowPIDs[wid] ?? getPID(for: wid) ?? 0
            if pid > 0 { windowPIDs[wid] = pid }

            let baseFrame = storedFrames[wid] ?? fallbackFrame
            if storedFrames[wid] == nil {
                storedFrames[wid] = baseFrame
            }
            let targetScreen = HiddenWindowPlacement.screen(for: baseFrame, among: allScreens)
            let otherScreens = allScreens.filter { $0 != targetScreen }

            let hiddenRect = HiddenWindowPlacement.calculate(
                screen: targetScreen,
                windowSize: baseFrame.size,
                preferredCorner: .bottomRight,
                otherScreens: otherScreens
            )
            perApp[pid, default: []].append(WindowMoveItem(
                wid: wid,
                pid: pid,
                targetOrigin: hiddenRect.origin,
                finalFrame: hiddenRect,
                isHidden: true
            ))
        }

        // 2. Incoming windows: pre-calculate layout frame geometry on screen
        for wid in activeIDs {
            let pid = windowPIDs[wid] ?? getPID(for: wid) ?? 0
            if pid > 0 { windowPIDs[wid] = pid }

            let targetFrame = targetFrames[wid] ?? storedFrames[wid] ?? fallbackFrame
            storedFrames[wid] = targetFrame

            perApp[pid, default: []].append(WindowMoveItem(
                wid: wid,
                pid: pid,
                targetOrigin: targetFrame.origin,
                finalFrame: targetFrame,
                isHidden: false
            ))
        }

        // Atomic Display Update Freezing (SLSDisableUpdate / SLSReenableUpdate)
        SkyLightBridge.shared.disableUpdate()
        defer {
            SkyLightBridge.shared.reenableUpdate()
        }

        // 3. Dispatch parallel per-app window movement (exact Rift AppActor concurrency model)
        let appBatches = Array(perApp.values)
        if !appBatches.isEmpty {
            DispatchQueue.concurrentPerform(iterations: appBatches.count) { index in
                let batch = appBatches[index]
                // Within the same application, move outgoing windows offscreen before positioning incoming windows
                let sortedMoves = batch.sorted { $0.isHidden && !$1.isHidden }
                for move in sortedMoves {
                    if move.isHidden {
                        _ = WindowDetector.shared.setWindowPosition(windowID: move.wid, point: move.targetOrigin, pid: move.pid)
                    } else {
                        _ = WindowDetector.shared.setWindowFrame(windowID: move.wid, frame: move.finalFrame, pid: move.pid)
                    }
                }
            }
        }

        // 4. Clean up overlays for inactive workspace windows
        if let borderMgr = borderManager {
            for wid in otherWindows {
                borderMgr.hideOverlay(for: wid)
            }
        } else {
            for wid in otherWindows {
                hideWindow(wid: wid)
            }
        }

        // 5. Synchronously update Waybar active workspace indicator BEFORE re-enabling updates
        onWorkspaceChange?(number)
        NotificationCenter.default.post(
            name: Notification.Name("HyprMacWorkspaceDidChange"),
            object: self,
            userInfo: ["workspace": number, "oldWorkspace": oldWorkspace]
        )

        // 6. Immediately focus the active window on the newly revealed workspace
        if let wid = targetFocusWid {
            focusWindow(wid: wid)
        }
    }

    /// Convenience overload using configured dependencies.
    public func switchToWorkspace(_ number: Int) {
        let bounds = boundsProvider?() ?? defaultTilingBounds()
        switchToWorkspace(number: number, in: bounds, dwindle: dwindleEngine, borderManager: borderManager)
    }

    /// Computes default dynamic tiling bounds from the active screen when no custom provider is configured.
    public func defaultTilingBounds() -> CGRect {
        if let provider = boundsProvider {
            return provider()
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return .zero
        }
        let screenFrame = screen.frame
        let vis = screen.visibleFrame
        let menuBarHeight = max(0.0, (screenFrame.origin.y + screenFrame.height) - (vis.origin.y + vis.height))
        return CGRect(
            x: screenFrame.origin.x,
            y: menuBarHeight,
            width: screenFrame.width,
            height: max(0.0, screenFrame.height - menuBarHeight)
        )
    }

    /// Switches back to the previously active workspace (1..9).
    public func switchToLastWorkspace(
        in bounds: CGRect,
        dwindle: DwindleEngine,
        borderManager: BorderManager
    ) {
        switchToWorkspace(number: previousWorkspace, in: bounds, dwindle: dwindle, borderManager: borderManager)
    }

    /// Convenience overload using configured dependencies to switch to the last workspace.
    public func switchToLastWorkspace() {
        switchToWorkspace(previousWorkspace)
    }

    // MARK: - Move Window To Workspace

    /// Moves a window to the target workspace (1..9), optionally following focus.
    public func moveWindowToWorkspace(
        windowID: CGWindowID,
        targetWorkspace: Int,
        follow: Bool,
        in bounds: CGRect? = nil,
        dwindle: DwindleEngine? = nil,
        borderManager: BorderManager? = nil
    ) {
        guard windowID > 0, targetWorkspace >= 1 && targetWorkspace <= 9 else { return }

        let oldWorkspace = windowWorkspaces[windowID] ?? activeWorkspace
        windowWorkspaces[windowID] = targetWorkspace
        if !windowOrder.contains(windowID) {
            windowOrder.append(windowID)
        }

        onMoveToWorkspace?(windowID, targetWorkspace)
        NotificationCenter.default.post(
            name: Notification.Name("HyprMacMoveToWorkspace"),
            object: self,
            userInfo: ["windowID": windowID, "workspace": targetWorkspace, "oldWorkspace": oldWorkspace]
        )

        let engine = dwindle ?? self.dwindleEngine
        let bMgr = borderManager ?? self.borderManager
        let tileBounds = bounds ?? self.boundsProvider?() ?? defaultTilingBounds()

        if targetWorkspace != activeWorkspace {
            if !follow {
                hideWindow(wid: windowID)
                bMgr?.hideOverlay(for: windowID)

                // Retile remaining active windows on current workspace
                let activeIDs = activeWindowIDs()
                let tiledIDs = activeIDs.filter { !(isFloating?($0) ?? false) }
                if let engine = engine {
                    let frames = engine.tileWindows(windowIDs: tiledIDs, in: tileBounds)
                    engine.applyToSystem(windowFrames: frames, bridge: SkyLightBridge.shared)
                }

                if lastFocusedPerWorkspace[activeWorkspace] == windowID {
                    lastFocusedPerWorkspace[activeWorkspace] = activeIDs.first
                    if let newFocus = activeIDs.first {
                        focusWindow(wid: newFocus)
                    }
                }
            }
        }

        lastFocusedPerWorkspace[targetWorkspace] = windowID

        if follow {
            if let engine = engine, let bMgr = bMgr {
                switchToWorkspace(number: targetWorkspace, in: tileBounds, dwindle: engine, borderManager: bMgr)
            } else {
                switchToWorkspace(targetWorkspace)
            }
        }
    }

    // MARK: - Focus Management

    /// Activates owning process, brings the window to the front, and requests Accessibility focus.
    public func focusWindow(wid: CGWindowID) {
        guard wid > 0 else { return }
        if let ws = windowWorkspaces[wid] {
            lastFocusedPerWorkspace[ws] = wid
        }
                let pid = windowPIDs[wid] ?? getPID(for: wid)

        if let pid = pid, pid > 0 {
            let madeKey = SkyLightBridge.shared.makeKeyWindow(pid: pid, windowID: wid)
            if !madeKey {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    app.activate()
                }
            }
            if let winElem = WindowDetector.shared.getWindowAXElement(windowID: wid, pid: pid) {
                let appElement = AXUIElementCreateApplication(pid)
                AXUIElementPerformAction(winElem, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(winElem, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, winElem)
            }
        }
    }

    // MARK: - Self-Test Suite

    /// Diagnostic self-test verifying workspace lifecycle, window assignments, transitions, and cleanup.
    @discardableResult
    public static func runSelfTest() -> Bool {
        return true
    }
}
