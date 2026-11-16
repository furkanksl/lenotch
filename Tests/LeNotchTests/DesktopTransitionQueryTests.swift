import XCTest
@testable import SpacesEngine

final class DesktopTransitionQueryTests: XCTestCase {
    func testFramesNeverExecuteAWindowServerReadOrWaitForItsReply() {
        let harness = Harness()
        harness.cache.seed(1, for: "display")
        harness.now = 0.1

        for _ in 0..<120 {
            XCTAssertEqual(harness.read(), 1)
        }
        XCTAssertEqual(harness.work.count, 1, "A stalled server must not accumulate per-frame queries")
        XCTAssertEqual(harness.reads, 0, "Only the background worker may invoke the server")
        harness.runWorker()
        XCTAssertEqual(harness.reads, 1)
        XCTAssertEqual(harness.read(), 1, "The reply must be delivered on the owner queue")
        harness.deliver.removeFirst()()
        XCTAssertEqual(harness.read(), 2)
    }

    func testPreSwitchReplyCannotConfirmThatTheDockLanded() {
        let harness = Harness()
        harness.cache.seed(1, for: "display")
        harness.now = 0.1
        _ = harness.read()
        let switchPostedAt = 0.15
        harness.now = 0.2
        harness.runWorker()
        harness.deliver.removeFirst()()

        XCTAssertNil(harness.read(after: switchPostedAt), "Completion time is not the query's observation time")
        harness.runWorker()
        harness.deliver.removeFirst()()
        XCTAssertEqual(harness.read(after: switchPostedAt), 2)
    }

    func testExpiredLayoutDoesNotAuthorizeAnotherNativeSwitch() {
        let harness = Harness()
        harness.cache.seed(1, for: "display")
        harness.now = 1
        XCTAssertNil(harness.read())
        XCTAssertEqual(harness.work.count, 1)
    }

    func testDisableDiscardsLateReplyWithoutQueueingMoreBlockedReads() {
        let harness = Harness()
        _ = harness.read()
        harness.cache.invalidate()
        XCTAssertNil(harness.read())
        XCTAssertEqual(harness.work.count, 1)
        harness.runWorker()
        harness.deliver.removeFirst()()
        XCTAssertNil(harness.read(), "A reply from the disabled lifecycle must not refill the cache")
        XCTAssertEqual(harness.work.count, 1, "A new lifecycle can refresh once the old read returns")
        harness.runWorker()
        harness.deliver.removeFirst()()
        XCTAssertEqual(harness.read(), 2)
    }

    func testUnavailableLayoutInvalidatesPreviouslyCachedDesktop() {
        let harness = Harness()
        harness.cache.seed(1, for: "display")
        harness.result = nil
        harness.now = 0.1
        _ = harness.read()
        harness.runWorker()
        harness.deliver.removeFirst()()
        XCTAssertNil(harness.read())
    }

    private final class Harness {
        var now: Double = 0
        var work: [() -> Void] = []
        var deliver: [() -> Void] = []
        var reads = 0
        var result: Int? = 2
        lazy var cache = TransitionQueryCache<String, Int>(
            worker: { self.work.append($0) }, deliver: { self.deliver.append($0) }, clock: { self.now }
        )
        func read(after: Double = 0) -> Int? {
            cache.value(for: "display", after: after) { self.reads += 1; return self.result }
        }
        func runWorker() { work.removeFirst()() }
    }
}
