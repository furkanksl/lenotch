import Foundation
import Observation

/// Owned by the director, but running only while its System page is visible.
/// Every open starts a fresh CPU interval; no samples are taken during construction.
@MainActor @Observable final class SystemUsageModel {
    private(set) var snapshot = SystemUsageSnapshot()
    private(set) var isMonitoring = false

    @ObservationIgnored private let sampler: any SystemUsageSampling
    @ObservationIgnored private let pollingInterval: Duration
    @ObservationIgnored private let baselineInterval: Duration
    @ObservationIgnored private let storageInterval: TimeInterval
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    init(sampler: any SystemUsageSampling = SystemUsageSampler(),
         pollingInterval: Duration = .seconds(2), baselineInterval: Duration = .milliseconds(500),
         storageInterval: TimeInterval = 30,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sampler = sampler
        self.pollingInterval = max(.milliseconds(1), pollingInterval)
        self.baselineInterval = max(.milliseconds(1), baselineInterval)
        self.storageInterval = max(1, storageInterval)
        self.now = now
        self.sleep = sleep
    }

    deinit { pollingTask?.cancel() }

    func start() {
        guard !isMonitoring else { return }
        generation &+= 1
        let generation = generation
        isMonitoring = true
        snapshot = SystemUsageSnapshot()
        let sampler = sampler, now = now, sleep = sleep
        let pollingInterval = pollingInterval, baselineInterval = baselineInterval, storageInterval = storageInterval
        pollingTask = Task { [weak self] in
            var previousCPU: SystemCPUTicks?
            var lastStorageReadAt: Date?
            var firstSample = true
            while !Task.isCancelled {
                let sampledAt = now()
                let includeStorage = lastStorageReadAt.map {
                    sampledAt.timeIntervalSince($0) >= storageInterval || sampledAt < $0
                } ?? true
                let reading: SystemUsageReading
                do {
                    reading = try await sampler.sample(includeStorage: includeStorage)
                } catch {
                    guard !Task.isCancelled else { return }
                    reading = SystemUsageReading()
                }
                guard !Task.isCancelled,
                      self?.publish(reading, previousCPU: previousCPU, includeStorage: includeStorage,
                                    sampledAt: sampledAt, generation: generation) == true else { return }
                previousCPU = reading.cpu
                if includeStorage { lastStorageReadAt = sampledAt }
                let delay = firstSample ? baselineInterval : pollingInterval
                firstSample = false
                do { try await sleep(delay) }
                catch { return }
            }
        }
    }

    func stop() {
        isMonitoring = false
        generation &+= 1
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func publish(_ reading: SystemUsageReading, previousCPU: SystemCPUTicks?,
                         includeStorage: Bool, sampledAt: Date, generation: UInt64) -> Bool {
        guard isMonitoring, self.generation == generation else { return false }
        var next = snapshot
        next.cpuFraction = reading.cpu?.fraction(since: previousCPU)
        next.cpuStatus = reading.cpu == nil ? .unavailable : next.cpuFraction == nil ? .collecting : .available
        next.memory = reading.memory
        if includeStorage {
            next.storage = reading.storage?.usage
            next.storageName = reading.storage?.name ?? "Startup disk"
            next.storageIncludesReclaimableSpace = reading.storage?.includesReclaimableSpace ?? false
        }
        next.updatedAt = reading.cpu != nil || reading.memory != nil || reading.storage != nil ? sampledAt : nil
        snapshot = next
        return true
    }
}
