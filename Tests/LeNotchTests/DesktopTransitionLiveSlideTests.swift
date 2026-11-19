import CDockSwipe
import XCTest
@testable import SpacesEngine

final class DesktopTransitionLiveSlideTests: XCTestCase {
    func testDurationControlsHowLongTheGestureKeepsMoving() {
        var quick = LiveSlide(direction: DSDirectionRight, start: 10, duration: 0.2, spaceCount: 3)
        var slow = LiveSlide(direction: DSDirectionRight, start: 10, duration: 0.6, spaceCount: 3)

        XCTAssertTrue(quick.advance(to: 10.25).ended)
        XCTAssertFalse(slow.advance(to: 10.25).ended)
        XCTAssertGreaterThan(quick.position, slow.position)
        XCTAssertTrue(slow.advance(to: 10.65).ended)
        XCTAssertEqual(quick.position, slow.position, accuracy: 0.0001)
    }

    func testDelayedFramesCatchUpWithoutOvershootOrReverseTravel() {
        var slide = LiveSlide(direction: DSDirectionLeft, start: 0, duration: 0.4, spaceCount: 3)
        let frames = [0.0, 0.02, 0.06, 0.11, 0.09, 0.27, 0.44].map { slide.advance(to: $0) }

        XCTAssertTrue(frames.dropLast().allSatisfy { !$0.ended && $0.delta >= 0 })
        XCTAssertTrue(frames.last?.ended == true)
        XCTAssertEqual(frames[4].delta, 0)
        XCTAssertEqual(frames.map(\.delta).reduce(LiveSlide.initialTravel, +), slide.position, accuracy: 0.0001)
        XCTAssertGreaterThan(slide.position, 0.5)
        XCTAssertLessThan(slide.position, 1.5)
        XCTAssertEqual(slide.advance(to: 2).delta, 0)
    }

    func testTravelIsScaledForTheSpacesOnThatDisplay() {
        var two = LiveSlide(direction: DSDirectionRight, start: 0, duration: 0.3, spaceCount: 2)
        var six = LiveSlide(direction: DSDirectionRight, start: 0, duration: 0.3, spaceCount: 6)
        _ = two.advance(to: 0.3)
        _ = six.advance(to: 0.3)
        XCTAssertGreaterThan(two.position, six.position)
        XCTAssertLessThan(two.position, 2)
    }

    func testTransportRejectsInvalidNumbersWithoutPostingEvents() {
        XCTAssertFalse(ds_post_live_slide(DSLiveSlideChanged, DSDirectionLeft, .nan, 0, 0))
        XCTAssertFalse(ds_post_live_slide(DSLiveSlideChanged, DSDirectionLeft, 0.1, 2.2, 0))
        XCTAssertFalse(ds_post_live_slide(DSLiveSlideEnded, DSDirectionLeft, 0, 0.8, .infinity))
    }
}
