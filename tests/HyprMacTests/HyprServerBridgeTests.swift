import XCTest
@testable import HyprMac

final class HyprServerBridgeTests: XCTestCase {

    func testHyprErrorRawValues() {
        XCTAssertEqual(HyprError.success.rawValue, 0x0000)
        XCTAssertEqual(HyprError.invalidWid.rawValue, 0x0001)
        XCTAssertEqual(HyprError.invalidCmd.rawValue, 0x0002)
        XCTAssertEqual(HyprError.unauthorized.rawValue, 0x0003)
        XCTAssertEqual(HyprError.hookUnavail.rawValue, 0x0006)
        XCTAssertEqual(HyprError.internal.rawValue, 0x00FF)
    }

    func testHyprErrorDescriptions() {
        XCTAssertEqual(HyprError.success.description, "Success")
        XCTAssertEqual(HyprError.invalidWid.description, "Invalid window ID")
        XCTAssertEqual(HyprError.invalidCmd.description, "Invalid command")
        XCTAssertEqual(HyprError.unauthorized.description, "Unauthorized")
        XCTAssertEqual(HyprError.hookUnavail.description, "Hook unavailable — WindowServer module not loaded")
        XCTAssertEqual(HyprError.internal.description, "Internal error")

        XCTAssertEqual(HyprError.hookUnavail.errorDescription, "Hook unavailable — WindowServer module not loaded")
    }

    func testHyprCommandRawValues() {
        XCTAssertEqual(HyprCommand.ping.rawValue, 0x0001)
        XCTAssertEqual(HyprCommand.setGlobalPolicy.rawValue, 0x0015)
        XCTAssertEqual(HyprCommand.setMenuBarSuppression.rawValue, 0x0016)
        XCTAssertEqual(HyprCommand.setWorkspaceTransform.rawValue, 0x0017)
        XCTAssertEqual(HyprCommand.queryWindow.rawValue, 0x0020)
    }

    func testCommandRingBufferCapacity() {
        let ring = CommandRingBuffer()
        XCTAssertEqual(ring.capacity, 64)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.count, 0)
    }

    func testCommandRingBufferEnqueueDequeue() {
        let ring = CommandRingBuffer(capacity: 4)
        let sampleData1 = Data([0x01, 0x02, 0x03])
        let sampleData2 = Data([0x04, 0x05, 0x06])

        ring.enqueue(sampleData1)
        XCTAssertFalse(ring.isEmpty)
        XCTAssertEqual(ring.count, 1)

        ring.enqueue(sampleData2)
        XCTAssertEqual(ring.count, 2)

        let dequeued1 = ring.dequeue()
        XCTAssertEqual(dequeued1, sampleData1)
        XCTAssertEqual(ring.count, 1)

        let dequeued2 = ring.dequeue()
        XCTAssertEqual(dequeued2, sampleData2)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.count, 0)
    }

    func testCommandRingBufferClear() {
        let ring = CommandRingBuffer(capacity: 4)
        ring.enqueue(Data([0xAA]))
        ring.enqueue(Data([0xBB]))
        XCTAssertEqual(ring.count, 2)

        ring.clear()
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.count, 0)
        XCTAssertNil(ring.dequeue())
    }

    func testProtocolConstants() {
        XCTAssertEqual(HyprProtocol.shmSize, 64 * 1024)
        XCTAssertEqual(HyprProtocol.cmdRingSize, 28 * 1024)
        XCTAssertEqual(HyprProtocol.rspRingSize, 28 * 1024)
        XCTAssertEqual(HyprProtocol.shmHeaderSize, 256)
        XCTAssertEqual(HyprProtocol.cmdRingOffset, 256)
        XCTAssertEqual(HyprProtocol.rspRingOffset, 28928)
        XCTAssertEqual(HyprProtocol.rspRingOffset, HyprProtocol.shmHeaderSize + HyprProtocol.cmdRingSize)

        XCTAssertEqual(HyprServerBridge.shmSize, 64 * 1024)
        XCTAssertEqual(HyprServerBridge.cmdRingSize, 28 * 1024)
        XCTAssertEqual(HyprServerBridge.rspRingSize, 28 * 1024)
        XCTAssertEqual(HyprServerBridge.shmHeaderSize, 256)
        XCTAssertEqual(HyprServerBridge.cmdRingOffset, 256)
        XCTAssertEqual(HyprServerBridge.rspRingOffset, 28928)
        XCTAssertEqual(HyprServerBridge.rspRingOffset, HyprServerBridge.shmHeaderSize + HyprServerBridge.cmdRingSize)
    }

    func testMenuBarSuppressionPayloadStructure() {
        let suppressVal: UInt32 = 1
        let exemptVal: UInt32 = 999
        let countVal: UInt32 = 2
        let testWIDs: [UInt32] = [10, 12]

        var payload = Data()
        var s = suppressVal
        var ex = exemptVal
        var c = countVal
        withUnsafeBytes(of: &s) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &ex) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &c) { payload.append(contentsOf: $0) }
        for wid in testWIDs {
            var w = wid
            withUnsafeBytes(of: &w) { payload.append(contentsOf: $0) }
        }
        let pad = (32 - testWIDs.count) * MemoryLayout<UInt32>.size
        payload.append(Data(count: pad))

        XCTAssertEqual(payload.count, 140, "Payload size must match HyprPacketMenuBarSuppression (140 bytes)")

        let sRead = payload.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let exRead = payload.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        let cRead = payload.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) }
        let w0 = payload.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self) }
        let w1 = payload.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self) }

        XCTAssertEqual(sRead, 1)
        XCTAssertEqual(exRead, 999)
        XCTAssertEqual(cRead, 2)
        XCTAssertEqual(w0, 10)
        XCTAssertEqual(w1, 12)
    }

    func testWorkspaceTransformPayloadStructure() {
        var payload = Data()
        var countVal: UInt32 = 1
        withUnsafeBytes(of: &countVal) { payload.append(contentsOf: $0) }

        var wid: UInt32 = 42
        var a: Float = 1.0
        var b: Float = 0.0
        var c: Float = 0.0
        var d: Float = 1.0
        var tx: Float = 120.0
        var ty: Float = -60.0
        var alpha: Float = 0.75

        withUnsafeBytes(of: &wid) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &a) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &b) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &c) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &d) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &tx) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &ty) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &alpha) { payload.append(contentsOf: $0) }

        let padBytes = (32 - 1) * 32
        payload.append(Data(count: padBytes))

        XCTAssertEqual(payload.count, 1028, "Payload size must match HyprPayloadWorkspaceTransform (4 + 32*32 = 1028 bytes)")

        let countRead = payload.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let widRead = payload.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        let aRead = payload.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: Float.self) }
        let txRead = payload.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: Float.self) }
        let tyRead = payload.subdata(in: 28..<32).withUnsafeBytes { $0.load(as: Float.self) }
        let alphaRead = payload.subdata(in: 32..<36).withUnsafeBytes { $0.load(as: Float.self) }

        XCTAssertEqual(countRead, 1)
        XCTAssertEqual(widRead, 42)
        XCTAssertEqual(aRead, 1.0)
        XCTAssertEqual(txRead, 120.0)
        XCTAssertEqual(tyRead, -60.0)
        XCTAssertEqual(alphaRead, 0.75)
    }

    func testResetWorkspaceTransformsEmptyReturnsTrue() {
        let bridge = HyprServerBridge.shared
        XCTAssertTrue(bridge.resetWorkspaceTransforms(windowIDs: []))
        XCTAssertTrue(bridge.setWorkspaceTransform(entries: []))
    }
}
