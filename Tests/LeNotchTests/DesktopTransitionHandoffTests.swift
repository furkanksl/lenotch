import XCTest
@testable import SpacesEngine

final class DesktopTransitionHandoffTests: XCTestCase {
    func testLongHeldOpaqueDesktopCutsInsteadOfFadingIntoSuspendedRendering() {
        XCTAssertTrue(TransitionHandoff.canFade(coveredFor: 0.1))
        XCTAssertTrue(TransitionHandoff.canFade(coveredFor: Config.fadeSafeTime - 0.001))
        XCTAssertFalse(TransitionHandoff.canFade(coveredFor: Config.fadeSafeTime))
        XCTAssertFalse(TransitionHandoff.canFade(coveredFor: 1.3), "WindowServer may no longer render beneath the overlay")
        XCTAssertFalse(TransitionHandoff.canFade(coveredFor: 30))
    }

    func testCaptureThatNeverCallsBackStillHasAnIndependentCompletionDeadline() {
        var callbacks: [() -> Void] = []
        var scheduledDelay: TimeInterval?
        let deadline = TransitionCompletionDeadline { delay, callback in
            scheduledDelay = delay
            callbacks.append(callback)
            return {}
        }
        var exposedLiveDesktop = 0
        deadline.arm { exposedLiveDesktop += 1 }
        XCTAssertEqual(scheduledDelay, 3)
        XCTAssertEqual(exposedLiveDesktop, 0)
        // No capture completion or display-link tick: only the wall-clock callback arrives.
        callbacks[0]()
        callbacks[0]()
        XCTAssertEqual(exposedLiveDesktop, 1, "A stalled capture cannot hold an opaque image forever")
    }

    func testNormalCompletionOrDisableInvalidatesEvenAnAlreadyQueuedTimeout() {
        var callbacks: [() -> Void] = []
        var cancellations = 0
        let deadline = TransitionCompletionDeadline { _, callback in
            callbacks.append(callback)
            return { cancellations += 1 }
        }
        var expired = false
        deadline.arm { expired = true }
        deadline.cancel()
        callbacks[0]()
        XCTAssertFalse(expired)
        XCTAssertEqual(cancellations, 1)
    }

    func testNewGestureCannotBeDismissedByThePreviousGesturesTimeout() {
        var callbacks: [() -> Void] = []
        let deadline = TransitionCompletionDeadline { _, callback in callbacks.append(callback); return {} }
        var first = 0, next = 0
        deadline.arm { first += 1 }
        deadline.cancel()
        deadline.arm { next += 1 }
        callbacks[0]()
        XCTAssertEqual(first, 0)
        XCTAssertEqual(next, 0)
        callbacks[1]()
        XCTAssertEqual(next, 1)
    }
}
