import AppKit
import IslandCore
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

@MainActor
final class TodoPageTests: XCTestCase {
    private let player = CardSize(width: 520, height: 240, radius: 32)
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    /// A store with a few lists the way a day might leave them: "Today" has three to do and one done.
    private func sampleStore() -> TodoStore {
        let store = TodoStore(storageURL: nil)
        let today = store.lists[0].id
        store.renameList(today, to: "Today")
        _ = store.addItem("Reply to Sam about the offsite")
        _ = store.addItem("Review the notch design")
        _ = store.addItem("Book flights to Lisbon")
        let done = store.addItem("Send the invoice")
        store.toggle(done!)
        _ = store.addList("Groceries")
        _ = store.addItem("Oat milk")
        _ = store.addList("Work")
        _ = store.addItem("Ship the to-do list")
        store.selectList(today)
        return store
    }

    private func defaults() -> UserDefaults {
        let suite = "lenotch.test.todopage.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func director(_ store: TodoStore, toolMenu: ToolMenuModel? = nil) -> IslandDirector {
        let preferences = defaults()
        let director = IslandDirector(prompter: PrompterModel(storageURL: nil), chatDefaults: preferences,
                                      toolMenu: toolMenu ?? ToolMenuModel(defaults: preferences), todos: store)
        let scheduler = ManualScheduler()
        director.schedule = scheduler.schedule
        director.clock = { 0 }
        director.realTime = { 0 }
        return director
    }

    // MARK: Drawing

    @MainActor private struct Rendered {
        let image: CGImage
        let card: CardSize
        let scale: Double
        let cardTop = 80.0
        var left: Double { FrameModel.cx - card.halfWidth }
        var cardRect: CGRect { CGRect(x: left, y: cardTop, width: card.width, height: card.height) }
        /// The tray's content: the card less its 20 pt margin.
        var content: CGRect { cardRect.insetBy(dx: 20, dy: 20) }
    }

    /// The page as AppKit draws it. SwiftUI's own image renderer leaves scroll views blank, and this page is made of them.
    private func render(_ director: IslandDirector, page: TrayModel.Page = .todo) async throws -> Rendered {
        director.openTray(at: page)
        let card = director.presentationCard(player: player)
        let frame = FrameModel()
        frame.cardHalfWidth = card.halfWidth
        frame.cardHeight = card.height
        frame.cardTop = 80
        frame.cardRadius = card.radius
        let size = NSSize(width: NotchContentView.size.width, height: NotchContentView.size.height)
        let view = TrayLayer(frame: frame, director: director, card: card)
            .environment(\.islandMotion, IslandMotion(reduce: true, stills: true))
            .frame(width: size.width, height: size.height)
            .background(.black)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        for _ in 0..<6 {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        return Rendered(image: image, card: card, scale: Double(image.width) / size.width)
    }

    private struct Line {
        let text: String
        /// In points, from the top left of the canvas.
        let box: CGRect
    }

    private func read(_ rendered: Rendered) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        try VNImageRequestHandler(cgImage: rendered.image).perform([request])
        let width = Double(NotchContentView.size.width), height = Double(NotchContentView.size.height)
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let b = observation.boundingBox
            return Line(text: text, box: CGRect(x: b.minX * width, y: (1 - b.maxY) * height, width: b.width * width, height: b.height * height))
        }
    }

    private func pixel(_ rendered: Rendered, x: Double, y: Double) throws -> (r: Double, g: Double, b: Double) {
        let bitmap = NSBitmapImageRep(cgImage: rendered.image)
        let color = try XCTUnwrap(bitmap.colorAt(x: Int(x * rendered.scale), y: Int(y * rendered.scale))?.usingColorSpace(.deviceRGB))
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    private func line(_ lines: [Line], containing text: String) -> Line? {
        lines.first { $0.text.lowercased().contains(text.lowercased()) }
    }

    func testThePageIsItsOwnCardInTheNotch() throws {
        let director = director(sampleStore())
        director.openTray(at: .todo)
        XCTAssertEqual(director.tray.page, .todo)
        XCTAssertEqual(director.presentationCard(player: player), CardSize(width: 440, height: 324, radius: 36))
        XCTAssertNotEqual(director.presentationCard(player: player), Island.trayOnly)
    }

    func testThePageShowsTheListsToDosAndTheField() async throws {
        let store = sampleStore()
        let rendered = try await render(director(store))
        let lines = try read(rendered)
        let transcript = lines.map(\.text).joined(separator: " | ")
        for expected in ["To-do", "Today", "Groceries", "Work", "Reply to Sam", "Review the notch design",
                         "Lisbon", "Done", "Clear", "Send the invoice", "Add to Today"] {
            XCTAssertNotNil(line(lines, containing: expected), "Missing “\(expected)”. Read: \(transcript)")
        }
        // Nothing is drawn outside the card.
        for line in lines {
            XCTAssertTrue(rendered.cardRect.insetBy(dx: -1, dy: -1).contains(line.box), "“\(line.text)” leaves the card: \(line.box)")
        }
        // The order down the page: the lists, the open ones, the done line and its to-do, the field.
        let order = ["Today", "Reply to Sam", "Review the notch", "Lisbon", "Done", "Send the invoice", "Add to Today"]
            .compactMap { line(lines, containing: $0)?.box.midY }
        XCTAssertEqual(order.count, 7, transcript)
        XCTAssertEqual(order, order.sorted(), "Top to bottom: \(order)")
    }

    func testAFinishedToDoIsTickedGreenAndAnOpenOneIsAnEmptyRing() async throws {
        let rendered = try await render(director(sampleStore()))
        let lines = try read(rendered)
        let done = try XCTUnwrap(line(lines, containing: "Send the invoice"))
        let open = try XCTUnwrap(line(lines, containing: "Reply to Sam"))
        // The ring is a 20 pt circle whose center is 18 pt in from the content's edge: its right side is inside the circle
        // and clear of the check mark.
        let ringX = rendered.content.minX + 4 + 14
        let tick = try pixel(rendered, x: ringX + 7.5, y: done.box.midY)
        XCTAssertGreaterThan(tick.g, 0.7, "A finished to-do's ring is filled green: \(tick)")
        XCTAssertGreaterThan(tick.g - tick.r, 0.25, "…clearly green, not grey or white: \(tick)")
        let empty = try pixel(rendered, x: ringX + 7.5, y: open.box.midY)
        XCTAssertLessThan(empty.g, 0.2, "An open to-do's ring is empty: \(empty)")
    }

    func testTheChosenListIsLitAndTheOthersAreNot() async throws {
        let store = sampleStore()
        let rendered = try await render(director(store))
        let lines = try read(rendered)
        let chosen = try XCTUnwrap(line(lines, containing: "Today"))
        let other = try XCTUnwrap(line(lines, containing: "Groceries"))
        let lit = try pixel(rendered, x: chosen.box.minX - 6, y: chosen.box.midY)
        let dark = try pixel(rendered, x: other.box.minX - 6, y: other.box.midY)
        XCTAssertGreaterThan(lit.r, 0.9, "The chosen chip is white: \(lit)")
        XCTAssertLessThan(dark.r, 0.3, "The others are dark: \(dark)")
        store.selectList(store.lists[1].id)
        let again = try await render(director(store))
        let nextLines = try read(again)
        XCTAssertNotNil(line(nextLines, containing: "Oat milk"), "The other list's to-dos show")
        XCTAssertNil(line(nextLines, containing: "Reply to Sam"))
        XCTAssertNotNil(line(nextLines, containing: "Add to Groceries"), "The field says where a to-do will go")
    }

    func testAListWithNothingInItSaysSo() async throws {
        let rendered = try await render(director(TodoStore(storageURL: nil)))
        let lines = try read(rendered)
        XCTAssertNotNil(line(lines, containing: "Nothing to do"), lines.map(\.text).joined(separator: " | "))
        XCTAssertNotNil(line(lines, containing: "Add to Tasks"))
        XCTAssertNil(line(lines, containing: "Done"), "No done line without a done to-do")
    }

    func testWithNoListsThereIsOneWayToMakeOneAndTheFieldWaits() async throws {
        let store = TodoStore(storageURL: nil)
        store.deleteList(store.lists[0].id)
        store.dismissUndo()
        let rendered = try await render(director(store))
        let lines = try read(rendered)
        let transcript = lines.map(\.text).joined(separator: " | ")
        XCTAssertNotNil(line(lines, containing: "No lists yet"), transcript)
        XCTAssertNotNil(line(lines, containing: "New list"), transcript)
        XCTAssertNotNil(line(lines, containing: "Make a list first"), transcript)
        XCTAssertNil(line(lines, containing: "Undo"), "The offer is gone once let go")
    }

    func testADeletionOffersUndoUntilItIsLetGoOrTaken() async throws {
        let store = sampleStore()
        store.deleteItem(store.selected!.open[0].id)
        let shown = try read(await render(director(store)))
        XCTAssertNotNil(line(shown, containing: "Deleted"), shown.map(\.text).joined(separator: " | "))
        XCTAssertNotNil(line(shown, containing: "Undo"))
        XCTAssertNotNil(shown.first { $0.text.contains("Deleted") && $0.text.contains("Reply") }, "The name is in the pill, so you know what was deleted")

        store.dismissUndo()
        let gone = try read(await render(director(store)))
        XCTAssertNil(line(gone, containing: "Undo"))

        store.deleteItem(store.selected!.open[0].id)
        store.undo()
        let back = try read(await render(director(store)))
        XCTAssertNil(line(back, containing: "Undo"))
        XCTAssertNotNil(line(back, containing: "Review the notch design"))
    }

    func testAnOverfullListIsCutAboveTheFieldAndFadesWhereThereIsMore() async throws {
        let store = sampleStore()
        for n in 1...14 { _ = store.addItem("Another thing to do number \(n)") }
        let rendered = try await render(director(store))
        let lines = try read(rendered)
        let field = try XCTUnwrap(line(lines, containing: "Add to Today"))
        let rows = lines.filter { $0.text.contains("Another thing") || $0.text.contains("Reply") || $0.text.contains("Review") || $0.text.contains("Book") }
        for row in rows { XCTAssertLessThan(row.box.maxY, field.box.minY - 4, "“\(row.text)” runs into the field") }
        XCTAssertEqual(rows.count, 5, "Five rows fit: \(rows.map(\.text))")
        XCTAssertNil(line(lines, containing: "number 3"), "The rest is scrolled away, not drawn over the field")
        // The field below is whole: its fill is the same across the full width of the content.
        for x in [rendered.content.minX + 40, rendered.content.midX, rendered.content.maxX - 40] {
            XCTAssertGreaterThan(try pixel(rendered, x: x, y: field.box.midY + 12).r, 0.06, "The field is drawn at \(x)")
        }
        // The last visible row fades where more is waiting; the first one doesn't.
        let first = try XCTUnwrap(line(lines, containing: "Reply to Sam"))
        let last = try XCTUnwrap(line(lines, containing: "number 2"))
        // The bottom of each ring: the cut row's lies in the fade, the first row's doesn't.
        let ringX = rendered.content.minX + 4 + 14
        func brightest(below y: Double) throws -> Double {
            try stride(from: y + 6, through: y + 13, by: 0.5).map { try pixel(rendered, x: ringX, y: $0).r }.max() ?? 0
        }
        let firstBottom = try brightest(below: first.box.midY)
        let lastBottom = try brightest(below: last.box.midY)
        XCTAssertGreaterThan(firstBottom, 0.2, "The first ring is drawn: \(firstBottom)")
        XCTAssertLessThan(lastBottom, firstBottom * 0.8, "The row at the cut is dimmer than the first: \(lastBottom) vs \(firstBottom)")
    }

    func testLongNamesAreCutInsideTheCardNotPastIt() async throws {
        let store = sampleStore()
        _ = store.addItem("A very long to-do that goes on and on well past the width of the card so it has to be cut with an ellipsis")
        _ = store.addList("A list with a very long name that must be cut")
        store.selectList(store.lists[0].id)
        let rendered = try await render(director(store))
        let lines = try read(rendered)
        let long = try XCTUnwrap(line(lines, containing: "A very long to-do"))
        XCTAssertLessThanOrEqual(long.box.maxX, rendered.content.maxX + 1, "The long to-do stays in the content: \(long.box)")
        XCTAssertTrue(long.text.contains("…") || long.text.hasSuffix("..."), "It ends in an ellipsis: \(long.text)")
        for line in lines { XCTAssertTrue(rendered.cardRect.insetBy(dx: -1, dy: -1).contains(line.box), "“\(line.text)” leaves the card") }
        // The chips scroll sideways and sit just under the title as they do without overflow.
        let chip = try XCTUnwrap(line(lines, containing: "Groceries"))
        let plain = try await render(director(sampleStore()))
        let plainChip = try XCTUnwrap(line(read(plain), containing: "Groceries"))
        XCTAssertEqual(chip.box.midY, plainChip.box.midY, accuracy: 1, "Overflowing chips don't shift the row")
    }

    // MARK: The tools menu

    func testToDoSitsInTheMenuWithTheNumberLeftToDo() async throws {
        let store = sampleStore()   // 5 to do across the lists
        let populatedDirector = director(store)
        let withCount = try await render(populatedDirector, page: .main)
        let populatedBadge = try badgeRegion(withCount, model: populatedDirector.toolMenu)
        XCTAssertGreaterThan(try brightPixels(withCount, in: populatedBadge), 60, "A badge sits at the To-do tile's corner")
        let lines = try read(withCount)
        XCTAssertNotNil(line(lines, containing: "To-do"), lines.map(\.text).joined(separator: " | "))
        XCTAssertNotNil(lines.first { $0.text == "5" }, "…and it says 5: \(lines.map(\.text))")

        let emptyDirector = director(TodoStore(storageURL: nil))
        let none = try await render(emptyDirector, page: .main)
        let emptyBadge = try badgeRegion(none, model: emptyDirector.toolMenu)
        XCTAssertEqual(try brightPixels(none, in: emptyBadge), 0, "No badge without anything to do")
    }

    func testTheBadgeStopsAtNinetyNine() async throws {
        let store = TodoStore(storageURL: nil)
        for n in 1...120 { _ = store.addItem("Item \(n)") }
        XCTAssertEqual(store.openCount, 120)
        let rendered = try await render(director(store), page: .main)
        let lines = try read(rendered)
        XCTAssertNotNil(lines.first { $0.text == "99" }, "Capped at 99: \(lines.map(\.text))")
        XCTAssertNil(lines.first { $0.text.contains("120") })
    }

    /// Locate To-do in the actual menu, including centered short rows.
    private func badgeRegion(_ rendered: Rendered, model: ToolMenuModel) throws -> CGRect {
        let rowIndex = try XCTUnwrap(model.rows.firstIndex { $0.contains(.todo) })
        let row = model.rows[rowIndex]
        let columnIndex = try XCTUnwrap(row.firstIndex(of: .todo))
        let cell = rendered.content.width / Double(ToolMenuModel.columns)
        let pitch = ToolMenuModel.rowHeight + ToolMenuModel.rowSpacing
        let leading = Double(ToolMenuModel.columns - row.count) / 2
        let tileCenterX = rendered.content.minX + cell * (leading + Double(columnIndex) + 0.5)
        let tileTop = rendered.content.minY + Double(rowIndex) * pitch
        return CGRect(x: tileCenterX + 20 - 9, y: tileTop - 6, width: 22, height: 20)
    }

    private func brightPixels(_ rendered: Rendered, in rect: CGRect) throws -> Int {
        let bitmap = NSBitmapImageRep(cgImage: rendered.image)
        var count = 0
        for px in Int(rect.minX * rendered.scale)..<Int(rect.maxX * rendered.scale) {
            for py in Int(rect.minY * rendered.scale)..<Int(rect.maxY * rendered.scale) {
                if let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB), color.redComponent > 0.9 { count += 1 }
            }
        }
        return count
    }

    func testHidingToDoTakesItOutOfTheMenuButNotOutOfReach() throws {
        let store = sampleStore()
        let menu = ToolMenuModel(defaults: defaults())
        let director = director(store, toolMenu: menu)
        XCTAssertTrue(menu.isEnabled(.todo))
        director.openTray(at: .todo)
        XCTAssertEqual(director.tray.page, .todo)
        menu.setEnabled(.todo, false)
        XCTAssertEqual(director.tray.page, .main, "Turning it off while it is open returns to the menu")
        XCTAssertFalse(menu.visible.contains(.todo))
        director.showTool(.todo)
        XCTAssertEqual(director.tray.page, .todo, "Anything that opens the page still can")
        XCTAssertEqual(store.openCount, 5, "Hiding the tool keeps every to-do")
    }

    func testTheToolsNameIconAndDescriptionAreReady() {
        XCTAssertEqual(TrayTool.todo.title, "To-do")
        XCTAssertEqual(TrayTool.todo.menuLabel, "To-do")
        XCTAssertEqual(TrayTool.todo.page, .todo)
        XCTAssertEqual(TrayTool.todo.icon, .todo)
        XCTAssertTrue(TrayTool.todo.enabledByDefault)
        XCTAssertTrue(TrayTool.todo.detail.contains("this Mac"))
        let box = CGRect(x: 0, y: 0, width: 24, height: 24)
        let bounds = ToolIconShape(icon: .todo).path(in: box).boundingRect
        XCTAssertGreaterThan(bounds.width, 15)
        XCTAssertGreaterThan(bounds.height, 15)
        for other in ToolIcon.allCases where other != .todo {
            XCTAssertNotEqual(ToolIconShape(icon: other).path(in: box).boundingRect, bounds, "\(other) looks different from To-do")
        }
    }
}
