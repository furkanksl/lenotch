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

    func testAllToolsFollowMenuOrderAndExactlySixHaveDefaults() throws {
        let store = try defaults()
        let settings = ToolShortcutSettings(defaults: store)
        XCTAssertEqual(ToolShortcutTarget.allCases,
                       [.chat, .dictation, .prompter, .today, .launcher, .clipboard, .shelf,
                        .shortcuts, .usage, .system, .todo, .notes, .notifications])
        XCTAssertEqual(ToolShortcutTarget.allCases.map(\.tool), TrayTool.allCases)
        XCTAssertEqual(ToolShortcutTarget.allCases.map(\.title), TrayTool.allCases.map(\.title))
        XCTAssertEqual(ToolShortcutTarget.allCases.map(\.page), TrayTool.allCases.map(\.page))
        XCTAssertEqual(ToolShortcutTarget.allCases.map(\.icon), TrayTool.allCases.map(\.icon))
        XCTAssertEqual(ToolShortcutTarget.allCases.compactMap { settings.binding(for: $0)?.display },
                       ["⌥Space", "⌥D", "⌥A", "⌥C", "⌥T", "⌥N"])
        for target in ToolShortcutTarget.allCases {
            XCTAssertEqual(settings.binding(for: target), target.defaultBinding)
        }
        XCTAssertNil(ToolShortcutTarget.chat.page)
        XCTAssertNil(ToolShortcutTarget.dictation.page)
        XCTAssertNil(ToolShortcutTarget.launcher.page)
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

    func testReassignableDefaultsAreValidButBackupChatShortcutRemainsReserved() {
        for shortcut in [binding(kVK_Space), binding(kVK_ANSI_D), binding(kVK_ANSI_A)] {
            XCTAssertNil(shortcut.validationError, shortcut.display)
        }
        XCTAssertTrue(binding(kVK_ANSI_A, controlKey | optionKey | cmdKey).validationError?.contains("Chat") == true)
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
        XCTAssertTrue(settings.validationError(for: binding(kVK_ANSI_N), target: .todo)?.contains("Notes") == true)
        for rejected in [binding(kVK_ANSI_N), binding(kVK_ANSI_A), binding(kVK_ANSI_T, 0)] {
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
                     Data(#"{"todo":{"binding":{"keyCode":0,"modifiers":6400}}}"#.utf8),
                     Data(#"{"todo":{"binding":{"keyCode":255,"modifiers":2048}}}"#.utf8)] {
            store.set(data, forKey: ToolShortcutSettings.storageKey)
            XCTAssertEqual(ToolShortcutSettings(defaults: store).binding(for: .todo), ToolShortcutTarget.todo.defaultBinding)
            XCTAssertEqual(store.data(forKey: ToolShortcutSettings.storageKey), data)
        }
    }

    func testConflictingStoredOverridesArePreservedAndReportedWithoutRegisteringEitherOwner() throws {
        let store = try defaults()
        let entry = ["binding": ["keyCode": kVK_ANSI_N, "modifiers": optionKey]]
        let data = try JSONSerialization.data(withJSONObject: ["todo": entry])
        store.set(data, forKey: ToolShortcutSettings.storageKey)
        let settings = ToolShortcutSettings(defaults: store)
        XCTAssertEqual(settings.binding(for: .todo), ToolShortcutTarget.notes.defaultBinding)
        XCTAssertEqual(settings.binding(for: .notes), ToolShortcutTarget.notes.defaultBinding)
        let registrar = MockRegistrar()
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        controller.start { _ in XCTFail("Conflicting shortcuts must not fire") }
        XCTAssertEqual(Set(settings.failures.keys), [.todo, .notes])
        XCTAssertTrue(settings.failures[.todo]?.contains("Notes") == true)
        XCTAssertTrue(settings.failures[.notes]?.contains("To-do") == true)
        XCTAssertEqual(registrar.handles.count, 4)
        XCTAssertFalse(registrar.handles.contains { $0.binding == binding(kVK_ANSI_N) })
        XCTAssertEqual(store.data(forKey: ToolShortcutSettings.storageKey), data)
        XCTAssertTrue(settings.reset(.todo))
        controller.refresh()
        XCTAssertTrue(settings.failures.isEmpty)
        controller.stop()
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

    func testLegacyFalseTogglesMigrateToDisabledWithoutChangingOtherDefaultsOrDeletingOldKeys() throws {
        let store = try defaults()
        store.set(false, forKey: "lenotch.launcher.shortcut")
        store.set(false, forKey: DictationInputSettings.toggleShortcutKey)
        let settings = ToolShortcutSettings(defaults: store)
        XCTAssertNil(settings.binding(for: .launcher))
        XCTAssertNil(settings.binding(for: .dictation))
        XCTAssertEqual(settings.binding(for: .chat), ToolShortcutTarget.chat.defaultBinding)
        XCTAssertEqual(settings.binding(for: .todo), ToolShortcutTarget.todo.defaultBinding)
        XCTAssertEqual(settings.binding(for: .notes), ToolShortcutTarget.notes.defaultBinding)
        XCTAssertEqual(settings.binding(for: .clipboard), ToolShortcutTarget.clipboard.defaultBinding)
        XCTAssertEqual(store.object(forKey: "lenotch.launcher.shortcut") as? Bool, false)
        XCTAssertEqual(store.object(forKey: DictationInputSettings.toggleShortcutKey) as? Bool, false)
        XCTAssertTrue(store.bool(forKey: ToolShortcutSettings.legacyMigrationKey))
        XCTAssertNotNil(store.data(forKey: ToolShortcutSettings.storageKey))
        let restored = ToolShortcutSettings(defaults: store)
        XCTAssertNil(restored.binding(for: .launcher))
        XCTAssertNil(restored.binding(for: .dictation))
    }

    func testLegacyTrueAndAbsentTogglesKeepAllSixDefaultsWithoutCreatingChoices() throws {
        for legacyValue in [nil, true] as [Bool?] {
            let store = try defaults()
            if let legacyValue {
                store.set(legacyValue, forKey: "lenotch.launcher.shortcut")
                store.set(legacyValue, forKey: DictationInputSettings.toggleShortcutKey)
            }
            let settings = ToolShortcutSettings(defaults: store)
            for target in ToolShortcutTarget.allCases {
                XCTAssertEqual(settings.binding(for: target), target.defaultBinding)
            }
            XCTAssertNil(store.data(forKey: ToolShortcutSettings.storageKey))
            XCTAssertTrue(store.bool(forKey: ToolShortcutSettings.legacyMigrationKey))
        }
    }

    func testLegacyMigrationPreservesEveryExistingExplicitChoice() throws {
        let store = try defaults()
        store.set(false, forKey: "lenotch.launcher.shortcut")
        store.set(false, forKey: DictationInputSettings.toggleShortcutKey)
        let replacement = binding(kVK_ANSI_B, controlKey | optionKey)
        let entry = ["binding": ["keyCode": replacement.keyCode, "modifiers": replacement.modifiers]]
        let data = try JSONSerialization.data(withJSONObject: [
            "launcher": entry,
            "dictation": entry,
            "todo": entry,
            "notes": [:],
            "clipboard": ["binding": ["keyCode": kVK_ANSI_E, "modifiers": optionKey]],
        ])
        store.set(data, forKey: ToolShortcutSettings.storageKey)
        let settings = ToolShortcutSettings(defaults: store)
        for target in [ToolShortcutTarget.launcher, .dictation, .todo] {
            XCTAssertEqual(settings.binding(for: target), replacement)
        }
        XCTAssertNil(settings.binding(for: .notes))
        XCTAssertEqual(settings.binding(for: .clipboard), binding(kVK_ANSI_E))
        XCTAssertEqual(store.data(forKey: ToolShortcutSettings.storageKey), data,
                       "Existing choices, including collisions, must not be silently rewritten during migration")
    }

    func testLegacyMigrationPreservesExplicitDisabledLauncherAndDictationWhenOldTogglesAreTrue() throws {
        let store = try defaults()
        store.set(true, forKey: "lenotch.launcher.shortcut")
        store.set(true, forKey: DictationInputSettings.toggleShortcutKey)
        store.set(Data(#"{"launcher":{},"dictation":{}}"#.utf8), forKey: ToolShortcutSettings.storageKey)
        let settings = ToolShortcutSettings(defaults: store)
        XCTAssertNil(settings.binding(for: .launcher))
        XCTAssertNil(settings.binding(for: .dictation))
    }

    func testResetAfterLegacyMigrationDoesNotReadStaleFalseTogglesAgain() throws {
        let store = try defaults()
        store.set(false, forKey: "lenotch.launcher.shortcut")
        store.set(false, forKey: DictationInputSettings.toggleShortcutKey)
        let settings = ToolShortcutSettings(defaults: store)
        XCTAssertTrue(settings.reset(.launcher))
        XCTAssertTrue(settings.reset(.dictation))
        XCTAssertNil(store.data(forKey: ToolShortcutSettings.storageKey))
        let restored = ToolShortcutSettings(defaults: store)
        XCTAssertEqual(restored.binding(for: .launcher), ToolShortcutTarget.launcher.defaultBinding)
        XCTAssertEqual(restored.binding(for: .dictation), ToolShortcutTarget.dictation.defaultBinding)
        XCTAssertEqual(store.object(forKey: "lenotch.launcher.shortcut") as? Bool, false)
        XCTAssertEqual(store.object(forKey: DictationInputSettings.toggleShortcutKey) as? Bool, false)
    }

    func testAbsentLegacyPreferencesAreOnlyReadOnTheFirstMigration() throws {
        let store = try defaults()
        _ = ToolShortcutSettings(defaults: store)
        store.set(false, forKey: "lenotch.launcher.shortcut")
        store.set(false, forKey: DictationInputSettings.toggleShortcutKey)
        let restored = ToolShortcutSettings(defaults: store)
        XCTAssertEqual(restored.binding(for: .launcher), ToolShortcutTarget.launcher.defaultBinding)
        XCTAssertEqual(restored.binding(for: .dictation), ToolShortcutTarget.dictation.defaultBinding)
    }

    func testEveryToolCanBeReassignedPersistedAndResetWithoutInventingNewDefaults() throws {
        let store = try defaults()
        let settings = ToolShortcutSettings(defaults: store)
        let keyCodes = [kVK_ANSI_B, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_I, kVK_ANSI_J,
                        kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_U]
        let replacements = keyCodes.map { binding($0, controlKey | optionKey) }
        for (target, replacement) in zip(ToolShortcutTarget.allCases, replacements) {
            XCTAssertTrue(settings.setBinding(replacement, for: target), target.title)
        }
        let restored = ToolShortcutSettings(defaults: store)
        for (target, replacement) in zip(ToolShortcutTarget.allCases, replacements) {
            XCTAssertEqual(restored.binding(for: target), replacement, target.title)
            XCTAssertTrue(restored.reset(target), target.title)
            XCTAssertEqual(restored.binding(for: target), target.defaultBinding, target.title)
        }
        XCTAssertNil(store.data(forKey: ToolShortcutSettings.storageKey))
    }

    func testFormerlyFixedDefaultsCanBeReleasedAndAssignedToAnyTool() throws {
        for original in [ToolShortcutTarget.chat, .dictation, .launcher] {
            let settings = ToolShortcutSettings(defaults: try defaults())
            let shortcut = try XCTUnwrap(original.defaultBinding)
            XCTAssertTrue(settings.validationError(for: shortcut, target: .notifications)?.contains(original.title) == true)
            XCTAssertFalse(settings.setBinding(shortcut, for: .notifications))
            XCTAssertTrue(settings.setBinding(nil, for: original))
            XCTAssertNil(settings.validationError(for: shortcut, target: .notifications))
            XCTAssertTrue(settings.setBinding(shortcut, for: .notifications))
            XCTAssertFalse(settings.reset(original))
            XCTAssertTrue(settings.reset(.notifications))
            XCTAssertTrue(settings.reset(original))
        }
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

    func testControllerRegistersExactlySixDefaultsAndRoutesEachTarget() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        var opened: [ToolShortcutTarget] = []
        controller.start { opened.append($0) }
        XCTAssertEqual(registrar.handles.map(\.binding), ToolShortcutTarget.allCases.compactMap(\.defaultBinding))
        registrar.handles.forEach { $0.fire() }
        XCTAssertEqual(opened, [.chat, .dictation, .launcher, .clipboard, .todo, .notes])
        controller.stop()
        XCTAssertTrue(registrar.handles.allSatisfy { $0.unregisterCount == 1 })
    }

    func testUnassignedTargetsNeverRegisterAndDisablingAllDefaultsInstallsNoKeys() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        for target in ToolShortcutTarget.allCases {
            XCTAssertTrue(settings.setBinding(nil, for: target))
        }
        let registrar = MockRegistrar()
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        controller.start { _ in XCTFail("All shortcuts are disabled") }
        XCTAssertTrue(registrar.handles.isEmpty)
        XCTAssertTrue(settings.failures.isEmpty)
        controller.stop()
    }

    func testControllerCanRouteAllThirteenTargetsWithoutGlobalKeyRegistration() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let keyCodes = [kVK_ANSI_B, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_I, kVK_ANSI_J,
                        kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_U]
        for (target, code) in zip(ToolShortcutTarget.allCases, keyCodes) {
            XCTAssertTrue(settings.setBinding(binding(code, controlKey | optionKey), for: target))
        }
        let registrar = MockRegistrar()
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        var opened: [ToolShortcutTarget] = []
        controller.start { opened.append($0) }
        XCTAssertEqual(registrar.handles.count, 13)
        registrar.handles.forEach { $0.fire() }
        XCTAssertEqual(opened, ToolShortcutTarget.allCases)
        controller.stop()
    }

    func testRefreshUnregistersOldHandlesAndStaleCallbacksCannotOpenTools() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        var opened: [ToolShortcutTarget] = []
        controller.start { opened.append($0) }
        let old = registrar.handles
        let oldTodo = try XCTUnwrap(old.first { $0.binding == ToolShortcutTarget.todo.defaultBinding })
        XCTAssertTrue(settings.setBinding(binding(kVK_ANSI_B), for: .todo))
        oldTodo.fire()
        XCTAssertTrue(opened.isEmpty, "Even before refresh, a callback must match the current binding")
        controller.refresh()
        XCTAssertTrue(old.allSatisfy { $0.unregisterCount == 1 })
        old.forEach { $0.fire() }
        XCTAssertTrue(opened.isEmpty)
        let remappedTodo = try XCTUnwrap(registrar.handles.last { $0.binding == binding(kVK_ANSI_B) })
        remappedTodo.fire()
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
        try XCTUnwrap(old.first { $0.binding == ToolShortcutTarget.notes.defaultBinding }).fire()
        controller.refresh()
        XCTAssertEqual(registrar.handles.count, 11)
        XCTAssertEqual(Array(registrar.handles.suffix(5)).map(\.binding),
                       [ToolShortcutTarget.chat, .dictation, .launcher, .clipboard, .todo].compactMap(\.defaultBinding))
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
        XCTAssertEqual(registrar.handles.count, 6, "No registration is attempted while recording")
        XCTAssertTrue(old.allSatisfy { $0.unregisterCount == 1 })
        settings.endRecording()
        controller.refresh()
        old.forEach { $0.fire() }
        XCTAssertTrue(opened.isEmpty)
        registrar.handles.last?.fire()
        XCTAssertEqual(opened, [.notes])
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
        XCTAssertEqual(registrar.handles.count, 6)
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
        XCTAssertEqual(registrar.handles.count, 6)
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
        XCTAssertEqual(second, [.notes])
        XCTAssertTrue(old.allSatisfy { $0.unregisterCount == 1 })
        controller.stop()
    }

    func testRegistrationFailuresAreReportedWithoutDroppingSavedMappingAndCanRecover() throws {
        let settings = ToolShortcutSettings(defaults: try defaults())
        let registrar = MockRegistrar()
        registrar.failures = [try XCTUnwrap(ToolShortcutTarget.notes.defaultBinding)]
        let controller = ToolShortcutController(settings: settings, register: registrar.register)
        controller.start { _ in }
        XCTAssertEqual(Set(settings.failures.keys), [.notes])
        XCTAssertTrue(settings.failures[.notes]?.contains("⌥N") == true)
        XCTAssertEqual(settings.binding(for: .notes), ToolShortcutTarget.notes.defaultBinding)
        XCTAssertEqual(registrar.handles.count, 5)
        registrar.failures = []
        controller.refresh()
        XCTAssertTrue(settings.failures.isEmpty)
        XCTAssertEqual(registrar.handles.count, 11)
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
        registrar.failures = [try XCTUnwrap(ToolShortcutTarget.todo.defaultBinding)]
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
        XCTAssertEqual(opened, [.chat])
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
