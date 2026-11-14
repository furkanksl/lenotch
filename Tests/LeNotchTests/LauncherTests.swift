import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

@MainActor
final class LauncherTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "com.lenotch.tests.launcher.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lenotch-launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertError(_ expected: LauncherError, _ action: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual(error as? LauncherError, expected, file: file, line: line)
        }
    }

    func testNewLauncherIsEmptyAndDoesNotPopulateOrPersistSamples() throws {
        let defaults = try defaults()
        let model = LauncherModel(defaults: defaults)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isLaunching)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(defaults.object(forKey: LauncherModel.defaultStorageKey))
    }

    func testAddsFoldersApplicationsAndWebsitesWithNativeDefaultNames() throws {
        let root = try directory()
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        let application = root.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        let model = LauncherModel(defaults: nil)

        let app = try model.add(url: application)
        let projects = try model.add(url: folder)
        let website = try model.addLink("https://example.com/docs")

        XCTAssertEqual(model.items.map(\.kind), [.application, .folder, .link])
        XCTAssertEqual(model.items.map(\.title), ["Example", "Projects", "example.com"])
        XCTAssertNotNil(app.bookmark)
        XCTAssertNotNil(projects.bookmark)
        XCTAssertNil(website.bookmark)
        XCTAssertNotNil(model.icon(for: app))
        XCTAssertNotNil(model.icon(for: projects))
        XCTAssertNotNil(model.icon(for: website))
    }

    func testOrderNamesAndDestinationsPersistWithoutOpeningAnything() throws {
        let defaults = try defaults()
        var opened = 0
        let model = LauncherModel(defaults: defaults, opener: { _, _ in opened += 1 })
        let first = try model.addLink("https://example.com/one", title: "First")
        let second = try model.addLink("https://example.com/two", title: "Second")
        let third = try model.addLink("https://example.com/three", title: "Third")
        try model.rename(second.id, title: "  Saved   name \n")
        model.move(third.id, by: -2)
        model.remove(first.id)

        let restored = LauncherModel(defaults: defaults, opener: { _, _ in opened += 1 })
        XCTAssertEqual(restored.items, model.items)
        XCTAssertEqual(restored.items.map(\.title), ["Third", "Saved name"])
        XCTAssertEqual(restored.items.map(\.id), [third.id, second.id])
        XCTAssertEqual(opened, 0)
        XCTAssertFalse(restored.isLaunching)
        XCTAssertNil(restored.errorMessage)
    }

    func testRejectsExecutableFilesDocumentsAndUnavailablePaths() throws {
        let root = try directory()
        let document = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: document)
        let model = LauncherModel(defaults: nil)
        assertError(.unsupportedFile) { try model.add(url: document) }
        assertError(.unsupportedFile) { try model.add(url: URL(fileURLWithPath: "/bin/sh")) }
        assertError(.missingFile) { try model.add(url: root.appendingPathComponent("absent")) }
        XCTAssertTrue(model.items.isEmpty)
    }

    func testRejectsUnsafeSchemesCredentialsAndRemoteFileHosts() throws {
        let model = LauncherModel(defaults: nil)
        for value in ["javascript:alert(1)", "data:text/plain,hello", "mailto:test@example.com", "shortcuts://run-shortcut?name=test",
                      "x-apple.systempreferences:com.apple.settings", "file://remote-host/Applications/Example.app",
                      "https://user:password@example.com", "https://user@example.com", "https:///", "https://example.com:0"] {
            if let url = URL(string: value) {
                assertError(.unsupportedURL, { try model.add(url: url) })
            }
        }
        XCTAssertTrue(model.items.isEmpty)
    }

    func testLinkEntryRequiresExplicitHTTPOrHTTPSAndRejectsWhitespace() throws {
        let model = LauncherModel(defaults: nil)
        for value in ["example.com", "ftp://example.com", "file:///Applications", "https://exa mple.com", "https://example.com/a\nb"] {
            assertError(.invalidWebsite) { try model.addLink(value) }
        }
        let item = try model.addLink("  https://example.com/path?q=hello%20world#section\n", title: "Documentation")
        XCTAssertEqual(item.url.absoluteString, "https://example.com/path?q=hello%20world#section")
        XCTAssertEqual(item.title, "Documentation")
        XCTAssertEqual(try model.addLink("http://example.org:8080/").kind, .link)
    }

    func testDuplicateWebsitesNormalizeSchemeHostDefaultPortAndRootSlash() throws {
        let model = LauncherModel(defaults: nil)
        try model.addLink("https://EXAMPLE.com")
        assertError(.duplicate) { try model.addLink("https://example.com:443/") }
        try model.addLink("http://example.com")
        assertError(.duplicate) { try model.addLink("http://example.com:80/") }
        try model.addLink("https://example.com/path")
        XCTAssertEqual(model.items.count, 3)
    }

    func testSymbolicLinksResolveBeforeDeduplicationAndTypeValidation() throws {
        let root = try directory()
        let actual = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let model = LauncherModel(defaults: nil)
        let added = try model.add(url: alias)
        XCTAssertEqual(added.url, actual.resolvingSymlinksInPath())
        assertError(.duplicate) { try model.add(url: actual) }
        let executableAlias = root.appendingPathComponent("Unsafe.app")
        try FileManager.default.createSymbolicLink(at: executableAlias, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        assertError(.unsupportedFile) { try model.add(url: executableAlias) }
    }

    func testNamesAreBoundedAndAnEmptyRenameUsesTheDestinationName() throws {
        let model = LauncherModel(defaults: nil)
        let item = try model.addLink("https://example.com", title: "   My\n  Website  ")
        XCTAssertEqual(item.title, "My Website")
        assertError(.titleTooLong) { try model.rename(item.id, title: String(repeating: "x", count: 65)) }
        assertError(.invalidTitle) { try model.rename(item.id, title: "Name\u{0}") }
        XCTAssertEqual(model.items.first?.title, "My Website")
        try model.rename(item.id, title: "   ")
        XCTAssertEqual(model.items.first?.title, "example.com")
        assertError(.unknownItem) { try model.rename(UUID(), title: "Other") }
    }

    func testCapacityIsBoundedWithoutDroppingExistingItems() throws {
        let model = LauncherModel(defaults: nil)
        for index in 0..<LauncherModel.maximumItems { try model.addLink("https://example.com/\(index)") }
        let before = model.items
        assertError(.full) { try model.addLink("https://example.com/overflow") }
        XCTAssertEqual(model.items, before)
        model.remove(try XCTUnwrap(model.items.first?.id))
        try model.addLink("https://example.com/replacement")
        XCTAssertEqual(model.items.count, LauncherModel.maximumItems)
    }

    func testListReorderUsesDestinationBeforeRemovalAndPreservesIdentity() throws {
        let defaults = try defaults()
        let model = LauncherModel(defaults: defaults)
        for label in ["A", "B", "C", "D", "E"] { try model.addLink("https://example.com/\(label)", title: label) }
        let ids = Set(model.items.map(\.id))
        model.move(fromOffsets: IndexSet([1, 3]), toOffset: 5)
        XCTAssertEqual(model.items.map(\.title), ["A", "C", "E", "B", "D"])
        model.move(fromOffsets: IndexSet([3, 4]), toOffset: 0)
        XCTAssertEqual(model.items.map(\.title), ["B", "D", "A", "C", "E"])
        XCTAssertEqual(Set(model.items.map(\.id)), ids)
        XCTAssertEqual(LauncherModel(defaults: defaults).items, model.items)
    }

    func testReorderingRejectsInvalidIndicesAndBoundsExtremeOffsets() throws {
        let model = LauncherModel(defaults: nil)
        let first = try model.addLink("https://example.com/first", title: "First")
        let second = try model.addLink("https://example.com/second", title: "Second")
        let before = model.items
        model.move(fromOffsets: IndexSet([7]), toOffset: 0)
        model.move(fromOffsets: IndexSet([0]), toOffset: 3)
        model.move(fromOffsets: IndexSet([0]), toOffset: -1)
        model.move(UUID(), by: 1)
        model.remove(UUID())
        XCTAssertEqual(model.items, before)
        model.move(first.id, by: .max)
        XCTAssertEqual(model.items.map(\.id), [second.id, first.id])
        model.move(first.id, by: .min)
        XCTAssertEqual(model.items, before)
    }

    func testLaunchUsesInjectedNativeOpenActionAndReportsSuccessOnlyAfterItCompletes() async throws {
        var opened: [(URL, LauncherItem.Kind)] = []
        let model = LauncherModel(defaults: nil, opener: { url, kind in opened.append((url, kind)) })
        let item = try model.addLink("https://example.com/docs", title: "Docs")
        let success = await model.launch(item)
        XCTAssertTrue(success)
        XCTAssertEqual(opened.map(\.0), [item.url])
        XCTAssertEqual(opened.map(\.1), [.link])
        XCTAssertFalse(model.isLaunching)
        XCTAssertNil(model.errorMessage)
    }

    func testFailureIsVisibleAndDoesNotDeleteConfiguration() async throws {
        let model = LauncherModel(defaults: nil, opener: { _, _ in throw LauncherError.cannotOpen })
        let item = try model.addLink("https://example.com")
        let success = await model.launch(item)
        XCTAssertFalse(success)
        XCTAssertEqual(model.errorMessage, LauncherError.cannotOpen.localizedDescription)
        XCTAssertEqual(model.items, [item])
        XCTAssertFalse(model.isLaunching)
        model.clearError()
        XCTAssertNil(model.errorMessage)
    }

    func testDeletedFolderCannotReachTheOpenAction() async throws {
        let root = try directory()
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var opened = false
        let model = LauncherModel(defaults: nil, opener: { _, _ in opened = true })
        let item = try model.add(url: folder)
        try FileManager.default.removeItem(at: folder)
        let success = await model.launch(item)
        XCTAssertFalse(success)
        XCTAssertFalse(opened)
        XCTAssertEqual(model.errorMessage, LauncherError.missingFile.localizedDescription)
    }

    func testFolderReplacedByAFileCannotReachTheOpenAction() async throws {
        let root = try directory()
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var opened = false
        let model = LauncherModel(defaults: nil, opener: { _, _ in opened = true })
        let item = try model.add(url: folder)
        try FileManager.default.removeItem(at: folder)
        try Data("not a directory".utf8).write(to: folder)
        let success = await model.launch(item)
        XCTAssertFalse(success)
        XCTAssertFalse(opened)
        XCTAssertEqual(model.errorMessage, LauncherError.unsupportedFile.localizedDescription)
    }

    func testLaunchingRemovedItemFailsAndTamperedArgumentsCannotReplaceTheSavedDestination() async throws {
        var opened: [URL] = []
        let model = LauncherModel(defaults: nil, opener: { url, _ in opened.append(url) })
        let item = try model.addLink("https://example.com")
        let tampered = LauncherItem(id: item.id, title: item.title, url: URL(string: "javascript:alert(1)")!,
                                    kind: .link, bookmark: nil)
        let launchedSaved = await model.launch(tampered)
        XCTAssertTrue(launchedSaved)
        XCTAssertEqual(opened, [item.url])
        model.remove(item.id)
        let launchedRemoved = await model.launch(item)
        XCTAssertFalse(launchedRemoved)
        XCTAssertEqual(opened, [item.url])
        XCTAssertEqual(model.errorMessage, LauncherError.unknownItem.localizedDescription)
    }

    func testRepeatedClicksDoNotStartConcurrentLaunches() async throws {
        var pending: CheckedContinuation<Void, Never>?
        var count = 0
        let model = LauncherModel(defaults: nil, opener: { _, _ in
            count += 1
            await withCheckedContinuation { pending = $0 }
        })
        let item = try model.addLink("https://example.com")
        let first = Task { @MainActor in await model.launch(item) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        guard let pending else {
            first.cancel()
            XCTFail("The first request did not reach the injected opener")
            return
        }
        XCTAssertTrue(model.isLaunching)
        XCTAssertEqual(model.launchingID, item.id)
        let repeated = await model.launch(item)
        XCTAssertFalse(repeated)
        XCTAssertEqual(count, 1)
        pending.resume()
        let success = await first.value
        XCTAssertTrue(success)
        XCTAssertFalse(model.isLaunching)
    }

    func testCancelledRequestDoesNotOpenADestinationOrDisplayAnError() async throws {
        var opened = false
        let model = LauncherModel(defaults: nil, opener: { _, _ in opened = true })
        let item = try model.addLink("https://example.com")
        let task = Task { @MainActor in await model.launch(item) }
        task.cancel()
        let success = await task.value
        XCTAssertFalse(success)
        XCTAssertFalse(opened)
        XCTAssertFalse(model.isLaunching)
        XCTAssertNil(model.errorMessage)
    }

    func testCorruptOrFutureVersionStorageDoesNotGetOverwrittenOnRead() throws {
        let defaults = try defaults()
        for data in [Data("not-json".utf8), Data(#"{"version":999,"items":[]}"#.utf8)] {
            defaults.set(data, forKey: LauncherModel.defaultStorageKey)
            let model = LauncherModel(defaults: defaults)
            XCTAssertTrue(model.items.isEmpty)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(defaults.data(forKey: LauncherModel.defaultStorageKey), data)
        }
    }

    func testSavedUnsafeDestinationsAndDuplicateIDsAreNotRestored() throws {
        let defaults = try defaults()
        let safe = LauncherItem(id: UUID(), title: "Docs", url: URL(string: "https://example.com")!, kind: .link, bookmark: nil)
        let unsafe = LauncherItem(id: UUID(), title: "Unsafe", url: URL(string: "javascript:alert(1)")!, kind: .link, bookmark: nil)
        let duplicate = LauncherItem(id: safe.id, title: "Duplicate", url: URL(string: "https://example.org")!, kind: .link, bookmark: nil)
        struct Saved: Codable { let version: Int; let items: [LauncherItem] }
        let data = try JSONEncoder().encode(Saved(version: 1, items: [safe, unsafe, duplicate]))
        defaults.set(data, forKey: LauncherModel.defaultStorageKey)
        let model = LauncherModel(defaults: defaults)
        XCTAssertEqual(model.items, [safe])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(defaults.data(forKey: LauncherModel.defaultStorageKey), data)
    }

    func testNativeLauncherCardShowsSevenTargetsAndConfigurationWithinItsBounds() throws {
        let model = LauncherModel(defaults: nil)
        for title in ["Browser", "Projects", "Docs", "Notes", "Mail", "Code", "Files"] {
            try model.addLink("https://example.com/\(title)", title: title)
        }
        let view = LauncherView(model: model, onClose: {}, onConfigure: {})
            .environment(\.islandMotion, IslandMotion(reduce: true, stills: true))
            .frame(width: 480, height: 220)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        for title in ["Launcher", "Browser", "Projects", "Docs", "Notes", "Mail", "Code", "Files"] {
            XCTAssertTrue(text.contains(title.lowercased()), "Missing \(title) in native 480×220 card: \(text)")
        }
    }

    func testEmptyLauncherRendersWithoutInventingDefaultItems() throws {
        let model = LauncherModel(defaults: nil)
        let view = LauncherView(model: model, onClose: {}, onConfigure: {})
            .environment(\.islandMotion, IslandMotion(reduce: true, stills: true))
            .frame(width: 480, height: 220)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.contains("Launcher"), text)
        XCTAssertTrue(text.contains("Configure"), text)
        XCTAssertTrue(model.items.isEmpty)
    }
}
