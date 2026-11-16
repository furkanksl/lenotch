import CoreGraphics
import XCTest
@testable import SpacesEngine

/// Pure math and synthetic touch reports only. These tests never create the engine,
/// overlays, screen captures, display links, input taps, or private-framework monitors.
final class DesktopTransitionMathTests: XCTestCase {
    func testRestingSpringConvergesMonotonicallyWithoutOvershootingFromEitherDirection() {
        for direction: CGFloat in [-1, 1] {
            for speed: CGFloat in [0.3, 1, 2] {
                var progress = direction * 0.85
                var velocity: CGFloat = 0
                var previousDistance = abs(progress)

                for _ in 0..<480 {
                    TransitionMath.stepSpring(
                        progress: &progress, velocity: &velocity,
                        delta: 1.0 / 120, speed: speed, limit: 2
                    )
                    XCTAssertTrue(progress.isFinite)
                    XCTAssertTrue(velocity.isFinite)
                    XCTAssertGreaterThanOrEqual(progress * direction, 0, "A resting critically damped spring must not cross its destination")
                    XCTAssertLessThanOrEqual(abs(progress), previousDistance + 1e-12)
                    previousDistance = abs(progress)
                }

                XCTAssertTrue(TransitionMath.isSettled(progress: progress, velocity: velocity))
            }
        }
    }

    func testSpringStopsOutwardVelocityAtBothProgressLimits() {
        for direction: CGFloat in [-1, 1] {
            var progress = direction * 5
            var velocity = direction * 1_000
            TransitionMath.stepSpring(
                progress: &progress, velocity: &velocity,
                delta: 1.0 / 240, speed: 1, limit: 2
            )
            XCTAssertEqual(progress, direction * 2, accuracy: 1e-12)
            XCTAssertEqual(velocity, 0, accuracy: 1e-12, "Do not accumulate outward momentum at an overlay boundary")

            TransitionMath.stepSpring(
                progress: &progress, velocity: &velocity,
                delta: 1.0 / 120, speed: 1, limit: 2
            )
            XCTAssertLessThan(abs(progress), 2, "The next frame must be free to spring back inward")
        }
    }

    func testZeroTimeStepDoesNotAdvanceTheSpring() {
        var progress: CGFloat = 0.4
        var velocity: CGFloat = -0.8
        TransitionMath.stepSpring(
            progress: &progress, velocity: &velocity,
            delta: 0, speed: 1, limit: 2
        )
        XCTAssertEqual(progress, 0.4)
        XCTAssertEqual(velocity, -0.8)
    }

    func testSettledRequiresBothDistanceAndVelocityStrictlyInsideTheirThresholds() {
        XCTAssertTrue(TransitionMath.isSettled(progress: 0.00099, velocity: 0.0199))
        XCTAssertTrue(TransitionMath.isSettled(progress: -0.00099, velocity: -0.0199))
        XCTAssertFalse(TransitionMath.isSettled(progress: 0.001, velocity: 0))
        XCTAssertFalse(TransitionMath.isSettled(progress: -0.001, velocity: 0))
        XCTAssertFalse(TransitionMath.isSettled(progress: 0, velocity: 0.02))
        XCTAssertFalse(TransitionMath.isSettled(progress: 0, velocity: -0.02))
        XCTAssertGreaterThan(Config.revealStartDistance, 0.001, "A settled frame must also fit inside the reveal-distance threshold")
    }

    func testCommitAndFlickThresholdsDistinguishJitterFlicksAndFullDistanceCommits() {
        XCTAssertGreaterThan(Config.directionSlop, 0)
        XCTAssertGreaterThan(Config.flickMinProgress, Config.directionSlop * Config.travelPerTrackpadWidth)
        XCTAssertGreaterThan(Config.commitThreshold, Config.flickMinProgress)
        XCTAssertLessThan(Config.commitThreshold, 1)
        XCTAssertGreaterThan(Config.flickVelocity, 0)
        XCTAssertGreaterThan(TransitionMath.maxReleaseVelocity, Config.flickVelocity)
        XCTAssertLessThan(Config.edgeRubberBand, Config.commitThreshold, "Edge resistance must not look like a committed full transition")
    }

    func testLightweightScaleIsBoundedSymmetricAndReturnsToFullSizeAtEachSpace() {
        for step in -120...120 {
            let progress = CGFloat(step) / 40
            let scale = TransitionMath.scale(progress: progress)
            XCTAssertGreaterThanOrEqual(scale, 1 - Config.scaleInset - 1e-12)
            XCTAssertLessThanOrEqual(scale, 1 + 1e-12)
            XCTAssertEqual(scale, TransitionMath.scale(progress: -progress), accuracy: 1e-12)
        }
        for space in -3...3 {
            XCTAssertEqual(TransitionMath.scale(progress: CGFloat(space)), 1, accuracy: 1e-12)
        }
        XCTAssertEqual(TransitionMath.scale(progress: 0.5), 1 - Config.scaleInset, accuracy: 1e-12)
        XCTAssertEqual(TransitionMath.dim(offCentre: -1), 0)
        XCTAssertEqual(TransitionMath.dim(offCentre: 2), Config.dimAmount)
    }

    func testMagneticGeometryHasSymmetricPositionsAndFullSizeCenter() {
        let gap: CGFloat = 0.02
        XCTAssertEqual(TransitionMath.magneticPosition(offset: 0, gap: gap), 0)
        XCTAssertEqual(TransitionMath.magneticScale(offset: 0), 1)
        XCTAssertEqual(TransitionMath.magneticScale(offset: 1), 1 - Config.magneticInset)
        // Center-to-center distance is the two rendered half-widths plus the gap.
        // The off-center card is smaller than the centered, full-width card.
        let neighborScale = 1 - Config.magneticInset
        XCTAssertEqual(TransitionMath.magneticPosition(offset: 1, gap: gap), (1 + neighborScale) / 2 + gap, accuracy: 1e-12)
        for step in 1...20 {
            let offset = CGFloat(step) / 20
            XCTAssertEqual(
                TransitionMath.magneticPosition(offset: offset, gap: gap),
                -TransitionMath.magneticPosition(offset: -offset, gap: gap), accuracy: 1e-12
            )
            XCTAssertEqual(
                TransitionMath.magneticScale(offset: offset),
                TransitionMath.magneticScale(offset: -offset), accuracy: 1e-12
            )
        }
    }

    func testStackSlidesOnlyTheIncomingSideAndDimsTheCoveredSide() {
        // Negative offsets are older cards already on the pile. Positive offsets
        // are newer cards waiting off the right edge, not off the left edge.
        XCTAssertEqual(TransitionMath.stackSlide(offset: -1), 0)
        XCTAssertEqual(TransitionMath.stackSlide(offset: 0), 0)
        XCTAssertEqual(TransitionMath.stackSlide(offset: 1), 1)
        XCTAssertEqual(TransitionMath.stackCover(offset: -1), 1)
        XCTAssertEqual(TransitionMath.stackCover(offset: 1), 0)
        XCTAssertEqual(TransitionMath.stackScale(offset: -1), 1 - Config.stackInset)
        XCTAssertEqual(TransitionMath.stackScale(offset: 1), 1)
        XCTAssertEqual(TransitionMath.stackDim(offset: -1), Config.stackDim)
        XCTAssertEqual(TransitionMath.stackDim(offset: 1), 0)
        XCTAssertEqual(TransitionMath.stackShadow(offset: 1), 0)
        XCTAssertEqual(TransitionMath.stackShadow(offset: 0), Config.stackShadow)
        XCTAssertEqual(TransitionMath.stackSlide(offset: 0.5), 0.5)
        XCTAssertEqual(TransitionMath.stackScale(offset: -0.5), 1 - Config.stackInset / 2)
        XCTAssertEqual(TransitionMath.stackDim(offset: -0.5), Config.stackDim / 2)
    }

    func testHexagonProjectionPreservesTheFrontFaceAndMirrorsSideFaces() {
        let front = TransitionMath.hexProject(x: 0.3, y: -0.2, offset: 0, progress: 0)
        XCTAssertEqual(front.x, 0.3, accuracy: 1e-12)
        XCTAssertEqual(front.y, -0.2, accuracy: 1e-12)
        XCTAssertEqual(front.scale, 1, accuracy: 1e-12)
        let left = TransitionMath.hexProject(x: -0.2, y: 0.3, offset: -0.6, progress: 0.4)
        let right = TransitionMath.hexProject(x: 0.2, y: 0.3, offset: 0.6, progress: 0.4)
        XCTAssertEqual(left.x, -right.x, accuracy: 1e-12)
        XCTAssertEqual(left.y, right.y, accuracy: 1e-12)
        XCTAssertEqual(left.scale, right.scale, accuracy: 1e-12)
        XCTAssertGreaterThan(left.scale, 0)
        XCTAssertEqual(TransitionMath.hexDim(offset: -2), Config.hexDim)
        XCTAssertEqual(TransitionMath.hexDim(offset: 0), 0)
    }

    func testThreeAndFourFingerSwipesBeginOnceAndReportTravelAndReleaseVelocity() {
        for count in [3, 4] {
            let probe = GestureProbe()
            probe.send(time: 0, count: count, x: 0.2)
            probe.send(time: 0.02, count: count, x: 0.24)
            probe.send(time: 0.04, count: count, x: 0.26)
            probe.send(time: 0.06, count: count, x: 0.28)
            probe.send(time: 0.09, count: 0)
            probe.send(time: 0.1, count: 0)

            XCTAssertEqual(probe.arms, 1)
            XCTAssertEqual(probe.begins, 1)
            XCTAssertEqual(probe.changes.count, 2)
            XCTAssertEqual(probe.changes.last ?? -1, 0.04, accuracy: 1e-12)
            XCTAssertEqual(probe.ends.count, 1)
            XCTAssertFalse(probe.ends[0].cancelled)
            XCTAssertEqual(probe.ends[0].velocity, 1, accuracy: 1e-10)
        }
    }

    func testDirectionSlopDebouncesStationaryContactsAndFingerCountChanges() {
        let probe = GestureProbe()
        probe.send(time: 0, count: 3, x: 0.2)
        probe.send(time: 0.01, count: 3, x: 0.2 + Config.directionSlop / 2)
        probe.send(time: 0.02, count: 4, x: 0.7)
        probe.send(time: 0.03, count: 4, x: 0.7 + Config.directionSlop / 2)
        XCTAssertEqual(probe.arms, 1)
        XCTAssertEqual(probe.begins, 0, "Adding a finger must not look like horizontal movement")
        XCTAssertTrue(probe.changes.isEmpty)

        probe.send(time: 0.04, count: 4, x: 0.7 + Config.directionSlop * 2)
        probe.send(time: 0.05, count: 4, x: 0.75)
        XCTAssertEqual(probe.begins, 1)
        XCTAssertEqual(probe.arms, 1)
    }

    func testVerticalAndDiagonalGesturesStayRejectedUntilTheFingersLift() {
        // Stay clearly past slop: averaging three identical coordinates can round
        // an exact slop-sized delta just below its threshold.
        let verticalMovement = Config.directionSlop * 2
        for horizontalMovement: CGFloat in [0, verticalMovement * 1.1] {
            let probe = GestureProbe()
            probe.send(time: 0, count: 3, x: 0.2, y: 0.2)
            probe.send(time: 0.02, count: 3, x: 0.2 + horizontalMovement, y: 0.2 + verticalMovement)
            probe.send(time: 0.04, count: 3, x: 0.8, y: 0.2)
            XCTAssertEqual(probe.begins, 0)
            XCTAssertEqual(probe.disarms, 1)
            XCTAssertTrue(probe.ends.isEmpty)

            probe.send(time: 0.06, count: 0)
            probe.send(time: 0.08, count: 3, x: 0.2)
            probe.send(time: 0.1, count: 3, x: 0.3)
            XCTAssertEqual(probe.begins, 1, "A rejected gesture must not poison the next contact sequence")
        }
    }

    func testTwoAndFiveFingerGesturesNeverActivateDesktopSwitching() {
        for count in [2, 5] {
            let probe = GestureProbe()
            probe.send(time: 0, count: count, x: 0.2)
            probe.send(time: 0.02, count: count, x: 0.8)
            XCTAssertEqual(probe.arms, 0)
            XCTAssertEqual(probe.begins, 0)
            XCTAssertTrue(probe.changes.isEmpty)
            XCTAssertTrue(probe.ends.isEmpty)
        }
    }

    func testAddingAFourthFingerDuringASwipeDoesNotJumpItsProgress() {
        let probe = GestureProbe()
        probe.send(time: 0, count: 3, x: 0.2)
        probe.send(time: 0.02, count: 3, x: 0.25)
        probe.send(time: 0.04, count: 3, x: 0.3)
        probe.send(time: 0.06, count: 4, x: 0.8)
        probe.send(time: 0.08, count: 4, x: 0.85)
        XCTAssertEqual(probe.changes.count, 3)
        XCTAssertEqual(probe.changes[0], 0.05, accuracy: 1e-12)
        XCTAssertEqual(probe.changes[1], 0.05, accuracy: 1e-12)
        XCTAssertEqual(probe.changes[2], 0.1, accuracy: 1e-12)
        XCTAssertEqual(probe.begins, 1)
    }

    func testExtraFingersCancelAnActiveGestureAndDoNotRestartUntilLift() {
        let probe = GestureProbe()
        probe.send(time: 0, count: 3, x: 0.2)
        probe.send(time: 0.02, count: 3, x: 0.3)
        probe.send(time: 0.04, count: 5, x: 0.4)
        probe.send(time: 0.06, count: 3, x: 0.8)
        XCTAssertEqual(probe.ends.count, 1)
        XCTAssertTrue(probe.ends[0].cancelled)
        XCTAssertEqual(probe.ends[0].velocity, 0)
        XCTAssertEqual(probe.begins, 1)

        probe.send(time: 0.08, count: 0)
        probe.send(time: 0.1, count: 3, x: 0.2)
        probe.send(time: 0.12, count: 3, x: 0.3)
        XCTAssertEqual(probe.begins, 2)
    }

    func testForeignDevicesAndInvalidCoordinatesCannotHijackAnActiveGesture() {
        let probe = GestureProbe()
        probe.send(time: 0, count: 3, x: 0.2)
        probe.send(time: 0.02, count: 3, x: 0.3, device: 99)
        probe.send(time: 0.03, count: 0, device: 99)
        probe.send(time: .nan, count: 3, x: 0.3)
        probe.send(time: 0.04, count: 3, x: .infinity)
        XCTAssertEqual(probe.arms, 1)
        XCTAssertEqual(probe.begins, 0)
        XCTAssertTrue(probe.ends.isEmpty)

        probe.send(time: 0.06, count: 3, x: 0.3)
        XCTAssertEqual(probe.begins, 1)
    }

    func testReleaseAfterHoldingStillDoesNotReuseStaleFlickVelocity() {
        let probe = GestureProbe()
        probe.send(time: 0, count: 3, x: 0.2)
        probe.send(time: 0.02, count: 3, x: 0.25)
        probe.send(time: 0.04, count: 3, x: 0.6)
        probe.send(time: 0.4, count: 0)
        XCTAssertEqual(probe.ends.count, 1)
        XCTAssertFalse(probe.ends[0].cancelled)
        XCTAssertEqual(probe.ends[0].velocity, 0)
    }

    func testExplicitRecognizerCancellationIsIdempotentAndDisarmsPendingContacts() {
        let pending = GestureProbe()
        pending.send(time: 0, count: 3, x: 0.2)
        pending.recognizer.cancel()
        pending.recognizer.cancel()
        XCTAssertEqual(pending.disarms, 1)
        XCTAssertTrue(pending.ends.isEmpty)

        let active = GestureProbe()
        active.send(time: 0, count: 3, x: 0.2)
        active.send(time: 0.02, count: 3, x: 0.3)
        active.recognizer.cancel()
        active.recognizer.cancel()
        XCTAssertEqual(active.ends.count, 1)
        XCTAssertTrue(active.ends[0].cancelled)
        XCTAssertEqual(active.ends[0].velocity, 0)
    }

    func testStylesSeparateSystemInstantAndSnapshotBasedTransitions() {
        XCTAssertEqual(Set(DesktopTransitionStyle.allCases), [.system, .instant, .lightweight, .hexagon, .magnetic, .stack])
        XCTAssertFalse(DesktopTransitionStyle.system.isDrawn)
        XCTAssertFalse(DesktopTransitionStyle.instant.isDrawn)
        for style in [DesktopTransitionStyle.lightweight, .hexagon, .magnetic, .stack] {
            XCTAssertTrue(style.isDrawn)
        }
        XCTAssertEqual(Set(DesktopTransitionStyle.allCases.map(\.id)).count, DesktopTransitionStyle.allCases.count)
    }

    func testDefaultVisualOptionsPreserveDockAndCornersWithoutReadingUserPreferences() {
        let options = DesktopTransitionOptions()
        XCTAssertEqual(options.style, .lightweight)
        XCTAssertEqual(options.speed, 1)
        XCTAssertEqual(options.sensitivity, 1)
        XCTAssertTrue(options.roundedCorners)
        XCTAssertFalse(options.moveDock)
    }

    private final class GestureProbe {
        let recognizer = SwipeRecognizer()
        var arms = 0
        var disarms = 0
        var begins = 0
        var changes: [CGFloat] = []
        var ends: [(velocity: CGFloat, cancelled: Bool)] = []

        init() {
            recognizer.onArm = { [weak self] in self?.arms += 1 }
            recognizer.onDisarm = { [weak self] in self?.disarms += 1 }
            recognizer.onBegin = { [weak self] in self?.begins += 1 }
            recognizer.onChange = { [weak self] dx in self?.changes.append(dx) }
            recognizer.onEnd = { [weak self] velocity, cancelled in self?.ends.append((velocity, cancelled)) }
        }

        func send(time: Double, count: Int, x: CGFloat = 0.2, y: CGFloat = 0.2, device: UInt = 1) {
            recognizer.handle(TouchFrame(
                device: device, timestamp: time,
                points: Array(repeating: CGPoint(x: x, y: y), count: count)
            ))
        }
    }
}
