import Cocoa
import Darwin

/// Reader for hardware CPU & Memory utilization using Mach host statistics
public enum HardwareMonitor {
    nonisolated(unsafe) private static var lastTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    private static let hostPort: mach_port_t = mach_host_self()

    /// Average utilization since boot, used when there is no delta window yet
    /// (first sample, or two samples taken within the same kernel tick).
    private static func cumulativePercent(
        user: UInt32,
        sys: UInt32,
        idle: UInt32,
        nice: UInt32
    ) -> Int {
        let total = Double(user) + Double(sys) + Double(idle) + Double(nice)
        guard total > 0 else { return 0 }
        let active = Double(user) + Double(sys) + Double(nice)
        let pct = Int((active / total) * 100.0)
        return Swift.max(1, Swift.min(100, pct))
    }

    public static func currentCPULoad() -> Int {
        let count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var actualCount = count
        var cpuLoad = host_cpu_load_info()
        let kerr = withUnsafeMutablePointer(to: &cpuLoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &actualCount)
            }
        }
        guard kerr == KERN_SUCCESS else {
            fputs("HardwareMonitor: host_statistics(HOST_CPU_LOAD_INFO) failed with kern_return_t: \(kerr)\n", stderr)
            return 0
        }

        let user = cpuLoad.cpu_ticks.0
        let sys = cpuLoad.cpu_ticks.1
        let idle = cpuLoad.cpu_ticks.2
        let nice = cpuLoad.cpu_ticks.3

        guard let previous = lastTicks else {
            lastTicks = (user, sys, idle, nice)
            return cumulativePercent(user: user, sys: sys, idle: idle, nice: nice)
        }

        let deltaUser = Double(user >= previous.user ? user - previous.user : 0)
        let deltaSys = Double(sys >= previous.sys ? sys - previous.sys : 0)
        let deltaIdle = Double(idle >= previous.idle ? idle - previous.idle : 0)
        let deltaNice = Double(nice >= previous.nice ? nice - previous.nice : 0)
        lastTicks = (user, sys, idle, nice)

        let total = deltaUser + deltaSys + deltaIdle + deltaNice
        guard total > 0 else {
            // No ticks elapsed in this window; report the since-boot average
            // instead of a misleading 0%.
            return cumulativePercent(user: user, sys: sys, idle: idle, nice: nice)
        }

        let active = deltaUser + deltaSys + deltaNice
        let pct = Int((active / total) * 100.0)
        return Swift.max(1, Swift.min(100, pct))
    }

    public static func currentMemoryLoad() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else {
            fputs("HardwareMonitor: host_statistics64(HOST_VM_INFO64) failed with kern_return_t: \(kerr)\n", stderr)
            return 0
        }
        let pageSize = UInt64(getpagesize())
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let usedBytes = active + wired + compressed
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        guard totalBytes > 0 else {
            fputs("HardwareMonitor: physicalMemory is 0\n", stderr)
            return 0
        }
        let pct = Int((Double(usedBytes) / Double(totalBytes)) * 100.0)
        return Swift.max(1, Swift.min(100, pct))
    }
}
