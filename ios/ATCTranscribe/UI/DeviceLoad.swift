import Foundation

/// Lightweight on-device load readouts for the Diagnostics widget — to chase down "the device is
/// hot but nothing's transcribing". iOS exposes **no public GPU/Neural-Engine utilization API**, so
/// we surface what we can: app CPU%, resident memory, and the system **thermal state** (the most
/// direct "is it heating up" signal).
enum DeviceLoad {
    /// App CPU usage across all live threads, as a percent of one core (can exceed 100% on multicore).
    static func cpuPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: UnsafeRawPointer(threads))),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }

    /// Resident memory of the app, in MB.
    static func memoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576.0 : 0
    }

    static func thermalState() -> ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "—"
        }
    }
}
