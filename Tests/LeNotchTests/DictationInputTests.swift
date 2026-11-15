import Carbon.HIToolbox
import CoreGraphics
import Foundation
import XCTest
@testable import Lenotch

/// Pure shortcut-state tests only: no tap, keyboard events, microphone or shared preferences are used.
final class DictationInputTests: XCTestCase {
    func testDefaultsKeepFnOptInAndExistingOptionDEnabled() throws {
        try withDefaults { defaults in
            let settings = DictationInputSettings(defaults: defaults)
            XCTAssertFalse(settings.pushToTalk)
            XCTAssertTrue(settings.toggleShortcut)
            XCTAssertNil(defaults.object(forKey: DictationInputSettings.pushToTalkKey))
            XCTAssertNil(defaults.object(forKey: DictationInputSettings.toggleShortcutKey),
                         "Reading defaults must not persist an opt-in or overwrite a future preference")
        }
    }

    func testFnAndOptionDPreferencesCanBeEnabledIndependently() throws {
        try withDefaults { defaults in
            for fn in [false, true] {
                for optionD in [false, true] {
                    defaults.set(fn, forKey: DictationInputSettings.pushToTalkKey)
                    defaults.set(optionD, forKey: DictationInputSettings.toggleShortcutKey)
                    let settings = DictationInputSettings(defaults: defaults)
                    XCTAssertEqual(settings.pushToTalk, fn)
                    XCTAssertEqual(settings.toggleShortcut, optionD)
                }
            }
        }
    }

    func testRemovingExplicitPreferencesRestoresOriginalDefaults() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: DictationInputSettings.pushToTalkKey)
            defaults.set(false, forKey: DictationInputSettings.toggleShortcutKey)
            XCTAssertTrue(DictationInputSettings(defaults: defaults).pushToTalk)
            XCTAssertFalse(DictationInputSettings(defaults: defaults).toggleShortcut)

            defaults.removeObject(forKey: DictationInputSettings.pushToTalkKey)
            defaults.removeObject(forKey: DictationInputSettings.toggleShortcutKey)
            XCTAssertFalse(DictationInputSettings(defaults: defaults).pushToTalk)
            XCTAssertTrue(DictationInputSettings(defaults: defaults).toggleShortcut)
        }
    }

    func testPhysicalFnPressAndReleaseOwnExactlyOneHold() throws {
        var input = enabledInput()
        let id = try pressFn(&input)
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []), consume: true, action: .released(id))
        XCTAssertNil(input.hold)
    }

    func testDuplicateFnTransitionsDoNotEmitDuplicateActions() throws {
        var input = enabledInput()
        let id = try pressFn(&input)
        for _ in 0..<3 {
            assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: .maskSecondaryFn), consume: true)
            XCTAssertEqual(input.hold, id)
        }
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []), consume: true, action: .released(id))
        for _ in 0..<3 {
            assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []))
        }
        XCTAssertNil(input.hold)
    }

    func testFnFlagsOnOtherKeysOrWrongEventTypesNeverStartDictation() {
        var input = enabledInput()
        for key in [Int64(kVK_ANSI_A), Int64(kVK_F8), Int64(kVK_LeftArrow), fnKey] {
            assertResult(input.route(.keyDown, keyCode: key, flags: .maskSecondaryFn))
            assertResult(input.route(.keyUp, keyCode: key, flags: .maskSecondaryFn))
            XCTAssertNil(input.hold)
        }
        assertResult(input.route(.flagsChanged, keyCode: Int64(kVK_Shift), flags: .maskSecondaryFn))
        assertResult(input.route(systemDefined, keyCode: 0, flags: .maskSecondaryFn))
        XCTAssertNil(input.hold)
    }

    func testModifierAlreadyHeldBlocksFnWithoutClaimingTheChord() throws {
        for (key, modifier) in modifiers {
            var input = enabledInput()
            assertResult(input.route(.flagsChanged, keyCode: key, flags: modifier))
            assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: [modifier, .maskSecondaryFn]))
            XCTAssertNil(input.hold)

            // Releasing the other modifier cannot turn the remaining held Fn into a fresh press.
            assertResult(input.route(.flagsChanged, keyCode: key, flags: .maskSecondaryFn))
            assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: .maskSecondaryFn))
            assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []))
            _ = try pressFn(&input)
        }
    }

    func testModifierJoiningFnCancelsOnceAndPassesThrough() throws {
        for (key, modifier) in modifiers {
            var input = enabledInput()
            let id = try pressFn(&input)
            let flags: CGEventFlags = [modifier, .maskSecondaryFn]
            assertResult(input.route(.flagsChanged, keyCode: key, flags: flags), action: .cancelled(id))
            XCTAssertNil(input.hold)
            assertResult(input.route(.flagsChanged, keyCode: key, flags: flags))
            assertResult(input.route(.flagsChanged, keyCode: key, flags: .maskSecondaryFn))
            assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: .maskSecondaryFn), consume: true)
            assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []), consume: true)
            XCTAssertNotEqual(try pressFn(&input), id)
        }
    }

    func testOrdinaryKeyJoiningFnCancelsButDoesNotConsumeTheKeyOrItsRelease() throws {
        for key in [Int64(kVK_ANSI_A), Int64(kVK_F8), Int64(kVK_LeftArrow)] {
            var input = enabledInput()
            let id = try pressFn(&input)
            assertResult(input.route(.keyDown, keyCode: key, flags: .maskSecondaryFn), action: .cancelled(id))
            assertResult(input.route(.keyDown, keyCode: key, flags: .maskSecondaryFn))
            assertResult(input.route(.keyUp, keyCode: key, flags: .maskSecondaryFn))
            XCTAssertNil(input.hold, "Key-up must not resurrect a cancelled hold")
            assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: .maskSecondaryFn), consume: true)
            assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []), consume: true)
            XCTAssertNotEqual(try pressFn(&input), id)
        }
    }

    func testSystemDefinedKeyCancelsButAlwaysPassesThrough() throws {
        var input = enabledInput()
        let id = try pressFn(&input)
        assertResult(input.route(systemDefined, keyCode: 0, flags: .maskSecondaryFn), action: .cancelled(id))
        assertResult(input.route(systemDefined, keyCode: 0, flags: .maskSecondaryFn))
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []), consume: true)
        XCTAssertNil(input.hold)
    }

    func testOrdinaryKeyHeldBeforeFnPreventsStartUntilAFreshFnPress() throws {
        for key in [Int64(kVK_ANSI_A), Int64(kVK_F8), Int64(kVK_LeftArrow)] {
            var input = enabledInput()
            assertResult(input.route(.keyDown, keyCode: key, flags: []))
            assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: .maskSecondaryFn))
            XCTAssertNil(input.hold)
            assertResult(input.route(.keyUp, keyCode: key, flags: .maskSecondaryFn))
            assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: .maskSecondaryFn))
            XCTAssertNil(input.hold)
            assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []))
            _ = try pressFn(&input)
        }
    }

    func testEveryPreviouslyHeldOrdinaryKeyMustBeReleased() throws {
        var input = enabledInput()
        assertResult(input.route(.keyDown, keyCode: Int64(kVK_ANSI_A), flags: []))
        assertResult(input.route(.keyDown, keyCode: Int64(kVK_ANSI_B), flags: []))
        assertResult(input.route(.keyUp, keyCode: Int64(kVK_ANSI_A), flags: []))
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: .maskSecondaryFn))
        XCTAssertNil(input.hold)
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []))
        assertResult(input.route(.keyUp, keyCode: Int64(kVK_ANSI_B), flags: []))
        _ = try pressFn(&input)
    }

    func testDisabledFnInputPassesThroughWithoutActions() {
        var input = FnPushToTalk()
        XCTAssertFalse(input.enabled)
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: .maskSecondaryFn))
        assertResult(input.route(.flagsChanged, keyCode: Int64(kVK_Shift), flags: [.maskSecondaryFn, .maskShift]))
        assertResult(input.route(.keyDown, keyCode: Int64(kVK_F8), flags: .maskSecondaryFn))
        assertResult(input.route(.keyUp, keyCode: Int64(kVK_F8), flags: .maskSecondaryFn))
        assertResult(input.route(systemDefined, keyCode: 0, flags: .maskSecondaryFn))
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []))
        XCTAssertNil(input.hold)
    }

    func testDisablingAnActiveHoldCancelsOnceAndStopsConsumingFn() throws {
        var input = enabledInput()
        let id = try pressFn(&input)
        XCTAssertEqual(input.setEnabled(false), .cancelled(id))
        XCTAssertFalse(input.enabled)
        XCTAssertNil(input.hold)
        XCTAssertNil(input.setEnabled(false))
        XCTAssertNil(input.interrupt())
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []))
    }

    func testReenablingWhileFnIsStillDownWaitsForReleaseAndFreshPress() throws {
        var input = enabledInput()
        let first = try pressFn(&input)
        XCTAssertEqual(input.setEnabled(false), .cancelled(first))
        XCTAssertNil(input.setEnabled(true))
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: .maskSecondaryFn))
        XCTAssertNil(input.hold)
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []))
        XCTAssertNotEqual(try pressFn(&input), first)
    }

    func testEnablingWhileUnclaimedFnIsDownDoesNotStartARecording() throws {
        var input = FnPushToTalk()
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: .maskSecondaryFn))
        XCTAssertNil(input.setEnabled(true))
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: .maskSecondaryFn))
        XCTAssertNil(input.hold)
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []))
        _ = try pressFn(&input)
    }

    func testApplyingAnUnchangedEnabledSettingDoesNotCancelAnActiveHold() throws {
        var input = enabledInput()
        let id = try pressFn(&input)
        XCTAssertNil(input.setEnabled(true))
        XCTAssertEqual(input.hold, id)
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []), consume: true, action: .released(id))
    }

    func testInterruptCancelsExactlyOnceAndReleaseCannotFinishTheCancelledHold() throws {
        var input = enabledInput()
        let first = try pressFn(&input)
        XCTAssertEqual(input.interrupt(), .cancelled(first))
        XCTAssertNil(input.interrupt())
        XCTAssertNil(input.hold)
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: .maskSecondaryFn), consume: true)
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []), consume: true)
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: []))
        XCTAssertNotEqual(try pressFn(&input), first)
    }

    func testCapsLockMayAlreadyBeOnOrChangeDuringAHold() throws {
        var input = enabledInput()
        assertResult(input.route(.flagsChanged, keyCode: Int64(kVK_CapsLock), flags: .maskAlphaShift))
        let id = try pressFn(&input, flags: [.maskAlphaShift, .maskSecondaryFn])
        assertResult(input.route(.flagsChanged, keyCode: Int64(kVK_CapsLock), flags: .maskSecondaryFn))
        assertResult(input.route(.flagsChanged, keyCode: Int64(kVK_CapsLock), flags: [.maskAlphaShift, .maskSecondaryFn]))
        XCTAssertEqual(input.hold, id)
        assertResult(input.route(.flagsChanged, keyCode: fnKey, flags: .maskAlphaShift), consume: true, action: .released(id))
    }

    func testHoldEndsOnlyItsOwnRunAndOnlyOnce() {
        var hold = DictationHold()
        let id = UUID()
        XCTAssertFalse(hold.end(id), "A release must not finish a menu or Option-D run that owns no Fn hold")
        hold.begin(id)
        XCTAssertEqual(hold.id, id)
        XCTAssertTrue(hold.end(id))
        XCTAssertNil(hold.id)
        XCTAssertFalse(hold.end(id))
    }

    func testStaleHoldReleaseCannotEndTheNextRun() {
        var hold = DictationHold()
        let first = UUID(), second = UUID()
        hold.begin(first)
        hold.begin(second)
        XCTAssertFalse(hold.end(first))
        XCTAssertEqual(hold.id, second)
        XCTAssertTrue(hold.end(second))
        XCTAssertNil(hold.id)
    }

    func testClearingHoldRejectsLateReleaseWithoutAffectingANewHold() {
        var hold = DictationHold()
        let first = UUID(), second = UUID()
        hold.begin(first)
        hold.clear()
        XCTAssertNil(hold.id)
        XCTAssertFalse(hold.end(first))
        hold.begin(second)
        XCTAssertFalse(hold.end(first))
        XCTAssertEqual(hold.id, second)
        hold.clear()
        XCTAssertFalse(hold.end(second))
        XCTAssertNil(hold.id)
    }

    private var fnKey: Int64 { Int64(kVK_Function) }
    private var systemDefined: CGEventType { CGEventType(rawValue: 14)! }
    private var modifiers: [(Int64, CGEventFlags)] {
        [(Int64(kVK_Command), .maskCommand), (Int64(kVK_Control), .maskControl),
         (Int64(kVK_Option), .maskAlternate), (Int64(kVK_Shift), .maskShift)]
    }

    private func enabledInput() -> FnPushToTalk {
        var input = FnPushToTalk()
        XCTAssertNil(input.setEnabled(true))
        return input
    }

    private func pressFn(_ input: inout FnPushToTalk, flags: CGEventFlags = .maskSecondaryFn,
                         file: StaticString = #filePath, line: UInt = #line) throws -> UUID {
        let result = input.route(.flagsChanged, keyCode: fnKey, flags: flags)
        let id = try XCTUnwrap(input.hold, file: file, line: line)
        assertResult(result, consume: true, action: .pressed(id), file: file, line: line)
        return id
    }

    private func assertResult(_ result: FnPushToTalk.Result, consume: Bool = false,
                              action: FnPushToTalk.Action? = nil,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.consume, consume, file: file, line: line)
        XCTAssertEqual(result.action, action, file: file, line: line)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "com.lenotch.tests.dictation-input.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
