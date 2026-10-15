import Foundation
import CoreGraphics
import Darwin

public typealias CGSConnectionID = Int32
public typealias CGError = Int32

public enum WindowOrderOp: Int32, Sendable {
    case orderOut = 0
    case orderAbove = 1
    case orderBelow = -1
}

public struct WindowTags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let disableShadow   = WindowTags(rawValue: 1 << 3)
    public static let titlebarless    = WindowTags(rawValue: 1 << 9)
    public static let sticky          = WindowTags(rawValue: 1 << 11)
    public static let fullScreen      = WindowTags(rawValue: 1 << 14)
    public static let modal           = WindowTags(rawValue: 1 << 15)
    public static let borderless      = WindowTags(rawValue: 1 << 18)
    public static let floating        = WindowTags(rawValue: 1 << 26)
}

public final class SkyLightBridge: @unchecked Sendable {
    public static let shared = SkyLightBridge()

    private let frameworkHandle: UnsafeMutableRawPointer?

    private typealias SLSMainConnectionIDFunc = @convention(c) () -> CGSConnectionID
    private typealias SLSSetWindowTagsFunc = @convention(c) (CGSConnectionID, CGWindowID, UnsafePointer<UInt32>, Int) -> CGError
    private typealias SLSClearWindowTagsFunc = @convention(c) (CGSConnectionID, CGWindowID, UnsafePointer<UInt32>, Int) -> CGError
    private typealias SLSGetWindowTagsFunc = @convention(c) (CGSConnectionID, CGWindowID, UnsafeMutablePointer<UInt32>, Int) -> CGError
    private typealias SLSMoveWindowFunc = @convention(c) (CGSConnectionID, CGWindowID, UnsafePointer<CGPoint>) -> CGError
    private typealias SLSOrderWindowFunc = @convention(c) (CGSConnectionID, CGWindowID, Int32, CGWindowID) -> CGError
    private typealias SLSGetWindowBoundsFunc = @convention(c) (CGSConnectionID, CGWindowID, UnsafeMutablePointer<CGRect>) -> CGError
    private typealias SLSSetWindowAlphaFunc = @convention(c) (CGSConnectionID, CGWindowID, Float) -> CGError
    private typealias SLSSetWindowLevelFunc = @convention(c) (CGSConnectionID, CGWindowID, Int32) -> CGError
    private typealias SLSSetWindowCornerRadiusFunc = @convention(c) (CGSConnectionID, CGWindowID, Float) -> CGError

    private let _mainConnectionID: SLSMainConnectionIDFunc?
    private let _setWindowTags: SLSSetWindowTagsFunc?
    private let _clearWindowTags: SLSClearWindowTagsFunc?
    private let _getWindowTags: SLSGetWindowTagsFunc?
    private let _moveWindow: SLSMoveWindowFunc?
    private let _orderWindow: SLSOrderWindowFunc?
    private let _getWindowBounds: SLSGetWindowBoundsFunc?
    private let _setWindowAlpha: SLSSetWindowAlphaFunc?
    private let _setWindowLevel: SLSSetWindowLevelFunc?
    private let _setWindowCornerRadius: SLSSetWindowCornerRadiusFunc?

    private init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        let handle = dlopen(path, RTLD_LAZY)
        self.frameworkHandle = handle

        func resolve<T>(_ names: [String]) -> T? {
            for name in names {
                if let h = handle, let sym = dlsym(h, name) {
                    return unsafeBitCast(sym, to: T.self)
                }
                if let sym = dlsym(dlopen(nil, RTLD_LAZY), name) {
                    return unsafeBitCast(sym, to: T.self)
                }
            }
            return nil
        }

        self._mainConnectionID = resolve(["SLSMainConnectionID", "CGSMainConnectionID"])
        self._setWindowTags = resolve(["SLSSetWindowTags", "CGSSetWindowTags"])
        self._clearWindowTags = resolve(["SLSClearWindowTags", "CGSClearWindowTags"])
        self._getWindowTags = resolve(["SLSGetWindowTags", "CGSGetWindowTags"])
        self._moveWindow = resolve(["SLSMoveWindow", "CGSMoveWindow"])
        self._orderWindow = resolve(["SLSOrderWindow", "CGSOrderWindow"])
        self._getWindowBounds = resolve(["SLSGetWindowBounds", "CGSGetWindowBounds"])
        self._setWindowAlpha = resolve(["SLSSetWindowAlpha", "CGSSetWindowAlpha"])
        self._setWindowLevel = resolve(["SLSSetWindowLevel", "CGSSetWindowLevel"])
        self._setWindowCornerRadius = resolve(["SLSWindowSetCornerRadius", "CGSSetWindowCornerRadius", "SLSSetWindowCornerRadius", "CGSWindowSetCornerRadius"])
    }

    deinit {
        if let handle = frameworkHandle {
            dlclose(handle)
        }
    }

    public var mainConnectionID: CGSConnectionID {
        guard let fn = _mainConnectionID else { return 0 }
        return fn()
    }

    // MARK: - Hook Availability Routing Check

    public var isHookAvailable: Bool {
        HyprServerBridge.shared.isAvailable
    }

    public func checkHookAvailable() -> Bool {
        HyprServerBridge.shared.isAvailable
    }

    public func getWindowBounds(windowID: CGWindowID) -> CGRect? {
        guard let fn = _getWindowBounds else { return nil }
        var rect = CGRect.zero
        let err = fn(mainConnectionID, windowID, &rect)
        guard err == 0 else { return nil }
        return rect
    }

    @discardableResult
    public func moveWindow(windowID: CGWindowID, to point: CGPoint) -> Bool {
        guard let fn = _moveWindow else { return false }
        var pt = point
        let err = fn(mainConnectionID, windowID, &pt)
        return err == 0
    }

    @discardableResult
    public func orderWindow(windowID: CGWindowID, op: WindowOrderOp, relativeTo: CGWindowID = 0) -> Bool {
        guard let fn = _orderWindow else { return false }
        let err = fn(mainConnectionID, windowID, op.rawValue, relativeTo)
        return err == 0
    }

    public func getWindowTags(windowID: CGWindowID) -> (tag0: UInt32, tag1: UInt32)? {
        guard let fn = _getWindowTags else { return nil }
        var tags: [UInt32] = [0, 0]
        let err = fn(mainConnectionID, windowID, &tags, 64)
        guard err == 0 else { return nil }
        return (tags[0], tags[1])
    }

    @discardableResult
    public func setWindowTags(windowID: CGWindowID, tag0: UInt32, tag1: UInt32 = 0) -> Bool {
        guard let fn = _setWindowTags else { return false }
        var tags: [UInt32] = [tag0, tag1]
        let err = fn(mainConnectionID, windowID, &tags, 64)
        return err == 0
    }

    @discardableResult
    public func clearWindowTags(windowID: CGWindowID, tag0: UInt32, tag1: UInt32 = 0) -> Bool {
        guard let fn = _clearWindowTags else { return false }
        var tags: [UInt32] = [tag0, tag1]
        let err = fn(mainConnectionID, windowID, &tags, 64)
        return err == 0
    }

    @discardableResult
    public func stripTitlebar(windowID: CGWindowID) -> Bool {
        if isHookAvailable {
            return HyprServerBridge.shared.setTitlebar(windowId: windowID, stripped: true)
        }
        let tagsToSet = WindowTags.titlebarless.rawValue | WindowTags.borderless.rawValue
        return setWindowTags(windowID: windowID, tag0: tagsToSet, tag1: 0)
    }

    @discardableResult
    public func restoreTitlebar(windowID: CGWindowID) -> Bool {
        if isHookAvailable {
            return HyprServerBridge.shared.setTitlebar(windowId: windowID, stripped: false)
        }
        let tagsToClear = WindowTags.titlebarless.rawValue | WindowTags.borderless.rawValue
        return clearWindowTags(windowID: windowID, tag0: tagsToClear, tag1: 0)
    }

    @discardableResult
    public func setCornerRadius(windowID: CGWindowID, radius: Float) -> Bool {
        if isHookAvailable {
            return HyprServerBridge.shared.setCornerRadius(windowId: windowID, radius: radius)
        }
        if let fn = _setWindowCornerRadius {
            return fn(mainConnectionID, windowID, radius) == 0
        }
        return false
    }

    @discardableResult
    public func setShadow(windowID: CGWindowID, enabled: Bool) -> Bool {
        if isHookAvailable {
            return HyprServerBridge.shared.setShadow(windowId: windowID, enabled: enabled)
        }
        if enabled {
            return clearWindowTags(windowID: windowID, tag0: WindowTags.disableShadow.rawValue, tag1: 0)
        } else {
            return setWindowTags(windowID: windowID, tag0: WindowTags.disableShadow.rawValue, tag1: 0)
        }
    }

    @discardableResult
    public func setBorder(windowID: CGWindowID, width: Float, activeColor: UInt32, inactiveColor: UInt32) -> Bool {
        if isHookAvailable {
            return HyprServerBridge.shared.setBorder(windowId: windowID, width: width, activeColor: activeColor, inactiveColor: inactiveColor)
        }
        return false
    }

    @discardableResult
    public func setWindowAlpha(windowID: CGWindowID, alpha: Float) -> Bool {
        guard let fn = _setWindowAlpha else { return false }
        let err = fn(mainConnectionID, windowID, alpha)
        return err == 0
    }

    @discardableResult
    public func setWindowLevel(windowID: CGWindowID, level: Int32) -> Bool {
        guard let fn = _setWindowLevel else { return false }
        let err = fn(mainConnectionID, windowID, level)
        return err == 0
    }
}
