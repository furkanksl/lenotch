import XCTest
@testable import SpacesEngine

@MainActor
final class SpaceCaptureRequestTests: XCTestCase {
    private final class Clock {
        final class Job {
            let delay: TimeInterval
            let action: () -> Void
            var cancelled = false
            init(delay: TimeInterval, action: @escaping () -> Void) {
                self.delay = delay
                self.action = action
            }
        }
        var jobs: [Job] = []
        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
            let job = Job(delay: delay, action: action)
            jobs.append(job)
            return { job.cancelled = true }
        }
    }

    func testCaptureCoalescesClientsAndCompletesExactlyOnce() throws {
        let clock = Clock()
        var retired: [String] = []
        let requests = CaptureRequestLifecycle<String, Int>(schedule: clock.schedule, onRetire: { key, _ in
            retired.append(key)
        })
        var results: [Int?] = []
        let ticket = try XCTUnwrap(requests.begin("display") { results.append($0) })
        XCTAssertNil(requests.begin("display") { results.append($0) })
        XCTAssertEqual(clock.jobs.count, 1)
        XCTAssertEqual(clock.jobs[0].delay, 2)

        requests.finish("display", ticket: ticket, value: 42)
        requests.finish("display", ticket: ticket, value: 43)
        clock.jobs[0].action() // A deadline already queued when cancelled must also be harmless.

        XCTAssertEqual(results, [42, 42])
        XCTAssertEqual(retired, ["display"])
        XCTAssertTrue(clock.jobs[0].cancelled)
        XCTAssertFalse(requests.contains("display", ticket: ticket))
    }

    func testTimeoutReleasesCoalescedClientsAndStaleScreenshotCannotFinishRetry() throws {
        let clock = Clock()
        let requests = CaptureRequestLifecycle<String, Int>(schedule: clock.schedule)
        var oldResults: [Int?] = []
        let old = try XCTUnwrap(requests.begin("display") { oldResults.append($0) })
        XCTAssertNil(requests.begin("display") { oldResults.append($0) })
        clock.jobs[0].action()
        XCTAssertEqual(oldResults, [nil, nil])

        var retryResults: [Int?] = []
        let retry = try XCTUnwrap(requests.begin("display") { retryResults.append($0) })
        requests.finish("display", ticket: old, value: 10)
        clock.jobs[0].action()
        XCTAssertTrue(requests.contains("display", ticket: retry))
        XCTAssertTrue(retryResults.isEmpty)
        requests.finish("display", ticket: retry, value: 20)
        XCTAssertEqual(retryResults, [20])
    }

    func testMissingMetadataCallbackCannotPoisonNextRefreshOrCapture() throws {
        let clock = Clock()
        let captures = CaptureRequestLifecycle<String, Int>(schedule: clock.schedule)
        let refreshes = CaptureRequestLifecycle<Bool, Int>(schedule: clock.schedule)
        var results: [Int?] = []
        let capture = try XCTUnwrap(captures.begin("display") { results.append($0) })
        let refresh = try XCTUnwrap(refreshes.begin(true) { metadata in
            // The screenshot is never issued if discovery has timed out.
            guard captures.contains("display", ticket: capture) else { return }
            captures.finish("display", ticket: capture, value: metadata)
        })
        XCTAssertEqual(clock.jobs.map(\.delay), [2, 2])
        clock.jobs[0].action()
        clock.jobs[1].action()
        XCTAssertEqual(results, [nil])

        let retry = try XCTUnwrap(captures.begin("display") { results.append($0) })
        let newRefresh = try XCTUnwrap(refreshes.begin(true) { metadata in
            captures.finish("display", ticket: retry, value: metadata)
        })
        refreshes.finish(true, ticket: refresh, value: 1)
        XCTAssertTrue(results.count == 1)
        refreshes.finish(true, ticket: newRefresh, value: 2)
        XCTAssertEqual(results, [nil, 2])
    }

    func testRequestRetiresBeforeCallbackSoImmediateRetryWorks() throws {
        let clock = Clock()
        let requests = CaptureRequestLifecycle<String, Int>(schedule: clock.schedule)
        var retry: UUID?
        let old = try XCTUnwrap(requests.begin("display") { _ in
            retry = requests.begin("display") { _ in }
        })
        clock.jobs[0].action()
        XCTAssertNotNil(retry)
        XCTAssertFalse(requests.contains("display", ticket: old))
        XCTAssertTrue(requests.contains("display", ticket: try XCTUnwrap(retry)))
    }

    func testCancelIsTerminalAndSuppressesAlreadyQueuedCallbacks() throws {
        let clock = Clock()
        var retireCount = 0
        let requests = CaptureRequestLifecycle<String, Int>(schedule: clock.schedule, onRetire: { _, _ in
            retireCount += 1
        })
        var callCount = 0
        let ticket = try XCTUnwrap(requests.begin("display") { _ in callCount += 1 })
        requests.cancel()
        clock.jobs[0].action()
        requests.finish("display", ticket: ticket, value: 1)
        XCTAssertNil(requests.begin("display") { _ in callCount += 1 })
        requests.cancel()
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(retireCount, 1)
        XCTAssertTrue(clock.jobs[0].cancelled)
    }

    func testCancellationDuringFanOutStopsRemainingClients() throws {
        let clock = Clock()
        let requests = CaptureRequestLifecycle<String, Int>(schedule: clock.schedule)
        var values: [Int] = []
        let ticket = try XCTUnwrap(requests.begin("display") { _ in
            values.append(1)
            requests.cancel()
        })
        XCTAssertNil(requests.begin("display") { _ in values.append(2) })
        requests.finish("display", ticket: ticket, value: 1)
        XCTAssertEqual(values, [1])
    }

    func testIndependentCaptureModesDoNotShareSnapshots() throws {
        let clock = Clock()
        let requests = CaptureRequestLifecycle<String, Int>(schedule: clock.schedule)
        var dockResult: Int?
        var stationaryResult: Int?
        let moving = try XCTUnwrap(requests.begin("display-moving-dock") { dockResult = $0 })
        let stationary = try XCTUnwrap(requests.begin("display-stationary-dock") { stationaryResult = $0 })
        requests.finish("display-moving-dock", ticket: moving, value: 1)
        XCTAssertEqual(dockResult, 1)
        XCTAssertNil(stationaryResult)
        requests.finish("display-stationary-dock", ticket: stationary, value: 2)
        XCTAssertEqual(stationaryResult, 2)
    }

    func testStationaryDockPolicyKeepsWallpaperAndExcludesHighWindowsAndAllOwnWindows() {
        let dockLevel = 20
        let ownPID: pid_t = 501
        let dockPID: pid_t = 700
        // The Dock owns wallpaper below level zero as well as its UI at level twenty.
        XCTAssertFalse(CaptureWindowPolicy.excludes(layer: -2147483623, ownerPID: dockPID, ownPID: ownPID, below: dockLevel))
        XCTAssertFalse(CaptureWindowPolicy.excludes(layer: 0, ownerPID: 800, ownPID: ownPID, below: dockLevel))
        XCTAssertTrue(CaptureWindowPolicy.excludes(layer: dockLevel, ownerPID: dockPID, ownPID: ownPID, below: dockLevel))
        XCTAssertTrue(CaptureWindowPolicy.excludes(layer: 24, ownerPID: 900, ownPID: ownPID, below: dockLevel))
        XCTAssertTrue(CaptureWindowPolicy.excludes(layer: 0, ownerPID: ownPID, ownPID: ownPID, below: dockLevel))
        XCTAssertTrue(CaptureWindowPolicy.excludes(layer: 1_000, ownerPID: nil, ownPID: ownPID, below: dockLevel))
    }
}
