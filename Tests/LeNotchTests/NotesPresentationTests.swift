import AppKit
import Carbon.HIToolbox
import IslandCore
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

/// Render the real tray through AppKit: ImageRenderer does not draw the contents of its scroll views.
/// The native editor checks below use only this process's views and never post global input events.
@MainActor
final class NotesPresentationTests: XCTestCase {
    private let player = CardSize(width: 520, height: 240, radius: 32)

    override func setUp() async throws {
        _ = NSApplication.shared
    }

    private func defaults() -> UserDefaults {
        let suite = "lenotch.test.notes.presentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func director(_ store: NotesStore, toolMenu: ToolMenuModel? = nil) -> IslandDirector {
        let preferences = defaults()
        let director = IslandDirector(prompter: PrompterModel(storageURL: nil), chatDefaults: preferences,
                                      toolMenu: toolMenu ?? ToolMenuModel(defaults: preferences), notes: store)
        let scheduler = ManualScheduler()
        director.schedule = scheduler.schedule
        director.clock = { 0 }
        director.realTime = { 0 }
        return director
    }

    @discardableResult
    private func createNote(_ store: NotesStore, title: String, body: String,
                            now: Date = Date()) -> UUID {
        let id = store.addNote(now: now)
        store.updateTitle(id, to: title, now: now)
        store.updateBody(id, to: body, now: now)
        return id
    }

    @MainActor private struct Rendered {
        let image: CGImage
        let card: CardSize
        let scale: Double
        let cardTop = 80.0
        var left: Double { FrameModel.cx - card.halfWidth }
        var cardRect: CGRect { CGRect(x: left, y: cardTop, width: card.width, height: card.height) }
        var content: CGRect { cardRect.insetBy(dx: 20, dy: 20) }
    }

    private struct ReadLine {
        let text: String
        let box: CGRect
    }

    private func render(_ director: IslandDirector, page: TrayModel.Page = .notes,
                        scheme: ColorScheme = .dark) async throws -> Rendered {
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
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
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

    private func read(_ rendered: Rendered) throws -> [ReadLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        try VNImageRequestHandler(cgImage: rendered.image).perform([request])
        let width = Double(NotchContentView.size.width), height = Double(NotchContentView.size.height)
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return ReadLine(text: text, box: CGRect(x: box.minX * width,
                y: (1 - box.maxY) * height, width: box.width * width,
                height: box.height * height))
        }
    }

    private func line(_ lines: [ReadLine], containing text: String) -> ReadLine? {
        lines.first { $0.text.localizedCaseInsensitiveContains(text) }
    }

    private func transcript(_ lines: [ReadLine]) -> String { lines.map(\.text).joined(separator: " | ") }

    private func assertInsideCard(_ lines: [ReadLine], rendered: Rendered,
                                  file: StaticString = #filePath, line: UInt = #line) {
        for item in lines {
            XCTAssertTrue(rendered.cardRect.insetBy(dx: -1, dy: -1).contains(item.box),
                          "“\(item.text)” leaves the card: \(item.box)", file: file, line: line)
        }
    }

    // MARK: Index and editor presentation

    func testAnEmptyIndexExplainsNotesAndOffersANewNoteInBothThemes() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let rendered = try await render(director(NotesStore(storageURL: nil)), scheme: scheme)
            let lines = try read(rendered)
            let text = transcript(lines)
            XCTAssertNotNil(line(lines, containing: "Notes"), text)
            XCTAssertNotNil(line(lines, containing: "A place for your thoughts"), text)
            XCTAssertNotNil(line(lines, containing: "New note"), text)
            XCTAssertNil(line(lines, containing: "words"), "The index is not an empty editor: \(text)")
            assertInsideCard(lines, rendered: rendered)
        }
    }

    func testTheIndexShowsMultipleTitlesAndBodyPreviewsNewestFirst() async throws {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = NotesStore(storageURL: nil)
        createNote(store, title: "Garden ideas", body: "Plant basil by the window.", now: date)
        date.addTimeInterval(60)
        createNote(store, title: "Weekend walks", body: "Take the coastal path.", now: date)
        date.addTimeInterval(60)
        createNote(store, title: "Launch checklist", body: "Call Mira.\nBring the sketches.", now: date)
        store.select(nil)

        let rendered = try await render(director(store))
        let lines = try read(rendered)
        let text = transcript(lines)
        let newest = try XCTUnwrap(line(lines, containing: "Launch checklist"), text)
        let middle = try XCTUnwrap(line(lines, containing: "Weekend walks"), text)
        let oldest = try XCTUnwrap(line(lines, containing: "Garden ideas"), text)
        XCTAssertLessThan(newest.box.minY, middle.box.minY, "Most recently edited notes lead the list")
        XCTAssertLessThan(middle.box.minY, oldest.box.minY)
        XCTAssertNotNil(line(lines, containing: "Call Mira."), text)
        XCTAssertNil(line(lines, containing: "Bring the sketches."), "The index uses only the first nonempty body line")
        XCTAssertNotNil(line(lines, containing: "Take the coastal path."), text)
        XCTAssertNotNil(line(lines, containing: "Plant basil by the window."), text)
        XCTAssertNil(line(lines, containing: "A place for your thoughts"))
        assertInsideCard(lines, rendered: rendered)
    }

    func testOpeningANoteShowsItsTitleMultilineBodyAndActualWordCount() async throws {
        let body = "First paragraph stays here.\n\nSecond paragraph stays below.\nLast line stays visible."
        for scheme in [ColorScheme.light, .dark] {
            let store = NotesStore(storageURL: nil)
            createNote(store, title: "Field notes", body: body)
            let rendered = try await render(director(store), scheme: scheme)
            let lines = try read(rendered)
            let text = transcript(lines)
            XCTAssertNotNil(line(lines, containing: "Field notes"), text)
            let first = try XCTUnwrap(line(lines, containing: "First paragraph stays here."), text)
            let second = try XCTUnwrap(line(lines, containing: "Second paragraph stays below."), text)
            let last = try XCTUnwrap(line(lines, containing: "Last line stays visible."), text)
            let count = try XCTUnwrap(line(lines, containing: "\(body.split(whereSeparator: \.isWhitespace).count) words"), text)
            XCTAssertLessThan(first.box.maxY, second.box.minY, "Paragraphs remain separate")
            XCTAssertLessThan(second.box.maxY, last.box.minY, "Line breaks are not collapsed into the preview")
            XCTAssertLessThan(last.box.maxY, count.box.minY, "The word count sits below the body")
            XCTAssertNil(line(lines, containing: "Start writing"), "Saved text replaces the placeholder")
            XCTAssertNil(line(lines, containing: "A place for your thoughts"), "Opening a note replaces the index")
            assertInsideCard(lines, rendered: rendered)
        }
    }

    func testANewUntitledNoteHasAnEditorPlaceholderAndZeroWords() async throws {
        let store = NotesStore(storageURL: nil)
        _ = store.addNote()
        let rendered = try await render(director(store))
        let lines = try read(rendered)
        let text = transcript(lines)
        XCTAssertNotNil(line(lines, containing: "Untitled"), text)
        XCTAssertNotNil(line(lines, containing: "Start writing"), text)
        XCTAssertNotNil(line(lines, containing: "0 words"), text)
        XCTAssertNil(line(lines, containing: "A place for your thoughts"), "A new note is already open")
        assertInsideCard(lines, rendered: rendered)
    }

    func testAnOverflowingBodyScrollsAboveThePinnedWordCount() async throws {
        let body = (["Opening paragraph stays visible."]
            + (1...24).map { "Another paragraph number \($0)." }
            + ["Final paragraph waits below."]).joined(separator: "\n")
        let store = NotesStore(storageURL: nil)
        createNote(store, title: "Long notebook", body: body)
        let rendered = try await render(director(store))
        let lines = try read(rendered)
        let text = transcript(lines)
        XCTAssertNotNil(line(lines, containing: "Opening paragraph stays visible."), text)
        XCTAssertNil(line(lines, containing: "Final paragraph waits below."), "Overflow must not paint past the editor")
        let count = try XCTUnwrap(line(lines, containing: "\(body.split(whereSeparator: \.isWhitespace).count) words"), text)
        for paragraph in lines where paragraph.text.contains("paragraph") {
            XCTAssertLessThan(paragraph.box.maxY, count.box.minY,
                              "The scrolling body cannot overlap its word count: \(paragraph.text)")
        }
        assertInsideCard(lines, rendered: rendered)
    }

    func testReturningToTheIndexKeepsTheNotesAndReopeningKeepsTheBody() async throws {
        let store = NotesStore(storageURL: nil)
        let id = createNote(store, title: "Trip plans", body: "Pack the notebook.\nLeave after breakfast.")
        let original = store.notes
        let director = director(store)
        director.openTray(at: .notes)

        store.select(nil)
        XCTAssertNil(store.selected)
        XCTAssertEqual(director.tray.page, .notes, "Back from a note stays on the Notes index")
        let index = try read(await render(director))
        XCTAssertNotNil(line(index, containing: "Trip plans"), transcript(index))
        XCTAssertNil(line(index, containing: "words"))
        XCTAssertEqual(store.notes, original, "Returning to the list does not edit or delete anything")

        store.select(id)
        let reopened = try read(await render(director))
        XCTAssertNotNil(line(reopened, containing: "Pack the notebook."), transcript(reopened))
        XCTAssertNotNil(line(reopened, containing: "Leave after breakfast."), transcript(reopened))
        XCTAssertEqual(store.notes, original)
    }

    func testDeletingTheOpenNoteReturnsToTheIndexAndUndoRestoresItsEditor() async throws {
        let store = NotesStore(storageURL: nil)
        let id = createNote(store, title: "Coffee ideas", body: "Bring a blue notebook.")
        let director = director(store)
        store.delete(id)
        let deleted = try read(await render(director))
        XCTAssertNotNil(line(deleted, containing: "A place for your thoughts"), transcript(deleted))
        XCTAssertNotNil(line(deleted, containing: "Undo"), transcript(deleted))
        XCTAssertNil(store.selected)

        store.undo()
        let restored = try read(await render(director))
        XCTAssertNotNil(line(restored, containing: "Coffee ideas"), transcript(restored))
        XCTAssertNotNil(line(restored, containing: "Bring a blue notebook."), transcript(restored))
        XCTAssertNil(line(restored, containing: "Undo"))
        XCTAssertEqual(store.selectedID, id)
        XCTAssertEqual(store.notes.count, 1)
    }

    // MARK: Tool lifecycle

    func testNotesOpensItsOwnCardAndHidingItReturnsToTheMenuWithoutDeletingAnything() {
        let store = NotesStore(storageURL: nil)
        let id = createNote(store, title: "Saved locally", body: "Keep this note when the tool is hidden.")
        let menu = ToolMenuModel(defaults: defaults())
        let director = director(store, toolMenu: menu)
        let original = store.notes

        XCTAssertTrue(menu.isEnabled(.notes))
        XCTAssertEqual(TrayTool.notes.title, "Notes")
        XCTAssertEqual(TrayTool.notes.page, .notes)
        director.showTool(.notes)
        XCTAssertEqual(director.tray.page, .notes)
        XCTAssertEqual(director.presentationCard(player: player).width, 460)
        XCTAssertEqual(director.presentationCard(player: player).height, 348)

        menu.setEnabled(.notes, false)
        XCTAssertEqual(director.tray.page, .main)
        XCTAssertFalse(menu.visible.contains(.notes))
        XCTAssertEqual(store.notes, original)
        XCTAssertEqual(store.selectedID, id, "Hiding a tool must not discard the open note")

        director.showTool(.notes)
        XCTAssertEqual(director.tray.page, .notes, "Hiding removes only the menu entry")
        XCTAssertEqual(director.notes.selected?.body, "Keep this note when the tool is hidden.")
    }

    // MARK: Real AppKit body editing (no key window or external input required)

    private final class EditorEvents {
        var changes: [String] = []
        var keyboardRequests = 0
        var focused = false
        var escapes = 0
    }

    private struct EditorFixture {
        let store: NotesStore
        let id: UUID
        let events: EditorEvents
        let host: NSHostingView<NotesBodyEditor>
        let window: NSWindow
        let view: NotesTextView
    }

    private func bodyEditor(_ store: NotesStore, id: UUID, events: EditorEvents) -> NotesBodyEditor {
        NotesBodyEditor(text: store.notes.first(where: { $0.id == id })?.body ?? "", onChange: {
            events.changes.append($0)
            store.updateBody(id, to: $0)
        }, requestKeyboard: { events.keyboardRequests += 1 }, focusChanged: { events.focused = $0 },
           escape: { events.escapes += 1 })
    }

    private func nativeEditor(initialBody: String = "") async throws -> EditorFixture {
        let store = NotesStore(storageURL: nil)
        let id = createNote(store, title: "Native editor", body: initialBody)
        let events = EditorEvents()
        let host = NSHostingView(rootView: bodyEditor(store, id: id, events: events))
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 220)
        let window = NotchPanel()
        window.setContentSize(host.frame.size)
        window.contentView = host
        var succeeded = false
        defer { if !succeeded { window.close() } }

        // Realizing an NSViewRepresentable needs a hosting hierarchy, not an activated app. Keep this window hidden;
        // NSTextView's native insertion/paragraph commands and delegate notifications work without a key window.
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            if let view = notesTextView(in: host) {
                succeeded = true
                return EditorFixture(store: store, id: id, events: events, host: host, window: window, view: view)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let view = try XCTUnwrap(notesTextView(in: host), "NotesBodyEditor must create its native scroll and text views")
        succeeded = true
        return EditorFixture(store: store, id: id, events: events, host: host, window: window, view: view)
    }

    private func notesTextView(in view: NSView) -> NotesTextView? {
        if let scroll = view as? NSScrollView, let text = scroll.documentView as? NotesTextView { return text }
        for child in view.subviews {
            if let text = notesTextView(in: child) { return text }
        }
        return nil
    }

    func testTheNativeEditorInsertsParagraphsAndUnicodeThroughItsDelegateIntoTheStore() async throws {
        let fixture = try await nativeEditor()
        defer { fixture.window.close() }
        let view = fixture.view

        XCTAssertTrue(view.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "First paragraph."))
        view.insertText("First paragraph.", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertNewline(nil)
        view.insertNewline(nil)
        view.insertText("Café 👋🏽 and 世界", replacementRange: NSRange(location: NSNotFound, length: 0))

        let expected = "First paragraph.\n\nCafé 👋🏽 and 世界"
        XCTAssertEqual(view.string, expected)
        XCTAssertEqual(fixture.events.changes.last, expected, "NSTextView.didChangeText must reach the coordinator")
        XCTAssertTrue(fixture.events.changes.contains("First paragraph.\n\n"), "Return inserts real paragraphs")
        XCTAssertEqual(fixture.store.selected?.body, expected, "The binding receives the complete Unicode body")
        XCTAssertEqual(view.selectedRange(), NSRange(location: (expected as NSString).length, length: 0),
                       "AppKit selection uses UTF-16 offsets, including emoji and non-Latin text")
    }

    func testUndoAndRedoShortcutsUpdateTheSavedNoteBody() async throws {
        let fixture = try await nativeEditor(initialBody: "First line.")
        defer { fixture.window.close() }
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.view))
        let original = fixture.view.string
        let insertion = NSRange(location: original.utf16.count, length: 0)
        fixture.view.insertText("\nCafé 👋", replacementRange: insertion)
        let edited = "First line.\nCafé 👋"
        XCTAssertEqual(fixture.store.selected?.body, edited)

        for (shift, expected) in [(false, original), (true, edited)] {
            let character = shift ? "Z" : "z"
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shift ? [.command, .shift] : [.command], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: UInt16(kVK_ANSI_Z)))
            XCTAssertTrue(fixture.window.performKeyEquivalent(with: event))
            XCTAssertEqual(fixture.view.string, expected)
            XCTAssertEqual(fixture.store.selected?.body, expected)
        }
    }

    func testRenderingTheSameSavedBodyDoesNotResetNativeSelectionOrReplaceTheEditor() async throws {
        let fixture = try await nativeEditor(initialBody: "Plan the first paragraph.")
        defer { fixture.window.close() }
        fixture.view.setSelectedRange(NSRange(location: 5, length: 3))
        fixture.view.insertText("our", replacementRange: NSRange(location: NSNotFound, length: 0))
        let body = fixture.view.string
        let selection = NSRange(location: 5, length: 3)
        fixture.view.setSelectedRange(selection)
        let changes = fixture.events.changes

        fixture.host.rootView = bodyEditor(fixture.store, id: fixture.id, events: fixture.events)
        fixture.host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        fixture.host.layoutSubtreeIfNeeded()

        let updated = try XCTUnwrap(notesTextView(in: fixture.host))
        XCTAssertTrue(updated === fixture.view, "Saving text must update the existing native editor")
        XCTAssertEqual(updated.string, body)
        XCTAssertEqual(fixture.store.selected?.body, body)
        XCTAssertEqual(updated.selectedRange(), selection, "A model echo must not move the insertion point")
        XCTAssertEqual(fixture.events.changes, changes, "Rendering the saved model must not emit another edit")
    }

    func testTheNativeEditorRejectsAnOversizedEditBeforeChangingItsText() async throws {
        let fixture = try await nativeEditor(initialBody: "Keep this paragraph.")
        defer { fixture.window.close() }
        let original = fixture.view.string
        let insertion = NSRange(location: (original as NSString).length, length: 0)
        let tooLong = String(repeating: "x", count: NotesStore.bodyLimit)

        XCTAssertFalse(fixture.view.shouldChangeText(in: insertion, replacementString: tooLong),
                       "The coordinator must reject the proposal, not save a truncated version after typing")
        XCTAssertEqual(fixture.view.string, original)
        XCTAssertEqual(fixture.store.selected?.body, original)
        XCTAssertTrue(fixture.events.changes.isEmpty)
    }

    func testEscapeIsHandledLocallyByTheNativeEditor() async throws {
        let fixture = try await nativeEditor(initialBody: "An unfinished thought.")
        defer { fixture.window.close() }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))

        fixture.view.keyDown(with: event)

        XCTAssertEqual(fixture.events.escapes, 1, "Escape releases the Notes editor instead of inserting text")
        XCTAssertEqual(fixture.view.string, "An unfinished thought.")
        XCTAssertEqual(fixture.store.selected?.body, "An unfinished thought.")
        XCTAssertTrue(fixture.events.changes.isEmpty)
    }
}
