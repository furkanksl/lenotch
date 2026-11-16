import XCTest
@testable import SpacesEngine

final class DesktopTransitionPollingTests: XCTestCase {
    private typealias Policy = DesktopTransitionPollingPolicy

    func testFullyConfiguredEngineHasNoPeriodicPollingOutsideSystemSettings() {
        XCTAssertFalse(Policy.shouldPoll(enabled: true, customTransition: true, paused: false,
                                        fullySetUp: true, settingsInFront: false, pendingInspection: false))
        XCTAssertEqual(Policy.action(paused: false, active: true, fullySetUp: true, transitioning: false,
                                     settingsInFront: false, explicit: false), .keepActive)
    }

    func testSystemSettingsKeepsPermissionAndShortcutRecoveryPollingAlive() {
        XCTAssertTrue(Policy.shouldPoll(enabled: true, customTransition: true, paused: false,
                                       fullySetUp: true, settingsInFront: true, pendingInspection: false))
        XCTAssertEqual(Policy.action(paused: false, active: true, fullySetUp: true, transitioning: false,
                                     settingsInFront: true, explicit: false), .inspect)
        XCTAssertEqual(Policy.systemSettingsBundleID, "com.apple.systempreferences")
    }

    func testMissingPermissionOrResourceKeepsRecoveryPollingAlive() {
        for active in [false, true] {
            XCTAssertTrue(Policy.shouldPoll(enabled: true, customTransition: true, paused: false,
                                           fullySetUp: false, settingsInFront: false, pendingInspection: false))
            XCTAssertEqual(Policy.action(paused: false, active: active, fullySetUp: false, transitioning: false,
                                         settingsInFront: false, explicit: false), .inspect)
        }
    }

    func testExplicitNotificationsReevaluateEvenACompleteSetupOutsideSettings() {
        // Wake, app activation, permission/display notifications and leaving Settings all use this path.
        XCTAssertEqual(Policy.action(paused: false, active: true, fullySetUp: true, transitioning: false,
                                     settingsInFront: false, explicit: true), .inspect)
    }

    func testGestureDefersAllPermissionAndSystemInspection() {
        for explicit in [false, true] {
            for settingsInFront in [false, true] {
                for fullySetUp in [false, true] {
                    XCTAssertEqual(Policy.action(paused: false, active: true, fullySetUp: fullySetUp,
                                                 transitioning: true, settingsInFront: settingsInFront,
                                                 explicit: explicit), .deferInspection)
                }
            }
        }
    }

    func testDeferredExplicitNotificationIsRecheckedAfterGestureThenPollingStops() {
        XCTAssertEqual(Policy.action(paused: false, active: true, fullySetUp: true, transitioning: true,
                                     settingsInFront: false, explicit: true), .deferInspection)
        XCTAssertTrue(Policy.shouldPoll(enabled: true, customTransition: true, paused: false,
                                       fullySetUp: true, settingsInFront: false, pendingInspection: true))
        XCTAssertEqual(Policy.action(paused: false, active: true, fullySetUp: true, transitioning: false,
                                     settingsInFront: false, explicit: true), .inspect)
        XCTAssertFalse(Policy.shouldPoll(enabled: true, customTransition: true, paused: false,
                                        fullySetUp: true, settingsInFront: false, pendingInspection: false))
    }

    func testPrivacyPauseWinsOverInFlightGestureAndRecoveryWork() {
        // The engine caches suspend/sleep/Reduce Motion notifications before consulting this policy.
        // Pausing cannot wait for a Dock transition or for the next permission poll.
        for active in [false, true] {
            for explicit in [false, true] {
                XCTAssertEqual(Policy.action(paused: true, active: active, fullySetUp: false,
                                             transitioning: true, settingsInFront: true,
                                             explicit: explicit), .pause)
            }
        }
        XCTAssertFalse(Policy.shouldPoll(enabled: true, customTransition: true, paused: true,
                                        fullySetUp: false, settingsInFront: true, pendingInspection: true))
    }

    func testDisabledAndNativeStylesNeverScheduleRecoveryPolling() {
        XCTAssertFalse(Policy.shouldPoll(enabled: false, customTransition: true, paused: false,
                                        fullySetUp: false, settingsInFront: true, pendingInspection: true))
        XCTAssertFalse(Policy.shouldPoll(enabled: true, customTransition: false, paused: false,
                                        fullySetUp: false, settingsInFront: true, pendingInspection: true))
    }

    func testInactiveEngineStillPerformsInitialCapabilityInspection() {
        XCTAssertEqual(Policy.action(paused: false, active: false, fullySetUp: false, transitioning: false,
                                     settingsInFront: false, explicit: false), .inspect)
    }

    func testSettingsChangesKeepDesktopPicturesUnlessWhatTheyShowChanges() {
        let base = DesktopTransitionOptions(style: .lightweight, speed: 1, sensitivity: 1, roundedCorners: true, moveDock: true)
        var restyled = base; restyled.style = .hexagon; restyled.speed = 1.6; restyled.sensitivity = 1.8; restyled.roundedCorners = false
        XCTAssertTrue(Policy.keepsPictures(from: base, to: restyled), "Style, speed, sensitivity and corners don't change the pixels")
        var dock = base; dock.moveDock = false
        XCTAssertFalse(Policy.keepsPictures(from: base, to: dock), "Pictures with the Dock can't stand in for pictures without it")
        var instant = base; instant.style = .instant
        XCTAssertFalse(Policy.keepsPictures(from: base, to: instant), "A style that draws nothing keeps no pixels")
        var system = base; system.style = .system
        XCTAssertFalse(Policy.keepsPictures(from: base, to: system))
    }
}

final class DesktopTransitionLiveReadinessTests: XCTestCase {
    private let width = 96, height = 60

    private func desktop(_ value: UInt8 = 40) -> [UInt8] { [UInt8](repeating: value, count: width * height) }

    func testTheSameDesktopMatchesItsPictureDespiteScalingNoise() {
        let picture = desktop()
        var live = picture
        for index in live.indices where index % 3 == 0 { live[index] &+= 2 }   // resampling/colour rounding
        XCTAssertTrue(Snapshotter.liveMatchesPicture(picture, live))
    }

    func testAWindowMacOSHasNotDrawnYetIsNotReady() {
        let picture = desktop()
        var live = picture
        // An alert of ~260x120 pt on a 1800 pt wide display is about 14x6 sample points: ~1.5% of the sample.
        for row in 20..<26 { for column in 40..<54 { live[row * width + column] = 200 } }
        XCTAssertFalse(Snapshotter.liveMatchesPicture(picture, live))
        // The Dock along one edge, about 3x40 points.
        var withoutDock = picture
        for row in 10..<50 { for column in 93..<96 { withoutDock[row * width + column] = 160 } }
        XCTAssertFalse(Snapshotter.liveMatchesPicture(picture, withoutDock))
    }

    func testTheMenuBarRowIsLeftOutOfTheComparison() {
        let picture = desktop()
        var live = picture
        for index in 0..<(width * Snapshotter.pictureCompareSkippedRows) { live[index] = 255 }   // notch, clock, menu extras
        XCTAssertTrue(Snapshotter.liveMatchesPicture(picture, live))
    }

    func testSamplesOfDifferentSizesNeverMatch() {
        XCTAssertFalse(Snapshotter.liveMatchesPicture(desktop(), Array(desktop().prefix(100))))
    }
}
