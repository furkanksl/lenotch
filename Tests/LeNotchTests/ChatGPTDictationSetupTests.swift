import AppKit
import Carbon
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

@MainActor
final class ChatGPTDictationSetupTests: XCTestCase {
    func testDictationUsesTheSharedShortcutAndNeverWritesTheLegacyToggle() async throws {
        let suite = "lenotch.test.setup.dictation-shortcut.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DictationProvider.chatGPT.rawValue, forKey: DictationProvider.preferenceKey)
        defaults.set(false, forKey: DictationInputSettings.pushToTalkKey)
        defaults.set(false, forKey: DictationInputSettings.toggleShortcutKey)
        let shortcuts = ToolShortcutSettings(defaults: defaults)
        let remapped = ToolKeyBinding(keyCode: kVK_F12, modifiers: cmdKey | shiftKey)
        XCTAssertTrue(shortcuts.setBinding(remapped, for: .dictation))

        for binding in [remapped, nil] {
            XCTAssertTrue(shortcuts.setBinding(binding, for: .dictation))
            shortcuts.setRegistrationFailures(binding == nil ? [:] : [.dictation: "Shortcut registration failed"])
            for scheme in [ColorScheme.light, .dark] {
                let view = SetupDictationPage(reviewAccess: {}, shortcutSettings: shortcuts)
                    .padding(24)
                    .frame(width: 656)
                    .background(SetupTheme.card)
                    .defaultAppStorage(defaults)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: image).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ").lowercased()
                for label in ["keyboard shortcut", "configure", "hold fn to talk"] {
                    XCTAssertTrue(text.contains(label), "Missing \(label): \(text)")
                }
                XCTAssertTrue(text.contains(binding == nil ? "dictate from the notch" : "f12"), text)
                XCTAssertEqual(text.contains("not set"), binding == nil, text)
                XCTAssertEqual(text.contains("shortcut registration failed"), binding != nil, text)
                XCTAssertFalse(text.contains("toggle dictation with"), "Shortcuts are configured only in Tools: \(text)")
                XCTAssertFalse(defaults.bool(forKey: DictationInputSettings.toggleShortcutKey))
                XCTAssertEqual(shortcuts.binding(for: .dictation), binding)
            }
        }
    }

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
