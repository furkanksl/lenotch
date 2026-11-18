import AppKit
import IslandCore
import XCTest
@testable import Lenotch

@MainActor
final class ToolShortcutRoutingTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func director() throws -> IslandDirector {
        let suite = "lenotch.test.toolshortcut.routing.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let director = IslandDirector(prompter: PrompterModel(storageURL: nil), chatDefaults: defaults)
        let scheduler = ManualScheduler()
        director.schedule = scheduler.schedule
        director.clock = { 0 }
        director.realTime = { 0 }
        return director
    }

    func testEachShortcutOpensItsToolEvenWhenHiddenAndRepeatingClosesIt() throws {
        for target in ToolShortcutTarget.allCases {
            let director = try director()
            defer { director.stopAll() }
            let tool = try XCTUnwrap(TrayTool.allCases.first { $0.page == target.page })
            director.toolMenu.setEnabled(tool, false)
            XCTAssertFalse(director.toolMenu.visible.contains(tool))
            director.toggleToolShortcut(target)
            XCTAssertTrue(director.island.opened)
            XCTAssertTrue(director.groups.tray)
            XCTAssertEqual(director.tray.page, target.page)
            director.toggleToolShortcut(target)
            XCTAssertFalse(director.island.opened)
        }
    }

    func testASecondToolSwitchesWithoutClosingTheCard() throws {
        let director = try director()
        defer { director.stopAll() }
        director.toggleToolShortcut(.todo)
        director.toggleToolShortcut(.notes)
        XCTAssertTrue(director.island.opened)
        XCTAssertEqual(director.tray.page, .notes)
        director.toggleToolShortcut(.clipboard)
        XCTAssertTrue(director.island.opened)
        XCTAssertEqual(director.tray.page, .clipboard)
    }

    func testToolShortcutsNeverRevealContentWhileLockedOrPresenting() throws {
        for context in [DesktopContext(locked: true), DesktopContext(sharing: true)] {
            for target in ToolShortcutTarget.allCases {
                let director = try director()
                defer { director.stopAll() }
                director.systemContextChanged(context)
                director.toggleToolShortcut(target)
                XCTAssertFalse(director.island.opened)
                XCTAssertFalse(director.groups.tray)
            }
        }
    }

    func testShortcutToggleLeavesSavedNotesAndTasksIntact() throws {
        let director = try director()
        defer { director.stopAll() }
        _ = director.todos.addItem("Keep this task")
        let note = director.notes.addNote()
        director.notes.updateBody(note, to: "Keep this note")
        director.toggleToolShortcut(.todo)
        director.toggleToolShortcut(.notes)
        director.toggleToolShortcut(.notes)
        XCTAssertEqual(director.todos.selected?.items.first?.title, "Keep this task")
        XCTAssertEqual(director.notes.notes.first?.body, "Keep this note")
    }
}
