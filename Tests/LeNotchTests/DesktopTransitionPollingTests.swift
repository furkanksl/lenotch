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

    func testIncompleteInstantSetupKeepsRecoveryPollingAlive() {
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

    func testDisabledAndSystemDefaultStylesNeverScheduleRecoveryPolling() {
        XCTAssertFalse(Policy.shouldPoll(enabled: false, customTransition: true, paused: false,
                                        fullySetUp: false, settingsInFront: true, pendingInspection: true))
        XCTAssertFalse(Policy.shouldPoll(enabled: true, customTransition: false, paused: false,
                                        fullySetUp: false, settingsInFront: true, pendingInspection: true))
    }

    func testInactiveEngineStillPerformsInitialCapabilityInspection() {
        XCTAssertEqual(Policy.action(paused: false, active: false, fullySetUp: false, transitioning: false,
                                     settingsInFront: false, explicit: false), .inspect)
    }
}
