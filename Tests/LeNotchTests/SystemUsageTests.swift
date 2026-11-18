import Foundation
import XCTest
@testable import Lenotch

final class SystemUsageCalculationTests: XCTestCase {
    func testCPUUsesIntervalRatherThanLifetimeTicks() throws {
        let before = SystemCPUTicks(user: 100, system: 200, idle: 10_000, nice: 20)
        let after = SystemCPUTicks(user: 120, system: 210, idle: 10_065, nice: 25)
        XCTAssertEqual(try XCTUnwrap(after.fraction(since: before)), 0.35, accuracy: 0.0001)
        XCTAssertNil(after.fraction(since: nil))
        XCTAssertNil(before.fraction(since: before))
    }

    func testCPUIsNormalizedAcrossAllCores() throws {
        let before = SystemCPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let busy = SystemCPUTicks(user: 800, system: 400, idle: 0, nice: 400)
        let idle = SystemCPUTicks(user: 0, system: 0, idle: 1_600, nice: 0)
        XCTAssertEqual(busy.fraction(since: before), 1)
        XCTAssertEqual(idle.fraction(since: before), 0)
    }

    func testCPUResetsNeedANewBaseline() {
        let before = SystemCPUTicks(user: 1_000, system: 100, idle: 10_000, nice: 5)
        let reset = SystemCPUTicks(user: 5, system: 101, idle: 10_020, nice: 5)
        XCTAssertNil(reset.fraction(since: before))
        let after = SystemCPUTicks(user: 15, system: 101, idle: 10_030, nice: 5)
        XCTAssertEqual(after.fraction(since: reset), 0.5)
    }

    func testCPUTickRolloverKeepsAValidInterval() {
        let before = SystemCPUTicks(user: .max - 4, system: 100, idle: 100, nice: 0)
        let after = SystemCPUTicks(user: 3, system: 102, idle: 110, nice: 0)
        XCTAssertEqual(after.fraction(since: before), 0.5)
    }

    func testMemoryExcludesPurgeableAppPagesAndUsesPhysicalCompressedPages() throws {
        let usage = try XCTUnwrap(SystemUsageCalculations.memory(
            internalPages: 600, purgeablePages: 100, wiredPages: 200, compressorPages: 50,
            pageSize: 4_096, physicalMemory: 1_000 * 4_096))
        // Anonymous app pages already exclude file-backed cache; compressor pages
        // are physical storage, not their larger uncompressed contents.
        XCTAssertEqual(usage.usedBytes, 750 * 4_096)
        XCTAssertEqual(usage.availableBytes, 250 * 4_096)
        XCTAssertEqual(usage.fraction, 0.75)
    }

    func testMemoryPurgeableCountsCannotUnderflowOrRemoveWiredMemory() throws {
        let usage = try XCTUnwrap(SystemUsageCalculations.memory(
            internalPages: 10, purgeablePages: 40, wiredPages: 30, compressorPages: 10,
            pageSize: 16_384, physicalMemory: 100 * 16_384))
        XCTAssertEqual(usage.usedBytes, 40 * 16_384)
    }

    func testMemoryClampsRacingCountersAndArithmeticOverflow() throws {
        let usage = try XCTUnwrap(SystemUsageCalculations.memory(
            internalPages: .max, purgeablePages: 0, wiredPages: .max, compressorPages: .max,
            pageSize: 16_384, physicalMemory: 1_000))
        XCTAssertEqual(usage.usedBytes, 1_000)
        XCTAssertEqual(usage.fraction, 1)
        XCTAssertNil(SystemUsageCalculations.memory(internalPages: 1, purgeablePages: 0,
            wiredPages: 1, compressorPages: 1, pageSize: 0, physicalMemory: 1_000))
        XCTAssertNil(SystemUsageCalculations.memory(internalPages: 1, purgeablePages: 0,
            wiredPages: 1, compressorPages: 1, pageSize: 4_096, physicalMemory: 0))
    }

    func testCapacityRejectsMissingTotalAndClampsOverfullValues() throws {
        XCTAssertNil(SystemCapacityUsage(usedBytes: 0, totalBytes: 0))
        let usage = try XCTUnwrap(SystemCapacityUsage(usedBytes: 150, totalBytes: 100))
        XCTAssertEqual(usage.usedBytes, 100)
        XCTAssertEqual(usage.availableBytes, 0)
        XCTAssertEqual(usage.fraction, 1)
    }

    func testStoragePrefersReclaimableCapacityAndLabelsItsMeaning() throws {
        let reading = try XCTUnwrap(SystemUsageCalculations.storage(
            totalBytes: 1_000, availableBytes: 100, availableForImportantUsage: 300, name: "Data"))
        XCTAssertEqual(reading.usage.usedBytes, 700)
        XCTAssertEqual(reading.usage.availableBytes, 300)
        XCTAssertTrue(reading.includesReclaimableSpace)
        XCTAssertEqual(reading.name, "Data")
    }

    func testStorageFallsBackToOrdinaryAvailabilityAndClampsAPFSCapacity() throws {
        let reading = try XCTUnwrap(SystemUsageCalculations.storage(
            totalBytes: 1_000, availableBytes: 100, availableForImportantUsage: -1, name: "Data"))
        XCTAssertEqual(reading.usage.usedBytes, 900)
        XCTAssertFalse(reading.includesReclaimableSpace)
        let over = try XCTUnwrap(SystemUsageCalculations.storage(
            totalBytes: 1_000, availableBytes: nil, availableForImportantUsage: 1_200, name: "Data"))
        XCTAssertEqual(over.usage.usedBytes, 0)
        XCTAssertEqual(over.usage.availableBytes, 1_000)
    }

    func testUnavailableStorageIsNotAZeroReading() {
        XCTAssertNil(SystemUsageCalculations.storage(totalBytes: nil, availableBytes: 20,
            availableForImportantUsage: 20, name: "Data"))
        XCTAssertNil(SystemUsageCalculations.storage(totalBytes: 0, availableBytes: 20,
            availableForImportantUsage: 20, name: "Data"))
        XCTAssertNil(SystemUsageCalculations.storage(totalBytes: 100, availableBytes: -1,
            availableForImportantUsage: nil, name: "Data"))
    }
}

@MainActor
final class SystemUsageTests: XCTestCase {
    private let baseline = SystemCPUTicks(user: 100, system: 50, idle: 1_000, nice: 0)
    private let next = SystemCPUTicks(user: 120, system: 60, idle: 1_070, nice: 0)

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for system sampling")
        throw URLError(.timedOut)
    }

    private func reading(cpu: SystemCPUTicks?, used: UInt64 = 60,
                         storage: Bool = true) -> SystemUsageReading {
        let capacity = SystemCapacityUsage(usedBytes: used, totalBytes: 100)!
        return SystemUsageReading(cpu: cpu, memory: capacity,
            storage: storage ? SystemStorageReading(usage: capacity, name: "Test disk",
                                                    includesReclaimableSpace: true) : nil)
    }

    func testConstructionAndImmediateStopDoNotSample() async {
        let sampler = ControlledSystemSampler()
        let model = SystemUsageModel(sampler: sampler)
        XCTAssertFalse(model.isMonitoring)
        XCTAssertNil(model.snapshot.cpuFraction)
        XCTAssertEqual(model.snapshot.cpuStatus, .collecting)
        XCTAssertNil(model.snapshot.memory)
        XCTAssertNil(model.snapshot.storage)
        XCTAssertNil(model.snapshot.updatedAt)
        await Task.yield()
        var count = await sampler.requestCount
        XCTAssertEqual(count, 0)
        model.start()
        model.stop()
        await Task.yield()
        count = await sampler.requestCount
        XCTAssertEqual(count, 0)
    }

    func testStartIsIdempotentAndFirstCPUIntervalIsShort() async throws {
        let sampler = ControlledSystemSampler()
        let sleeper = ControlledSystemSleeper()
        let model = SystemUsageModel(sampler: sampler, sleep: { try await sleeper.sleep($0) })
        model.start()
        model.start()
        try await waitUntil { await sampler.requestCount == 1 }
        await sampler.deliver(0, reading: reading(cpu: baseline))
        try await waitUntil { await sleeper.count == 1 }
        XCTAssertEqual(model.snapshot.cpuStatus, .collecting)
        XCTAssertNil(model.snapshot.cpuFraction)
        XCTAssertEqual(model.snapshot.memory?.usedBytes, 60)
        XCTAssertEqual(model.snapshot.storageName, "Test disk")
        let firstDelay = await sleeper.durations[0]
        XCTAssertEqual(firstDelay, .milliseconds(500))
        await sleeper.release()
        try await waitUntil { await sampler.requestCount == 2 }
        await sampler.deliver(1, reading: reading(cpu: next, storage: false))
        try await waitUntil { await sleeper.count == 2 }
        XCTAssertEqual(model.snapshot.cpuStatus, .available)
        XCTAssertEqual(try XCTUnwrap(model.snapshot.cpuFraction), 0.3, accuracy: 0.0001)
        XCTAssertEqual(model.snapshot.storage?.usedBytes, 60)
        let laterDelay = await sleeper.durations[1]
        XCTAssertEqual(laterDelay, .seconds(2))
        model.stop()
        await sleeper.release()
        await Task.yield()
        let count = await sampler.requestCount
        XCTAssertEqual(count, 2)
        XCTAssertFalse(model.isMonitoring)
    }

    func testStopRejectsAnUncooperativeLateResult() async throws {
        let sampler = ControlledSystemSampler()
        let model = SystemUsageModel(sampler: sampler)
        model.start()
        try await waitUntil { await sampler.requestCount == 1 }
        model.stop()
        await sampler.deliver(0, reading: reading(cpu: baseline))
        await Task.yield()
        XCTAssertNil(model.snapshot.memory)
        XCTAssertNil(model.snapshot.updatedAt)
        XCTAssertFalse(model.isMonitoring)
    }

    func testMonitoringTaskDoesNotKeepTheModelAlive() async throws {
        let sampler = ControlledSystemSampler()
        let sleeper = ControlledSystemSleeper()
        var model: SystemUsageModel? = SystemUsageModel(sampler: sampler, sleep: { try await sleeper.sleep($0) })
        weak let weakModel = model
        model?.start()
        try await waitUntil { await sampler.requestCount == 1 }
        await sampler.deliver(0, reading: reading(cpu: baseline))
        try await waitUntil { await sleeper.count == 1 }
        model = nil
        XCTAssertNil(weakModel)
        await sleeper.release()
        await Task.yield()
        let count = await sampler.requestCount
        XCTAssertEqual(count, 1)
    }

    func testRestartIgnoresOldGenerationAndCollectsAFreshBaseline() async throws {
        let sampler = ControlledSystemSampler()
        let sleeper = ControlledSystemSleeper()
        let model = SystemUsageModel(sampler: sampler, sleep: { try await sleeper.sleep($0) })
        model.start()
        try await waitUntil { await sampler.requestCount == 1 }
        model.stop()
        model.start()
        try await waitUntil { await sampler.requestCount == 2 }
        await sampler.deliver(1, reading: reading(cpu: next, used: 70))
        try await waitUntil { model.snapshot.memory?.usedBytes == 70 }
        await sampler.deliver(0, reading: reading(cpu: baseline, used: 10))
        await Task.yield()
        XCTAssertEqual(model.snapshot.memory?.usedBytes, 70)
        XCTAssertNil(model.snapshot.cpuFraction)
        XCTAssertEqual(model.snapshot.cpuStatus, .collecting)
        model.stop()
        await sleeper.release()
    }

    func testFailedReadClearsCurrentMetricsInsteadOfInventingZeroes() async throws {
        let sampler = ControlledSystemSampler()
        let sleeper = ControlledSystemSleeper()
        let model = SystemUsageModel(sampler: sampler, sleep: { try await sleeper.sleep($0) })
        model.start()
        try await waitUntil { await sampler.requestCount == 1 }
        await sampler.fail(0)
        try await waitUntil { await sleeper.count == 1 }
        XCTAssertEqual(model.snapshot.cpuStatus, .unavailable)
        XCTAssertNil(model.snapshot.cpuFraction)
        XCTAssertNil(model.snapshot.memory)
        XCTAssertNil(model.snapshot.storage)
        XCTAssertNil(model.snapshot.updatedAt)
        await sleeper.release()
        try await waitUntil { await sampler.requestCount == 2 }
        await sampler.deliver(1, reading: reading(cpu: baseline, storage: false))
        try await waitUntil { await sleeper.count == 2 }
        XCTAssertEqual(model.snapshot.cpuStatus, .collecting)
        XCTAssertNil(model.snapshot.cpuFraction)
        model.stop()
        await sleeper.release()
    }

    func testStorageIsReadEveryThirtySecondsRatherThanEveryCPUSample() async throws {
        let sampler = ControlledSystemSampler()
        let sleeper = ControlledSystemSleeper()
        let clock = SystemTestClock()
        let model = SystemUsageModel(sampler: sampler, now: { clock.now() },
                                    sleep: { try await sleeper.sleep($0) })
        model.start()
        try await waitUntil { await sampler.requestCount == 1 }
        await sampler.deliver(0, reading: reading(cpu: baseline))
        try await waitUntil { await sleeper.count == 1 }
        clock.advance(29)
        await sleeper.release()
        try await waitUntil { await sampler.requestCount == 2 }
        await sampler.deliver(1, reading: reading(cpu: next, storage: false))
        try await waitUntil { await sleeper.count == 2 }
        clock.advance(1)
        await sleeper.release()
        try await waitUntil { await sampler.requestCount == 3 }
        let flags = await sampler.storageRequests
        XCTAssertEqual(flags, [true, false, true])
        await sampler.deliver(2, reading: SystemUsageReading(cpu: next))
        try await waitUntil { await sleeper.count == 3 }
        XCTAssertNil(model.snapshot.storage, "A failed disk refresh must not keep claiming a stale value is current")
        model.stop()
        await sleeper.release()
    }

    func testNativeSamplerReturnsSaneBoundsWithoutSpecialPermissions() async throws {
        let sampler = SystemUsageSampler()
        let first = try await sampler.sample(includeStorage: true)
        XCTAssertNotNil(first.cpu)
        let memory = try XCTUnwrap(first.memory)
        XCTAssertGreaterThan(memory.totalBytes, 0)
        XCTAssertLessThanOrEqual(memory.usedBytes, memory.totalBytes)
        XCTAssertTrue((0...1).contains(memory.fraction))
        if let disk = first.storage {
            XCTAssertGreaterThan(disk.usage.totalBytes, 0)
            XCTAssertLessThanOrEqual(disk.usage.usedBytes, disk.usage.totalBytes)
            XCTAssertFalse(disk.name.isEmpty)
        }
        try await Task.sleep(for: .milliseconds(50))
        let second = try await sampler.sample(includeStorage: false)
        XCTAssertNil(second.storage)
        let fraction = try XCTUnwrap(second.cpu?.fraction(since: first.cpu))
        XCTAssertTrue((0...1).contains(fraction))
    }
}

private actor ControlledSystemSampler: SystemUsageSampling {
    private var pending: [Int: CheckedContinuation<SystemUsageReading, any Error>] = [:]
    private(set) var storageRequests: [Bool] = []
    var requestCount: Int { storageRequests.count }

    // Deliberately ignore task cancellation to exercise late-result rejection.
    func sample(includeStorage: Bool) async throws -> SystemUsageReading {
        let id = storageRequests.count
        storageRequests.append(includeStorage)
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }

    func deliver(_ id: Int, reading: SystemUsageReading) { pending.removeValue(forKey: id)?.resume(returning: reading) }
    func fail(_ id: Int) { pending.removeValue(forKey: id)?.resume(throwing: URLError(.unknown)) }
}

private actor ControlledSystemSleeper {
    private var pending: [CheckedContinuation<Void, any Error>] = []
    private(set) var durations: [Duration] = []
    var count: Int { durations.count }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        durations.append(duration)
        try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func release() {
        let continuations = pending
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private final class SystemTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
