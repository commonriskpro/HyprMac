import XCTest
import Cocoa
@testable import HyprMac

@MainActor
final class AXProcessObserverPoolTests: XCTestCase {

    func testInitializationAndDefaults() {
        let pool = AXProcessObserverPool()
        XCTAssertFalse(pool.isRunning)
        XCTAssertEqual(pool.observedProcessCount, 0)
        XCTAssertTrue(pool.excludedAppNames.contains("HyprMac"))
        XCTAssertTrue(pool.excludedAppNames.contains("Dock"))
        XCTAssertTrue(pool.excludedAppNames.contains("Window Server"))
    }

    func testStartAndStopLifecycle() {
        let pool = AXProcessObserverPool()
        XCTAssertFalse(pool.isRunning)

        pool.start()
        XCTAssertTrue(pool.isRunning)

        // Starting again should be idempotent
        pool.start()
        XCTAssertTrue(pool.isRunning)

        pool.stop()
        XCTAssertFalse(pool.isRunning)
        XCTAssertEqual(pool.observedProcessCount, 0)

        // Stopping again should be idempotent
        pool.stop()
        XCTAssertFalse(pool.isRunning)
    }

    func testObserveAndUnobserveApplication() {
        let pool = AXProcessObserverPool()
        XCTAssertEqual(pool.observedProcessCount, 0)

        // Observing an invalid or dummy PID should not crash
        let dummyPID: pid_t = 999999
        pool.observeApplication(pid: dummyPID)
        XCTAssertEqual(pool.observedProcessCount, 1)

        // Observing duplicate PID should not increment count
        pool.observeApplication(pid: dummyPID)
        XCTAssertEqual(pool.observedProcessCount, 1)

        pool.unobserveApplication(pid: dummyPID)
        XCTAssertEqual(pool.observedProcessCount, 0)

        // Unobserving unknown PID should be safe
        pool.unobserveApplication(pid: dummyPID)
        XCTAssertEqual(pool.observedProcessCount, 0)
    }

    func testFlushTilingUpdate() {
        let pool = AXProcessObserverPool()
        var callbackFired = false
        pool.onTilingLayoutDirty = {
            callbackFired = true
        }

        pool.scheduleCoalescedTilingUpdate()
        pool.flushTilingUpdate()

        XCTAssertTrue(callbackFired, "flushTilingUpdate should synchronously trigger the dirty layout callback")
    }

    func testCoalescedTilingDebounce() {
        let pool = AXProcessObserverPool()
        var callCount = 0
        pool.onTilingLayoutDirty = {
            callCount += 1
        }

        let exp = expectation(description: "Coalesced tiling debounce fires once")

        // Trigger multiple rapid requests in sequence
        for _ in 0..<10 {
            pool.scheduleCoalescedTilingUpdate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.100) {
            XCTAssertEqual(callCount, 1, "Burst of 10 scheduleCoalescedTilingUpdate calls should collapse into exactly 1 execution")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)
    }

    func testSuppressionFlagDropsTilingUpdates() {
        let pool = AXProcessObserverPool()
        var callCount = 0
        pool.onTilingLayoutDirty = {
            callCount += 1
        }

        pool.isSuppressingTilingEvents = true
        pool.scheduleCoalescedTilingUpdate()

        let exp = expectation(description: "Suppressed update should not fire")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.050) {
            XCTAssertEqual(callCount, 0, "No tiling update should fire when suppressed")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 0.5)
    }

    func testNonStarvingCoalescingPromptExecution() {
        let pool = AXProcessObserverPool()
        var callCount = 0
        pool.onTilingLayoutDirty = {
            callCount += 1
        }

        let exp = expectation(description: "Coalesced update executes promptly despite continuous event stream")

        // Simulate incoming events spaced every 10ms for 60ms
        for i in 0..<6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.010) {
                pool.scheduleCoalescedTilingUpdate()
            }
        }

        // At 50ms, a non-starving coalesce scheduled at 20-30ms MUST have already executed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) {
            XCTAssertGreaterThanOrEqual(callCount, 1, "Non-starving coalescing must have executed by 55ms without waiting for event burst to end")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)
    }
}
