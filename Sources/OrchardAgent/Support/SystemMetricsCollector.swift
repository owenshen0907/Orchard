import Darwin
import Foundation
import OrchardCore

final class SystemMetricsCollector: @unchecked Sendable {
    private var previousCPUTicks: [UInt32]?

    func snapshot(runningTasks: Int, codexDesktop: CodexDesktopMetrics? = nil) -> DeviceMetrics {
        DeviceMetrics(
            cpuPercentApprox: currentCPUPercent(),
            memoryPercent: currentMemoryPercent(),
            loadAverage: currentLoadAverage(),
            runningTasks: runningTasks,
            codexDesktop: codexDesktop
        )
    }

    private func currentCPUPercent() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }

        let ticks = [
            UInt32(info.cpu_ticks.0),
            UInt32(info.cpu_ticks.1),
            UInt32(info.cpu_ticks.2),
            UInt32(info.cpu_ticks.3),
        ]
        defer { previousCPUTicks = ticks }

        guard let previousCPUTicks else {
            return nil
        }

        let deltas = zip(ticks, previousCPUTicks).map { current, previous in
            max(0, Int64(current) - Int64(previous))
        }
        let totalTicks = deltas.reduce(0, +)
        guard totalTicks > 0 else {
            return nil
        }

        let idleTicks = deltas[Int(CPU_STATE_IDLE)]
        let busyPercent = (Double(totalTicks - idleTicks) / Double(totalTicks)) * 100
        return min(max(busyPercent, 0), 100)
    }

    private func currentMemoryPercent() -> Double? {
        let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
        guard totalMemory > 0 else {
            return nil
        }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return nil
        }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }

        let usedPages =
            UInt64(stats.active_count) +
            UInt64(stats.wire_count) +
            UInt64(stats.compressor_page_count)
        let usedBytes = Double(usedPages) * Double(pageSize)
        return min(max((usedBytes / totalMemory) * 100, 0), 100)
    }

    private func currentLoadAverage() -> Double? {
        var values = [Double](repeating: 0, count: 3)
        let result = getloadavg(&values, 3)
        guard result > 0 else {
            return nil
        }
        return values[0]
    }
}
