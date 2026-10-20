import Foundation
import Darwin
import os.log
import CoreGraphics
import AppKit

// MARK: - Protocol Constants

public enum HyprProtocol {
    public static let magic: UInt32 = 0x48595052  // "HYPR"
    public static let version: UInt16 = 1
    public static let socketPath = "/tmp/hyprmac-server.sock"

    // Shared Memory IPC
    public static let shmPath = "/tmp/hyprmac-ipc.shm"
    public static let shmSize = 64 * 1024       // 64KB
    public static let cmdRingSize = 28 * 1024   // 28KB
    public static let rspRingSize = 28 * 1024   // 28KB
    public static let shmHeaderSize = 256
    public static let cmdRingOffset = 256
    public static let rspRingOffset = shmHeaderSize + cmdRingSize  // 28928
    public static let shmMagic: UInt32 = 0x48534D49     // "HSMI"
    public static let shmVersion: UInt32 = 1
}

public enum HyprCommand: UInt16, Sendable {
    case ping             = 0x0001
    case pong             = 0x0002
    case ack              = 0x0003
    case error            = 0x0004
    case setCornerRadius  = 0x0010
    case setShadowState   = 0x0011
    case setWindowBorder  = 0x0012
    case stripTitlebar    = 0x0013
    case setWindowFocus   = 0x0014
    case setGlobalPolicy  = 0x0015
    case setMenuBarSuppression = 0x0016
    case setWorkspaceTransform = 0x0017
    case queryWindow      = 0x0020
    case auth             = 0x0030
}

public enum HyprError: UInt32, Error, Sendable, CustomStringConvertible, LocalizedError {
    case success      = 0x0000
    case invalidWid   = 0x0001
    case invalidCmd   = 0x0002
    case unauthorized = 0x0003
    case hookUnavail  = 0x0006
    case `internal`   = 0x00FF

    public var description: String {
        switch self {
        case .success:
            return "Success"
        case .invalidWid:
            return "Invalid window ID"
        case .invalidCmd:
            return "Invalid command"
        case .unauthorized:
            return "Unauthorized"
        case .hookUnavail:
            return "Hook unavailable — WindowServer module not loaded"
        case .internal:
            return "Internal error"
        }
    }

    public var errorDescription: String? {
        description
    }
}

// MARK: - Notifications

extension Notification.Name {
    public static let hyprServerHookAvailable = Notification.Name("HyprServerHookAvailable")
    public static let hyprServerHookUnavailable = Notification.Name("HyprServerHookUnavailable")
}

// MARK: - Models

public struct WindowDecorationState: Sendable, Equatable {
    public let cornerRadius: Float
    public let shadowEnabled: Bool
    public let titlebarStripped: Bool
    public let borderColor: UInt32
    public let borderWidth: Float

    public init(
        cornerRadius: Float,
        shadowEnabled: Bool,
        titlebarStripped: Bool,
        borderColor: UInt32,
        borderWidth: Float
    ) {
        self.cornerRadius = cornerRadius
        self.shadowEnabled = shadowEnabled
        self.titlebarStripped = titlebarStripped
        self.borderColor = borderColor
        self.borderWidth = borderWidth
    }
}

public struct HyprGlobalPolicy: Sendable, Equatable {
    public var autoSquareCorners: Bool
    public var autoStripShadow: Bool
    public var autoStripTitlebar: Bool
    public var autoSetBorder: Bool
    public var borderWidth: Float
    public var borderColorActive: UInt32
    public var borderColorInactive: UInt32

    public init(
        autoSquareCorners: Bool = false,
        autoStripShadow: Bool = false,
        autoStripTitlebar: Bool = false,
        autoSetBorder: Bool = false,
        borderWidth: Float = 1.0,
        borderColorActive: UInt32 = 0x33CCFFEE,
        borderColorInactive: UInt32 = 0x595959AA
    ) {
        self.autoSquareCorners = autoSquareCorners
        self.autoStripShadow = autoStripShadow
        self.autoStripTitlebar = autoStripTitlebar
        self.autoSetBorder = autoSetBorder
        self.borderWidth = borderWidth
        self.borderColorActive = borderColorActive
        self.borderColorInactive = borderColorInactive
    }
}

// MARK: - Shared Memory Header (Protocol 1: 256-byte layout)

public struct HyprShmHeader {
    public var magic: UInt32          // HYPR_SHM_MAGIC (0x48534D49)
    public var version: UInt32        // HYPR_SHM_VERSION (1)
    public var hookPid: UInt32        // PID of WindowServer (written by hook)
    public var hookReady: UInt32      // 1 when hook has mapped and is polling
    public var cmdWritePos: UInt32    // Written by Swift
    public var cmdReadPos: UInt32     // Written by Hook
    public var rspWritePos: UInt32    // Written by Hook
    public var rspReadPos: UInt32     // Written by Swift
    public var reserved: (
        UInt64, UInt64, UInt64, UInt64,
        UInt64, UInt64, UInt64, UInt64,
        UInt64, UInt64, UInt64, UInt64,
        UInt64, UInt64, UInt64, UInt64,
        UInt64, UInt64, UInt64, UInt64,
        UInt64, UInt64, UInt64, UInt64,
        UInt64, UInt64, UInt64, UInt64
    )
}

public struct HyprResponseHeader: Sendable, Equatable {
    public let magic: UInt32
    public let version: UInt16
    public let commandId: UInt16
    public let sequence: UInt32
    public let windowId: UInt32
    public let payloadSize: UInt32

    public var command: HyprCommand? {
        HyprCommand(rawValue: commandId)
    }

    public init(
        magic: UInt32,
        version: UInt16,
        commandId: UInt16,
        sequence: UInt32,
        windowId: UInt32,
        payloadSize: UInt32
    ) {
        self.magic = magic
        self.version = version
        self.commandId = commandId
        self.sequence = sequence
        self.windowId = windowId
        self.payloadSize = payloadSize
    }
}

public typealias HyprMessageHeader = HyprResponseHeader

public enum HyprBridgeError: Error, LocalizedError, Sendable {
    case notConnected
    case timeout
    case shmMappingFailed(Int32)
    case invalidMagic(UInt32)
    case payloadTooLarge(UInt32)
    case serverError(HyprError, String)
    case unexpectedResponse(UInt16)
    case ringBufferFull

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "HyprServer shared memory not initialized or hook not ready"
        case .timeout:
            return "Shared memory operation timed out"
        case .shmMappingFailed(let code):
            return "Shared memory mapping failed: \(String(cString: strerror(code))) (errno \(code))"
        case .invalidMagic(let magic):
            return "Invalid protocol magic: 0x\(String(magic, radix: 16))"
        case .payloadTooLarge(let size):
            return "Payload size exceeds maximum allowed: \(size) bytes"
        case .serverError(let err, let msg):
            return "HyprServer error \(err): \(msg)"
        case .unexpectedResponse(let cmd):
            return "Unexpected response command: 0x\(String(cmd, radix: 16))"
        case .ringBufferFull:
            return "Shared memory command ring buffer is full"
        }
    }
}

// MARK: - Server Status Model

public struct HyprServerStatusInfo: Sendable, Equatable {
    public let isConnected: Bool
    public let serverVersion: UInt32?
    public let activeWindows: UInt32?
    public let versionString: String?

    public init(
        isConnected: Bool,
        serverVersion: UInt32? = nil,
        activeWindows: UInt32? = nil,
        versionString: String? = nil
    ) {
        self.isConnected = isConnected
        self.serverVersion = serverVersion
        self.activeWindows = activeWindows
        self.versionString = versionString
    }
}

// MARK: - Command Ring Buffer (Replay Queue)

public final class CommandRingBuffer: @unchecked Sendable {
    public static let defaultCapacity: Int = 64
    public let capacity: Int
    private var buffer: [Data?]
    private var head: Int = 0
    private var tail: Int = 0
    private var _count: Int = 0
    private var lock = os_unfair_lock()

    public init(capacity: Int = CommandRingBuffer.defaultCapacity) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
    }

    public var isEmpty: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _count == 0
    }

    public var countValue: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _count
    }

    public var count: Int {
        countValue
    }

    public func enqueue(_ data: Data) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if _count == capacity {
            buffer[tail] = data
            head = (head + 1) % capacity
            tail = (tail + 1) % capacity
        } else {
            buffer[tail] = data
            tail = (tail + 1) % capacity
            _count += 1
        }
    }

    public func dequeue() -> Data? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard _count > 0 else { return nil }
        let item = buffer[head]
        buffer[head] = nil
        head = (head + 1) % capacity
        _count -= 1
        return item
    }

    public func dequeueAll() -> [Data] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard _count > 0 else { return [] }
        var result: [Data] = []
        result.reserveCapacity(_count)
        while _count > 0 {
            if let item = buffer[head] {
                result.append(item)
            }
            buffer[head] = nil
            head = (head + 1) % capacity
            _count -= 1
        }
        tail = 0
        head = 0
        return result
    }

    public func clear() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        for i in 0..<capacity {
            buffer[i] = nil
        }
        head = 0
        tail = 0
        _count = 0
    }
}

// MARK: - Client Bridge

public final class HyprServerBridge: @unchecked Sendable {
    public static let shared = HyprServerBridge()

    public static let shmSize = HyprProtocol.shmSize
    public static let cmdRingSize = HyprProtocol.cmdRingSize
    public static let rspRingSize = HyprProtocol.rspRingSize
    public static let shmHeaderSize = HyprProtocol.shmHeaderSize
    public static let cmdRingOffset = HyprProtocol.cmdRingOffset
    public static let rspRingOffset = HyprProtocol.rspRingOffset

    public let shmPath: String
    public let socketPath: String

    private let log = OSLog(subsystem: "com.hyprmac.server-bridge", category: "ipc")
    private let queue = DispatchQueue(label: "com.hyprmac.server-bridge.ipc")
    private let queueKey = DispatchSpecificKey<Void>()

    private var shmFD: Int32 = -1
    private var shmBase: UnsafeMutableRawPointer? = nil
    private var shmHeader: UnsafeMutablePointer<HyprShmHeader>? = nil
    private var cmdRingBase: UnsafeMutablePointer<UInt8>? = nil
    private var rspRingBase: UnsafeMutablePointer<UInt8>? = nil

    private var _isAvailable: Bool = false
    private var authToken: Data?
    private var sequenceCounter: UInt32 = 0

    public let ringBuffer = CommandRingBuffer()
    public var replayQueue: CommandRingBuffer { ringBuffer }
    public var pendingCommandCount: Int { ringBuffer.countValue }

    private var cmdWritePosPtr: UnsafeMutablePointer<UInt32>? {
        shmBase?.advanced(by: 16).assumingMemoryBound(to: UInt32.self)
    }
    private var cmdReadPosPtr: UnsafeMutablePointer<UInt32>? {
        shmBase?.advanced(by: 20).assumingMemoryBound(to: UInt32.self)
    }
    private var rspWritePosPtr: UnsafeMutablePointer<UInt32>? {
        shmBase?.advanced(by: 24).assumingMemoryBound(to: UInt32.self)
    }
    private var rspReadPosPtr: UnsafeMutablePointer<UInt32>? {
        shmBase?.advanced(by: 28).assumingMemoryBound(to: UInt32.self)
    }
    private var hookReadyPtr: UnsafeMutablePointer<UInt32>? {
        shmBase?.advanced(by: 12).assumingMemoryBound(to: UInt32.self)
    }
    private var hookPidPtr: UnsafeMutablePointer<UInt32>? {
        shmBase?.advanced(by: 8).assumingMemoryBound(to: UInt32.self)
    }

    private func atomicLoad(_ ptr: UnsafeMutablePointer<UInt32>) -> UInt32 {
        OSMemoryBarrier()
        let val = ptr.pointee
        OSMemoryBarrier()
        return val
    }

    private func atomicStore(_ ptr: UnsafeMutablePointer<UInt32>, _ value: UInt32) {
        OSMemoryBarrier()
        ptr.pointee = value
        OSMemoryBarrier()
    }

    private func isHookReadyDirect() -> Bool {
        guard let ptr = hookReadyPtr else { return false }
        return atomicLoad(ptr) == 1
    }

    public var isHookReady: Bool {
        executeOnQueue { isHookReadyDirect() }
    }

    public var isAvailable: Bool {
        executeOnQueue { _isAvailable && shmBase != nil }
    }

    public var isAuthenticated: Bool {
        executeOnQueue { _isAvailable && isHookReadyDirect() }
    }

    public var hookPID: pid_t? {
        executeOnQueue {
            guard let ptr = hookPidPtr, isHookReadyDirect() else { return nil }
            let pid = atomicLoad(ptr)
            return pid > 0 ? pid_t(pid) : nil
        }
    }

    public init(shmPath: String = HyprProtocol.shmPath, socketPath: String = HyprProtocol.socketPath) {
        self.shmPath = shmPath
        self.socketPath = socketPath
        self.queue.setSpecific(key: queueKey, value: ())
        self.authToken = HyprServerBridge.loadAuthToken()
    }

    public convenience init(socketPath: String) {
        self.init(shmPath: HyprProtocol.shmPath, socketPath: socketPath)
    }

    deinit {
        executeOnQueue {
            if let base = shmBase {
                Darwin.munmap(base, HyprProtocol.shmSize)
                shmBase = nil
                shmHeader = nil
                cmdRingBase = nil
                rspRingBase = nil
            }
            if shmFD >= 0 {
                Darwin.close(shmFD)
                shmFD = -1
            }
            _isAvailable = false
        }
    }

    // MARK: - Queue Synchronization

    private func executeOnQueue<T>(_ block: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try block()
        } else {
            return try queue.sync(execute: block)
        }
    }

    // MARK: - Authentication

    private static let authTokenPath = "/tmp/hyprmac-auth-token"

    private static func loadAuthToken() -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authTokenPath)) else {
            return nil
        }
        guard data.count == 16 else { return nil }
        return data
    }

    /// Reload the auth token from disk (e.g. after a new loading session)
    public func reloadAuthToken() {
        executeOnQueue {
            self.authToken = HyprServerBridge.loadAuthToken()
        }
    }

    // MARK: - Shared Memory Management

    /// Sets up mmap shared memory at HYPR_SHM_PATH, initializes the HyprShmHeader, and configures ring pointers.
    @discardableResult
    public func setupSharedMemory(path: String = HyprProtocol.shmPath) -> Bool {
        executeOnQueue {
            if self.shmBase != nil {
                return true
            }

            os_log(.info, log: self.log, "Setting up shared memory at %{public}s", path)

            let fd = Darwin.open(path, O_RDWR | O_CREAT, 0o666)
            guard fd >= 0 else {
                let err = errno
                os_log(.error, log: self.log, "Failed to open shared memory file %{public}s: %{public}s (errno %d)",
                       path, String(cString: strerror(err)), err)
                self._isAvailable = false
                return false
            }

            Darwin.fchmod(fd, 0o666)

            if Darwin.ftruncate(fd, off_t(HyprProtocol.shmSize)) != 0 {
                let err = errno
                os_log(.error, log: self.log, "Failed to ftruncate shared memory file: %{public}s (errno %d)",
                       String(cString: strerror(err)), err)
                Darwin.close(fd)
                self._isAvailable = false
                return false
            }

            guard let map = Darwin.mmap(nil, HyprProtocol.shmSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
                  map != MAP_FAILED else {
                let err = errno
                os_log(.error, log: self.log, "Failed to mmap shared memory file: %{public}s (errno %d)",
                       String(cString: strerror(err)), err)
                Darwin.close(fd)
                self._isAvailable = false
                return false
            }

            self.shmFD = fd
            self.shmBase = map

            let hdrPtr = map.bindMemory(to: HyprShmHeader.self, capacity: 1)
            self.shmHeader = hdrPtr

            self.cmdRingBase = map.advanced(by: HyprProtocol.cmdRingOffset).assumingMemoryBound(to: UInt8.self)
            self.rspRingBase = map.advanced(by: HyprProtocol.rspRingOffset).assumingMemoryBound(to: UInt8.self)

            // Only initialize header layout if not already initialized by the hook
            if hdrPtr.pointee.magic != HyprProtocol.shmMagic {
                memset(map, 0, HyprProtocol.shmHeaderSize)
                hdrPtr.pointee.magic = HyprProtocol.shmMagic
                hdrPtr.pointee.version = HyprProtocol.shmVersion
                hdrPtr.pointee.hookPid = 0
                hdrPtr.pointee.hookReady = 0
                hdrPtr.pointee.cmdWritePos = 0
                hdrPtr.pointee.cmdReadPos = 0
                hdrPtr.pointee.rspWritePos = 0
                hdrPtr.pointee.rspReadPos = 0
            }
            OSMemoryBarrier()

            let wasAvailable = self._isAvailable
            self._isAvailable = true

            os_log(.info, log: self.log, "Shared memory initialized successfully (64KB mapped at %{public}s)", path)

            if !wasAvailable {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .hyprServerHookAvailable, object: self)
                }
            }

            return true
        }
    }

    /// Polls hdr->hook_ready until it becomes 1 (with timeout).
    @discardableResult
    public func waitForHook(timeout: TimeInterval = 10.0) -> Bool {
        executeOnQueue {
            if self.shmBase == nil {
                guard self.setupSharedMemory() else { return false }
            }
            guard let ptr = self.hookReadyPtr else { return false }
            if self.atomicLoad(ptr) == 1 {
                self.replayBufferedCommands()
                return true
            }

            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                if self.atomicLoad(ptr) == 1 {
                    let pid = self.hookPidPtr.map { self.atomicLoad($0) } ?? 0
                    os_log(.info, log: self.log, "HyprServer hook ready detected (pid: %u)", pid)
                    self.replayBufferedCommands()
                    return true
                }
                usleep(10_000) // 10ms
            }

            let ready = (self.atomicLoad(ptr) == 1)
            if ready {
                self.replayBufferedCommands()
            }
            return ready
        }
    }

    /// Backwards-compatible connect method: maps shared memory and waits for hook.
    @discardableResult
    public func connect(maxAttempts: Int = 1) -> Bool {
        guard setupSharedMemory() else { return false }
        return waitForHook(timeout: max(Double(maxAttempts), 1.0))
    }

    // MARK: - Replay Queue Execution

    private func replayBufferedCommands() {
        let commands = ringBuffer.dequeueAll()
        guard !commands.isEmpty else { return }
        os_log(.info, log: log, "Replaying %d buffered commands to HyprServer", commands.count)
        for (index, cmdData) in commands.enumerated() {
            do {
                try writeCommandToRing(message: cmdData)
                _ = try readResponse()
            } catch {
                os_log(.error, log: log, "Failed to replay command %d/%d: %{public}@. Re-enqueuing remaining.",
                       index + 1, commands.count, error.localizedDescription)
                for remaining in commands[index...] {
                    ringBuffer.enqueue(remaining)
                }
                break
            }
        }
    }

    // MARK: - Wire Protocol Serialization & Shared Memory Ring I/O

    public func buildMessage(command: HyprCommand, windowId: UInt32, payload: Data) -> Data {
        sequenceCounter = sequenceCounter &+ 1
        let seq = sequenceCounter

        var data = Data(capacity: 20 + payload.count)
        var magic = HyprProtocol.magic.littleEndian
        var version = HyprProtocol.version.littleEndian
        var cmd = command.rawValue.littleEndian
        var seqLE = seq.littleEndian
        var wid = windowId.littleEndian
        var size = UInt32(payload.count).littleEndian

        withUnsafeBytes(of: &magic) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &cmd) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &seqLE) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &wid) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }

        if !payload.isEmpty {
            data.append(payload)
        }

        return data
    }

    private func writeCommandToRing(message: Data, timeout: TimeInterval = 0.5) throws {
        guard let base = cmdRingBase, let wPtr = cmdWritePosPtr, let rPtr = cmdReadPosPtr else {
            throw HyprBridgeError.notConnected
        }

        let msgLen = UInt32(message.count)
        let totalBytes = 4 + Int(msgLen)
        let ringSize = HyprProtocol.cmdRingSize
        guard totalBytes <= ringSize - 8 else {
            throw HyprBridgeError.payloadTooLarge(msgLen)
        }

        let startUptime = ProcessInfo.processInfo.systemUptime
        var backoffUs: useconds_t = 50

        while true {
            let w = atomicLoad(wPtr)
            let r = atomicLoad(rPtr)

            if Int(w) + totalBytes <= ringSize {
                let hasSpace: Bool
                if w >= r {
                    if r == 0 {
                        hasSpace = (Int(w) + totalBytes < ringSize)
                    } else {
                        hasSpace = true
                    }
                } else {
                    hasSpace = (Int(w) + totalBytes < Int(r))
                }

                if hasSpace {
                    var leLen = msgLen.littleEndian
                    memcpy(base.advanced(by: Int(w)), &leLen, 4)
                    _ = message.withUnsafeBytes { raw in
                        memcpy(base.advanced(by: Int(w) + 4), raw.baseAddress!, message.count)
                    }
                    OSMemoryBarrier()
                    var newW = w + UInt32(totalBytes)
                    if newW == UInt32(ringSize) {
                        newW = 0
                    }
                    atomicStore(wPtr, newW)
                    return
                }
            } else {
                if r > 0 && totalBytes < Int(r) {
                    let rem = ringSize - Int(w)
                    if rem >= 4 {
                        var zero: UInt32 = 0
                        memcpy(base.advanced(by: Int(w)), &zero, 4)
                    } else if rem > 0 {
                        memset(base.advanced(by: Int(w)), 0, rem)
                    }
                    OSMemoryBarrier()
                    var leLen = msgLen.littleEndian
                    memcpy(base, &leLen, 4)
                    _ = message.withUnsafeBytes { raw in
                        memcpy(base.advanced(by: 4), raw.baseAddress!, message.count)
                    }
                    OSMemoryBarrier()
                    let newW = UInt32(totalBytes)
                    atomicStore(wPtr, newW)
                    return
                }
            }

            if (ProcessInfo.processInfo.systemUptime - startUptime) >= timeout {
                throw HyprBridgeError.timeout
            }
            usleep(backoffUs)
            if backoffUs < 1000 { backoffUs &*= 2 }
        }
    }

    private func readResponse(timeout: TimeInterval = 0.5) throws -> (header: HyprResponseHeader, payload: Data) {
        guard let base = rspRingBase, let wPtr = rspWritePosPtr, let rPtr = rspReadPosPtr else {
            throw HyprBridgeError.notConnected
        }

        let startUptime = ProcessInfo.processInfo.systemUptime
        let ringSize = HyprProtocol.rspRingSize
        var backoffUs: useconds_t = 50

        while true {
            let w = atomicLoad(wPtr)
            let r = atomicLoad(rPtr)

            if r != w {
                if ringSize - Int(r) < 4 {
                    atomicStore(rPtr, 0)
                    continue
                }

                var rawLen: UInt32 = 0
                memcpy(&rawLen, base.advanced(by: Int(r)), 4)
                let msgLen = UInt32(littleEndian: rawLen)

                if msgLen == 0 {
                    // Skip marker: wrap read_pos to 0
                    atomicStore(rPtr, 0)
                    continue
                }

                guard msgLen >= 20 else {
                    os_log(.error, log: log, "Corrupt response length in ring: %u", msgLen)
                    throw HyprBridgeError.unexpectedResponse(0)
                }
                guard msgLen <= 65536 else {
                    throw HyprBridgeError.payloadTooLarge(msgLen)
                }
                guard Int(r) + 4 + Int(msgLen) <= ringSize else {
                    os_log(.error, log: log, "Response exceeds ring buffer bounds: pos=%u, len=%u", r, msgLen)
                    throw HyprBridgeError.timeout
                }

                let msgData = Data(bytes: base.advanced(by: Int(r) + 4), count: Int(msgLen))

                var newR = r + 4 + msgLen
                if newR == UInt32(ringSize) {
                    newR = 0
                }
                atomicStore(rPtr, newR)

                let header = msgData.withUnsafeBytes { raw -> HyprResponseHeader in
                    let magic = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                    let version = raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self)
                    let commandId = raw.loadUnaligned(fromByteOffset: 6, as: UInt16.self)
                    let sequence = raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
                    let windowId = raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                    let payloadSize = raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
                    return HyprResponseHeader(
                        magic: magic,
                        version: version,
                        commandId: commandId,
                        sequence: sequence,
                        windowId: windowId,
                        payloadSize: payloadSize
                    )
                }

                guard header.magic == HyprProtocol.magic else {
                    os_log(.error, log: log, "Protocol magic mismatch: expected 0x%08X, got 0x%08X",
                           HyprProtocol.magic, header.magic)
                    throw HyprBridgeError.invalidMagic(header.magic)
                }

                var payload = Data()
                if header.payloadSize > 0 {
                    let expectedEnd = 20 + Int(header.payloadSize)
                    guard msgData.count >= expectedEnd else {
                        throw HyprBridgeError.timeout
                    }
                    payload = msgData.subdata(in: 20..<expectedEnd)
                }

                return (header: header, payload: payload)
            }

            if (ProcessInfo.processInfo.systemUptime - startUptime) >= timeout {
                throw HyprBridgeError.timeout
            }
            usleep(backoffUs)
            if backoffUs < 1000 { backoffUs &*= 2 }
        }
    }

    private func sendTransaction(
        command: HyprCommand,
        windowId: UInt32,
        payload: Data
    ) throws -> (header: HyprResponseHeader, payload: Data) {
        return try executeOnQueue {
            if self.shmBase == nil {
                guard self.setupSharedMemory() else {
                    throw HyprBridgeError.notConnected
                }
            }

            let message = self.buildMessage(command: command, windowId: windowId, payload: payload)

            do {
                os_log(.debug, log: self.log, "Sending command 0x%04X (wid: %u, bytes: %d)", command.rawValue, windowId, message.count)
                try self.writeCommandToRing(message: message)
                return try self.readResponse()
            } catch {
                os_log(.default, log: self.log, "Command 0x%04X attempt 1 failed: %{public}@. Retrying once...",
                       command.rawValue, error.localizedDescription)

                do {
                    try self.writeCommandToRing(message: message)
                    return try self.readResponse()
                } catch {
                    os_log(.error, log: self.log, "Command 0x%04X retry failed: %{public}@",
                           command.rawValue, error.localizedDescription)
                    throw error
                }
            }
        }
    }

    private func handleAckResponse(header: HyprResponseHeader, payload: Data, commandName: String) -> Bool {
        if header.commandId == HyprCommand.ack.rawValue {
            return true
        } else if header.commandId == HyprCommand.error.rawValue {
            var statusStr = "unknown"
            if payload.count >= 4 {
                let status = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
                statusStr = String(format: "0x%04X", status)
            }
            var msg = ""
            if payload.count > 4 {
                let msgBytes = payload.subdata(in: 4..<payload.count)
                msg = String(decoding: msgBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            os_log(.error, log: log, "%{public}s rejected by HyprServer with status %{public}s: %{public}s", commandName, statusStr, msg)
            return false
        } else {
            os_log(.error, log: log, "%{public}s received unexpected response command 0x%04X", commandName, header.commandId)
            return false
        }
    }

    @discardableResult
    private func sendMutation(
        command: HyprCommand,
        windowId: UInt32,
        payload: Data,
        commandName: String
    ) -> Bool {
        let message = buildMessage(command: command, windowId: windowId, payload: payload)

        return executeOnQueue {
            if self.shmBase == nil {
                _ = self.setupSharedMemory()
            }

            guard self.shmBase != nil && self.isHookReadyDirect() else {
                self.ringBuffer.enqueue(message)
                os_log(.default, log: self.log, "%{public}s buffered while hook not ready (wid: %u, queue size: %d)",
                       commandName, windowId, self.ringBuffer.countValue)
                return false
            }

            do {
                try self.writeCommandToRing(message: message)
                let response = try self.readResponse()
                let ok = self.handleAckResponse(header: response.header, payload: response.payload, commandName: commandName)
                if ok {
                    os_log(.info, log: self.log, "%{public}s succeeded for window %u", commandName, windowId)
                }
                return ok
            } catch {
                os_log(.default, log: self.log, "%{public}s attempt 1 failed: %{public}@. Retrying once...",
                       commandName, error.localizedDescription)

                do {
                    try self.writeCommandToRing(message: message)
                    let response = try self.readResponse()
                    return self.handleAckResponse(header: response.header, payload: response.payload, commandName: commandName)
                } catch {
                    os_log(.error, log: self.log, "%{public}s retry failed: %{public}@. Enqueuing in ring buffer.",
                           commandName, error.localizedDescription)
                    self.ringBuffer.enqueue(message)
                    return false
                }
            }
        }
    }

    // MARK: - Public API Methods

    /// Query server health, connection status, version, and active window count
    public func getServerStatus() -> HyprServerStatusInfo {
        do {
            let (header, payload) = try sendTransaction(command: .ping, windowId: 0, payload: Data())
            guard header.commandId == HyprCommand.pong.rawValue || header.commandId == HyprCommand.ack.rawValue else {
                return HyprServerStatusInfo(isConnected: false)
            }

            var ver: UInt32? = nil
            var activeWins: UInt32? = nil
            var verStr: String? = nil

            if payload.count >= 8 {
                let rawVer = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
                let rawWins = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
                ver = rawVer
                activeWins = rawWins
                let major = (rawVer >> 16) & 0xFF
                let minor = (rawVer >> 8) & 0xFF
                let patch = rawVer & 0xFF
                verStr = "\(major).\(minor).\(patch)"
            }

            return HyprServerStatusInfo(
                isConnected: true,
                serverVersion: ver,
                activeWindows: activeWins,
                versionString: verStr
            )
        } catch {
            return HyprServerStatusInfo(isConnected: false)
        }
    }

    /// Check if the hook is loaded and responsive
    @discardableResult
    public func ping() -> Bool {
        let status = getServerStatus()
        return status.isConnected
    }

    /// Set corner radius for a window (0.0 = square)
    @discardableResult
    public func setCornerRadius(windowId: UInt32, radius: Float) -> Bool {
        var r = radius
        var payload = Data(capacity: 4)
        withUnsafeBytes(of: &r) { payload.append(contentsOf: $0) }
        return sendMutation(command: .setCornerRadius, windowId: windowId, payload: payload, commandName: "setCornerRadius")
    }

    /// Enable/disable window shadow
    @discardableResult
    public func setShadow(windowId: UInt32, enabled: Bool) -> Bool {
        let s: UInt8 = enabled ? 1 : 0
        let payload = Data([s])
        return sendMutation(command: .setShadowState, windowId: windowId, payload: payload, commandName: "setShadow")
    }

    /// Set window border
    @discardableResult
    public func setBorder(windowId: UInt32, width: Float, activeColor: UInt32, inactiveColor: UInt32) -> Bool {
        var w = width
        var act = activeColor
        var inact = inactiveColor
        var payload = Data(capacity: 12)
        withUnsafeBytes(of: &w) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &act) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &inact) { payload.append(contentsOf: $0) }
        return sendMutation(command: .setWindowBorder, windowId: windowId, payload: payload, commandName: "setBorder")
    }

    /// Strip or restore titlebar
    @discardableResult
    public func setTitlebar(windowId: UInt32, stripped: Bool) -> Bool {
        let s: UInt8 = stripped ? 1 : 0
        let payload = Data([s])
        return sendMutation(command: .stripTitlebar, windowId: windowId, payload: payload, commandName: "setTitlebar")
    }

    /// Focus window via server hook
    @discardableResult
    public func setWindowFocus(windowId: UInt32) -> Bool {
        return sendMutation(command: .setWindowFocus, windowId: windowId, payload: Data(), commandName: "setWindowFocus")
    }

    /// Set global server decoration policy
    @discardableResult
    public func setGlobalPolicy(_ policy: HyprGlobalPolicy) -> Bool {
        var payload = Data(capacity: 16)
        let b0: UInt8 = policy.autoSquareCorners ? 1 : 0
        let b1: UInt8 = policy.autoStripShadow ? 1 : 0
        let b2: UInt8 = policy.autoStripTitlebar ? 1 : 0
        let b3: UInt8 = policy.autoSetBorder ? 1 : 0
        var bw = policy.borderWidth
        var ca = policy.borderColorActive
        var ci = policy.borderColorInactive

        payload.append(b0)
        payload.append(b1)
        payload.append(b2)
        payload.append(b3)
        withUnsafeBytes(of: &bw) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &ca) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &ci) { payload.append(contentsOf: $0) }

        return sendMutation(command: .setGlobalPolicy, windowId: 0, payload: payload, commandName: "setGlobalPolicy")
    }

    /// Suppress or restore native macOS menu bar reveal at the compositor level
    @discardableResult
    public func setMenuBarSuppression(suppress: Bool, exemptWid: UInt32 = 0) throws -> Bool {
        var effectiveExemptWid = exemptWid
        if effectiveExemptWid == 0 && suppress {
            if Thread.isMainThread {
                if let barWid = MainActor.assumeIsolated({ HyprBarWindow.shared?.windowNumber }), barWid > 0 {
                    effectiveExemptWid = UInt32(barWid)
                }
            } else {
                effectiveExemptWid = DispatchQueue.main.sync {
                    if let barWid = HyprBarWindow.shared?.windowNumber, barWid > 0 {
                        return UInt32(barWid)
                    }
                    return 0
                }
            }
        }

        var targetWIDs: [UInt32] = []
        if let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            let myPid = getpid()
            for item in windowList {
                let layer = item[kCGWindowLayer as String] as? Int ?? -1
                let owner = item[kCGWindowOwnerName as String] as? String ?? ""
                let name = item[kCGWindowName as String] as? String ?? ""
                let pid = item[kCGWindowOwnerPID as String] as? pid_t ?? 0

                guard owner != "HyprMac" && pid != myPid else { continue }

                if layer == 24 || owner == "MenuBarAgent" || (owner == "Window Server" && name.contains("Menubar")) {
                    if let wid = item[kCGWindowNumber as String] as? CGWindowID, wid > 0 {
                        if wid != effectiveExemptWid && !targetWIDs.contains(wid) {
                            targetWIDs.append(wid)
                            if targetWIDs.count >= 32 { break }
                        }
                    }
                }
            }
        }

        var payload = Data()
        var sVal: UInt32 = suppress ? 1 : 0
        var exVal: UInt32 = effectiveExemptWid
        var cVal: UInt32 = UInt32(targetWIDs.count)
        withUnsafeBytes(of: &sVal) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &exVal) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &cVal) { payload.append(contentsOf: $0) }
        for wid in targetWIDs {
            var w = wid
            withUnsafeBytes(of: &w) { payload.append(contentsOf: $0) }
        }
        if targetWIDs.count < 32 {
            let pad = (32 - targetWIDs.count) * MemoryLayout<UInt32>.size
            payload.append(Data(count: pad))
        }

        let (header, responsePayload) = try sendTransaction(
            command: .setMenuBarSuppression,
            windowId: 0,
            payload: payload
        )
        let success = handleAckResponse(header: header, payload: responsePayload, commandName: "setMenuBarSuppression")
        if success {
            KeybindManager.shared.isMenuBarSuppressed = suppress
        }
        return success
    }

    /// Apply GPU-accelerated workspace transforms (2x2 matrix, translation, opacity) in SkyLight WindowServer
    @discardableResult
    public func setWorkspaceTransform(entries: [(windowID: CGWindowID, transform: CGAffineTransform, alpha: Float)]) -> Bool {
        guard !entries.isEmpty else { return true }

        var overallSuccess = true
        let strideSize = 32

        for chunkStart in stride(from: 0, to: entries.count, by: strideSize) {
            let chunkEnd = min(chunkStart + strideSize, entries.count)
            let chunk = entries[chunkStart..<chunkEnd]

            var payload = Data()
            var countVal = UInt32(chunk.count)
            withUnsafeBytes(of: &countVal) { payload.append(contentsOf: $0) }

            for item in chunk {
                var wid = UInt32(item.windowID)
                var a = Float(item.transform.a)
                var b = Float(item.transform.b)
                var c = Float(item.transform.c)
                var d = Float(item.transform.d)
                var tx = Float(item.transform.tx)
                var ty = Float(item.transform.ty)
                var alpha = item.alpha

                withUnsafeBytes(of: &wid) { payload.append(contentsOf: $0) }
                withUnsafeBytes(of: &a) { payload.append(contentsOf: $0) }
                withUnsafeBytes(of: &b) { payload.append(contentsOf: $0) }
                withUnsafeBytes(of: &c) { payload.append(contentsOf: $0) }
                withUnsafeBytes(of: &d) { payload.append(contentsOf: $0) }
                withUnsafeBytes(of: &tx) { payload.append(contentsOf: $0) }
                withUnsafeBytes(of: &ty) { payload.append(contentsOf: $0) }
                withUnsafeBytes(of: &alpha) { payload.append(contentsOf: $0) }
            }

            if chunk.count < 32 {
                let padBytes = (32 - chunk.count) * 32
                payload.append(Data(count: padBytes))
            }

            let ok = sendMutation(
                command: .setWorkspaceTransform,
                windowId: 0,
                payload: payload,
                commandName: "setWorkspaceTransform"
            )
            if !ok {
                overallSuccess = false
            }
        }

        return overallSuccess
    }

    /// Reset workspace transforms and alpha to identity for given window IDs
    @discardableResult
    public func resetWorkspaceTransforms(windowIDs: [CGWindowID]) -> Bool {
        guard !windowIDs.isEmpty else { return true }
        let entries = windowIDs.map { (windowID: $0, transform: CGAffineTransform.identity, alpha: Float(1.0)) }
        return setWorkspaceTransform(entries: entries)
    }

    /// Query window decoration state
    public func queryWindow(windowId: UInt32) -> WindowDecorationState? {
        do {
            let (header, payload) = try sendTransaction(command: .queryWindow, windowId: windowId, payload: Data())
            guard header.commandId == HyprCommand.ack.rawValue else {
                os_log(.default, log: log, "queryWindow(wid: %u) returned non-ACK status: 0x%04X", windowId, header.commandId)
                return nil
            }
            guard payload.count >= 14 else {
                os_log(.error, log: log, "queryWindow(wid: %u) payload too small: %d bytes (expected >= 14)", windowId, payload.count)
                return nil
            }

            let cornerRadius = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Float.self) }
            let shadowEnabled = payload[4] != 0
            let titlebarStripped = payload[5] != 0
            let borderColor = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt32.self) }
            let borderWidth = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 10, as: Float.self) }

            os_log(.info, log: log, "queryWindow(wid: %u) success (radius: %.2f, shadow: %{public}s, titlebar: %{public}s, border: 0x%08X, width: %.2f)",
                   windowId, cornerRadius, shadowEnabled ? "true" : "false", titlebarStripped ? "stripped" : "native", borderColor, borderWidth)

            return WindowDecorationState(
                cornerRadius: cornerRadius,
                shadowEnabled: shadowEnabled,
                titlebarStripped: titlebarStripped,
                borderColor: borderColor,
                borderWidth: borderWidth
            )
        } catch {
            os_log(.default, log: log, "queryWindow(wid: %u) failed: %{public}@", windowId, error.localizedDescription)
            return nil
        }
    }

    // MARK: - Convenience Methods for Hyprland-Style Decorations

    /// Apply full Hyprland-style decoration: square corners, no shadow, thin border
    public func applyHyprlandStyle(
        windowId: UInt32,
        borderWidth: Float = 1.0,
        activeColor: UInt32 = 0xFF00AAFF,
        inactiveColor: UInt32 = 0xFF444444
    ) {
        setCornerRadius(windowId: windowId, radius: 0.0)
        setShadow(windowId: windowId, enabled: false)
        setBorder(windowId: windowId, width: borderWidth, activeColor: activeColor, inactiveColor: inactiveColor)
        setTitlebar(windowId: windowId, stripped: true)
    }

    /// Restore macOS native decorations
    public func restoreNativeStyle(windowId: UInt32) {
        setCornerRadius(windowId: windowId, radius: 10.0)
        setShadow(windowId: windowId, enabled: true)
        setBorder(windowId: windowId, width: 0.0, activeColor: 0, inactiveColor: 0)
        setTitlebar(windowId: windowId, stripped: false)
    }
}

