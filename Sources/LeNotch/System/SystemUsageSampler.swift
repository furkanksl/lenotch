import Darwin
import Foundation

struct SystemCapacityUsage: Sendable, Equatable {
    let usedBytes: UInt64
    let totalBytes: UInt64

    init?(usedBytes: UInt64, totalBytes: UInt64) {
        guard totalBytes > 0 else { return nil }
        self.usedBytes = min(usedBytes, totalBytes)
        self.totalBytes = totalBytes
    }

    var availableBytes: UInt64 { totalBytes - usedBytes }
    var fraction: Double { Double(usedBytes) / Double(totalBytes) }
}

enum SystemCPUStatus: Sendable, Equatable {
    case collecting, available, unavailable
}

struct SystemUsageSnapshot: Sendable, Equatable {
    var cpuFraction: Double?
    var cpuStatus: SystemCPUStatus = .collecting
    var memory: SystemCapacityUsage?
    var storage: SystemCapacityUsage?
    var storageName = "Startup disk"
    var storageIncludesReclaimableSpace = false
    var updatedAt: Date?
}

/// HOST_CPU_LOAD_INFO contains aggregate 32-bit ticks for all logical CPUs.
struct SystemCPUTicks: Sendable, Equatable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    /// The fraction is already normalized across cores. A first sample, stopped clock,
    /// or reset counter needs a new baseline, not a fabricated zero-percent reading.
    func fraction(since previous: SystemCPUTicks?) -> Double? {
        guard let previous else { return nil }
        let pairs = [(previous.user, user), (previous.system, system),
                     (previous.idle, idle), (previous.nice, nice)]
        var deltas: [UInt64] = []
        for (before, after) in pairs {
            if after < before {
                // Only accept a decrease across the rollover boundary. An ordinary
                // counter reset must not look like billions of busy ticks.
                guard before > UInt32.max / 4 * 3, after < UInt32.max / 4 else { return nil }
            }
            deltas.append(UInt64(after &- before))
        }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return nil }
        return min(1, max(0, Double(total - deltas[2]) / Double(total)))
    }
}

struct SystemStorageReading: Sendable, Equatable {
    let usage: SystemCapacityUsage
    let name: String
    let includesReclaimableSpace: Bool
}

struct SystemUsageReading: Sendable {
    var cpu: SystemCPUTicks?
    var memory: SystemCapacityUsage?
    var storage: SystemStorageReading?
}

protocol SystemUsageSampling: Sendable {
    func sample(includeStorage: Bool) async throws -> SystemUsageReading
}

enum SystemUsageCalculations {
    /// App memory is resident anonymous pages minus purgeable pages. Add wired
    /// memory and the compressor's *physical* pages, not its uncompressed payload.
    /// File-backed cache is not app memory, and speculative pages are already part
    /// of the kernel's free count, so neither is added or subtracted again here.
    /// This is a used-RAM estimate, not memory pressure or a sum of process RSS.
    static func memory(internalPages: UInt64, purgeablePages: UInt64,
                       wiredPages: UInt64, compressorPages: UInt64,
                       pageSize: UInt64, physicalMemory: UInt64) -> SystemCapacityUsage? {
        guard pageSize > 0, physicalMemory > 0 else { return nil }
        let appPages = internalPages - min(internalPages, purgeablePages)
        let pages = saturatedAdd(saturatedAdd(appPages, wiredPages), compressorPages)
        let (bytes, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        return SystemCapacityUsage(usedBytes: overflow ? .max : bytes, totalBytes: physicalMemory)
    }

    /// Important-usage capacity includes space macOS can reclaim. The resulting
    /// used count is total minus that estimate, not a recursive file-size scan.
    static func storage(totalBytes: Int64?, availableBytes: Int64?,
                        availableForImportantUsage: Int64?, name: String) -> SystemStorageReading? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        let important = availableForImportantUsage.flatMap { $0 >= 0 ? $0 : nil }
        let fallback = availableBytes.flatMap { $0 >= 0 ? $0 : nil }
        guard let available = important ?? fallback else { return nil }
        let total = UInt64(totalBytes)
        guard let usage = SystemCapacityUsage(usedBytes: total - min(total, UInt64(available)),
                                              totalBytes: total) else { return nil }
        return SystemStorageReading(usage: usage, name: name,
                                    includesReclaimableSpace: important != nil)
    }

    private static func saturatedAdd(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? .max : sum
    }
}

/// All native reads run outside MainActor. Construction does not read system state,
/// start a timer, enumerate files, or request any privacy permission.
actor SystemUsageSampler: SystemUsageSampling {
    func sample(includeStorage: Bool) async throws -> SystemUsageReading {
        try Task.checkCancellation()
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let cpu = cpuTicks(host: host)
        let memory = memoryUsage(host: host)
        try Task.checkCancellation()
        let storage = includeStorage ? storageUsage() : nil
        try Task.checkCancellation()
        return SystemUsageReading(cpu: cpu, memory: memory, storage: storage)
    }

    private func cpuTicks(host: host_t) -> SystemCPUTicks? {
        var info = host_cpu_load_info_data_t()
        let count = MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        var size = mach_msg_type_number_t(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: count) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS, size >= count else { return nil }
        return SystemCPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                              idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func memoryUsage(host: host_t) -> SystemCapacityUsage? {
        var info = vm_statistics64_data_t()
        let count = MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        var size = mach_msg_type_number_t(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: count) {
                host_statistics64(host, HOST_VM_INFO64, $0, &size)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        return SystemUsageCalculations.memory(
            internalPages: UInt64(info.internal_page_count), purgeablePages: UInt64(info.purgeable_count),
            wiredPages: UInt64(info.wire_count), compressorPages: UInt64(info.compressor_page_count),
            pageSize: UInt64(pageSize), physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    private func storageUsage() -> SystemStorageReading? {
        // The writable startup volume includes user files on modern split-volume
        // macOS installs. Older layouts use the root volume instead.
        let dataPath = "/System/Volumes/Data"
        let path = FileManager.default.fileExists(atPath: dataPath) ? dataPath : "/"
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                       .volumeNameKey, .volumeIsLocalKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsLocal != false else { return nil }
        let importantValues = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return SystemUsageCalculations.storage(
            totalBytes: values.volumeTotalCapacity.map(Int64.init),
            availableBytes: values.volumeAvailableCapacity.map(Int64.init),
            availableForImportantUsage: importantValues?.volumeAvailableCapacityForImportantUsage,
            name: values.volumeName.flatMap { $0.isEmpty ? nil : $0 } ?? "Startup disk")
    }
}
