import Foundation
import CoreGraphics
public final class WindowStateStore: @unchecked Sendable {
    public static let shared = WindowStateStore()

    private let lock = NSLock()

    private var _floatingWindowIDs: Set<CGWindowID> = []
    private var _fullscreenWindows: [CGWindowID: CGRect] = [:]
    private var _minimizedWindowIDs: Set<CGWindowID> = []
    private var _windowWorkspaces: [CGWindowID: Int] = [:]
    private var _storedFrames: [CGWindowID: CGRect] = [:]
    private var _strippedWindows: Set<CGWindowID> = []
    private var _pinnedWindowIDs: Set<CGWindowID> = []
    private var _noBorderWindows: Set<CGWindowID> = []
    private var _windowOpacityOverrides: [CGWindowID: (active: Double, inactive: Double)] = [:]
    private var _evaluatedRuleWindows: Set<CGWindowID> = []

    public init() {}

    // MARK: - Floating State

    public var floatingWindowIDs: Set<CGWindowID> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _floatingWindowIDs
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _floatingWindowIDs = newValue
        }
    }

    public func isFloating(_ windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _floatingWindowIDs.contains(windowID)
    }

    public func setFloating(_ windowID: CGWindowID, floating: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if floating {
            _floatingWindowIDs.insert(windowID)
        } else {
            _floatingWindowIDs.remove(windowID)
        }
    }

    // MARK: - Fullscreen State

    public var fullscreenWindows: [CGWindowID: CGRect] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _fullscreenWindows
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _fullscreenWindows = newValue
        }
    }

    public func isFullscreen(_ windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fullscreenWindows[windowID] != nil
    }

    public func getFullscreenFrame(_ windowID: CGWindowID) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return _fullscreenWindows[windowID]
    }

    public func setFullscreen(_ windowID: CGWindowID, fullscreen: Bool, restoreFrame: CGRect? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if fullscreen {
            _fullscreenWindows[windowID] = restoreFrame ?? _fullscreenWindows[windowID] ?? .zero
        } else {
            _fullscreenWindows.removeValue(forKey: windowID)
        }
    }

    // MARK: - Minimized State

    public var minimizedWindowIDs: Set<CGWindowID> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _minimizedWindowIDs
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _minimizedWindowIDs = newValue
        }
    }

    public func isMinimized(_ windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _minimizedWindowIDs.contains(windowID)
    }

    public func setMinimized(_ windowID: CGWindowID, minimized: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if minimized {
            _minimizedWindowIDs.insert(windowID)
        } else {
            _minimizedWindowIDs.remove(windowID)
        }
    }

    // MARK: - Workspace Assignment State

    public var windowWorkspaces: [CGWindowID: Int] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _windowWorkspaces
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _windowWorkspaces = newValue
        }
    }

    public func workspace(for windowID: CGWindowID) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return _windowWorkspaces[windowID]
    }

    public func setWorkspace(_ ws: Int?, for windowID: CGWindowID) {
        lock.lock()
        defer { lock.unlock() }
        if let ws = ws {
            _windowWorkspaces[windowID] = ws
        } else {
            _windowWorkspaces.removeValue(forKey: windowID)
        }
    }

    // MARK: - Stored Frames (Offscreen Parking)

    public var storedFrames: [CGWindowID: CGRect] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _storedFrames
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _storedFrames = newValue
        }
    }

    public func getStoredFrame(_ windowID: CGWindowID) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return _storedFrames[windowID]
    }

    public func setStoredFrame(_ frame: CGRect?, for windowID: CGWindowID) {
        lock.lock()
        defer { lock.unlock() }
        if let frame = frame {
            _storedFrames[windowID] = frame
        } else {
            _storedFrames.removeValue(forKey: windowID)
        }
    }

    // MARK: - Stripped Windows State

    public var strippedWindows: Set<CGWindowID> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _strippedWindows
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _strippedWindows = newValue
        }
    }

    public func isStripped(_ windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _strippedWindows.contains(windowID)
    }

    public func setStripped(_ windowID: CGWindowID, stripped: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if stripped {
            _strippedWindows.insert(windowID)
        } else {
            _strippedWindows.remove(windowID)
        }
    }

    // MARK: - Pinned Windows State

    public var pinnedWindowIDs: Set<CGWindowID> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _pinnedWindowIDs
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _pinnedWindowIDs = newValue
        }
    }

    public func isPinned(_ windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _pinnedWindowIDs.contains(windowID)
    }

    public func setPinned(_ windowID: CGWindowID, pinned: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if pinned {
            _pinnedWindowIDs.insert(windowID)
        } else {
            _pinnedWindowIDs.remove(windowID)
        }
    }

    // MARK: - Rule-Driven Overrides State

    public var noBorderWindows: Set<CGWindowID> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _noBorderWindows
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _noBorderWindows = newValue
        }
    }

    public func hasNoBorder(_ windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _noBorderWindows.contains(windowID)
    }

    public func setNoBorder(_ windowID: CGWindowID, noBorder: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if noBorder {
            _noBorderWindows.insert(windowID)
        } else {
            _noBorderWindows.remove(windowID)
        }
    }

    public var windowOpacityOverrides: [CGWindowID: (active: Double, inactive: Double)] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _windowOpacityOverrides
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _windowOpacityOverrides = newValue
        }
    }

    public func opacityOverride(for windowID: CGWindowID) -> (active: Double, inactive: Double)? {
        lock.lock()
        defer { lock.unlock() }
        return _windowOpacityOverrides[windowID]
    }

    public func setOpacityOverride(_ override: (active: Double, inactive: Double)?, for windowID: CGWindowID) {
        lock.lock()
        defer { lock.unlock() }
        if let o = override {
            _windowOpacityOverrides[windowID] = o
        } else {
            _windowOpacityOverrides.removeValue(forKey: windowID)
        }
    }

    public var evaluatedRuleWindows: Set<CGWindowID> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _evaluatedRuleWindows
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _evaluatedRuleWindows = newValue
        }
    }

    public func isRuleEvaluated(_ windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _evaluatedRuleWindows.contains(windowID)
    }

    public func setRuleEvaluated(_ windowID: CGWindowID, evaluated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if evaluated {
            _evaluatedRuleWindows.insert(windowID)
        } else {
            _evaluatedRuleWindows.remove(windowID)
        }
    }

    // MARK: - Lifecycle & Cleanup

    public func prune(aliveWindowIDs: Set<CGWindowID>) {
        lock.lock()
        defer { lock.unlock() }
        _floatingWindowIDs.formIntersection(aliveWindowIDs)
        _fullscreenWindows = _fullscreenWindows.filter { aliveWindowIDs.contains($0.key) }
        _minimizedWindowIDs.formIntersection(aliveWindowIDs)
        _windowWorkspaces = _windowWorkspaces.filter { aliveWindowIDs.contains($0.key) }
        _storedFrames = _storedFrames.filter { aliveWindowIDs.contains($0.key) }
        _strippedWindows.formIntersection(aliveWindowIDs)
        _pinnedWindowIDs.formIntersection(aliveWindowIDs)
        _noBorderWindows.formIntersection(aliveWindowIDs)
        _windowOpacityOverrides = _windowOpacityOverrides.filter { aliveWindowIDs.contains($0.key) }
        _evaluatedRuleWindows.formIntersection(aliveWindowIDs)
    }

    public func removeWindow(_ windowID: CGWindowID) {
        lock.lock()
        defer { lock.unlock() }
        _floatingWindowIDs.remove(windowID)
        _fullscreenWindows.removeValue(forKey: windowID)
        _minimizedWindowIDs.remove(windowID)
        _windowWorkspaces.removeValue(forKey: windowID)
        _storedFrames.removeValue(forKey: windowID)
        _strippedWindows.remove(windowID)
        _pinnedWindowIDs.remove(windowID)
        _noBorderWindows.remove(windowID)
        _windowOpacityOverrides.removeValue(forKey: windowID)
        _evaluatedRuleWindows.remove(windowID)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _floatingWindowIDs.removeAll()
        _fullscreenWindows.removeAll()
        _minimizedWindowIDs.removeAll()
        _windowWorkspaces.removeAll()
        _storedFrames.removeAll()
        _strippedWindows.removeAll()
        _pinnedWindowIDs.removeAll()
        _noBorderWindows.removeAll()
        _windowOpacityOverrides.removeAll()
        _evaluatedRuleWindows.removeAll()
    }
}
