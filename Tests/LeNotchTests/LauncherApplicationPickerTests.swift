import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

@MainActor final class LauncherApplicationPickerTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lenotch-application-picker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult private func app(_ name: String, in directory: URL, displayName: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name + ".app", isDirectory: true)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundlePackageType": "APPL", "CFBundleName": name, "CFBundleDisplayName": displayName ?? name]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }

    func testCatalogFindsNestedApplicationsButNotHelpersOrFakeBundles() throws {
        let root = try directory()
        let first = try app("Zed", in: root, displayName: "Alpha")
        let utilities = root.appendingPathComponent("Utilities", isDirectory: true)
        let second = try app("Terminal", in: utilities)
        try app("Embedded Helper", in: first.appendingPathComponent("Contents"))
        try app("Hidden", in: root.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Fake.app"), withIntermediateDirectories: true)
        let catalog = try LauncherApplicationCatalog.scan(roots: [root, root, root.appendingPathComponent("missing")])
        XCTAssertEqual(catalog.map(\.name), ["Alpha", "Terminal"])
        XCTAssertEqual(Set(catalog.map(\.url)), [first, second])
    }

    func testCatalogDoesNotFollowSymbolicLinksOrDeepDirectoryTrees() throws {
        let root = try directory(), external = try directory()
        try app("External", in: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: external)
        try app("Too Deep", in: root.appendingPathComponent("one/two/three"))
        XCTAssertTrue(try LauncherApplicationCatalog.scan(roots: [root]).isEmpty)
    }

    func testApplicationSymlinksAreIncludedWithoutRecursingIntoLinkedDirectories() throws {
        let root = try directory(), external = try directory()
        let app = try app("Browser", in: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Browser.app"), withDestinationURL: app)
        let applications = try LauncherApplicationCatalog.scan(roots: [root, external])
        XCTAssertEqual(applications.map(\.url), [app.resolvingSymlinksInPath()])
        XCTAssertEqual(applications.map(\.name), ["Browser"])
    }

    func testAsyncLoadingSearchSelectionAndAddUseExistingPersistence() async throws {
        let root = try directory()
        try app("Safari", in: root); try app("Notes", in: root)
        let catalog = LauncherApplicationPickerModel()
        catalog.load(roots: [root])
        let deadline = ContinuousClock.now + .seconds(3)
        while catalog.loading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(catalog.loading)
        XCTAssertEqual(catalog.applications.count, 2)
        catalog.query = " SAF "
        XCTAssertEqual(catalog.filtered.map(\.name), ["Safari"])
        let application = try XCTUnwrap(catalog.filtered.first)
        catalog.selected = [application.url]
        let launcher = LauncherModel(defaults: nil)
        for application in catalog.selection { try launcher.add(url: application.url) }
        XCTAssertEqual(launcher.items.count, 1)
        XCTAssertEqual(launcher.items.first?.kind, .application)
        catalog.load(roots: []); catalog.cancel()
        await Task.yield()
        XCTAssertFalse(catalog.loading)
        XCTAssertEqual(catalog.applications.count, 2, "Cancelled scans must not replace a completed catalog")
    }

    func testAddApplicationPresentsANativeSheetWithoutTheRemoteFileDialog() async throws {
        let model = LauncherModel(defaults: nil), editor = LauncherEditor(), root = try directory()
        try app("Example", in: root)
        editor.show(model: model)
        let parent = try XCTUnwrap(NSApp.windows.first { $0.title == "Launcher — LeNotch" && $0.isVisible })
        defer { editor.closeApplicationPicker(); parent.close() }
        editor.chooseApplications(model: model, roots: [root])
        let sheet = try XCTUnwrap(parent.attachedSheet)
        XCTAssertEqual(sheet.title, "Add applications")
        XCTAssertFalse(sheet is NSOpenPanel, "Do not reintroduce the failing remote Open/Save bridge")
        editor.chooseApplications(model: model, roots: [root])
        XCTAssertTrue(parent.attachedSheet === sheet, "Repeated clicks must not open duplicate sheets")
        editor.closeApplicationPicker()
        let deadline = ContinuousClock.now + .seconds(2)
        while parent.attachedSheet != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(parent.attachedSheet)
    }

    func testApplicationRowsAndControlsRenderInBothAppearances() async throws {
        let root = try directory(); try app("Example Editor", in: root)
        let catalog = LauncherApplicationPickerModel(); catalog.load(roots: [root])
        let deadline = ContinuousClock.now + .seconds(3)
        while catalog.loading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        for scheme in [ColorScheme.light, .dark] {
            let view = LauncherApplicationPicker(catalog: catalog, onCancel: {}, onAdd: { _ in })
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 470), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            window.contentView = host
            defer { window.close() }
            for _ in 0..<4 { await Task.yield(); host.layoutSubtreeIfNeeded() }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains("example editor"), text)
            XCTAssertTrue(text.contains("cancel"), text)
            XCTAssertTrue(text.contains("add applications"), text)
        }
    }
}
