import AppKit
import SwiftUI
import XCTest
@testable import Lenotch

@MainActor
final class AppIconBuildTests: XCTestCase {
    /// Exercise the same Apple compiler and metadata merge as packaging, not a checked-in flattened export.
    func testIconComposerBuildPreservesAppearancesAndGeneratesLegacyFallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("lenotch icon test \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let contents = temporary.appendingPathComponent("LeNotch.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let plist = contents.appendingPathComponent("Info.plist")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Resources/Info.plist"), to: plist)
        let before = try propertyList(plist)

        _ = try run("/bin/zsh", ["tools/build_icon.sh", resources.path, plist.path], in: root)

        let metadata = try propertyList(plist)
        XCTAssertEqual(metadata["CFBundleIconName"] as? String, "lenotch")
        XCTAssertEqual(metadata["CFBundleIconFile"] as? String, "lenotch")
        for key in ["CFBundleIdentifier", "CFBundleName", "CFBundleExecutable", "LSMinimumSystemVersion", "LSUIElement"] {
            XCTAssertEqual(metadata[key] as? NSObject, before[key] as? NSObject, "Icon compilation must preserve \(key)")
        }

        let catalog = resources.appendingPathComponent("Assets.car")
        let info = try run("/usr/bin/xcrun", ["assetutil", "--info", catalog.path], in: root)
        let assets = try XCTUnwrap(JSONSerialization.jsonObject(with: info) as? [[String: Any]])
        let stacks = assets.filter { $0["AssetType"] as? String == "IconImageStack" && $0["Name"] as? String == "lenotch" }
        XCTAssertEqual(Set(stacks.compactMap { $0["Appearance"] as? String }),
                       ["NSAppearanceNameAqua", "NSAppearanceNameDarkAqua", "ISAppearanceTintable"],
                       "Light, dark and tinted must remain separate native renditions")
        for stack in stacks {
            XCTAssertGreaterThan(stack["LayerCount"] as? Int ?? 0, 1, "Preserve the Icon Composer layers")
            XCTAssertEqual(stack["CanvasWidth"] as? Int, 1024)
            XCTAssertEqual(stack["CanvasHeight"] as? Int, 1024)
        }

        let fallback = try XCTUnwrap(NSImage(contentsOf: resources.appendingPathComponent("lenotch.icns")))
        let sizes = Set(fallback.representations.map(\.pixelsWide))
        XCTAssertTrue(sizes.contains(16), "The legacy fallback must include small Finder sizes")
        XCTAssertTrue(sizes.contains(1024), "The legacy fallback must include Retina artwork")

        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        for scheme in [ColorScheme.light, .dark] {
            let icon = SetupAppIcon(bundle: bundle).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: icon)
            renderer.scale = 2
            let rendered = try XCTUnwrap(renderer.cgImage, "The bundled icon must render in the Setup header")
            XCTAssertEqual(rendered.width, 80, "40-point header icon at Retina resolution")
            XCTAssertEqual(rendered.height, 80)
        }
    }

    private func propertyList(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    private func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(domain: "AppIconBuildTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self),
            ])
        }
        return data
    }
}
