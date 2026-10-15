import Foundation
import Darwin
import os.log

// MARK: - Protocol Constants

public enum HyprProtocol {
    public static let magic: UInt32 = 0x48595052  // "HYPR"
    public static let version: UInt16 = 1
    public static let socketPath = "/tmp/hyprmac-server.sock"
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
    case queryWindow      = 0x0020
    case auth             = 0x0030
}

public enum HyprError: UInt32, Error, Sendable {
    case success    = 0x0000
    case invalidWid = 0x0001
    case invalidCmd = 0x0002
    case unauthorized = 0x0003
    case `internal` = 0x00FF
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
    case connectionClosed
    case timeout
    case socketError(Int32)
    case invalidMagic(UInt32)
    case payloadTooLarge(UInt32)
    case serverError(HyprError, String)
    case unexpectedResponse(UInt16)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to HyprServer socket"
        case .connectionClosed:
            return "Connection closed by HyprServer"
        case .timeout:
            return "Socket operation timed out"
        case .socketError(let code):
            return "Socket error: \(String(cString: strerror(code))) (errno \(code))"
        case .invalidMagic(let magic):
            return "Invalid protocol magic: 0x\(String(magic, radix: 16))"
        case .payloadTooLarge(let size):
            return "Payload size exceeds maximum allowed: \(size) bytes"
        case .serverError(let err, let msg):
            return "HyprServer error \(err): \(msg)"
        case .unexpectedResponse(let cmd):
            return "Unexpected response command: 0x\(String(cmd, radix: 16))"
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

    public let socketPath: String

    private let log = OSLog(subsystem: "com.hyprmac.server-bridge", category: "ipc")
    private let queue = DispatchQueue(label: "com.hyprmac.server-bridge.ipc")
    private let queueKey = DispatchSpecificKey<Void>()

    private var socketFD: Int32 = -1
    private var _isAvailable: Bool = false
    private var _isAuthenticated: Bool = false
    private var authToken: Data?
    private var sequenceCounter: UInt32 = 0

    public let ringBuffer = CommandRingBuffer()
    public var replayQueue: CommandRingBuffer { ringBuffer }
    public var pendingCommandCount: Int { ringBuffer.countValue }

    private var reconnectAttempts: Int = 0
    private var isReconnecting: Bool = false
    private let initialBackoff: TimeInterval = 0.1   // 100ms
    private let maxBackoff: TimeInterval = 5.0       // 5s
    private let maxReconnectAttempts: Int = 10

    public var isAvailable: Bool {
        executeOnQueue { _isAvailable }
    }

    public init(socketPath: String = HyprProtocol.socketPath) {
        self.socketPath = socketPath
        self.queue.setSpecific(key: queueKey, value: ())
        self.authToken = HyprServerBridge.loadAuthToken()
    }

    deinit {
        executeOnQueue {
            if socketFD >= 0 {
                Darwin.close(socketFD)
                socketFD = -1
            }
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

    // MARK: - Connection Management

    @discardableResult
    private func connectSocket() -> Bool {
        if socketFD >= 0 {
            return true
        }

        os_log(.debug, log: log, "Attempting connection to HyprServer at %{public}s", socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let err = errno
            os_log(.error, log: log, "Failed to create AF_UNIX socket: %{public}s (errno %d)", String(cString: strerror(err)), err)
            _isAvailable = false
            return false
        }

        // Prevent SIGPIPE on write failures
        var nosigpipe: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        // Set 500ms send & receive timeouts
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            os_log(.error, log: log, "Socket path exceeds sockaddr_un buffer: %{public}s", socketPath)
            Darwin.close(fd)
            _isAvailable = false
            return false
        }

        _ = withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            pathBytes.withUnsafeBytes { src in
                memcpy(ptr.baseAddress!, src.baseAddress!, src.count)
            }
        }
        addr.sun_len = UInt8(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count - 1)

        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectRes != 0 {
            let err = errno
            if err == ECONNREFUSED || err == ENOENT {
                os_log(.default, log: log, "HyprServer socket connection failed (%{public}s): %{public}s",
                       err == ECONNREFUSED ? "ECONNREFUSED" : "ENOENT",
                       String(cString: strerror(err)))
            } else {
                os_log(.error, log: log, "HyprServer socket connection error: %{public}s (errno %d)",
                       String(cString: strerror(err)), err)
            }
            Darwin.close(fd)
            _isAvailable = false
            return false
        }

        socketFD = fd
        let wasAvailable = _isAvailable
        _isAvailable = true
        _isAuthenticated = false

        // Authenticate immediately after connecting
        if let token = authToken {
            let authMsg = buildMessage(command: .auth, windowId: 0, payload: token)
            do {
                try writeExact(authMsg)
                let resp = try readResponse()
                if resp.header.commandId == HyprCommand.ack.rawValue {
                    _isAuthenticated = true
                    os_log(.info, log: log, "Authenticated with HyprServer successfully")
                } else {
                    os_log(.error, log: log, "Authentication rejected by HyprServer (cmd: 0x%04X)", resp.header.commandId)
                    Darwin.close(fd)
                    socketFD = -1
                    _isAvailable = false
                    return false
                }
            } catch {
                os_log(.error, log: log, "Authentication handshake failed: %{public}@", error.localizedDescription)
                Darwin.close(fd)
                socketFD = -1
                _isAvailable = false
                return false
            }
        }

        reconnectAttempts = 0
        isReconnecting = false
        os_log(.info, log: log, "Connected to HyprServer socket at %{public}s", socketPath)

        if !wasAvailable {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .hyprServerHookAvailable, object: self)
            }
        }

        replayBufferedCommands()
        return true
    }

    public func disconnect() {
        executeOnQueue {
            disconnectSocket()
        }
    }

    private func disconnectSocket() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            _isAuthenticated = false
            socketFD = -1
            os_log(.info, log: log, "Disconnected from HyprServer socket")
        }
        let wasAvailable = _isAvailable
        _isAvailable = false
        if wasAvailable {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .hyprServerHookUnavailable, object: self)
            }
        }
    }

    private func scheduleReconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true
        reconnectAttempts = 0
        attemptScheduledReconnect()
    }

    private func attemptScheduledReconnect() {
        executeOnQueue {
            guard self.isReconnecting else { return }
            self.reconnectAttempts += 1

            if self.reconnectAttempts > self.maxReconnectAttempts {
                self.isReconnecting = false
                os_log(.error, log: self.log, "Exhausted all %d reconnection attempts to HyprServer", self.maxReconnectAttempts)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .hyprServerHookUnavailable, object: self)
                }
                return
            }

            let backoff = min(self.initialBackoff * pow(2.0, Double(self.reconnectAttempts - 1)), self.maxBackoff)
            os_log(.default, log: self.log, "Reconnection attempt %d/%d scheduled in %.2f seconds",
                   self.reconnectAttempts, self.maxReconnectAttempts, backoff)

            self.queue.asyncAfter(deadline: .now() + backoff) { [weak self] in
                guard let self = self else { return }
                self.executeOnQueue {
                    guard self.isReconnecting else { return }
                    if self.connectSocket() {
                        os_log(.info, log: self.log, "Successfully reconnected to HyprServer on attempt %d", self.reconnectAttempts)
                    } else {
                        self.attemptScheduledReconnect()
                    }
                }
            }
        }
    }

    @discardableResult
    public func connect(maxAttempts: Int = 1) -> Bool {
        executeOnQueue {
            if self.socketFD >= 0 {
                return true
            }
            if maxAttempts <= 1 {
                let success = self.connectSocket()
                if !success {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .hyprServerHookUnavailable, object: self)
                    }
                    self.scheduleReconnect()
                }
                return success
            }
            for attempt in 1...maxAttempts {
                if self.connectSocket() {
                    return true
                }
                if attempt < maxAttempts {
                    let backoff = min(self.initialBackoff * pow(2.0, Double(attempt - 1)), self.maxBackoff)
                    os_log(.default, log: self.log, "Reconnection attempt %d/%d failed; backing off for %.2f seconds",
                           attempt, maxAttempts, backoff)
                    Thread.sleep(forTimeInterval: backoff)
                }
            }
            os_log(.error, log: self.log, "Exhausted all %d reconnection attempts to HyprServer", maxAttempts)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .hyprServerHookUnavailable, object: self)
            }
            return false
        }
    }

    // MARK: - Replay Queue Execution

    private func replayBufferedCommands() {
        let commands = ringBuffer.dequeueAll()
        guard !commands.isEmpty else { return }
        os_log(.info, log: log, "Replaying %d buffered commands to HyprServer", commands.count)
        for (index, cmdData) in commands.enumerated() {
            do {
                try writeExact(cmdData)
                _ = try readResponse()
            } catch {
                os_log(.error, log: log, "Failed to replay command %d/%d: %{public}@. Re-enqueuing remaining.",
                       index + 1, commands.count, error.localizedDescription)
                for remaining in commands[index...] {
                    ringBuffer.enqueue(remaining)
                }
                disconnectSocket()
                scheduleReconnect()
                break
            }
        }
    }

    // MARK: - Wire Protocol Serialization & I/O

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

    private func writeExact(_ data: Data) throws {
        guard socketFD >= 0 else {
            throw HyprBridgeError.notConnected
        }
        var totalWritten = 0
        let total = data.count
        while totalWritten < total {
            let n = data.withUnsafeBytes { raw in
                let ptr = raw.baseAddress!.advanced(by: totalWritten)
                return Darwin.send(socketFD, ptr, total - totalWritten, 0)
            }
            if n > 0 {
                totalWritten += n
            } else if n == 0 {
                disconnectSocket()
                throw HyprBridgeError.connectionClosed
            } else {
                let err = errno
                if err == EINTR {
                    continue
                } else if err == EAGAIN || err == EWOULDBLOCK {
                    throw HyprBridgeError.timeout
                } else {
                    disconnectSocket()
                    throw HyprBridgeError.socketError(err)
                }
            }
        }
    }

    private func readExact(count: Int) throws -> Data {
        guard socketFD >= 0 else {
            throw HyprBridgeError.notConnected
        }
        var data = Data(count: count)
        var totalRead = 0
        while totalRead < count {
            let n = data.withUnsafeMutableBytes { raw in
                let ptr = raw.baseAddress!.advanced(by: totalRead)
                return Darwin.recv(socketFD, ptr, count - totalRead, 0)
            }
            if n > 0 {
                totalRead += n
            } else if n == 0 {
                disconnectSocket()
                throw HyprBridgeError.connectionClosed
            } else {
                let err = errno
                if err == EINTR {
                    continue
                } else if err == EAGAIN || err == EWOULDBLOCK {
                    throw HyprBridgeError.timeout
                } else {
                    disconnectSocket()
                    throw HyprBridgeError.socketError(err)
                }
            }
        }
        return data
    }

    private func readResponse() throws -> (header: HyprResponseHeader, payload: Data) {
        let headerData = try readExact(count: 20)
        let header = headerData.withUnsafeBytes { raw -> HyprResponseHeader in
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
            os_log(.error, log: log, "Protocol magic mismatch: expected 0x%08X, got 0x%08X", HyprProtocol.magic, header.magic)
            throw HyprBridgeError.invalidMagic(header.magic)
        }

        var payload = Data()
        if header.payloadSize > 0 {
            guard header.payloadSize <= 65536 else {
                os_log(.error, log: log, "Payload size exceeds 64KB limit: %u", header.payloadSize)
                throw HyprBridgeError.payloadTooLarge(header.payloadSize)
            }
            payload = try readExact(count: Int(header.payloadSize))
        }

        return (header: header, payload: payload)
    }

    private func sendTransaction(
        command: HyprCommand,
        windowId: UInt32,
        payload: Data
    ) throws -> (header: HyprResponseHeader, payload: Data) {
        return try executeOnQueue {
            if self.socketFD < 0 {
                guard self.connectSocket() else {
                    self.scheduleReconnect()
                    throw HyprBridgeError.notConnected
                }
            }

            let message = self.buildMessage(command: command, windowId: windowId, payload: payload)

            // Attempt 1
            do {
                os_log(.debug, log: self.log, "Sending command 0x%04X (wid: %u, bytes: %d)", command.rawValue, windowId, message.count)
                try self.writeExact(message)
                let response = try self.readResponse()
                os_log(.debug, log: self.log, "Received response 0x%04X (seq: %u, bytes: %d)", response.header.commandId, response.header.sequence, response.payload.count)
                return response
            } catch {
                os_log(.default, log: self.log, "Command 0x%04X attempt 1 failed: %{public}@. Retrying once...",
                       command.rawValue, error.localizedDescription)

                // Retry once: close socket, reconnect, resend
                self.disconnectSocket()
                guard self.connectSocket() else {
                    self.scheduleReconnect()
                    throw error
                }

                do {
                    os_log(.debug, log: self.log, "Retrying command 0x%04X (wid: %u)", command.rawValue, windowId)
                    try self.writeExact(message)
                    let response = try self.readResponse()
                    os_log(.debug, log: self.log, "Retry succeeded for command 0x%04X", command.rawValue)
                    return response
                } catch {
                    os_log(.error, log: self.log, "Command 0x%04X retry failed: %{public}@",
                           command.rawValue, error.localizedDescription)
                    self.disconnectSocket()
                    self.scheduleReconnect()
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
            if self.socketFD < 0 {
                if !self.connectSocket() {
                    self.ringBuffer.enqueue(message)
                    os_log(.default, log: self.log, "%{public}s buffered while disconnected (wid: %u, queue size: %d)",
                           commandName, windowId, self.ringBuffer.countValue)
                    self.scheduleReconnect()
                    return false
                }
            }

            do {
                try self.writeExact(message)
                let response = try self.readResponse()
                let ok = self.handleAckResponse(header: response.header, payload: response.payload, commandName: commandName)
                if ok {
                    os_log(.info, log: self.log, "%{public}s succeeded for window %u", commandName, windowId)
                }
                return ok
            } catch {
                os_log(.default, log: self.log, "%{public}s attempt 1 failed: %{public}@. Retrying once...",
                       commandName, error.localizedDescription)

                self.disconnectSocket()
                if self.connectSocket() {
                    do {
                        try self.writeExact(message)
                        let response = try self.readResponse()
                        let ok = self.handleAckResponse(header: response.header, payload: response.payload, commandName: commandName)
                        return ok
                    } catch {
                        os_log(.error, log: self.log, "%{public}s retry failed: %{public}@. Enqueuing in ring buffer.",
                               commandName, error.localizedDescription)
                        self.disconnectSocket()
                    }
                }

                self.ringBuffer.enqueue(message)
                os_log(.default, log: self.log, "%{public}s buffered after failure (wid: %u, queue size: %d)",
                       commandName, windowId, self.ringBuffer.countValue)
                self.scheduleReconnect()
                return false
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

