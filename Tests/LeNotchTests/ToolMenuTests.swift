import AppKit
import IslandCore
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

@MainActor
final class ToolMenuTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let suite = "lenotch.test.toolmenu.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func director(_ model: ToolMenuModel, defaults: UserDefaults) -> IslandDirector {
        let director = IslandDirector(prompter: PrompterModel(storageURL: nil), chatDefaults: defaults, toolMenu: model)
        let scheduler = ManualScheduler()
        director.schedule = scheduler.schedule
        director.clock = { 0 }
        director.realTime = { 0 }
        return director
    }

    private let player = CardSize(width: 520, height: 240, radius: 32)

    // MARK: Model

    func testTheMenuStartsWithElevenToolsAndUsageAndNotificationsHidden() throws {
        let model = ToolMenuModel(defaults: try defaults())
        XCTAssertEqual(model.visible.map(\.title),
                       ["Chat", "Dictation", "Prompter", "Today", "Launcher", "Clipboard", "Shelf", "Shortcuts", "System", "To-do", "Notes"])
        XCTAssertFalse(model.isEnabled(.usage))
        XCTAssertFalse(model.isEnabled(.notifications))
        XCTAssertEqual(TrayTool.allCases.count, 13)
        XCTAssertEqual(TrayTool.allCases.last, .notifications)
        XCTAssertEqual(model.rows.map { $0.map(\.menuLabel) },
                       [["Chat", "Dictation", "Prompter", "Today", "Launcher"],
                        ["Clipboard", "Shelf", "Shortcuts", "System", "To-do"],
                        ["Notes"]],
                       "Notes follows To-do, while Usage starts hidden")
        XCTAssertEqual(model.cardHeight, ToolMenuModel.cardHeight(rows: 3))
        XCTAssertEqual(ToolMenuModel.cardHeight(rows: 2), Island.trayOnly.height, "Two rows are the card's long-standing height")
        XCTAssertTrue(model.setEnabled(.notes, false))
        XCTAssertEqual(model.cardHeight, Island.trayOnly.height, "Hiding Notes leaves ten tools in two rows")
    }

    func testUsageCanStillBeEnabledAndItsExplicitChoiceSurvivesTheNewDefault() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        XCTAssertFalse(model.isEnabled(.usage), "Usage is off before anyone chooses otherwise")
        XCTAssertTrue(model.setEnabled(.usage, true))
        XCTAssertTrue(ToolMenuModel(defaults: store).isEnabled(.usage), "An explicit opt-in survives a restart")

        // Choices written by an earlier version also override today's defaults.
        store.set([TrayTool.usage.rawValue: true], forKey: ToolMenuModel.storageKey)
        let restored = ToolMenuModel(defaults: store)
        XCTAssertTrue(restored.isEnabled(.usage))
        XCTAssertTrue(restored.setEnabled(.usage, false))
        XCTAssertFalse(ToolMenuModel(defaults: store).isEnabled(.usage), "An explicit opt-out is saved too")
    }

    func testEveryToolHasItsOwnNameIconAndPage() {
        XCTAssertEqual(Set(TrayTool.allCases.map(\.title)).count, TrayTool.allCases.count)
        XCTAssertEqual(Set(TrayTool.allCases.map(\.icon)).count, TrayTool.allCases.count)
        let pages = TrayTool.allCases.compactMap(\.page)
        XCTAssertEqual(Set(pages).count, pages.count)
        XCTAssertEqual(Set(TrayTool.allCases.filter { $0.page == nil }), [.chat, .dictation, .launcher])
        for tool in TrayTool.allCases {
            XCTAssertFalse(tool.detail.isEmpty, tool.rawValue)
            XCTAssertLessThanOrEqual(tool.menuLabel.count, 10, "\(tool.rawValue)'s label has a fifth of the card")
        }
        XCTAssertEqual(TrayTool.notifications.menuLabel, "Inbox")
    }

    func testChoicesPersistAndOnlyChoicesAreStored() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        XCTAssertTrue(model.setEnabled(.notifications, true))
        XCTAssertTrue(model.setEnabled(.shelf, false))
        let again = ToolMenuModel(defaults: store)
        XCTAssertTrue(again.isEnabled(.notifications))
        XCTAssertFalse(again.isEnabled(.shelf))
        XCTAssertTrue(again.isEnabled(.chat))
        XCTAssertEqual(store.dictionary(forKey: ToolMenuModel.storageKey) as? [String: Bool],
                       ["notifications": true, "shelf": false],
                       "A tool nobody touched stays on its default, so one added later takes its own")
        // The defaults are the model's, not a copy: another suite starts clean.
        XCTAssertFalse(ToolMenuModel(defaults: try defaults()).isEnabled(.notifications))
    }

    func testTheLastToolStaysOnAndTheMenuNeverEmpties() throws {
        let model = ToolMenuModel(defaults: try defaults())
        for tool in TrayTool.allCases.dropFirst() where model.isEnabled(tool) { XCTAssertTrue(model.setEnabled(tool, false)) }
        XCTAssertEqual(model.visible, [.chat])
        XCTAssertFalse(model.canDisable(.chat))
        XCTAssertFalse(model.setEnabled(.chat, false), "Turning off the last tool is refused")
        XCTAssertTrue(model.isEnabled(.chat))
        XCTAssertEqual(model.rows, [[.chat]])
        XCTAssertTrue(model.setEnabled(.system, true))
        XCTAssertTrue(model.canDisable(.chat))
        XCTAssertTrue(model.setEnabled(.chat, false))
        XCTAssertEqual(model.visible, [.system])
    }

    func testStoredChoicesThatHideEverythingShowTheDefaultsInstead() throws {
        let store = try defaults()
        store.set(Dictionary(uniqueKeysWithValues: TrayTool.allCases.map { ($0.rawValue, false) }), forKey: ToolMenuModel.storageKey)
        let model = ToolMenuModel(defaults: store)
        XCTAssertEqual(model.visible.count, 11, "A menu with nothing in it is a dead end")
        XCTAssertFalse(model.isEnabled(.usage))
        XCTAssertFalse(model.isEnabled(.notifications))
        store.set("not a dictionary", forKey: ToolMenuModel.storageKey)
        XCTAssertEqual(ToolMenuModel(defaults: store).visible.count, 11)
    }

    func testRowsHoldFiveToolsAndTheCardGrowsAFullRowAtATime() throws {
        let model = ToolMenuModel(defaults: try defaults())
        XCTAssertEqual(model.rows.map(\.count), [5, 5, 1])
        XCTAssertTrue(model.setEnabled(.notifications, true))
        XCTAssertEqual(model.rows.map(\.count), [5, 5, 2])
        XCTAssertEqual(model.rows[2], [.notes, .notifications])
        XCTAssertEqual(model.cardHeight, 237)
        for tool in [TrayTool.notes, .notifications] { model.setEnabled(tool, false) }
        XCTAssertEqual(model.rows.map(\.count), [5, 5])
        XCTAssertEqual(model.cardHeight, 168)
        for tool in [TrayTool.clipboard, .shelf, .shortcuts, .system, .todo] { model.setEnabled(tool, false) }
        XCTAssertEqual(model.rows.map(\.count), [5])
        XCTAssertEqual(model.cardHeight, 99)
        XCTAssertEqual(ToolMenuModel.cardHeight(rows: 0), 99, "Never shorter than one row")
        XCTAssertEqual(ToolMenuModel.cardHeight(rows: 2), 168)
        XCTAssertEqual(ToolMenuModel.cardHeight(rows: 3), 237)
    }

    func testOnChangeReportsEachRealChangeOnceAfterItIsStored() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        var changes: [(TrayTool, Bool, Bool)] = []
        model.onChange = { tool in
            changes.append((tool, model.isEnabled(tool),
                            (store.dictionary(forKey: ToolMenuModel.storageKey) as? [String: Bool])?[tool.rawValue] == model.isEnabled(tool)))
        }
        model.setEnabled(.system, true)   // already on: nothing changes
        model.setEnabled(.system, false)
        model.setEnabled(.system, false)
        model.setEnabled(.system, true)
        XCTAssertEqual(changes.map(\.0), [.system, .system])
        XCTAssertEqual(changes.map(\.1), [false, true])
        XCTAssertTrue(changes.allSatisfy(\.2), "The choice is stored before anyone is told")
    }

    // MARK: Director

    func testNotesHasItsOwnMenuIdentityAndCanBeHiddenWithoutBlockingItsPage() throws {
        XCTAssertEqual(TrayTool.notes.title, "Notes")
        XCTAssertEqual(TrayTool.notes.menuLabel, "Notes")
        XCTAssertEqual(TrayTool.notes.icon, .notes)
        XCTAssertEqual(TrayTool.notes.page, .notes)
        XCTAssertTrue(TrayTool.notes.enabledByDefault)

        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        let director = director(model, defaults: store)
        director.showTool(.notes)
        XCTAssertEqual(director.tray.page, .notes)
        XCTAssertTrue(director.groups.tray)
        model.setEnabled(.notes, false)
        XCTAssertFalse(model.visible.contains(.notes))
        XCTAssertEqual(director.tray.page, .main, "Hiding the open tool returns to the menu")
        XCTAssertFalse(ToolMenuModel(defaults: store).isEnabled(.notes), "The visibility choice survives a restart")
        director.showTool(.notes)
        XCTAssertEqual(director.tray.page, .notes, "Hiding the menu button does not disable Notes")
    }

    func testTheMenuCardFollowsTheRowsAndKeepsItsWidth() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        let director = director(model, defaults: store)
        director.openTray()
        XCTAssertEqual(director.presentationCard(player: player), CardSize(width: 372, height: 237, radius: 34),
                       "The default menu is three rows, Notes alone on the last")
        model.setEnabled(.notes, false)
        XCTAssertEqual(director.presentationCard(player: player), Island.trayOnly)
        model.setEnabled(.notifications, true)
        model.setEnabled(.notes, true)
        XCTAssertEqual(director.presentationCard(player: player), CardSize(width: 372, height: 237, radius: 34))
        for tool in [TrayTool.clipboard, .shelf, .shortcuts, .usage, .system, .todo, .notes, .notifications] { model.setEnabled(tool, false) }
        XCTAssertEqual(director.presentationCard(player: player), CardSize(width: 372, height: 99, radius: 34))

        // The shape the notch grows into is the one the card reports.
        var context = TargetContext()
        context.card = director.presentationCard(player: player)
        let shape = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: Tuning(), context: context).resting(director.mode)
        XCTAssertEqual(shape.cardHeight, 99, accuracy: 0.01)
        XCTAssertEqual(shape.cardHalfWidth * 2, 372, accuracy: 0.01)
    }

    func testOnlyTheMenuChangesSizeWhileAToolPageKeepsItsOwn() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        let director = director(model, defaults: store)
        director.openTray(at: .usage)
        model.setEnabled(.notifications, true)
        XCTAssertEqual(director.presentationCard(player: player), CardSize(width: 480, height: 266, radius: 36))
        director.tray.go(.system)
        XCTAssertEqual(director.presentationCard(player: player), CardSize(width: 400, height: 208, radius: 36))
        director.tray.go(.shelf)
        XCTAssertEqual(director.presentationCard(player: player), Island.trayOnly,
                       "A page without its own size keeps the default card")
        director.tray.go(.main)
        XCTAssertEqual(director.presentationCard(player: player).height, 237)
    }

    func testTurningOffTheToolOnScreenReturnsToTheMenuAndOthersLeaveItAlone() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        let director = director(model, defaults: store)
        director.openTray(at: .system)
        model.setEnabled(.chat, false)
        XCTAssertEqual(director.tray.page, .system, "Another tool's switch doesn't move you")
        model.setEnabled(.system, false)
        XCTAssertEqual(director.tray.page, .main)
        XCTAssertTrue(director.groups.tray, "The menu stays open")
        XCTAssertEqual(director.toolMenu.rows.flatMap { $0 }.count, 9)
    }

    func testAHiddenToolIsStillReachableWhereItsOwnShortcutOrEventOpensIt() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        let director = director(model, defaults: store)
        XCTAssertFalse(model.isEnabled(.notifications))
        director.showTool(.notifications)
        XCTAssertEqual(director.tray.page, .notifications)
        XCTAssertEqual(director.presentationCard(player: player), CardSize(width: 420, height: 348, radius: 36))
        model.setEnabled(.chat, false)
        XCTAssertEqual(director.tray.page, .notifications, "Switching another tool off leaves a notification on screen")
        director.clickOutside()
        director.openTray(at: .shelf)   // a file dropped on the notch
        model.setEnabled(.shelf, false)
        XCTAssertEqual(director.tray.page, .main, "The page of the tool just hidden closes")
        director.tray.go(.shelf)
        XCTAssertEqual(director.tray.page, .shelf, "Dropping a file still opens the Shelf")
    }

    // MARK: The menu as drawn

    private struct RenderedMenu {
        let image: CGImage
        let card: CardSize
        let cardTop: Double
        let left: Double
    }

    private func render(_ model: ToolMenuModel, defaults store: UserDefaults) throws -> RenderedMenu {
        let director = director(model, defaults: store)
        director.openTray()
        let card = director.presentationCard(player: player)
        let frame = FrameModel()
        frame.cardHalfWidth = card.halfWidth
        frame.cardHeight = card.height
        frame.cardTop = 80
        frame.cardRadius = card.radius
        let view = TrayLayer(frame: frame, director: director, card: card)
            .environment(\.islandMotion, IslandMotion(reduce: true, stills: true))
            .frame(width: NotchContentView.size.width, height: NotchContentView.size.height)
            .background(.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return RenderedMenu(image: try XCTUnwrap(renderer.cgImage), card: card, cardTop: 80,
                            left: FrameModel.cx - card.halfWidth)
    }

    /// The centers of the lit tiles across `y` (points), left to right.
    private func tileCenters(in menu: RenderedMenu, atY y: Double) -> [Double] {
        let bitmap = NSBitmapImageRep(cgImage: menu.image)
        var centers: [Double] = [], start: Int?
        let from = Int((menu.left + 4) * 2), to = Int((menu.left + menu.card.width - 4) * 2)
        for x in from...to {
            let lit = (bitmap.colorAt(x: x, y: Int(y * 2))?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.07 && x < to
            if lit, start == nil { start = x }
            if !lit, let s = start { centers.append(Double(s + x) / 4); start = nil }
        }
        return centers
    }

    private func labels(in menu: RenderedMenu, cellCenter: Double, cellWidth: Double,
                        tileTop: Double) throws -> [(text: String, centerX: Double)] {
        // Reading a whole row lets Vision merge adjacent labels, biasing their bounding boxes.
        let rect = CGRect(x: cellCenter - cellWidth / 2, y: tileTop + 41, width: cellWidth, height: 22)
        let crop = try XCTUnwrap(menu.image.cropping(to: CGRect(x: rect.minX * 2, y: rect.minY * 2,
                                                              width: rect.width * 2, height: rect.height * 2)))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: crop).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, rect.minX + observation.boundingBox.midX * rect.width) }
        }
    }

    private func normalizedLabel(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func assertMenu(_ tools: Set<TrayTool>, rows expectedRows: [[TrayTool]], file: StaticString = #filePath, line: UInt = #line) throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        for tool in TrayTool.allCases where !tools.contains(tool) { model.setEnabled(tool, false) }
        for tool in tools { model.setEnabled(tool, true) }
        XCTAssertEqual(model.rows, expectedRows, file: file, line: line)
        let menu = try render(model, defaults: store)
        XCTAssertEqual(menu.card.height, ToolMenuModel.cardHeight(rows: expectedRows.count), file: file, line: line)
        let cell = (menu.card.width - 40) / Double(ToolMenuModel.columns)
        let innerLeft = menu.left + 20

        // Each row's tiles sit in the five columns, a short row centered under them.
        let pitch = (menu.card.height - 2 * ToolMenuModel.margin + ToolMenuModel.rowSpacing) / Double(expectedRows.count)
        for (index, row) in expectedRows.enumerated() {
            let tileTop = menu.cardTop + ToolMenuModel.margin + Double(index) * pitch
            let centers = tileCenters(in: menu, atY: tileTop + 20)
            let leading = Double(ToolMenuModel.columns - row.count) / 2
            let expected = row.indices.map { innerLeft + (leading + Double($0) + 0.5) * cell }
            XCTAssertEqual(centers.count, row.count, "Row \(index) draws one tile per tool: \(centers)", file: file, line: line)
            for (found, want) in zip(centers, expected) {
                XCTAssertEqual(found, want, accuracy: 1.5, "Row \(index) keeps the columns", file: file, line: line)
            }
            for (position, tool) in row.enumerated() {
                let read = try labels(in: menu, cellCenter: expected[position], cellWidth: cell, tileTop: tileTop)
                let match = read.first { normalizedLabel($0.text) == normalizedLabel(tool.menuLabel) }
                XCTAssertNotNil(match, "Row \(index) is missing \(tool.menuLabel). Read: \(read.map(\.text))", file: file, line: line)
                if let match {
                    XCTAssertEqual(match.centerX, expected[position], accuracy: 6, "\(tool.menuLabel) sits under its tile", file: file, line: line)
                }
            }
        }
    }

    func testTheDefaultMenuDrawsThreeRowsWithNotesCentered() throws {
        let defaultTools = Set(TrayTool.allCases.filter(\.enabledByDefault))
        try assertMenu(defaultTools, rows: [[.chat, .dictation, .prompter, .today, .launcher],
                                            [.clipboard, .shelf, .shortcuts, .system, .todo],
                                            [.notes]])
    }

    func testHidingNotesFitsTheOtherDefaultToolsInTwoRows() throws {
        let tools = Set(TrayTool.allCases.filter { $0.enabledByDefault && $0 != .notes })
        try assertMenu(tools, rows: [[.chat, .dictation, .prompter, .today, .launcher],
                                     [.clipboard, .shelf, .shortcuts, .system, .todo]])
    }

    func testAllEnabledToolsCenterToDoNotesAndInboxOnTheThirdRow() throws {
        try assertMenu(Set(TrayTool.allCases), rows: [[.chat, .dictation, .prompter, .today, .launcher],
                                                      [.clipboard, .shelf, .shortcuts, .usage, .system],
                                                      [.todo, .notes, .notifications]])
    }

    func testAFewToolsDrawOneShortCenteredRow() throws {
        try assertMenu([.chat, .system, .usage], rows: [[.chat, .usage, .system]])
        try assertMenu([.today, .shelf], rows: [[.today, .shelf]])
    }

    // MARK: Setup

    private func words(of page: SetupToolsPage, scheme: ColorScheme) throws -> String {
        let view = page
            .padding(24)
            .frame(width: 700, height: 1760, alignment: .topLeading)
            .background(scheme == .dark ? Color(red: 0.09, green: 0.09, blue: 0.086) : .white)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
    }

    func testSetupListsEveryToolWithItsCountInBothThemes() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        let shortcuts = ToolShortcutSettings(defaults: store)
        for scheme in [ColorScheme.light, .dark] {
            let read = try words(of: SetupToolsPage(model: model, shortcuts: shortcuts), scheme: scheme)
            for tool in TrayTool.allCases {
                XCTAssertTrue(read.contains(tool.title.lowercased()), "\(tool.title) is missing in \(scheme). Read: \(read)")
            }
            XCTAssertTrue(read.contains("tools menu"), read)
            XCTAssertTrue(read.contains("11 of 13 shown"), "The default menu shows eleven of the thirteen: \(read)")
            XCTAssertFalse(read.contains("at least one tool"), "The reminder shows only when one tool is left")
            XCTAssertTrue(read.contains("shortcut"), "The page says what hiding a tool leaves working: \(read)")
        }
    }

    func testSetupExplainsWhyTheLastToolCannotBeTurnedOff() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        for tool in TrayTool.allCases.dropFirst() { model.setEnabled(tool, false) }
        let read = try words(of: SetupToolsPage(model: model, shortcuts: ToolShortcutSettings(defaults: store)), scheme: .light)
        XCTAssertTrue(read.contains("1 of 13 shown"), read)
        XCTAssertTrue(read.contains("at least one tool stays on"), read)
    }

    func testSetupSwitchesReadAndWriteTheSharedMenu() throws {
        let store = try defaults()
        let model = ToolMenuModel(defaults: store)
        let page = SetupToolsPage(model: model, shortcuts: ToolShortcutSettings(defaults: store))
        XCTAssertFalse(page.isOn(.notifications).wrappedValue)
        XCTAssertTrue(page.isOn(.chat).wrappedValue)
        page.isOn(.notifications).wrappedValue = true
        XCTAssertTrue(page.isOn(.notifications).wrappedValue)
        XCTAssertTrue(ToolMenuModel(defaults: store).isEnabled(.notifications), "The choice is stored")
        XCTAssertEqual(model.rows.map(\.count), [5, 5, 2])
        page.isOn(.chat).wrappedValue = false
        XCTAssertEqual(model.visible.count, 11)
        XCTAssertFalse(page.isOn(.chat).wrappedValue)
        for tool in TrayTool.allCases.dropFirst() { page.isOn(tool).wrappedValue = false }
        XCTAssertEqual(model.visible.count, 1)
        let last = model.visible[0]
        XCTAssertEqual(last, .notifications, "The only tool left is the one switched on last")
        page.isOn(last).wrappedValue = false
        XCTAssertTrue(page.isOn(last).wrappedValue, "The last tool's switch won't go off")
    }
}
