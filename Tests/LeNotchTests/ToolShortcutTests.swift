import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Lenotch

@MainActor
final class ToolShortcutTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        ToolShortcutRecordingGate.setRecording(false)
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let suite = "lenotch.test.toolshortcuts.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func binding(_ code: Int, _ modifiers: Int = optionKey) -> ToolKeyBinding {
        ToolKeyBinding(keyCode: code, modifiers: modifiers)
    }

    private func event(_ code: Int, flags: NSEvent.ModifierFlags = .option,
                       type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                      keyCode: UInt16(code)))
    }

    // MARK: Bindings and validation

    func testDefaultsUseOptionTOptionNAndOptionCWithoutWritingPreferences() throws {
        let store = try defaults()
        let settings = ToolShortcutSettings(defaults: store)
        XCTAssertEqual(ToolShortcutTarget.allCases, [.todo, .notes, .clipboard])
        XCTAssertEqual(ToolShortcutTarget.allCases.map(\.title), ["To-do", "Notes", "Clipboard"])
        XCTAssertEqual(ToolShortcutTarget.allCases.map(\.page), [.todo, .notes, .clipboard])
        XCTAssertEqual(ToolShortcutTarget.allCases.map(\.icon), [.todo, .notes, .clipboard])
        XCTAssertEqual(ToolShortcutTarget.allCases.compactMap { settings.binding(for: $0)?.display }, ["⌥T", "⌥N", "⌥C"])
        XCTAssertNil(store.object(forKey: ToolShortcutSettings.storageKey))
        XCTAssertTrue(settings.failures.isEmpty)
        XCTAssertFalse(settings.isRecording)
    }

    func testDisplayUsesMacModifierOrderAndPhysicalANSIKeyNames() {
        XCTAssertEqual(binding(kVK_ANSI_T, cmdKey | shiftKey | optionKey | controlKey).display, "⌃⌥⇧⌘T")
        XCTAssertEqual(binding(kVK_ANSI_4).display, "⌥4")
        XCTAssertEqual(binding(kVK_ANSI_LeftBracket).display, "⌥[")
        XCTAssertEqual(binding(kVK_ANSI_Grave).display, "⌥`")
        XCTAssertEqual(binding(kVK_Space, cmdKey | shiftKey).display, "⇧⌘Space")
        XCTAssertEqual(binding(kVK_LeftArrow).display, "⌥←")
        XCTAssertEqual(binding(kVK_F12).display, "⌥F12")
        XCTAssertEqual(binding(kVK_Return).display, "⌥↩")
        XCTAssertEqual(binding(kVK_ANSI_Keypad1).display, "⌥Keypad 1")
        XCTAssertEqual(binding(255).display, "⌥Key 255")
    }

    func testValidKeysIncludeLettersNumbersPunctuationSpaceArrowsAndFunctionKeys() {
        for key in [kVK_ANSI_B, kVK_ANSI_Z, kVK_ANSI_0, kVK_ANSI_9, kVK_ANSI_Minus, kVK_ANSI_Slash,
                    kVK_Space, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                    kVK_F1, kVK_F20, kVK_ANSI_Keypad0, kVK_Return, kVK_Tab] {
            // Shift avoids the reserved plain Option-Space Chat shortcut.
            XCTAssertNil(binding(key, optionKey | shiftKey).validationError, "Key \(key)")
        }
        XCTAssertNil(binding(kVK_ANSI_T, cmdKey).validationError)
        XCTAssertNil(binding(kVK_ANSI_T, controlKey).validationError)
    }

    func testPlainShiftOnlyModifierKeysUnknownKeysAndUnsupportedFlagsAreRejected() {
        for modifiers in [0, shiftKey] { XCTAssertNotNil(binding(kVK_ANSI_T, modifiers).validationError) }
        for key in [kVK_Command, kVK_Option, kVK_Control, kVK_Shift, kVK_Function, kVK_CapsLock, 255, -1] {
            XCTAssertNotNil(binding(key).validationError)
        }
        XCTAssertNotNil(binding(kVK_ANSI_T, optionKey | (1 << 23)).validationError)
    }

    func testFixedAppShortcutsAreReservedEvenIfTheirFeatureIsCurrentlyHidden() {
        for shortcut in [binding(kVK_Space), binding(kVK_ANSI_D), binding(kVK_ANSI_A),
                         binding(kVK_ANSI_A, controlKey | optionKey | cmdKey)] {
            XCTAssertNotNil(shortcut.validationError, shortcut.display)
        }
        XCTAssertTrue(binding(kVK_ANSI_A).validationError?.contains("Launcher") == true)
        XCTAssertTrue(binding(kVK_Space).validationError?.contains("Chat") == true)
        XCTAssertTrue(binding(kVK_ANSI_D).validationError?.contains("Dictation") == true)
    }

    func testCommonMacCommandsScreenshotsForceQuitAndDesktopNavigationAreReserved() {
        for key in [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M, kVK_Tab, kVK_Space] {
            XCTAssertNotNil(binding(key, cmdKey).validationError)
            XCTAssertNotNil(binding(key, cmdKey | shiftKey).validationError)
        }
        for key in [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow] {
            XCTAssertNotNil(binding(key, controlKey).validationError)
            XCTAssertNotNil(binding(key, controlKey | shiftKey).validationError)
        }
        for key in [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5] {
            XCTAssertNotNil(binding(key, cmdKey | shiftKey).validationError)
            XCTAssertNotNil(binding(key, cmdKey | shiftKey | controlKey).validationError)
        }
        XCTAssertNotNil(binding(kVK_Escape, cmdKey | optionKey).validationError)
        XCTAssertNil(binding(kVK_ANSI_3, optionKey).validationError)
    }

    func testNSEventConvertsToCarbonWithoutOptionProducedCharactersOrCapsLock() throws {
        let typed = try event(kVK_ANSI_T, flags: [.option, .command, .shift, .control, .capsLock, .numericPad])
        XCTAssertEqual(ToolKeyBinding.from(event: typed), binding(kVK_ANSI_T, optionKey | cmdKey | shiftKey | controlKey))
        XCTAssertEqual(ToolKeyBinding.from(event: try event(kVK_ANSI_C)), ToolShortcutTarget.clipboard.defaultBinding)
        XCTAssertEqual(ToolKeyBinding.from(event: try event(kVK_ANSI_T, flags: [])), binding(kVK_ANSI_T, 0),
                       "The recorder can show the specific missing-modifier validation message")
    }

    func testFunctionFlagIsAllowedOnArrowAndFKeysButNotFnLetterCombinations() throws {
        XCTAssertEqual(ToolKeyBinding.from(event: try event(kVK_F5, flags: [.option, .function])), binding(kVK_F5))
        XCTAssertEqual(ToolKeyBinding.from(event: try event(kVK_LeftArrow, flags: [.option, .function, .numericPad])),
                       binding(kVK_LeftArrow))
        XCTAssertNil(ToolKeyBinding.from(event: try event(kVK_ANSI_T, flags: [.option, .function])))
        XCTAssertNil(ToolKeyBinding.from(event: try event(kVK_Function, flags: .function)))
        XCTAssertNil(ToolKeyBinding.from(event: try event(kVK_Option, flags: .option, type: .flagsChanged)))
        XCTAssertNil(ToolKeyBinding.from(event: try event(kVK_ANSI_T, type: .keyUp)))
        XCTAssertNil(ToolKeyBinding.from(event: try event(255)))
    }

    func testBindingsAreCodableAndHashable() throws {
        let original = binding(kVK_ANSI_N, cmdKey | shiftKey)
        let restored = try JSONDecoder().decode(ToolKeyBinding.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(Set([original, restored]).count, 1)
    }

    // MARK: Saved choices

    func testChangedAndDisabledShortcutsSurviveRestartAndResetRestoresDefaults() throws {
        let store = try defaults()
        let settings = ToolShortcutSettings(defaults: store)
        let replacement = binding(kVK_ANSI_B, controlKey | optionKey)
        XCTAssertTrue(settings.setBinding(replacement, for: .todo))
        XCTAssertTrue(settings.setBinding(nil, for: .notes))
        let again = ToolShortcutSettings(defaults: store)
        XCTAssertEqual(again.binding(for: .todo), replacement)
        XCTAssertNil(again.binding(for: .notes))
        XCTAssertEqual(again.binding(for: .clipboard), ToolShortcutTarget.clipboard.defaultBinding)
        XCTAssertTrue(again.reset(.todo))
        XCTAssertTrue(again.reset(.notes))
        XCTAssertNil(store.object(forKey: ToolShortcutSettings.storageKey), "Defaults aren't redundantly stored")
        XCTAssertEqual(ToolShortcutSettings(defaults: store).binding(for: .notes), ToolShortcutTarget.notes.defaultBinding)
    }

    func testDuplicateAndReservedBindingsLeaveThePreviousMappingAndDataIntact() throws {
        let store = try defaults()
        let settings = ToolShortcutSettings(defaults: store)
        let replacement = binding(kVK_ANSI_B, controlKey | optionKey)
        XCTAssertTrue(settings.setBinding(replacement, for: .todo))
        let before = store.data(forKey: ToolShortcutSettings.storageKey)
        XCTAssertTrue(settings.validationError(for: ToolShortcutTarget.notes.defaultBinding, target: .todo)?.contains("Notes") == true)
        for rejected in [ToolShortcutTarget.notes.defaultBinding, binding(kVK_ANSI_A), binding(kVK_ANSI_T, 0)] {
            XCTAssertFalse(settings.setBinding(rejected, for: .todo))
            XCTAssertEqual(settings.binding(for: .todo), replacement)
            XCTAssertEqual(store.data(forKey: ToolShortcutSettings.storageKey), before)
        }
        XCTAssertNil(settings.validationError(for: replacement, target: .todo), "Keeping your own shortcut isn't a duplicate")
    }

    func testDisabledBindingIsReleasedForAnotherToolAndResetRespectsItsNewOwner() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        XCTAssertTrue(settings.setBinding(nil, for: .todo))
        XCTAssertTrue(settings.setBinding(ToolShortcutTarget.todo.defaultBinding, for: .notes))
        XCTAssertFalse(settings.reset(.todo), "Reset can't steal another tool's shortcut")
        XCTAssertNil(settings.binding(for: .todo))
        XCTAssertTrue(settings.reset(.notes))
        XCTAssertTrue(settings.reset(.todo))
    }

    func testMenuVisibilityDoesNotChangeBindingsAndBindingsDoNotChangeMenuChoices() throws {
        let store = try defaults()
        let menu = ToolMenuModel(defaults: store)
        let settings = ToolShortcutSettings(defaults: store)
        XCTAssertTrue(menu.setEnabled(.notes, false))
        XCTAssertEqual(settings.binding(for: .notes), ToolShortcutTarget.notes.defaultBinding)
        let menuData = store.dictionary(forKey: ToolMenuModel.storageKey) as? [String: Bool]
        XCTAssertTrue(settings.setBinding(nil, for: .clipboard))
        XCTAssertTrue(menu.isEnabled(.clipboard))
        XCTAssertEqual(store.dictionary(forKey: ToolMenuModel.storageKey) as? [String: Bool], menuData)
    }

    func testMalformedOrReservedStoredChoicesFallBackWithoutOverwritingStoredData() throws {
        let store = try defaults()
        for data in [Data("not json".utf8),
                     Data(#"{"todo":{"binding":{"keyCode":49,"modifiers":2048}}}"#.utf8),
                     Data(#"{"todo":{"binding":{"keyCode":255,"modifiers":2048}}}"#.utf8)] {
            store.set(data, forKey: ToolShortcutSettings.storageKey)
            XCTAssertEqual(ToolShortcutSettings(defaults: store).binding(for: .todo), ToolShortcutTarget.todo.defaultBinding)
            XCTAssertEqual(store.data(forKey: ToolShortcutSettings.storageKey), data)
        }
    }

    func testStoredOverridesCannotDuplicateAnUntouchedDefault() throws {
        let store = try defaults()
        let entry = ["binding": ["keyCode": kVK_ANSI_N, "modifiers": optionKey]]
        let data = try JSONSerialization.data(withJSONObject: ["todo": entry])
        store.set(data, forKey: ToolShortcutSettings.storageKey)
        let settings = ToolShortcutSettings(defaults: store)
        XCTAssertEqual(settings.binding(for: .todo), ToolShortcutTarget.todo.defaultBinding)
        XCTAssertEqual(settings.binding(for: .notes), ToolShortcutTarget.notes.defaultBinding)
        XCTAssertEqual(store.data(forKey: ToolShortcutSettings.storageKey), data)
    }

    func testValidSwappedBindingsAndExplicitDisabledChoicesAreRestored() throws {
        let store = try defaults()
        let data = try JSONSerialization.data(withJSONObject: [
            "todo": ["binding": ["keyCode": kVK_ANSI_N, "modifiers": optionKey]],
            "notes": ["binding": ["keyCode": kVK_ANSI_T, "modifiers": optionKey]],
            "clipboard": [:],
        ])
        store.set(data, forKey: ToolShortcutSettings.storageKey)
        let settings = ToolShortcutSettings(defaults: store)
        XCTAssertEqual(settings.binding(for: .todo), ToolShortcutTarget.notes.defaultBinding)
        XCTAssertEqual(settings.binding(for: .notes), ToolShortcutTarget.todo.defaultBinding)
        XCTAssertNil(settings.binding(for: .clipboard))
    }

    func testOnlyActualBindingChangesPostSynchronousNotifications() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let probe = NotificationProbe()
        let token = NotificationCenter.default.addObserver(forName: .toolShortcutsChanged, object: nil, queue: .main) { note in
            let source = note.object as? ToolShortcutSettings
            MainActor.assumeIsolated {
                guard source === settings else { return }
                probe.bindingDisplays.append(settings.binding(for: .todo)?.display)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertTrue(settings.setBinding(ToolShortcutTarget.todo.defaultBinding, for: .todo))
        XCTAssertFalse(settings.setBinding(ToolShortcutTarget.notes.defaultBinding, for: .todo))
        XCTAssertTrue(probe.bindingDisplays.isEmpty)
        XCTAssertTrue(settings.setBinding(nil, for: .todo))
        XCTAssertEqual(probe.bindingDisplays.count, 1)
        XCTAssertNil(probe.bindingDisplays[0])
        XCTAssertTrue(settings.setBinding(nil, for: .todo))
        XCTAssertEqual(probe.bindingDisplays.count, 1)
        XCTAssertTrue(settings.reset(.todo))
        XCTAssertEqual(probe.bindingDisplays, [nil, "⌥T"])
    }

    func testRecordingNotificationsSeeTheUpdatedSettingsAndThreadSafeGateSynchronously() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let probe = NotificationProbe()
        let token = NotificationCenter.default.addObserver(forName: .toolShortcutRecordingChanged, object: nil, queue: .main) { note in
            let source = note.object as? ToolShortcutSettings
            MainActor.assumeIsolated {
                guard source === settings else { return }
                probe.recordingStates.append(settings.isRecording)
                probe.gateStates.append(ToolShortcutRecordingGate.isRecording)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        settings.beginRecording()
        XCTAssertEqual(probe.recordingStates, [true])
        XCTAssertEqual(probe.gateStates, [true])
        settings.beginRecording()
        settings.endRecording()
        settings.endRecording()
        XCTAssertEqual(probe.recordingStates, [true, false])
        XCTAssertEqual(probe.gateStates, [true, false])
        XCTAssertFalse(settings.isRecording)
    }

    // MARK: Mock registrations: these tests never install global hotkeys

    func testControllerRegistersExactlyThreeDefaultsAndRoutesEachTarget() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        var opened: [ToolShortcutTarget] = []
        controller.start { opened.append($0) }
        XCTAssertEqual(registrar.handles.map(\.binding), ToolShortcutTarget.allCases.map(\.defaultBinding))
        registrar.handles.forEach { $0.fire() }
        XCTAssertEqual(opened, [.todo, .notes, .clipboard])
        controller.stop()
        XCTAssertTrue(registrar.handles.allSatisfy { $0.unregisterCount == 1 })
    }

    func testRefreshUnregistersOldHandlesAndStaleCallbacksCannotOpenTools() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        var opened: [ToolShortcutTarget] = []
        controller.start { opened.append($0) }
        let old = registrar.handles
        XCTAssertTrue(settings.setBinding(binding(kVK_ANSI_B), for: .todo))
        old[0].fire()
        XCTAssertTrue(opened.isEmpty, "Even before refresh, a callback must match the current binding")
        controller.refresh()
        XCTAssertTrue(old.allSatisfy { $0.unregisterCount == 1 })
        old.forEach { $0.fire() }
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(registrar.handles[3].binding, binding(kVK_ANSI_B))
        registrar.handles[3].fire()
        XCTAssertEqual(opened, [.todo])
        controller.stop()
    }

    func testDisabledTargetsAreNotRegisteredAndTheirPriorCallbacksAreIgnored() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        var opened: [ToolShortcutTarget] = []
        controller.start { opened.append($0) }
        let old = registrar.handles
        XCTAssertTrue(settings.setBinding(nil, for: .notes))
        old[1].fire()
        controller.refresh()
        XCTAssertEqual(registrar.handles.count, 5)
        XCTAssertEqual(Array(registrar.handles.suffix(2)).map(\.binding),
                       [ToolShortcutTarget.todo.defaultBinding, ToolShortcutTarget.clipboard.defaultBinding])
        XCTAssertTrue(opened.isEmpty)
        controller.stop()
    }

    func testRecordingImmediatelyBlocksCallbacksAndRefreshReleasesUntilRecordingEnds() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        var opened: [ToolShortcutTarget] = []
        controller.start { opened.append($0) }
        let old = registrar.handles
        settings.beginRecording()
        old.forEach { $0.fire() }
        XCTAssertTrue(opened.isEmpty)
        controller.refresh()
        XCTAssertEqual(registrar.handles.count, 3, "No registration is attempted while recording")
        XCTAssertTrue(old.allSatisfy { $0.unregisterCount == 1 })
        settings.endRecording()
        controller.refresh()
        old.forEach { $0.fire() }
        XCTAssertTrue(opened.isEmpty)
        registrar.handles.last?.fire()
        XCTAssertEqual(opened, [.clipboard])
        controller.stop()
    }

    func testStartingDuringRecordingWaitsForExplicitRefresh() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        settings.beginRecording()
        controller.start { _ in XCTFail("Nothing is registered yet") }
        XCTAssertTrue(registrar.handles.isEmpty)
        settings.endRecording()
        XCTAssertTrue(registrar.handles.isEmpty, "AppDelegate, not this owner, observes recording changes")
        controller.refresh()
        XCTAssertEqual(registrar.handles.count, 3)
        controller.stop()
    }

    func testStopIsIdempotentRefreshAfterStopDoesNotRegisterAndOldCallbacksAreIgnored() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        var opened: [ToolShortcutTarget] = []
        controller.start { opened.append($0) }
        let old = registrar.handles
        controller.stop()
        controller.stop()
        controller.refresh()
        old.forEach { $0.fire() }
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(registrar.handles.count, 3)
        XCTAssertTrue(old.allSatisfy { $0.unregisterCount == 1 })
    }

    func testRestartUsesNewActionAndRejectsCallbacksFromAnEarlierStart() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        var first: [ToolShortcutTarget] = []
        var second: [ToolShortcutTarget] = []
        controller.start { first.append($0) }
        let old = registrar.handles
        controller.start { second.append($0) }
        old.forEach { $0.fire() }
        registrar.handles.last?.fire()
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second, [.clipboard])
        XCTAssertTrue(old.allSatisfy { $0.unregisterCount == 1 })
        controller.stop()
    }

    func testRegistrationFailuresAreReportedWithoutDroppingSavedMappingAndCanRecover() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        registrar.failures = [ToolShortcutTarget.notes.defaultBinding]
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        controller.start { _ in }
        XCTAssertEqual(Set(settings.failures.keys), [.notes])
        XCTAssertTrue(settings.failures[.notes]?.contains("⌥N") == true)
        XCTAssertEqual(settings.binding(for: .notes), ToolShortcutTarget.notes.defaultBinding)
        XCTAssertEqual(registrar.handles.count, 2)
        registrar.failures = []
        controller.refresh()
        XCTAssertTrue(settings.failures.isEmpty)
        XCTAssertEqual(registrar.handles.count, 5)
        controller.stop()
    }

    func testEditingOrDisablingAFailedShortcutClearsItsStaleError() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        settings.setRegistrationFailures([.todo: "Taken", .notes: "Also taken"])
        XCTAssertTrue(settings.setBinding(nil, for: .todo))
        XCTAssertNil(settings.failures[.todo])
        XCTAssertEqual(settings.failures[.notes], "Also taken")
        XCTAssertTrue(settings.setBinding(binding(kVK_ANSI_B), for: .notes))
        XCTAssertTrue(settings.failures.isEmpty)
    }

    func testRecordingAndStopClearPreviouslyReportedRegistrationFailures() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        registrar.failures = [ToolShortcutTarget.todo.defaultBinding]
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        controller.start { _ in }
        XCTAssertFalse(settings.failures.isEmpty)
        settings.beginRecording()
        controller.refresh()
        XCTAssertTrue(settings.failures.isEmpty)
        settings.endRecording()
        controller.refresh()
        XCTAssertFalse(settings.failures.isEmpty)
        controller.stop()
        XCTAssertTrue(settings.failures.isEmpty)
    }

    func testSynchronousRegistrationCallbackCannotFireBeforeItsHandleExists() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        registrar.fireDuringRegistration = true
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        var opened: [ToolShortcutTarget] = []
        controller.start { opened.append($0) }
        XCTAssertTrue(opened.isEmpty)
        registrar.handles.first?.fire()
        XCTAssertEqual(opened, [.todo])
        controller.stop()
    }

    func testStopDuringRegistrationReleasesTheNewHandleAndDoesNotRegisterFurtherKeys() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        registrar.onRegister = { controller.stop() }
        controller.start { _ in XCTFail("Stopped") }
        XCTAssertEqual(registrar.handles.count, 1)
        XCTAssertEqual(registrar.handles.first?.unregisterCount, 1)
        registrar.handles.first?.fire()
    }
}

@MainActor
private final class NotificationProbe {
    var bindingDisplays: [String?] = []
    var recordingStates: [Bool] = []
    var gateStates: [Bool] = []
}

@MainActor
private final class MockRegistration: ToolShortcutRegistration {
    let binding: ToolKeyBinding
    private let callback: () -> Void
    private(set) var unregisterCount = 0

    init(binding: ToolKeyBinding, callback: @escaping () -> Void) {
        self.binding = binding
        self.callback = callback
    }

    func unregister() { unregisterCount += 1 }
    /// Deliberately invokes even after unregister, like an already queued Carbon callback.
    func fire() { callback() }
}

@MainActor
private final class MockRegistrar {
    var handles: [MockRegistration] = []
    var failures: Set<ToolKeyBinding> = []
    var fireDuringRegistration = false
    var onRegister: (() -> Void)?

    func register(_ binding: ToolKeyBinding, action: @escaping () -> Void) -> (any ToolShortcutRegistration)? {
        if failures.contains(binding) { return nil }
        let handle = MockRegistration(binding: binding, callback: action)
        handles.append(handle)
        if fireDuringRegistration { handle.fire() }
        onRegister?()
        return handle
    }
}
