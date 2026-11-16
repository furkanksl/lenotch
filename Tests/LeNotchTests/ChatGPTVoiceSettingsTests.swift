import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

@MainActor
final class ChatGPTVoiceSettingsTests: XCTestCase {
    func testVoicePickerShowsTheSavedVoiceAndConnectionGuidanceInBothThemes() async throws {
        let suite = "lenotch.test.voice.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ChatGPTVoice.maple.rawValue, forKey: ChatGPTVoice.preferenceKey)

        for scheme in [ColorScheme.light, .dark] {
            for connected in [true, false] {
                let size = NSSize(width: 690, height: 260)
                let view = SetupChatGPTVoiceSettings(connected: connected)
                    .padding(24)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .background(SetupTheme.card)
                    .defaultAppStorage(defaults)
                    .environment(\.colorScheme, scheme)
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
                let recognition = VNRecognizeTextRequest()
                recognition.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: image).perform([recognition])
                let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ").lowercased()
                XCTAssertTrue(text.contains("voice mode"), text)
                XCTAssertTrue(text.contains("chatgpt voice"), text)
                XCTAssertTrue(text.contains("maple"), "Must display the saved selection, not hardcoded Cove: \(text)")
                XCTAssertTrue(text.contains("next voice conversation"), text)
                XCTAssertTrue(text.contains("voice you hear in chat"), text)
                XCTAssertFalse(text.contains("ask ai"), text)
                XCTAssertTrue(text.contains(connected ? "end an active" : "connect chatgpt"), text)
                if let path = ProcessInfo.processInfo.environment["SETUP_SNAPSHOT_DIR"] {
                    let folder = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: folder.appendingPathComponent("voice-settings-\(scheme)-\(connected).png"))
                }
            }
        }
    }
}
