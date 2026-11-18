import XCTest
@testable import Lenotch

@MainActor
final class TodoStoreTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lenotch-todo-\(UUID().uuidString)")
        directories.append(directory)
        return directory.appendingPathComponent("lenotch", isDirectory: true).appendingPathComponent("todos.json")
    }

    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    private func store() -> TodoStore { TodoStore(storageURL: nil) }

    // MARK: Lists

    func testAFreshStoreStartsWithOneEmptyListToTypeInto() {
        let store = store()
        XCTAssertEqual(store.lists.map(\.title), ["Tasks"])
        XCTAssertEqual(store.selected?.id, store.lists[0].id)
        XCTAssertTrue(store.lists[0].items.isEmpty)
        XCTAssertEqual(store.openCount, 0)
        XCTAssertNil(store.removal)
    }

    func testAListNeedsAName() {
        let store = store()
        XCTAssertNil(store.addList("   "))
        XCTAssertNil(store.addList("\n"))
        let id = store.addList("  Groceries \n")
        XCTAssertEqual(store.list(try! XCTUnwrap(id))?.title, "Groceries")
        XCTAssertEqual(store.selected?.id, id, "A new list is shown at once")
        XCTAssertEqual(store.lists.map(\.title), ["Tasks", "Groceries"])
        let long = store.addList(String(repeating: "x", count: 90))
        XCTAssertEqual(store.list(try! XCTUnwrap(long))?.title.count, TodoStore.listTitleLimit)
    }

    func testSelectingAndRenamingLists() throws {
        let store = store()
        let first = store.lists[0].id
        let second = try XCTUnwrap(store.addList("Work"))
        store.selectList(first)
        XCTAssertEqual(store.selected?.id, first)
        store.selectList(UUID())
        XCTAssertEqual(store.selected?.id, first, "An unknown list changes nothing")
        store.renameList(second, to: "  Work stuff ")
        XCTAssertEqual(store.list(second)?.title, "Work stuff")
        store.renameList(second, to: "   ")
        XCTAssertEqual(store.list(second)?.title, "Work stuff", "An empty name keeps the old one")
    }

    func testDeletingTheListShownShowsItsNeighbourAndTheLastLeavesNone() throws {
        let store = store()
        let a = store.lists[0].id
        let b = try XCTUnwrap(store.addList("B")), c = try XCTUnwrap(store.addList("C"))
        store.selectList(b)
        store.deleteList(b)
        XCTAssertEqual(store.selected?.id, c, "The one that took its place")
        store.deleteList(c)
        XCTAssertEqual(store.selected?.id, a)
        store.deleteList(a)
        XCTAssertTrue(store.lists.isEmpty)
        XCTAssertNil(store.selected)
        XCTAssertNil(store.addItem("Nowhere to go"), "A to-do needs a list")
        store.deleteList(a)   // already gone: nothing
    }

    func testDeletingAnotherListLeavesTheOneShown() throws {
        let store = store()
        let a = store.lists[0].id
        let b = try XCTUnwrap(store.addList("B"))
        store.selectList(a)
        store.deleteList(b)
        XCTAssertEqual(store.selected?.id, a)
    }

    // MARK: To-dos

    func testToDosAreTidiedAndAddedToTheListShown() throws {
        let store = store()
        let id = try XCTUnwrap(store.addItem("  Buy milk  ", now: noon))
        XCTAssertEqual(store.selected?.items.map(\.title), ["Buy milk"])
        XCTAssertEqual(store.selected?.items[0].createdAt, noon)
        XCTAssertEqual(store.selected?.items[0].id, id)
        XCTAssertNil(store.addItem(""))
        XCTAssertNil(store.addItem("  \n "))
        _ = store.addItem("Line one\nline two")
        XCTAssertEqual(store.selected?.items.last?.title, "Line one line two", "A pasted paragraph becomes one line")
        let long = String(repeating: "y", count: 500)
        _ = store.addItem(long)
        XCTAssertEqual(store.selected?.items.last?.title.count, TodoStore.titleLimit)
    }

    func testAToDoCanGoToAListThatIsNotShown() throws {
        let store = store()
        let first = store.lists[0].id
        _ = store.addList("Other")
        XCTAssertNotNil(store.addItem("For the first", to: first))
        XCTAssertEqual(store.list(first)?.items.count, 1)
        XCTAssertEqual(store.selected?.items.count, 0)
        XCTAssertNil(store.addItem("Lost", to: UUID()))
    }

    func testTickingMovesAToDoToDoneAndBackAndKeepsTheOrder() throws {
        let store = store()
        let a = try XCTUnwrap(store.addItem("A", now: noon)), b = try XCTUnwrap(store.addItem("B", now: noon)),
            c = try XCTUnwrap(store.addItem("C", now: noon))
        store.toggle(a, now: noon.addingTimeInterval(10))
        store.toggle(c, now: noon.addingTimeInterval(20))
        let list = try XCTUnwrap(store.selected)
        XCTAssertEqual(list.open.map(\.title), ["B"])
        XCTAssertEqual(list.done.map(\.title), ["C", "A"], "The one finished last comes first")
        XCTAssertEqual(list.openCount, 1)
        XCTAssertEqual(store.openCount, 1)
        XCTAssertEqual(list.items[0].completedAt, noon.addingTimeInterval(10))
        store.toggle(a)
        XCTAssertEqual(store.selected?.open.map(\.title), ["A", "B"], "Unticked, it is back where it was added")
        XCTAssertNil(store.selected?.items[0].completedAt)
        store.toggle(UUID())   // unknown: nothing
        _ = b
    }

    func testRenamingAndDeletingToDos() throws {
        let store = store()
        let a = try XCTUnwrap(store.addItem("A")), b = try XCTUnwrap(store.addItem("B"))
        store.renameItem(a, to: "  Alpha ")
        XCTAssertEqual(store.selected?.items.map(\.title), ["Alpha", "B"])
        store.renameItem(a, to: " ")
        XCTAssertEqual(store.selected?.items.map(\.title), ["Alpha", "B"], "An empty text keeps the old one")
        store.deleteItem(a)
        XCTAssertEqual(store.selected?.items.map(\.id), [b])
        store.deleteItem(a)   // already gone
        XCTAssertEqual(store.selected?.items.count, 1)
    }

    func testTheOpenCountAddsUpEveryList() throws {
        let store = store()
        _ = store.addItem("one"); _ = store.addItem("two")
        _ = store.addList("Second")
        let done = try XCTUnwrap(store.addItem("three"))
        _ = store.addItem("four")
        store.toggle(done)
        XCTAssertEqual(store.openCount, 3)
    }

    // MARK: Clearing and undo

    func testClearingTakesOnlyTheFinishedOnesAndUndoBringsThemBack() throws {
        let store = store()
        let a = try XCTUnwrap(store.addItem("A", now: noon)), b = try XCTUnwrap(store.addItem("B", now: noon)),
            c = try XCTUnwrap(store.addItem("C", now: noon))
        store.toggle(a); store.toggle(c)
        store.clearCompleted(in: store.lists[0].id)
        XCTAssertEqual(store.selected?.items.map(\.id), [b])
        XCTAssertEqual(store.removal.map { TodoPage.describe($0) }, "Cleared 2 done")
        store.undo()
        XCTAssertEqual(store.selected?.items.map(\.title), ["A", "B", "C"], "Back in the order they were added")
        XCTAssertEqual(store.selected?.done.count, 2, "Still ticked")
        XCTAssertNil(store.removal)
        store.clearCompleted(in: store.lists[0].id)
        store.undo()
        store.clearCompleted(in: UUID())   // unknown list: nothing to remember
        XCTAssertNil(store.removal)
    }

    func testUndoOfCompletedItemsPreservesInsertionOrderWhenTheClockMovesBackwards() throws {
        let url = try temporaryFile()
        let store = TodoStore(storageURL: url)
        let a = try XCTUnwrap(store.addItem("A", now: noon))
        let b = try XCTUnwrap(store.addItem("B", now: noon.addingTimeInterval(-10)))
        let c = try XCTUnwrap(store.addItem("C", now: noon.addingTimeInterval(-20)))
        let d = try XCTUnwrap(store.addItem("D", now: noon.addingTimeInterval(-30)))
        store.toggle(b)
        store.toggle(d)
        store.clearCompleted(in: store.lists[0].id)
        let e = try XCTUnwrap(store.addItem("E", now: noon.addingTimeInterval(-40)))
        store.undo()
        XCTAssertEqual(store.selected?.items.map(\.id), [a, b, c, d, e], "Undo restores positions, not clock order")
        XCTAssertEqual(TodoStore(storageURL: url).selected?.items.map(\.id), [a, b, c, d, e], "The restored order is saved")
    }

    func testClearingWithNothingDoneChangesNothing() throws {
        let store = store()
        _ = store.addItem("A")
        store.clearCompleted(in: store.lists[0].id)
        XCTAssertNil(store.removal)
    }

    func testUndoPutsADeletedToDoBackWhereItWas() throws {
        let store = store()
        let a = try XCTUnwrap(store.addItem("A")), b = try XCTUnwrap(store.addItem("B")), c = try XCTUnwrap(store.addItem("C"))
        store.toggle(b)
        store.deleteItem(b)
        XCTAssertEqual(store.selected?.items.map(\.id), [a, c])
        XCTAssertEqual(store.removal.map { TodoPage.describe($0) }, "Deleted “B”")
        store.undo()
        XCTAssertEqual(store.selected?.items.map(\.id), [a, b, c])
        XCTAssertEqual(store.selected?.items[1].isDone, true, "It was ticked, and still is")
    }

    func testUndoPutsADeletedListBackWithItsToDosAndShowsIt() throws {
        let store = store()
        let a = store.lists[0].id
        let b = try XCTUnwrap(store.addList("B"))
        _ = store.addItem("inside B")
        let c = try XCTUnwrap(store.addList("C"))
        store.selectList(b)
        store.deleteList(b)
        XCTAssertEqual(store.lists.map(\.id), [a, c])
        XCTAssertEqual(store.removal.map { TodoPage.describe($0) }, "Deleted “B”")
        store.undo()
        XCTAssertEqual(store.lists.map(\.id), [a, b, c], "Back at its place")
        XCTAssertEqual(store.selected?.id, b)
        XCTAssertEqual(store.selected?.items.map(\.title), ["inside B"])
    }

    func testOnlyTheLastDeletionCanBeUndoneAndItCanBeLetGo() throws {
        let store = store()
        let a = try XCTUnwrap(store.addItem("A")), b = try XCTUnwrap(store.addItem("B"))
        store.deleteItem(a)
        let first = store.removal?.id
        store.deleteItem(b)
        XCTAssertNotEqual(store.removal?.id, first, "A newer deletion replaces the offer")
        store.undo()
        XCTAssertEqual(store.selected?.items.map(\.title), ["B"])
        store.undo()   // nothing left to undo
        XCTAssertEqual(store.selected?.items.map(\.title), ["B"])
        store.deleteItem(b)
        store.dismissUndo()
        XCTAssertNil(store.removal)
        store.undo()
        XCTAssertTrue(store.selected?.items.isEmpty == true, "Once let go, it is final")
    }

    func testUndoOfAToDoWhoseListWasDeletedDoesNothingHarmful() throws {
        let store = store()
        let id = try XCTUnwrap(store.addItem("A"))
        store.deleteItem(id)
        store.deleteList(store.lists[0].id)
        store.undo()   // the removal now is the list's: it comes back whole
        XCTAssertEqual(store.lists.count, 1)
        XCTAssertTrue(store.lists[0].items.isEmpty)
    }

    /// The same lists, to the millisecond a date is kept to.
    private func assertSame(_ actual: [TodoList], _ expected: [TodoList], _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map(\.id), expected.map(\.id), message, file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.title, b.title, message, file: file, line: line)
            XCTAssertEqual(a.createdAt.timeIntervalSince1970, b.createdAt.timeIntervalSince1970, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(a.items.map(\.id), b.items.map(\.id), message, file: file, line: line)
            for (x, y) in zip(a.items, b.items) {
                XCTAssertEqual(x.title, y.title, file: file, line: line)
                XCTAssertEqual(x.isDone, y.isDone, file: file, line: line)
                XCTAssertEqual(x.createdAt.timeIntervalSince1970, y.createdAt.timeIntervalSince1970, accuracy: 0.001, file: file, line: line)
                XCTAssertEqual(x.completedAt?.timeIntervalSince1970 ?? -1, y.completedAt?.timeIntervalSince1970 ?? -1, accuracy: 0.001,
                               file: file, line: line)
            }
        }
    }

    // MARK: Files

    func testNothingIsWrittenUntilSomethingChanges() throws {
        let url = try temporaryFile()
        _ = TodoStore(storageURL: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEverythingSurvivesARestart() throws {
        let url = try temporaryFile()
        let store = TodoStore(storageURL: url)
        let today = store.lists[0].id
        let a = try XCTUnwrap(store.addItem("Reply to Sam", now: noon)), b = try XCTUnwrap(store.addItem("Book flights", now: noon.addingTimeInterval(5)))
        store.toggle(a, now: noon.addingTimeInterval(60))
        let work = try XCTUnwrap(store.addList("Work"))
        _ = store.addItem("Ship the notch", now: noon.addingTimeInterval(9))
        store.selectList(today)

        let again = TodoStore(storageURL: url)
        XCTAssertNil(again.storageError)
        assertSame(again.lists, store.lists, "Lists, to-dos, ticks and dates")
        XCTAssertEqual(again.selected?.id, today, "The list that was open")
        XCTAssertEqual(again.list(today)?.items.map(\.id), [a, b])
        XCTAssertEqual(again.list(today)?.items[0].completedAt, noon.addingTimeInterval(60))
        XCTAssertEqual(again.list(work)?.items.map(\.title), ["Ship the notch"])
        XCTAssertEqual(again.openCount, 2)
    }

    func testRealTimestampsKeepTheirFractionsAcrossARestart() throws {
        let url = try temporaryFile()
        let store = TodoStore(storageURL: url)
        let a = try XCTUnwrap(store.addItem("A")), b = try XCTUnwrap(store.addItem("B"))
        let base = Date(timeIntervalSince1970: 1_700_000_000.25)
        store.toggle(a, now: base)
        store.toggle(b, now: base.addingTimeInterval(0.3))   // the same second, a moment later
        let again = TodoStore(storageURL: url)
        XCTAssertEqual(again.selected?.done.map(\.title), ["B", "A"], "Finished last still comes first")
        assertSame(again.lists, store.lists)
    }

    func testFilesWithWholeSecondDatesStillLoad() throws {
        let url = try temporaryFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID().uuidString, item = UUID().uuidString
        let json = #"{"version": 1, "lists": [{"id": "\#(id)", "title": "Old", "createdAt": "2024-01-01T00:00:00Z", "items": "#
            + #"[{"id": "\#(item)", "title": "From a plain date", "isDone": false, "createdAt": "2024-01-01T00:00:01Z"}]}]}"#
        try Data(json.utf8).write(to: url)
        let store = TodoStore(storageURL: url)
        XCTAssertNil(store.storageError)
        XCTAssertEqual(store.selected?.items.map(\.title), ["From a plain date"])
    }

    func testEachChangeIsOnDiskAtOnce() throws {
        let url = try temporaryFile()
        let store = TodoStore(storageURL: url)
        func onDisk() throws -> TodoStore { TodoStore(storageURL: url) }
        let id = try XCTUnwrap(store.addItem("A"))
        XCTAssertEqual(try onDisk().selected?.items.map(\.title), ["A"])
        store.toggle(id)
        XCTAssertEqual(try onDisk().selected?.done.count, 1)
        store.renameItem(id, to: "B")
        XCTAssertEqual(try onDisk().selected?.items.map(\.title), ["B"])
        store.deleteItem(id)
        XCTAssertEqual(try onDisk().selected?.items.count, 0)
        let list = try XCTUnwrap(store.addList("Two"))
        store.renameList(list, to: "Three")
        XCTAssertEqual(try onDisk().lists.map(\.title), ["Tasks", "Three"])
        store.deleteList(list)
        XCTAssertEqual(try onDisk().lists.map(\.title), ["Tasks"])
        store.undo()
        XCTAssertEqual(try onDisk().lists.map(\.title), ["Tasks", "Three"], "Undo is saved too")
    }

    func testTheFileIsPlainVersionedJSON() throws {
        let url = try temporaryFile()
        let store = TodoStore(storageURL: url)
        _ = store.addItem("Readable", now: noon)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, 1)
        let lists = object?["lists"] as? [[String: Any]]
        XCTAssertEqual(lists?.first?["title"] as? String, "Tasks")
        let items = lists?.first?["items"] as? [[String: Any]]
        XCTAssertEqual(items?.first?["title"] as? String, "Readable")
        XCTAssertEqual(items?.first?["createdAt"] as? String, "2023-11-14T22:13:20.000Z", "Dates are ISO 8601")
        let siblings = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(siblings.map(\.lastPathComponent), ["todos.json"], "No temporary files are left behind")
    }

    func testDeletingEveryListIsRemembered() throws {
        let url = try temporaryFile()
        let store = TodoStore(storageURL: url)
        store.deleteList(store.lists[0].id)
        let again = TodoStore(storageURL: url)
        XCTAssertTrue(again.lists.isEmpty, "The starter list comes back only on a first launch")
        XCTAssertNil(again.selected)
        XCTAssertNil(again.storageError)
    }

    func testAFileThatCantBeReadIsKeptAndSetAsideBeforeItIsReplaced() throws {
        let url = try temporaryFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: url)
        let store = TodoStore(storageURL: url)
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(store.lists.map(\.title), ["Tasks"], "You can still type")
        XCTAssertEqual(try Data(contentsOf: url), garbage, "Opening changes nothing")
        _ = store.addItem("Fresh start")
        let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).sorted()
        XCTAssertEqual(files.count, 2)
        let backup = try XCTUnwrap(files.first { $0.hasPrefix("todos.recovered-") })
        XCTAssertEqual(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(backup)), garbage,
                       "The unreadable file is preserved as it was")
        XCTAssertEqual(TodoStore(storageURL: url).selected?.items.map(\.title), ["Fresh start"])
        XCTAssertNotNil(store.storageError, "The notice about the set-aside copy stays")
        _ = store.addItem("Again")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).count, 2,
                       "One copy, not one per save")
    }

    func testAFileFromANewerVersionIsNeverOverwrittenByInMemoryEdits() throws {
        let url = try temporaryFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version": 2, "lists": []}"#.utf8)
        try original.write(to: url)
        let store = TodoStore(storageURL: url)
        let notice = try XCTUnwrap(store.storageError)
        XCTAssertTrue(notice.contains("unsupported format"))
        XCTAssertTrue(notice.contains("memory only"), "The error must explain that edits are not saved")
        let item = try XCTUnwrap(store.addItem("In memory"))
        store.renameItem(item, to: "Still in memory")
        store.toggle(item)
        let other = try XCTUnwrap(store.addList("Other"))
        store.selectList(store.lists[0].id)
        store.deleteList(other)
        store.undo()
        XCTAssertEqual(store.lists[0].items.map(\.title), ["Still in memory"], "Editing remains available")
        XCTAssertEqual(store.storageError, notice, "Saving must not hide the unsupported-format warning")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).count, 1,
                       "Unsupported formats are not implicitly recovered or replaced")
        try FileManager.default.removeItem(at: url)
        _ = store.addItem("No implicit recovery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Removing the file does not unlock writes in this store")
        XCTAssertEqual(store.storageError, notice)
    }

    func testANewerVersionWithADifferentSchemaIsAlsoNeverOverwritten() throws {
        let url = try temporaryFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version": 2, "lists": {"newSchema": true}}"#.utf8)
        try original.write(to: url)
        let store = TodoStore(storageURL: url)
        _ = store.addItem("In memory")
        XCTAssertTrue(store.storageError?.contains("unsupported format") == true, "Read the version before decoding version-one lists")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).count, 1)
    }

    func testAFileWithClashingIdentifiersIsNotTrusted() throws {
        let url = try temporaryFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID().uuidString
        let clash = #"{"version": 1, "lists": [{"id": "\#(id)", "title": "A", "items": [], "createdAt": "2024-01-01T00:00:00Z"},"#
            + #"{"id": "\#(id)", "title": "B", "items": [], "createdAt": "2024-01-01T00:00:00Z"}]}"#
        try Data(clash.utf8).write(to: url)
        let store = TodoStore(storageURL: url)
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(store.lists.map(\.title), ["Tasks"])
    }

    func testAnUnwritableLocationIsReportedAndCanBeRepairedWithoutRestarting() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("lenotch-todo-block-\(UUID().uuidString)")
        try Data("a file where a folder must go".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let url = blocker.appendingPathComponent("todos.json")
        let store = TodoStore(storageURL: url)
        XCTAssertNotNil(store.storageError, "Reported on opening")
        _ = store.addItem("Can't be saved")
        XCTAssertTrue(store.storageError?.contains("couldn’t be saved") == true, "And again when a change can't be kept: \(store.storageError ?? "")")
        XCTAssertEqual(store.selected?.items.map(\.title), ["Can't be saved"], "It still works in memory")
        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        _ = store.addItem("Saved after repair")
        XCTAssertNil(store.storageError)
        XCTAssertEqual(TodoStore(storageURL: url).selected?.items.map(\.title), ["Can't be saved", "Saved after repair"])
    }

    func testAnUnreadableFileRemovedBeforeSavingDoesNotLeaveRecoveryStuck() throws {
        let url = try temporaryFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = TodoStore(storageURL: url)
        XCTAssertNotNil(store.storageError)
        try FileManager.default.removeItem(at: url)
        _ = store.addItem("Saved after removal")
        XCTAssertNil(store.storageError)
        XCTAssertEqual(TodoStore(storageURL: url).selected?.items.map(\.title), ["Saved after removal"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).count, 1)
    }

    func testAnExistingFileThatCannotBeBackedUpIsNotOverwritten() throws {
        let url = try temporaryFile()
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("unreadable original".utf8)
        try original.write(to: url)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        guard !manager.isReadableFile(atPath: url.path) else { throw XCTSkip("This user bypasses file read permissions") }
        let store = TodoStore(storageURL: url)
        XCTAssertNotNil(store.storageError)
        _ = store.addItem("Unsaved")
        XCTAssertTrue(store.storageError?.contains("couldn’t be saved") == true, "A permission error must not be treated as a missing source")
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original, "An unreadable existing file must remain untouched")
        _ = store.addItem("Recovered")
        XCTAssertEqual(TodoStore(storageURL: url).selected?.items.map(\.title), ["Unsaved", "Recovered"])
        let backup = try XCTUnwrap(manager.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("todos.recovered-") })
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testTheDefaultLocationIsOneFileInApplicationSupport() {
        let url = TodoStore.defaultStorageURL
        XCTAssertEqual(url.lastPathComponent, "todos.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "lenotch")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Application Support")
        XCTAssertEqual(url.deletingLastPathComponent(), PrompterModel.defaultStorageURL.deletingLastPathComponent(),
                       "Next to the Prompter's scripts")
    }

    func testADirectorUsesTheInjectedStoreAndItsTemporaryFile() throws {
        let url = try temporaryFile()
        let todos = TodoStore(storageURL: url)
        let suite = "lenotch.test.todo.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let director = IslandDirector(prompter: PrompterModel(storageURL: nil), chatDefaults: defaults, todos: todos)
        XCTAssertTrue(director.todos === todos)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Opening creates no file")
        _ = director.todos.addItem("test only")
        XCTAssertEqual(TodoStore(storageURL: url).selected?.items.map(\.title), ["test only"])
    }
}
