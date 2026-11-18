import XCTest
@testable import SpacesEngine

final class DesktopTransitionInstantTests: XCTestCase {
    private let spaces: [UInt64] = [11, 23, 35, 42]

    func testNextStepWaitsForDockToLandInsteadOfPostingTwice() {
        var run = InstantSpaceRun(displayUUID: "Main", spaceIDs: spaces, index: 1)
        XCTAssertEqual(run.next(displayUUID: "Main", spaceIDs: spaces, index: 1, offset: 2), .step(1))
        run.posted(1)
        XCTAssertEqual(run.next(displayUUID: "Main", spaceIDs: spaces, index: 1, offset: 2), .wait)
        XCTAssertEqual(run.next(displayUUID: "Main", spaceIDs: spaces, index: 2, offset: 2), .step(1))
        run.posted(1)
        XCTAssertEqual(run.next(displayUUID: "Main", spaceIDs: spaces, index: 3, offset: 2), .stop)
        XCTAssertFalse(run.awaitingLanding)
    }

    func testSwipeReversalWaitsForLandingBeforeGoingBack() {
        var run = InstantSpaceRun(displayUUID: "Main", spaceIDs: spaces, index: 1)
        run.posted(1)
        XCTAssertEqual(run.next(displayUUID: "Main", spaceIDs: spaces, index: 1, offset: 0), .wait)
        XCTAssertEqual(run.next(displayUUID: "Main", spaceIDs: spaces, index: 2, offset: 0), .step(-1))
    }

    func testEdgeAndChangedLayoutsDoNotPost() {
        var run = InstantSpaceRun(displayUUID: "Main", spaceIDs: spaces, index: 0)
        XCTAssertEqual(run.next(displayUUID: "Main", spaceIDs: spaces, index: 0, offset: -1), .stop)
        XCTAssertEqual(run.next(displayUUID: "Other", spaceIDs: spaces, index: 0, offset: 1), .stop)
        XCTAssertEqual(run.next(displayUUID: "Main", spaceIDs: spaces.reversed(), index: 0, offset: 1), .stop)
        XCTAssertEqual(run.next(displayUUID: "Main", spaceIDs: spaces, index: 2, offset: 1), .stop)
    }
}
