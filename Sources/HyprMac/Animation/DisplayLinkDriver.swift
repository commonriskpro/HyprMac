import Foundation
import CoreVideo
import CoreGraphics
import Darwin

/// DisplayLink abstraction bound directly to a monitor's hardware vblank (CVDisplayLink),
/// delivering tick callbacks synchronized with the monitor's native refresh rate (60Hz, 120Hz, 144Hz, ProMotion, etc.).
public final class DisplayLinkDriver: @unchecked Sendable {
    public typealias TickCallback = @Sendable (_ timestamp: Double, _ dt: Double) -> Void

    public let displayID: CGDirectDisplayID
    private var displayLink: CVDisplayLink?
    private var isRunningInternal: Bool = false
    private var lastHostTime: UInt64 = 0
    private var timebaseInfo = mach_timebase_info()
    private let lock = NSLock()
    private var tickCallback: TickCallback?

    public init(displayID: CGDirectDisplayID = CGMainDisplayID()) {
        self.displayID = displayID
        mach_timebase_info(&timebaseInfo)
        setupDisplayLink()
    }

    deinit {
        stop()
    }

    private func setupDisplayLink() {
        var link: CVDisplayLink?
        let err = CVDisplayLinkCreateWithCGDisplay(displayID, &link)
        guard err == kCVReturnSuccess, let createdLink = link else {
            return
        }
        self.displayLink = createdLink

        let unretainedSelf = Unmanaged.passUnretained(self).toOpaque()

        let callback: CVDisplayLinkOutputCallback = { (_, inNow, inOutputTime, _, _, userInfo) -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnSuccess }
            let driver = Unmanaged<DisplayLinkDriver>.fromOpaque(userInfo).takeUnretainedValue()
            driver.handleVBlank(inNow: inNow.pointee, inOutputTime: inOutputTime.pointee)
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(createdLink, callback, unretainedSelf)
    }

    private func handleVBlank(inNow: CVTimeStamp, inOutputTime: CVTimeStamp) {
        let currentHostTime = inNow.hostTime
        var dt: Double = 0.0

        lock.lock()
        let lastTime = lastHostTime
        lastHostTime = currentHostTime
        let cb = tickCallback
        lock.unlock()

        if lastTime > 0 {
            let elapsedNanos = (currentHostTime - lastTime) * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
            dt = Double(elapsedNanos) / 1_000_000_000.0
        } else {
            dt = nominalRefreshPeriod
        }

        // Guard against absurd dt spikes (e.g. machine wake from sleep)
        if dt <= 0.0 || dt > 0.25 {
            dt = nominalRefreshPeriod
        }

        let timestamp = Double(currentHostTime) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom) / 1_000_000_000.0
        cb?(timestamp, dt)
    }

    /// The nominal hardware refresh period in seconds (e.g. 1/120 for 120Hz, 1/60 for 60Hz).
    public var nominalRefreshPeriod: Double {
        guard let link = displayLink else { return 1.0 / 60.0 }
        let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
        if period.timeScale > 0 && period.timeValue > 0 {
            return Double(period.timeValue) / Double(period.timeScale)
        }
        return 1.0 / 60.0
    }

    /// Nominal hardware refresh rate in Hertz (e.g. 60.0, 120.0, 144.0).
    public var nominalRefreshRate: Double {
        let period = nominalRefreshPeriod
        return period > 0 ? (1.0 / period) : 60.0
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunningInternal
    }

    /// Starts vblank delivery on this monitor's display link.
    public func start(onTick: @escaping TickCallback) {
        lock.lock()
        defer { lock.unlock() }
        self.tickCallback = onTick
        self.lastHostTime = 0
        guard let link = displayLink, !isRunningInternal else { return }
        let err = CVDisplayLinkStart(link)
        if err == kCVReturnSuccess {
            isRunningInternal = true
        }
    }

    /// Stops vblank delivery.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let link = displayLink, isRunningInternal else { return }
        CVDisplayLinkStop(link)
        isRunningInternal = false
        self.tickCallback = nil
        self.lastHostTime = 0
    }

    /// Manually drives a simulated tick with delta-time dt (used for deterministic testing).
    public func step(dt: Double, timestamp: Double = 0.0) {
        let cb: TickCallback?
        lock.lock()
        cb = tickCallback
        lock.unlock()
        cb?(timestamp, dt)
    }
}
