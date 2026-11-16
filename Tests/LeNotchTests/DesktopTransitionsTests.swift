import Foundation
import XCTest
@testable import Lenotch
@testable import SpacesEngine

@MainActor
final class DesktopTransitionsTests: XCTestCase {
    private final class Driver: DesktopTransitionsDriving {
        var onStatus: ((DesktopTransitionStatus) -> Void)?
        var onTransition: ((Bool) -> Void)?
        var starts: [DesktopTransitionOptions] = []
        var updates: [DesktopTransitionOptions] = []
        var suspensions: [Bool] = []
        var stops = 0
        func start(_ options: DesktopTransitionOptions) { starts.append(options) }
        func update(_ options: DesktopTransitionOptions) { updates.append(options) }
        func setSuspended(_ suspended: Bool) { suspensions.append(suspended) }
        func stop() { stops += 1 }
    }

    private func defaults() throws -> (UserDefaults, String) {
        let name = "lenotch.test.spaces.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }


    func testTransitionActivityIsPostedAndClearedWhenTheFeatureStops() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: DesktopTransitionsModel.enabledKey)
        let driver = Driver()
        let model = DesktopTransitionsModel(defaults: defaults) { driver }
        var posted: [Bool] = []
        let token = NotificationCenter.default.addObserver(forName: DesktopTransitionsModel.transitionChanged, object: nil, queue: nil) {
            posted.append($0.userInfo?["active"] as? Bool ?? false)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        model.start()
        driver.onTransition?(true)
        XCTAssertTrue(model.isTransitioning)
        model.stop()
        XCTAssertFalse(model.isTransitioning)
        XCTAssertEqual(posted, [true, false])
    }

    func testDefaultOffDoesNotEvenConstructThePrivateAPIEngine() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var created = 0
        let model = DesktopTransitionsModel(defaults: defaults) { created += 1; return Driver() }
        XCTAssertFalse(model.enabled)
        model.start()
        model.start()
        model.setSuspended(true)
        model.configure(style: .hexagon, speed: 1.4)
        model.stop()
        XCTAssertEqual(created, 0, "No observers, taps, keyboard changes, captures or trackpad monitoring while off")
        XCTAssertEqual(model.status, .off)
    }

    func testOptInLifecycleAndSettingsAreIndependentOfOpeningSetup() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let driver = Driver()
        var created = 0
        let model = DesktopTransitionsModel(defaults: defaults) { created += 1; return driver }
        model.setEnabled(true)
        XCTAssertEqual(created, 0, "A preference set before the app starts doesn't activate system controls")
        model.setSuspended(true)
        model.start()
        model.start()
        model.setEnabled(true)
        XCTAssertEqual(created, 1)
        XCTAssertEqual(driver.starts.count, 1)
        XCTAssertEqual(driver.suspensions, [true], "Respect an existing lock/presentation before starting")
        driver.onStatus?(.active(keyboard: true, trackpad: false))
        XCTAssertEqual(model.status, .active(keyboard: true, trackpad: false))
        model.configure(style: .stack, speed: 1.8, sensitivity: 1.2, roundedCorners: false, moveDock: true)
        XCTAssertEqual(driver.updates.last?.style, .stack)
        XCTAssertEqual(driver.updates.last?.moveDock, true)
        XCTAssertTrue(defaults.bool(forKey: DesktopTransitionsModel.enabledKey))
        let restored = DesktopTransitionsModel(defaults: defaults) { XCTFail("Restoring preferences isn't activation"); return Driver() }
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(restored.options, model.options)
        model.setEnabled(false)
        XCTAssertEqual(driver.stops, 1)
        XCTAssertNil(driver.onStatus)
        XCTAssertEqual(model.status, .off)
        model.stop()
        XCTAssertEqual(driver.stops, 1)
        XCTAssertFalse(defaults.bool(forKey: DesktopTransitionsModel.enabledKey))
        XCTAssertEqual(defaults.string(forKey: "lenotch.spaces.style"), "stack", "Keep visual choices when disabled")
    }

    func testLateStatusFromDisabledGenerationCannotReactivateTheUI() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = Driver(), second = Driver()
        var count = 0
        let model = DesktopTransitionsModel(defaults: defaults) { count += 1; return count == 1 ? first : second }
        model.start()
        model.setEnabled(true)
        let stale = first.onStatus
        model.setEnabled(false)
        stale?(.active(keyboard: true, trackpad: true))
        XCTAssertEqual(model.status, .off)
        model.setEnabled(true)
        second.onStatus?(.needsScreenRecording)
        stale?(.active(keyboard: true, trackpad: true))
        XCTAssertEqual(model.status, .needsScreenRecording)
        model.stop()
    }

    func testInvalidStoredSettingsAreBoundedAndUnknownStylesFallBack() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("future-style", forKey: "lenotch.spaces.style")
        defaults.set(-100, forKey: "lenotch.spaces.speed")
        defaults.set(100, forKey: "lenotch.spaces.sensitivity")
        let model = DesktopTransitionsModel(defaults: defaults)
        XCTAssertEqual(model.options.style, .lightweight)
        XCTAssertEqual(model.options.speed, 0.3)
        XCTAssertEqual(model.options.sensitivity, 2)
        model.configure(speed: .nan, sensitivity: .infinity)
        XCTAssertEqual(model.options.speed, 1)
        XCTAssertEqual(model.options.sensitivity, 1)
        XCTAssertEqual(Set(DesktopTransitionStyle.allCases.map(\.title)).count, 6)
    }

    func testSuspensionPreservesOptInAndReturnsToThePreviousConfiguration() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let driver = Driver()
        let model = DesktopTransitionsModel(defaults: defaults) { driver }
        model.start()
        model.setEnabled(true)
        model.setSuspended(true)
        model.setSuspended(false)
        XCTAssertEqual(driver.suspensions, [false, true, false])
        XCTAssertTrue(model.enabled)
        model.stop()
    }
}
