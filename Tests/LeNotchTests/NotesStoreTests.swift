import XCTest
@testable import Lenotch

@MainActor
final class NotesStoreTests: XCTestCase {
    private var directories: [URL] = []
    private let noon = Date(timeIntervalSince1970: 1_700_000_000.25)

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func temporaryFile() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lenotch-notes-\(UUID().uuidString)")
        directories.append(directory)
        return directory.appendingPathComponent("lenotch", isDirectory: true).appendingPathComponent("notes.json")
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func savedNote(_ id: UUID = UUID(), title: String = "A note") -> [String: Any] {
        ["id": id.uuidString, "title": title, "body": "Some text", "createdAt": "2024-01-01T00:00:00Z",
         "updatedAt": "2024-01-01T00:00:01Z"]
    }

    private func assertSame(_ actual: [NoteItem], _ expected: [NoteItem],
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map(\.id), expected.map(\.id), file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.title, b.title, file: file, line: line)
            XCTAssertEqual(a.body, b.body, file: file, line: line)
            XCTAssertEqual(a.createdAt.timeIntervalSince1970, b.createdAt.timeIntervalSince1970, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(a.updatedAt.timeIntervalSince1970, b.updatedAt.timeIntervalSince1970, accuracy: 0.001, file: file, line: line)
        }
    }

    func testFreshStoreHasNoFakeNotesAndWritesNothing() {
        let url = temporaryFile()
        let store = NotesStore(storageURL: url)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(store.orderedNotes.isEmpty)
        XCTAssertNil(store.selectedID)
        XCTAssertNil(store.selected)
        XCTAssertNil(store.storageError)
        XCTAssertNil(store.removal)
        store.select(nil)
        store.select(UUID())
        store.updateTitle(UUID(), to: "Unknown")
        store.updateBody(UUID(), to: "Unknown")
        store.delete(UUID())
        store.undo()
        store.dismissUndo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDefaultLocationIsNotesJSONBesideTodosWithoutReadingUserFiles() {
        XCTAssertEqual(NotesStore.defaultStorageURL.lastPathComponent, "notes.json")
        XCTAssertEqual(NotesStore.defaultStorageURL.deletingLastPathComponent(), TodoStore.defaultStorageURL.deletingLastPathComponent())
    }

    func testDisplayTitleAndPreviewUseReadableFallbacks() {
        XCTAssertEqual(NoteItem().displayTitle, "Untitled note")
        XCTAssertEqual(NoteItem(title: " \n\t ").displayTitle, "Untitled note")
        XCTAssertEqual(NoteItem(title: "  A title  ").displayTitle, "A title")
        XCTAssertEqual(NoteItem().preview, "No text yet")
        XCTAssertEqual(NoteItem(body: " \n\r\n \t ").preview, "No text yet")
        XCTAssertEqual(NoteItem(body: "\n \t\r\n  First useful line 📝  \nNext line").preview, "First useful line 📝")
    }

    func testAddingCreatesAnEmptyNoteAndOpensIt() throws {
        let store = NotesStore(storageURL: nil)
        let first = store.addNote(now: noon)
        XCTAssertEqual(store.selectedID, first)
        let note = try XCTUnwrap(store.selected)
        XCTAssertEqual(note.title, "")
        XCTAssertEqual(note.body, "")
        XCTAssertEqual(note.createdAt, noon)
        XCTAssertEqual(note.updatedAt, noon)
        let second = store.addNote(now: noon.addingTimeInterval(10))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.notes.map(\.id), [first, second])
        XCTAssertEqual(store.selectedID, second)
    }

    func testSelectingNilReturnsToIndexAndUnknownIDsDoNothing() {
        let store = NotesStore(storageURL: nil)
        let first = store.addNote(), second = store.addNote()
        store.select(first)
        XCTAssertEqual(store.selected?.id, first)
        store.select(UUID())
        XCTAssertEqual(store.selected?.id, first)
        store.select(nil)
        XCTAssertNil(store.selected)
        XCTAssertNil(store.selectedID)
        store.select(UUID())
        XCTAssertNil(store.selectedID)
        store.select(second)
        XCTAssertEqual(store.selected?.id, second)
    }

    func testTitleIsOneLineAndPreservesTypingSpacesButDisplayTrimsThem() throws {
        let store = NotesStore(storageURL: nil)
        let id = store.addNote(now: noon)
        store.updateTitle(id, to: "  Plan\nfor\r\nFriday  ", now: noon.addingTimeInterval(1))
        XCTAssertEqual(store.selected?.title, "  Plan for  Friday  ")
        XCTAssertEqual(store.selected?.displayTitle, "Plan for  Friday")
        XCTAssertEqual(store.selected?.createdAt, noon)
        XCTAssertEqual(store.selected?.updatedAt, noon.addingTimeInterval(1))
        store.updateTitle(id, to: " \n\t ", now: noon.addingTimeInterval(2))
        XCTAssertEqual(store.selected?.title, "  \t ")
        XCTAssertEqual(store.selected?.displayTitle, "Untitled note")
    }

    func testMultiwordTitleCanBeTypedOneKeystrokeAtATime() {
        let store = NotesStore(storageURL: nil)
        let id = store.addNote()
        for character in "Meeting notes" {
            store.updateTitle(id, to: (store.selected?.title ?? "") + String(character))
        }
        XCTAssertEqual(store.selected?.title, "Meeting notes", "A live binding must not swallow the space keystroke")
    }

    func testTitleLimitDoesNotSplitUnicodeCharacters() throws {
        let store = NotesStore(storageURL: nil)
        let id = store.addNote()
        let glyph = "👩🏽‍💻"
        store.updateTitle(id, to: String(repeating: glyph, count: 140))
        XCTAssertEqual(store.selected?.title, String(repeating: glyph, count: NotesStore.titleLimit))
    }

    func testBodyPreservesWhitespaceUnicodeAndNewlines() {
        let store = NotesStore(storageURL: nil)
        let id = store.addNote(now: noon)
        let body = "\n  Keep indentation\r\n\t你好, café 👨‍👩‍👧‍👦\n\nLast line  \n"
        store.updateBody(id, to: body, now: noon.addingTimeInterval(1))
        XCTAssertEqual(store.selected?.body, body)
        XCTAssertEqual(store.selected?.createdAt, noon)
        XCTAssertEqual(store.selected?.updatedAt, noon.addingTimeInterval(1))
        store.updateBody(id, to: "", now: noon.addingTimeInterval(2))
        XCTAssertEqual(store.selected?.body, "")
    }

    func testBodyLimitDoesNotSplitUnicodeCharacters() {
        let store = NotesStore(storageURL: nil)
        let id = store.addNote()
        let glyph = "é"
        store.updateBody(id, to: String(repeating: glyph, count: NotesStore.bodyLimit + 2))
        XCTAssertEqual(store.selected?.body.count, NotesStore.bodyLimit)
        XCTAssertEqual(store.selected?.body, String(repeating: glyph, count: NotesStore.bodyLimit))
    }

    func testUnchangedSanitizedEditsDoNotTouchTimestampOrDisk() throws {
        let url = temporaryFile()
        let store = NotesStore(storageURL: url)
        let id = store.addNote(now: noon)
        store.updateTitle(id, to: "Title", now: noon.addingTimeInterval(1))
        store.updateBody(id, to: "Body\n", now: noon.addingTimeInterval(2))
        let original = try Data(contentsOf: url)
        store.updateTitle(id, to: "Title", now: noon.addingTimeInterval(3))
        store.updateBody(id, to: "Body\n", now: noon.addingTimeInterval(4))
        store.updateTitle(UUID(), to: "Not here")
        store.updateBody(UUID(), to: "Not here")
        store.select(id)
        XCTAssertEqual(store.selected?.updatedAt, noon.addingTimeInterval(2))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testUpdatedNewestFirstAndCreationBreaksTies() {
        let store = NotesStore(storageURL: nil)
        let old = store.addNote(now: noon), recent = store.addNote(now: noon.addingTimeInterval(1))
        XCTAssertEqual(store.orderedNotes.map(\.id), [recent, old])
        store.updateBody(old, to: "Edited", now: noon.addingTimeInterval(2))
        XCTAssertEqual(store.orderedNotes.map(\.id), [old, recent])
        store.updateBody(recent, to: "Also edited", now: noon.addingTimeInterval(2))
        XCTAssertEqual(store.orderedNotes.map(\.id), [recent, old])
        XCTAssertEqual(store.notes.map(\.id), [old, recent], "The display order does not change storage positions")
    }

    func testIdenticalTimestampsHaveStableIDOrderAcrossRestart() throws {
        let url = temporaryFile()
        let store = NotesStore(storageURL: url)
        for _ in 0..<8 { store.addNote(now: noon) }
        let expected = store.notes.map(\.id).sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(store.orderedNotes.map(\.id), expected)
        XCTAssertEqual(store.orderedNotes.map(\.id), expected)
        XCTAssertEqual(NotesStore(storageURL: url).orderedNotes.map(\.id), expected)
    }

    func testDeletingSelectedReturnsToIndexAndUndoRestoresAndOpensIt() throws {
        let store = NotesStore(storageURL: nil)
        let a = store.addNote(now: noon), b = store.addNote(now: noon.addingTimeInterval(-5)), c = store.addNote(now: noon.addingTimeInterval(5))
        store.updateTitle(b, to: "Middle", now: noon.addingTimeInterval(20))
        let before = store.notes
        let order = store.orderedNotes
        store.select(b)
        store.delete(b)
        XCTAssertEqual(store.notes.map(\.id), [a, c])
        XCTAssertNil(store.selected)
        XCTAssertEqual(store.removal?.note, before[1])
        XCTAssertEqual(store.removal?.index, 1)
        store.undo()
        XCTAssertEqual(store.notes, before)
        XCTAssertEqual(store.orderedNotes, order)
        XCTAssertEqual(store.selected?.id, b)
        XCTAssertNil(store.removal)
    }

    func testDeletingAnotherNoteLeavesSelectionAndDeletingAllLeavesEmptyIndex() {
        let store = NotesStore(storageURL: nil)
        let a = store.addNote(), b = store.addNote()
        store.delete(a)
        XCTAssertEqual(store.selectedID, b)
        store.delete(b)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNil(store.selectedID)
        store.delete(UUID())
        XCTAssertEqual(store.removal?.note.id, b)
    }

    func testOnlyLastDeletionCanBeUndoneAndDismissUndoIsFinal() {
        let store = NotesStore(storageURL: nil)
        let a = store.addNote(), b = store.addNote()
        store.delete(a)
        let firstRemoval = store.removal?.id
        store.delete(b)
        XCTAssertNotEqual(store.removal?.id, firstRemoval)
        store.undo()
        XCTAssertEqual(store.notes.map(\.id), [b])
        store.undo()
        XCTAssertEqual(store.notes.map(\.id), [b])
        store.delete(b)
        store.dismissUndo()
        store.undo()
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNil(store.removal)
    }

    func testMultipleNotesBodyDatesAndSelectionSurviveRestart() throws {
        let url = temporaryFile()
        let store = NotesStore(storageURL: url)
        let a = store.addNote(now: noon), b = store.addNote(now: noon.addingTimeInterval(0.3))
        store.updateTitle(a, to: "中文 📝", now: noon.addingTimeInterval(0.4))
        store.updateBody(a, to: "\n  First line\r\nSecond line\n\n🎉  \n", now: noon.addingTimeInterval(0.5))
        store.updateBody(b, to: "Another", now: noon.addingTimeInterval(0.6))
        store.select(a)
        let restored = NotesStore(storageURL: url)
        XCTAssertNil(restored.storageError)
        assertSame(restored.notes, store.notes)
        XCTAssertEqual(restored.selected?.id, a)
        XCTAssertEqual(restored.orderedNotes.map(\.id), [b, a])
        XCTAssertNil(restored.removal, "Undo is only for the current session")
        store.select(nil)
        XCTAssertNil(NotesStore(storageURL: url).selected, "The index is also a saved selection")
    }

    func testEachMutationIsSavedImmediatelyIncludingDeletionAndUndo() throws {
        let url = temporaryFile()
        let store = NotesStore(storageURL: url)
        let id = store.addNote(now: noon)
        XCTAssertEqual(NotesStore(storageURL: url).selected?.id, id)
        store.updateTitle(id, to: "Title", now: noon.addingTimeInterval(1))
        XCTAssertEqual(NotesStore(storageURL: url).selected?.title, "Title")
        store.updateBody(id, to: "Body", now: noon.addingTimeInterval(2))
        XCTAssertEqual(NotesStore(storageURL: url).selected?.body, "Body")
        store.delete(id)
        XCTAssertTrue(NotesStore(storageURL: url).notes.isEmpty)
        XCTAssertNil(NotesStore(storageURL: url).selected)
        store.undo()
        XCTAssertEqual(NotesStore(storageURL: url).selected?.id, id)
        store.select(nil)
        XCTAssertNil(NotesStore(storageURL: url).selected)
    }

    func testPlainVersionedJSONContainsAllFieldsAndLeavesNoTemporaryFiles() throws {
        let url = temporaryFile()
        let store = NotesStore(storageURL: url)
        let id = store.addNote(now: noon)
        store.updateTitle(id, to: "Readable", now: noon.addingTimeInterval(0.3))
        store.updateBody(id, to: "Text\nText", now: noon.addingTimeInterval(0.4))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["selectedID"] as? String, id.uuidString)
        let notes = try XCTUnwrap(object["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.first?["title"] as? String, "Readable")
        XCTAssertEqual(notes.first?["body"] as? String, "Text\nText")
        XCTAssertEqual(notes.first?["createdAt"] as? String, "2023-11-14T22:13:20.250Z")
        let updatedText = try XCTUnwrap(notes.first?["updatedAt"] as? String)
        let updated = try Date(updatedText, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        XCTAssertEqual(updated.timeIntervalSince1970, noon.addingTimeInterval(0.4).timeIntervalSince1970,
                       accuracy: 0.0011, "ISO dates retain millisecond precision without depending on binary-double rounding")
        let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map(\.lastPathComponent), ["notes.json"])
    }

    func testWholeSecondDatesLoadAndMissingOrUnknownSelectionShowsIndex() throws {
        let url = temporaryFile()
        let note = savedNote()
        for selection in [nil, UUID().uuidString] as [String?] {
            var json: [String: Any] = ["version": 1, "notes": [note]]
            json["selectedID"] = selection
            try write(JSONSerialization.data(withJSONObject: json), to: url)
            let store = NotesStore(storageURL: url)
            XCTAssertNil(store.storageError)
            XCTAssertEqual(store.notes.map(\.title), ["A note"])
            XCTAssertNil(store.selectedID)
            XCTAssertNil(store.selected)
            XCTAssertEqual(store.notes.first?.updatedAt.timeIntervalSince1970, 1_704_067_201)
        }
    }

    func testCorruptFileStaysUntouchedUntilFirstMutationThenIsBackedUp() throws {
        let url = temporaryFile()
        let broken = Data("broken notes\n".utf8)
        try write(broken, to: url)
        let store = NotesStore(storageURL: url)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(store.storageError?.contains("couldn’t be loaded") == true)
        XCTAssertEqual(try Data(contentsOf: url), broken)
        var files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let id = store.addNote(now: noon)
        files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("notes.recovered-") })
        XCTAssertEqual(try Data(contentsOf: backup), broken)
        XCTAssertEqual(NotesStore(storageURL: url).selected?.id, id)
        XCTAssertTrue(store.storageError?.contains(backup.lastPathComponent) == true)
        store.updateTitle(id, to: "Continue")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).count, 2)
    }

    func testDuplicateIdentifiersAreRejectedWithoutPartialRestore() throws {
        let url = temporaryFile()
        let id = UUID(), note = savedNote(id)
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "notes": [note, note], "selectedID": id.uuidString])
        try write(data, to: url)
        let store = NotesStore(storageURL: url)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNil(store.selected)
        XCTAssertTrue(store.storageError?.contains("duplicate") == true)
        XCTAssertEqual(try Data(contentsOf: url), data)
        store.addNote()
        let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("notes.recovered-") })
        XCTAssertEqual(try Data(contentsOf: backup), data)
    }

    func testUnsupportedVersionsNeverGetOverwrittenEvenWithAnUnknownSchema() throws {
        for version in [0, 2, 1_000] {
            let url = temporaryFile()
            let data = Data("{\"version\":\(version),\"futureNotes\":{\"doNotReplace\":true}}".utf8)
            try write(data, to: url)
            let store = NotesStore(storageURL: url)
            XCTAssertTrue(store.notes.isEmpty)
            XCTAssertTrue(store.storageError?.contains("unsupported format") == true)
            let id = store.addNote()
            store.updateTitle(id, to: "Memory only")
            store.updateBody(id, to: "Still editable")
            store.select(nil)
            store.select(id)
            store.delete(id)
            store.undo()
            XCTAssertEqual(store.selected?.body, "Still editable")
            XCTAssertTrue(store.storageError?.contains("unsupported format") == true)
            XCTAssertEqual(try Data(contentsOf: url), data)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).count, 1)
        }
    }

    func testMalformedNoteDatesAreRecoverableErrors() throws {
        let url = temporaryFile()
        var note = savedNote()
        note["updatedAt"] = "not a date"
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "notes": [note]])
        try write(data, to: url)
        let store = NotesStore(storageURL: url)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testFailedSaveKeepsEditsInMemoryAndCanRetryAfterStorageIsRepaired() throws {
        let url = temporaryFile()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let blocker = Data("not a directory".utf8)
        try blocker.write(to: directory)
        let store = NotesStore(storageURL: url)
        let id = store.addNote(now: noon)
        XCTAssertEqual(store.selected?.id, id)
        XCTAssertTrue(store.storageError?.contains("couldn’t be saved") == true)
        XCTAssertEqual(try Data(contentsOf: directory), blocker)
        try FileManager.default.removeItem(at: directory)
        store.updateBody(id, to: "Saved after repair")
        XCTAssertNil(store.storageError)
        XCTAssertEqual(NotesStore(storageURL: url).selected?.body, "Saved after repair")
    }

    func testDeletingCorruptFileAllowsRecoveryWithoutInventingABackup() throws {
        let url = temporaryFile()
        try write(Data("bad".utf8), to: url)
        let store = NotesStore(storageURL: url)
        XCTAssertNotNil(store.storageError)
        try FileManager.default.removeItem(at: url)
        let id = store.addNote()
        XCTAssertNil(store.storageError)
        XCTAssertEqual(NotesStore(storageURL: url).selected?.id, id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).map(\.lastPathComponent), ["notes.json"])
    }

    func testExistingFileThatCannotBeBackedUpIsNeverOverwritten() throws {
        let url = temporaryFile()
        let manager = FileManager.default
        let original = Data("unreadable original".utf8)
        try write(original, to: url)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        guard !manager.isReadableFile(atPath: url.path) else { throw XCTSkip("This user bypasses file read permissions") }
        let store = NotesStore(storageURL: url)
        XCTAssertNotNil(store.storageError)
        let id = store.addNote()
        XCTAssertTrue(store.storageError?.contains("couldn’t be saved") == true)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original)
        store.updateBody(id, to: "Saved after repair")
        XCTAssertEqual(NotesStore(storageURL: url).selected?.body, "Saved after repair")
        let backup = try XCTUnwrap(manager.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("notes.recovered-") })
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }
}
