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

    func testPageShortcutsOpenHiddenToolsAndRepeatingClosesThem() throws {
        let pageTargets = ToolShortcutTarget.allCases.filter { $0.page != nil }
        XCTAssertEqual(pageTargets.count, 10)
        for target in pageTargets {
            let director = try director()
            defer { director.stopAll() }
            let page = try XCTUnwrap(target.page)
            let tool = target.tool
            director.toolMenu.setEnabled(tool, false)
            XCTAssertFalse(director.toolMenu.visible.contains(tool))
            director.toggleToolShortcut(target)
            XCTAssertTrue(director.island.opened)
            XCTAssertTrue(director.groups.tray)
            XCTAssertEqual(director.tray.page, page)
            director.toggleToolShortcut(target)
            XCTAssertFalse(director.island.opened)
        }
    }

    func testNonPageShortcutsUseChatDictationAndLauncherActionsEvenWhenHidden() throws {
        let actionTargets = ToolShortcutTarget.allCases.filter { $0.page == nil }
        XCTAssertEqual(Set(actionTargets), [.chat, .dictation, .launcher])
        for target in actionTargets {
            let director = try director()
            defer { director.stopAll() }
            director.toolMenu.setEnabled(target.tool, false)
            XCTAssertFalse(director.toolMenu.visible.contains(target.tool))
            switch target {
            case .chat:
                director.toggleToolShortcut(target)
                XCTAssertTrue(director.island.opened)
                XCTAssertEqual(director.island.askOpen, .codex)
                XCTAssertFalse(director.groups.tray, "Chat uses its own card")
                director.toggleToolShortcut(target)
                XCTAssertFalse(director.island.opened)
                XCTAssertNil(director.island.askOpen)
            case .dictation:
                var toggles = 0
                director.onToggleDictation = { toggles += 1 }
                director.toggleToolShortcut(target)
                director.toggleToolShortcut(target)
                XCTAssertEqual(toggles, 2, "Dictation delegates without starting a real recorder in tests")
                XCTAssertFalse(director.groups.tray)
            case .launcher:
                var toggles = 0
                director.onToggleLauncher = {
                    toggles += 1
                    director.launcherVisibilityChanged(!director.launcherVisible)
                }
                director.toggleToolShortcut(target)
                XCTAssertTrue(director.launcherVisible)
                director.toggleToolShortcut(target)
                XCTAssertFalse(director.launcherVisible)
                XCTAssertEqual(toggles, 2)
                XCTAssertFalse(director.groups.tray, "Launcher keeps its independent fan presentation")
            default:
                XCTFail("Unexpected non-page tool: \(target)")
            }
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
                var actions = 0
                director.onToggleDictation = { actions += 1 }
                director.onToggleLauncher = { actions += 1 }
                director.onShowLauncher = { actions += 1 }
                director.systemContextChanged(context)
                director.toggleToolShortcut(target)
                XCTAssertFalse(director.island.opened)
                XCTAssertFalse(director.groups.tray)
                XCTAssertNil(director.island.askOpen)
                XCTAssertFalse(director.launcherVisible)
                XCTAssertEqual(actions, 0, "Privacy guards also apply to \(target)'s delegated action")
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
