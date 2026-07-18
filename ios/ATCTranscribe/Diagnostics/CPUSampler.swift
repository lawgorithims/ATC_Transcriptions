import Darwin.Mach
import Foundation

/// Whole-process CPU usage via Mach `task_threads` + `thread_info`, so a battery sample can attribute the
/// drain to CPU/ANE load (Whisper transcription) vs the map. `task_threads(mach_task_self_)` is sandbox-safe
/// (unlike host-level calls). Returns percent of ONE core summed across live threads (e.g. 180 ≈ 1.8 cores).
enum CPUSampler {
    static let maxThreads = 1024                       // hard loop bound (rule 2)

    /// nil on any Mach failure — a bad read must never fabricate a number.
    static func processUsagePercent() -> Double? {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return nil }
        assert(count <= UInt32(maxThreads), "CPUSampler: implausible thread count \(count)")
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        let bound = min(Int(count), maxThreads)        // bounded (rule 2)
        for i in 0..<bound {
            var info = thread_basic_info()
            // THREAD_BASIC_INFO_COUNT isn't exported to Swift — it's the struct size in natural_t units.
            var c = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &c)
                }
            }
            guard kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
        }
        assert(total >= 0, "CPUSampler: negative total")
        return total
    }
}

/// A single frame counter the MapLibre coordinator bumps per rendered frame; the battery sampler deltas it
/// into frames-per-second, so we can tell whether the map is compositing continuously (~30 fps) while idle
/// vs paused (~0 fps). A shared reference (NOT a back-pointer to the view/coordinator → no retain cycle).
/// Touched only on the main thread (MLNMapViewDelegate callback + the @MainActor sampler) → a plain Int is safe.
final class MapRenderMeter {
    private(set) var count: Int = 0
    func tick() {
        assert(Thread.isMainThread, "MapRenderMeter.tick off the main thread")
        count &+= 1
        assert(count >= 0, "MapRenderMeter: counter underflow")
    }
}
