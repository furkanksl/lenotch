import Foundation
import XCTest
@testable import Lenotch

private final class OrderTrackingDefaults: UserDefaults, @unchecked Sendable {
    var writtenKeys: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        writtenKeys.append(defaultName)
        super.set(value, forKey: defaultName)
    }
}

@MainActor
final class ToolMenuOrderTests: XCTestCase {
    private var suites: [String] = []
    private let canonical: [TrayTool] = [
        .chat, .dictation, .prompter, .today, .launcher, .clipboard, .shelf,
        .shortcuts, .usage, .system, .todo, .notes, .notifications,
    ]

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults() throws -> OrderTrackingDefaults {
        let suite = "lenotch.test.toolmenuorder.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(OrderTrackingDefaults(suiteName: suite))
    }

    func testFreshModelHasAllThirteenToolsInDefaultOrderWithoutWriting() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)

        XCTAssertEqual(model.orderedTools, canonical)
        XCTAssertEqual(Set(model.orderedTools).count, 13)
        XCTAssertEqual(model.visible, canonical.filter { $0 != .usage && $0 != .notifications })
        XCTAssertEqual(model.visible.count, 11)
        XCTAssertFalse(model.hasCustomOrder)
        XCTAssertTrue(model.choices.isEmpty)
        XCTAssertNil(store.object(forKey: ToolMenuModel.orderStorageKey))
        XCTAssertTrue(store.writtenKeys.isEmpty)
    }

    func testEveryToolMovesAndAllThirteenOrdersSurviveRestart() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)

        for step in 1...canonical.count {
            let first = try XCTUnwrap(model.orderedTools.first)
            let last = try XCTUnwrap(model.orderedTools.last)
            model.move(last, before: first)

            let cut = canonical.count - step
            let expected = Array(canonical[cut...]) + Array(canonical[..<cut])
            XCTAssertEqual(model.orderedTools, expected)
            XCTAssertEqual(store.stringArray(forKey: ToolMenuModel.orderStorageKey), expected.map(\.rawValue))
            let restored = ToolMenuModel(defaults: store)
            XCTAssertEqual(restored.orderedTools, expected)
            XCTAssertEqual(restored.hasCustomOrder, step != canonical.count)
            XCTAssertEqual(Set(restored.orderedTools).count, 13)
            XCTAssertEqual(restored.visible.count, 11)
            XCTAssertFalse(restored.isEnabled(.usage))
            XCTAssertFalse(restored.isEnabled(.notifications))
        }
        XCTAssertEqual(store.writtenKeys, Array(repeating: ToolMenuModel.orderStorageKey, count: 13))
        XCTAssertNil(store.object(forKey: ToolMenuModel.storageKey))
    }

    func testSavedOrderDropsUnknownAndDuplicateLabelsAndAppendsMissingToolsOnce() throws {
        let store = try defaults()
        let saved = ["notes", "unknown-future-tool", "chat", "notes", "notifications", "Clipboard", "", "chat"]
        store.set(saved, forKey: ToolMenuModel.orderStorageKey)
        store.writtenKeys = []

        let model = ToolMenuModel(defaults: store)
        let prefix: [TrayTool] = [.notes, .chat, .notifications]
        XCTAssertEqual(model.orderedTools, prefix + canonical.filter { !prefix.contains($0) })
        XCTAssertEqual(Set(model.orderedTools), Set(canonical))
        XCTAssertEqual(model.orderedTools.count, 13)
        XCTAssertTrue(model.hasCustomOrder)
        XCTAssertEqual(store.stringArray(forKey: ToolMenuModel.orderStorageKey), saved,
                       "Loading must not overwrite a preference a newer version may have saved")
        XCTAssertTrue(store.writtenKeys.isEmpty)
    }

    func testOlderPartialOrderKeepsItsSequenceAndAppendsNewToolsInDefaultOrder() throws {
        let store = try defaults()
        let olderOrder: [TrayTool] = [.launcher, .chat, .dictation, .today]
        store.set(olderOrder.map(\.rawValue), forKey: ToolMenuModel.orderStorageKey)
        store.writtenKeys = []

        let model = ToolMenuModel(defaults: store)
        XCTAssertEqual(model.orderedTools, olderOrder + canonical.filter { !olderOrder.contains($0) })
        XCTAssertEqual(model.orderedTools.filter { $0 == .notes }.count, 1)
        XCTAssertEqual(model.orderedTools.filter { $0 == .todo }.count, 1)
        XCTAssertTrue(store.writtenKeys.isEmpty)
    }

    func testInvalidAndEmptySavedOrdersUseDefaultsWithoutWriting() throws {
        let store = try defaults()
        let invalid: [Any] = ["not an array", 42, ["notes": true], [String](), ["retired-tool", "NOTES"]]

        for value in invalid {
            store.set(value, forKey: ToolMenuModel.orderStorageKey)
            store.writtenKeys = []
            let model = ToolMenuModel(defaults: store)
            XCTAssertEqual(model.orderedTools, canonical)
            XCTAssertFalse(model.hasCustomOrder)
            XCTAssertTrue(store.writtenKeys.isEmpty)
        }
    }

    func testBeforeAndAfterMovesReachBothEndsAndHandleBothDirections() throws {
        let model = ToolMenuModel(defaults: try defaults())

        model.move(.notifications, before: .chat)
        XCTAssertEqual(model.orderedTools, [.notifications] + canonical.filter { $0 != .notifications })

        model.move(.notifications, after: .notes)
        XCTAssertEqual(model.orderedTools, canonical)

        model.move(.chat, after: .notifications)
        XCTAssertEqual(model.orderedTools, Array(canonical.dropFirst()) + [.chat])

        model.move(.chat, before: .dictation)
        XCTAssertEqual(model.orderedTools, canonical)

        model.move(.dictation, after: .today)
        XCTAssertEqual(Array(model.orderedTools.prefix(5)), [.chat, .prompter, .today, .dictation, .launcher])

        model.move(.dictation, before: .prompter)
        XCTAssertEqual(model.orderedTools, canonical)
    }

    func testMoveByOffsetUsesFullOrderIncludingHiddenTools() throws {
        let model = ToolMenuModel(defaults: try defaults())

        model.move(.system, by: -1)
        XCTAssertEqual(Array(model.orderedTools[7...10]), [.shortcuts, .system, .usage, .todo])
        XCTAssertEqual(Array(model.visible[7...9]), [.shortcuts, .system, .todo],
                       "Moving over hidden Usage still changes its saved position")

        model.move(.system, by: 1)
        XCTAssertEqual(model.orderedTools, canonical)

        model.move(.dictation, by: 2)
        XCTAssertEqual(Array(model.orderedTools.prefix(5)), [.chat, .prompter, .today, .dictation, .launcher])
        model.move(.dictation, by: -3)
        XCTAssertEqual(Array(model.orderedTools.prefix(4)), [.dictation, .chat, .prompter, .today])
    }

    func testSelfAdjacentZeroAndOutOfBoundsMovesDoNotWriteOrNotify() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        var changes: [TrayTool] = []
        model.onChange = { changes.append($0) }

        for tool in canonical {
            model.move(tool, before: tool)
            model.move(tool, after: tool)
            model.move(tool, by: 0)
        }
        model.move(.chat, before: .dictation)
        model.move(.notifications, after: .notes)
        model.move(.shelf, after: .clipboard)
        model.move(.chat, by: -1)
        model.move(.notifications, by: 1)
        model.move(.chat, by: -13)
        model.move(.notes, by: 13)
        model.move(.chat, by: Int.min)
        model.move(.notes, by: Int.max)
        model.move(.notes, by: Int.min)
        model.restoreOrder()

        XCTAssertEqual(model.orderedTools, canonical)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertTrue(store.writtenKeys.isEmpty)
        XCTAssertNil(store.object(forKey: ToolMenuModel.orderStorageKey))
    }

    func testEachMoveWritesOnceAndNotifiesMovedToolAfterPersistence() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        var changes: [TrayTool] = []
        model.onChange = { tool in
            changes.append(tool)
            XCTAssertEqual(store.stringArray(forKey: ToolMenuModel.orderStorageKey), model.orderedTools.map(\.rawValue))
            XCTAssertEqual(store.writtenKeys.count, changes.count)
        }

        model.move(.notes, before: .chat)
        model.move(.clipboard, after: .notifications)
        model.move(.today, by: -1)

        XCTAssertEqual(changes, [.notes, .clipboard, .today])
        XCTAssertEqual(store.writtenKeys, Array(repeating: ToolMenuModel.orderStorageKey, count: 3))
    }

    func testHiddenToolKeepsItsPositionWhenEnabledDisabledAndRestarted() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        model.move(.usage, before: .chat)
        let order = model.orderedTools

        XCTAssertEqual(order.first, .usage)
        XCTAssertFalse(model.visible.contains(.usage))
        XCTAssertTrue(model.setEnabled(.usage, true))
        XCTAssertEqual(model.visible.first, .usage)
        XCTAssertEqual(model.orderedTools, order)
        XCTAssertTrue(model.setEnabled(.usage, false))
        XCTAssertEqual(model.orderedTools, order)

        let restarted = ToolMenuModel(defaults: store)
        XCTAssertEqual(restarted.orderedTools, order)
        XCTAssertFalse(restarted.visible.contains(.usage))
        XCTAssertTrue(restarted.setEnabled(.usage, true))
        XCTAssertEqual(restarted.visible.first, .usage)
    }

    func testVisibleRowsFollowCustomOrderAndUseAllThirteenToolsOnce() throws {
        let model = ToolMenuModel(defaults: try defaults())
        model.setEnabled(.usage, true)
        model.setEnabled(.notifications, true)
        model.move(.notifications, before: .chat)
        model.move(.notes, before: .chat)

        XCTAssertEqual(model.rows, [
            [.notifications, .notes, .chat, .dictation, .prompter],
            [.today, .launcher, .clipboard, .shelf, .shortcuts],
            [.usage, .system, .todo],
        ])
        XCTAssertEqual(model.rows.flatMap { $0 }, model.visible)
        XCTAssertEqual(model.cardHeight, 237)

        model.setEnabled(.notes, false)
        XCTAssertEqual(model.rows.first, [.notifications, .chat, .dictation, .prompter, .today])
        XCTAssertEqual(model.orderedTools[1], .notes, "Hiding a tool must not move it in Settings")
    }

    func testReorderingAndRestoringPreserveVisibilityShortcutsAndUnrelatedPreferences() throws {
        let store = try defaults()
        let choices = ["chat": false, "notes": false, "notifications": true, "future-tool": true]
        let shortcuts = Data("saved shortcut preferences".utf8)
        store.set(choices, forKey: ToolMenuModel.storageKey)
        store.set(shortcuts, forKey: ToolShortcutSettings.storageKey)
        store.set("unchanged", forKey: "lenotch.unrelated.preference")
        store.writtenKeys = []
        let model = ToolMenuModel(defaults: store)

        model.move(.todo, before: .chat)
        model.move(.notes, after: .notifications)
        XCTAssertTrue(model.hasCustomOrder)
        model.restoreOrder()

        XCTAssertEqual(model.orderedTools, canonical)
        XCTAssertFalse(model.hasCustomOrder)
        XCTAssertEqual(model.choices, choices)
        XCTAssertEqual(store.dictionary(forKey: ToolMenuModel.storageKey) as? [String: Bool], choices)
        XCTAssertEqual(store.data(forKey: ToolShortcutSettings.storageKey), shortcuts)
        XCTAssertEqual(store.string(forKey: "lenotch.unrelated.preference"), "unchanged")
        XCTAssertEqual(store.writtenKeys, Array(repeating: ToolMenuModel.orderStorageKey, count: 3))
        let restarted = ToolMenuModel(defaults: store)
        XCTAssertEqual(restarted.orderedTools, canonical)
        XCTAssertEqual(restarted.choices, choices)
    }

    func testRestoreNotifiesOnceAfterSavingAndDefaultRestoreIsANoop() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        model.move(.notes, before: .chat)
        store.writtenKeys = []
        var changes: [TrayTool] = []
        model.onChange = { tool in
            changes.append(tool)
            XCTAssertEqual(model.orderedTools, self.canonical)
            XCTAssertEqual(store.stringArray(forKey: ToolMenuModel.orderStorageKey), self.canonical.map(\.rawValue))
        }

        model.restoreOrder()
        XCTAssertEqual(changes, [.notes])
        XCTAssertEqual(store.writtenKeys, [ToolMenuModel.orderStorageKey])
        model.restoreOrder()
        XCTAssertEqual(changes, [.notes])
        XCTAssertEqual(store.writtenKeys, [ToolMenuModel.orderStorageKey])
    }

    func testNoOpDoesNotRewriteNormalizedSavedLabelsButARealMoveDoes() throws {
        let store = try defaults()
        let saved = ["notes", "notes", "unknown", "chat"]
        store.set(saved, forKey: ToolMenuModel.orderStorageKey)
        store.writtenKeys = []
        let model = ToolMenuModel(defaults: store)

        model.move(.notes, before: .chat)
        XCTAssertTrue(store.writtenKeys.isEmpty)
        XCTAssertEqual(store.stringArray(forKey: ToolMenuModel.orderStorageKey), saved)

        model.move(.notes, after: .chat)
        XCTAssertEqual(store.writtenKeys, [ToolMenuModel.orderStorageKey])
        XCTAssertEqual(store.stringArray(forKey: ToolMenuModel.orderStorageKey), model.orderedTools.map(\.rawValue))
        XCTAssertEqual(model.orderedTools.count, 13)
    }
}
