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

public struct ProcessSerialNumber: Sendable {
    public var highLongOfPSN: UInt32 = 0
    public var lowLongOfPSN: UInt32 = 0
    public init(highLongOfPSN: UInt32 = 0, lowLongOfPSN: UInt32 = 0) {
        self.highLongOfPSN = highLongOfPSN
        self.lowLongOfPSN = lowLongOfPSN
    }
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

    public typealias SLSTransactionRef = UnsafeMutableRawPointer

    private let trackingLock = NSLock()
    public private(set) var lastAppliedTransforms: [CGWindowID: CGAffineTransform] = [:]
    public private(set) var lastAppliedAlphas: [CGWindowID: Float] = [:]

    public func getTrackedTransform(windowID: CGWindowID) -> CGAffineTransform? {
        trackingLock.lock()
        defer { trackingLock.unlock() }
        return lastAppliedTransforms[windowID]
    }

    public func getTrackedAlpha(windowID: CGWindowID) -> Float? {
        trackingLock.lock()
        defer { trackingLock.unlock() }
        return lastAppliedAlphas[windowID]
    }

    public func clearTracking() {
        trackingLock.lock()
        defer { trackingLock.unlock() }
        lastAppliedTransforms.removeAll()
        lastAppliedAlphas.removeAll()
    }

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
    private typealias SLSSetWindowBackgroundBlurRadiusFunc = @convention(c) (CGSConnectionID, CGWindowID, UInt32) -> CGError
    private typealias SLSDisableUpdateFunc = @convention(c) (CGSConnectionID) -> CGError
    private typealias SLSReenableUpdateFunc = @convention(c) (CGSConnectionID) -> CGError
    private typealias CGSetLocalEventsSuppressionIntervalFunc = @convention(c) (Double) -> Int32
    private typealias SLSSetWindowTransformFunc = @convention(c) (CGSConnectionID, CGWindowID, CGAffineTransform) -> CGError
    private typealias SLSGetWindowTransformFunc = @convention(c) (CGSConnectionID, CGWindowID, UnsafeMutablePointer<CGAffineTransform>) -> CGError
    private typealias SLSTransactionCreateFunc = @convention(c) (CGSConnectionID) -> SLSTransactionRef?
    private typealias SLSTransactionSetWindowTransformFunc = @convention(c) (SLSTransactionRef, CGWindowID, Int32, Int32, UnsafePointer<CGAffineTransform>) -> Void
    private typealias SLSTransactionCommitFunc = @convention(c) (SLSTransactionRef, Int32) -> Void
    private typealias GetProcessForPIDFunc = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus
    private typealias SLPSSetFrontProcessWithOptionsFunc = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias SLPSPostEventRecordToFunc = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Int32

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
    private let _setWindowBackgroundBlurRadius: SLSSetWindowBackgroundBlurRadiusFunc?
    private let _disableUpdate: SLSDisableUpdateFunc?
    private let _reenableUpdate: SLSReenableUpdateFunc?
    private let _setLocalEventsSuppressionInterval: CGSetLocalEventsSuppressionIntervalFunc?
    private let _setWindowTransform: SLSSetWindowTransformFunc?
    private let _getWindowTransform: SLSGetWindowTransformFunc?
    private let _transactionCreate: SLSTransactionCreateFunc?
    private let _transactionSetWindowTransform: SLSTransactionSetWindowTransformFunc?
    private let _transactionCommit: SLSTransactionCommitFunc?
    private let _getProcessForPID: GetProcessForPIDFunc?
    private let _slpsSetFrontProcessWithOptions: SLPSSetFrontProcessWithOptionsFunc?
    private let _slpsPostEventRecordTo: SLPSPostEventRecordToFunc?

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
        self._setWindowBackgroundBlurRadius = resolve(["SLSSetWindowBackgroundBlurRadius", "CGSSetWindowBackgroundBlurRadius"])
        self._disableUpdate = resolve(["SLSDisableUpdate", "CGSDisableUpdate"])
        self._reenableUpdate = resolve(["SLSReenableUpdate", "CGSReenableUpdate"])
        self._setLocalEventsSuppressionInterval = resolve(["CGSetLocalEventsSuppressionInterval"])
        self._setWindowTransform = resolve(["SLSSetWindowTransform", "CGSSetWindowTransform"])
        self._getWindowTransform = resolve(["SLSGetWindowTransform", "CGSGetWindowTransform"])
        self._transactionCreate = resolve(["SLSTransactionCreate", "CGSTransactionCreate"])
        self._transactionSetWindowTransform = resolve(["SLSTransactionSetWindowTransform", "CGSTransactionSetWindowTransform"])
        self._transactionCommit = resolve(["SLSTransactionCommit", "CGSTransactionCommit"])
        self._getProcessForPID = resolve(["GetProcessForPID"])
        self._slpsSetFrontProcessWithOptions = resolve(["_SLPSSetFrontProcessWithOptions"])
        self._slpsPostEventRecordTo = resolve(["SLPSPostEventRecordTo"])

        _ = self._setLocalEventsSuppressionInterval?(0.0)
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
    public func setWindowBackgroundBlurRadius(windowID: CGWindowID, radius: UInt32) -> Bool {
        guard let fn = _setWindowBackgroundBlurRadius else { return false }
        return fn(mainConnectionID, windowID, radius) == 0
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
        trackingLock.lock()
        lastAppliedAlphas[windowID] = alpha
        trackingLock.unlock()
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

    // MARK: - Window GPU Affine Transforms & Transactions

    public func getWindowTransform(windowID: CGWindowID) -> CGAffineTransform? {
        guard let fn = _getWindowTransform else { return nil }
        var transform = CGAffineTransform.identity
        let err = fn(mainConnectionID, windowID, &transform)
        guard err == 0 else { return nil }
        return transform
    }

    @discardableResult
    public func setWindowTransform(windowID: CGWindowID, transform: CGAffineTransform) -> Bool {
        trackingLock.lock()
        lastAppliedTransforms[windowID] = transform
        trackingLock.unlock()
        guard let fn = _setWindowTransform else { return false }
        let err = fn(mainConnectionID, windowID, transform)
        return err == 0
    }

    public func transactionCreate() -> SLSTransactionRef? {
        guard let fn = _transactionCreate else { return nil }
        return fn(mainConnectionID)
    }

    @discardableResult
    public func transactionSetWindowTransform(
        transaction: SLSTransactionRef,
        windowID: CGWindowID,
        transform: CGAffineTransform
    ) -> Bool {
        trackingLock.lock()
        lastAppliedTransforms[windowID] = transform
        trackingLock.unlock()
        guard let fn = _transactionSetWindowTransform else { return false }
        var xf = transform
        fn(transaction, windowID, 0, 0, &xf)
        return true
    }

    @discardableResult
    public func transactionCommit(transaction: SLSTransactionRef, sync: Bool = false) -> Bool {
        guard let fn = _transactionCommit else { return false }
        fn(transaction, sync ? 1 : 0)
        return true
    }

    // MARK: - Display Update Freezing & Latency Suppression

    @discardableResult
    public func disableUpdate() -> Bool {
        guard let fn = _disableUpdate else { return false }
        let err = fn(mainConnectionID)
        return err == 0
    }

    @discardableResult
    public func reenableUpdate() -> Bool {
        guard let fn = _reenableUpdate else { return false }
        let err = fn(mainConnectionID)
        return err == 0
    }

    @discardableResult
    public func setLocalEventsSuppressionInterval(_ interval: Double = 0.0) -> Bool {
        if let fn = _setLocalEventsSuppressionInterval {
            return fn(interval) == 0
        }
        return CGSetLocalEventsSuppressionInterval(interval) == 0
    }

    /// Activates a specific window in WindowServer and Carbon as the key window for a process,
    /// without pulling all other windows of the application to the front.
    @discardableResult
    public func makeKeyWindow(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getPsn = _getProcessForPID,
              let setFront = _slpsSetFrontProcessWithOptions,
              let postEvent = _slpsPostEventRecordTo else {
            return false
        }
        var psn = ProcessSerialNumber()
        guard withUnsafeMutablePointer(to: &psn, { getPsn(pid, UnsafeMutableRawPointer($0)) }) == 0 else {
            return false
        }

        let kCPSUserGenerated: UInt32 = 0x200
        var event1 = [UInt8](repeating: 0, count: 0x100)
        event1[0x04] = 0xf8
        event1[0x08] = 0x01
        event1[0x3a] = 0x10
        var widLittle = windowID.littleEndian
        withUnsafeBytes(of: &widLittle) { raw in
            for i in 0..<4 {
                event1[0x3c + i] = raw[i]
            }
        }
        for i in 0x20..<0x30 {
            event1[i] = 0xff
        }

        var event2 = event1
        event2[0x08] = 0x02

        let err1 = withUnsafeMutablePointer(to: &psn) { psnPtr in
            setFront(UnsafeMutableRawPointer(psnPtr), windowID, kCPSUserGenerated)
        }
        let err2 = withUnsafeMutablePointer(to: &psn) { psnPtr in
            event1.withUnsafeBytes { evPtr in
                postEvent(UnsafeMutableRawPointer(psnPtr), evPtr.baseAddress!)
            }
        }
        let err3 = withUnsafeMutablePointer(to: &psn) { psnPtr in
            event2.withUnsafeBytes { evPtr in
                postEvent(UnsafeMutableRawPointer(psnPtr), evPtr.baseAddress!)
            }
        }
        return err1 == 0 && err2 == 0 && err3 == 0
    }
}

@discardableResult
public func CGSetLocalEventsSuppressionInterval(_ seconds: Double) -> CGError {
    if let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGSetLocalEventsSuppressionInterval") {
        typealias Fn = @convention(c) (Double) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(seconds)
    }
    return 0
}
