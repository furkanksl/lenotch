import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

@MainActor
final class ChatGPTDictationSetupTests: XCTestCase {
    func testChatGPTSettingsRenderWithoutSpeechModelDownloadsInBothThemes() async throws {
        let suite = "lenotch.test.setup.chatgpt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(DictationProvider.chatGPT.rawValue, forKey: DictationProvider.preferenceKey)
        defer { defaults.removePersistentDomain(forName: suite) }

        for scheme in [ColorScheme.light, .dark] {
            let size = SetupWindowController.initialContentSize
            let view = SetupView(page: .dictation)
                .defaultAppStorage(defaults)
                .environment(\.colorScheme, scheme)
                .frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.close() }
            for _ in 0..<4 { await Task.yield(); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains("transcription"), text)
            XCTAssertTrue(text.contains("chatgpt"), text)
            XCTAssertTrue(text.contains("no speech model download") || text.contains("disconnected"), text)
            XCTAssertFalse(text.contains("fluid speech pro"), "Cloud dictation must not require a local speech model")
            XCTAssertFalse(text.contains("nemotron"), "Cloud dictation must not require a local speech model")
            if let path = ProcessInfo.processInfo.environment["SETUP_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("dictation-chatgpt-\(scheme).png"))
            }
        }
    }
}
