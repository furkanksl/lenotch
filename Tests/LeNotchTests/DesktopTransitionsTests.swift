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
        XCTAssertEqual(model.options, DesktopTransitionOptions(style: .system, sensitivity: 1))
        XCTAssertEqual(model.options.slideDuration, 0.35)
        XCTAssertEqual(DesktopTransitionStyle.allCases, [.system, .instant, .liveSlide])
        model.start()
        model.start()
        model.setSuspended(true)
        model.configure(style: .instant, sensitivity: 1.4)
        model.stop()
        XCTAssertEqual(created, 0, "No switcher driver is constructed while off")
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
        model.configure(style: .instant, sensitivity: 1.2)
        XCTAssertEqual(driver.updates, [DesktopTransitionOptions(style: .instant, sensitivity: 1.2)])
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
        XCTAssertEqual(defaults.string(forKey: "lenotch.spaces.style"), "instant", "Keep the selected style when disabled")
        XCTAssertEqual(defaults.double(forKey: "lenotch.spaces.sensitivity"), 1.2)
    }

    func testLiveSlidePersistsDurationIndependentlyOfStyleAndSensitivity() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let driver = Driver()
        let model = DesktopTransitionsModel(defaults: defaults) { driver }
        model.start()
        model.setEnabled(true)
        model.configure(style: .liveSlide, slideDuration: 0.475)
        XCTAssertEqual(driver.updates, [DesktopTransitionOptions(style: .liveSlide, slideDuration: 0.475)])
        XCTAssertEqual(defaults.string(forKey: "lenotch.spaces.style"), "liveSlide")
        XCTAssertEqual(defaults.double(forKey: "lenotch.spaces.slideDuration"), 0.475)

        model.configure(style: .instant, sensitivity: 1.4)
        XCTAssertEqual(driver.updates.last, DesktopTransitionOptions(style: .instant, sensitivity: 1.4, slideDuration: 0.475))
        model.stop()

        let restoredDriver = Driver()
        let restored = DesktopTransitionsModel(defaults: defaults) { restoredDriver }
        restored.configure(style: .liveSlide)
        restored.start()
        XCTAssertEqual(restoredDriver.starts, [DesktopTransitionOptions(style: .liveSlide, sensitivity: 1.4, slideDuration: 0.475)])
        restored.stop()
    }

    func testRemovedCurtainSelectionFallsBackToSystemStyle() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: DesktopTransitionsModel.enabledKey)
        defaults.set("curtain", forKey: "lenotch.spaces.style")
        defaults.set(1.4, forKey: "lenotch.spaces.sensitivity")
        defaults.set(0.475, forKey: "lenotch.spaces.slideDuration")
        let driver = Driver()
        let model = DesktopTransitionsModel(defaults: defaults) { driver }
        model.start()
        defer { model.stop() }
        XCTAssertTrue(model.enabled)
        let expected = DesktopTransitionOptions(style: .system, sensitivity: 1.4, slideDuration: 0.475)
        XCTAssertEqual(model.options, expected)
        XCTAssertEqual(driver.starts, [expected])
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
        second.onStatus?(.needsAccessibility)
        stale?(.active(keyboard: true, trackpad: true))
        XCTAssertEqual(model.status, .needsAccessibility)
        model.stop()
    }

    func testLegacyStylesFallBackToSystemWithoutDiscardingOptInOrSensitivity() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: DesktopTransitionsModel.enabledKey)
        defaults.set(1.5, forKey: "lenotch.spaces.sensitivity")
        defaults.set(1.8, forKey: "lenotch.spaces.speed")
        defaults.set(false, forKey: "lenotch.spaces.rounded")
        defaults.set(true, forKey: "lenotch.spaces.moveDock")
        let expected = DesktopTransitionOptions(style: .system, sensitivity: 1.5)

        for legacyStyle in ["lightweight", "magnetic", "hexagon", "stack"] {
            defaults.set(legacyStyle, forKey: "lenotch.spaces.style")
            let driver = Driver()
            let model = DesktopTransitionsModel(defaults: defaults) { driver }
            XCTAssertTrue(model.enabled, legacyStyle)
            XCTAssertEqual(model.options, expected, legacyStyle)
            XCTAssertTrue(driver.starts.isEmpty, legacyStyle)
            model.start()
            XCTAssertEqual(driver.starts, [expected], legacyStyle)
            model.stop()
        }
    }

    func testInvalidStoredSettingsAreBoundedAndUnknownStylesFallBack() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("future-style", forKey: "lenotch.spaces.style")
        defaults.set(100, forKey: "lenotch.spaces.sensitivity")
        defaults.set(1.5, forKey: "lenotch.spaces.slideDuration")
        let model = DesktopTransitionsModel(defaults: defaults)
        XCTAssertEqual(model.options.style, .system)
        XCTAssertEqual(model.options.sensitivity, 2)
        XCTAssertEqual(model.options.slideDuration, 0.75)
        model.configure(sensitivity: -100, slideDuration: 0.01)
        XCTAssertEqual(model.options.sensitivity, 0.5)
        XCTAssertEqual(model.options.slideDuration, 0.15)
        model.configure(sensitivity: .infinity, slideDuration: .nan)
        XCTAssertEqual(model.options.sensitivity, 1)
        XCTAssertEqual(model.options.slideDuration, 0.35)
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
