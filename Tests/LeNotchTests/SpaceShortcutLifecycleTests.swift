import Foundation
import XCTest
@testable import SpacesEngine

/// These exercise only value-state transitions and supplied dictionaries. No event taps,
/// synthetic keypresses, system preference reads, or macOS shortcut changes are involved.
final class SpaceShortcutLifecycleTests: XCTestCase {
    private typealias Configuration = SpaceShortcuts.Configuration
    private typealias Shortcut = SpaceShortcuts.Shortcut
    private typealias ActivationState = SpaceShortcuts.ActivationState

    func testDisabledStateHasNoConfigurationOrCallbackTicket() {
        var state = ActivationState()
        XCTAssertNil(state.current)
        XCTAssertNil(state.ticket())
        XCTAssertFalse(state.accepts(0))
        XCTAssertFalse(state.update(nil), "Repeated off refreshes do not reconfigure the tap")
        XCTAssertNil(state.current)
    }

    func testUnchangedActiveRefreshPreservesAnAlreadyConsumedKeypress() throws {
        var state = ActivationState()
        let configuration = Configuration(entries: [:])
        XCTAssertTrue(state.update(configuration))
        let consumedKeyTicket = try XCTUnwrap(state.ticket())

        for _ in 0..<100 {
            XCTAssertFalse(state.update(Configuration(entries: [:])), "Polling unchanged settings is a no-op")
            XCTAssertEqual(state.current, configuration)
            XCTAssertEqual(state.ticket(), consumedKeyTicket)
            XCTAssertTrue(state.accepts(consumedKeyTicket), "A consumed key must retain its queued action")
        }
    }

    func testDisableRejectsQueuedActionsAndReenableCannotReviveThem() throws {
        var state = ActivationState()
        let configuration = Configuration(entries: [:])
        state.update(configuration)
        let oldTicket = try XCTUnwrap(state.ticket())

        XCTAssertTrue(state.update(nil))
        XCTAssertNil(state.current)
        XCTAssertNil(state.ticket())
        XCTAssertFalse(state.accepts(oldTicket))
        XCTAssertFalse(state.update(nil))

        XCTAssertTrue(state.update(configuration))
        let newTicket = try XCTUnwrap(state.ticket())
        XCTAssertNotEqual(newTicket, oldTicket)
        XCTAssertFalse(state.accepts(oldTicket), "Re-enabling must not revive an old activation")
        XCTAssertTrue(state.accepts(newTicket))
    }

    func testChangingBindingsWhileActiveKeepsTheCapturedOldKeyAction() throws {
        var state = ActivationState()
        state.update(Configuration(entries: [:]))
        let consumedKeyTicket = try XCTUnwrap(state.ticket())
        let changed = Configuration(entries: [
            "79": entry(key: 0, flags: 0x180000),
            "81": entry(key: 2, flags: 0x180000),
        ])

        XCTAssertTrue(state.update(changed), "Changed bindings need to reach the native tap")
        XCTAssertEqual(state.current, changed)
        XCTAssertEqual(state.ticket(), consumedKeyTicket)
        XCTAssertTrue(state.accepts(consumedKeyTicket), "The action already captured its direction")
        XCTAssertFalse(state.update(changed))
    }

    func testMissingPreferencesUseTheNativeControlArrowDefaults() {
        let configuration = Configuration(entries: [:])
        XCTAssertEqual(configuration.left, Shortcut(key: 123, flags: 0x40000))
        XCTAssertEqual(configuration.right, Shortcut(key: 124, flags: 0x40000))
        XCTAssertTrue(configuration.isEnabled)
    }

    func testCustomBindingsPreserveRawModifierBits() {
        let flags: UInt64 = 0x8000000000940000
        let configuration = Configuration(entries: [
            "79": entry(key: 0, flags: flags),
            "81": entry(key: 65535, flags: 0),
        ])
        XCTAssertEqual(configuration.left, Shortcut(key: 0, flags: flags))
        XCTAssertEqual(configuration.right, Shortcut(key: 65535, flags: 0))
    }

    func testDisabledPreferencesNeverFallBackToControlArrows() {
        let configuration = Configuration(entries: [
            "79": entry(key: 0, flags: 0x100000, enabled: false),
            "81": ["enabled": false],
        ])
        XCTAssertNil(configuration.left)
        XCTAssertNil(configuration.right)
        XCTAssertFalse(configuration.isEnabled)
        var state = ActivationState()
        XCTAssertFalse(state.update(configuration))
        XCTAssertNil(state.current)
        XCTAssertNil(state.ticket())
    }

    func testDisablingTheLastBindingEndsTheActivation() throws {
        var state = ActivationState()
        state.update(Configuration(entries: [:]))
        let ticket = try XCTUnwrap(state.ticket())
        let oneBinding = Configuration(entries: ["79": ["enabled": false]])
        XCTAssertTrue(state.update(oneBinding))
        XCTAssertNil(state.current?.left)
        XCTAssertNotNil(state.current?.right)
        XCTAssertTrue(state.accepts(ticket), "One active direction keeps the activation alive")

        XCTAssertTrue(state.update(Configuration(left: nil, right: nil)))
        XCTAssertNil(state.current)
        XCTAssertFalse(state.accepts(ticket))
    }

    func testMalformedEnabledEntriesUseDefaultsButInvalidKeyCodesAreDisabled() {
        let malformed = Configuration(entries: [
            "79": ["enabled": true, "value": ["parameters": [NSNumber(value: 0)]]],
            "81": ["enabled": true],
        ])
        XCTAssertEqual(malformed, Configuration(entries: [:]))

        let invalid = Configuration(entries: [
            "79": entry(key: -1, flags: 0x40000),
            "81": entry(key: 65536, flags: 0x40000),
        ])
        XCTAssertNil(invalid.left)
        XCTAssertNil(invalid.right)
    }

    private func entry(key: Int, flags: UInt64, enabled: Bool = true) -> [String: Any] {
        [
            "enabled": enabled,
            "value": ["parameters": [NSNumber(value: 65535), NSNumber(value: key), NSNumber(value: flags)]],
        ]
    }
}
