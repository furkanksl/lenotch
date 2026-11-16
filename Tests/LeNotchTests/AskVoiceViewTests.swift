import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

@MainActor
final class AskVoiceViewTests: XCTestCase {
    func testVoicePhasesRenderWithReadableControlsInBothThemesAndMotionModes() async throws {
        let phases: [(String, AskVoicePresentation, String)] = [
            ("connecting", .connecting, "connecting"),
            ("listening", .listening, "listening"),
            ("thinking", .thinking, "thinking"),
            ("speaking", .speaking, "speaking"),
            ("failed", .failed("This account cannot start voice. Please try again."), "couldn't connect"),
        ]
        let motions = [IslandMotion(), IslandMotion(reduce: true), IslandMotion(stills: true)]
        for scheme in [ColorScheme.light, .dark] {
            for (motionIndex, motion) in motions.enumerated() {
                for (name, phase, status) in phases {
                    let text = try await render(phase: phase, scheme: scheme, motion: motion,
                                                name: "\(name)-\(scheme)-\(motionIndex)")
                    XCTAssertTrue(text.contains("chatgpt voice"), text)
                    XCTAssertTrue(text.contains("experimental"), text)
                    XCTAssertTrue(text.contains(status), text)
                    XCTAssertTrue(text.contains("mute"), text)
                    XCTAssertTrue(text.contains("end voice"), text)
                    if phase == .connecting {
                        XCTAssertTrue(text.contains("microphone audio is sent to chatgpt"), text)
                    }
                    if case .failed = phase {
                        XCTAssertTrue(text.contains("retry"), text)
                        XCTAssertTrue(text.contains("this account"), text)
                    }
                }
            }
        }
    }

    func testConnectingDisclosureIsNotReplacedByAPreviousTranscript() async throws {
        let text = try await render(phase: .connecting, transcript: "A previous voice reply.", scheme: .dark,
                                    motion: IslandMotion(stills: true), name: "connecting-disclosure")
        XCTAssertTrue(text.contains("microphone audio is sent to chatgpt"), text)
        XCTAssertFalse(text.contains("previous voice reply"), text)
    }

    func testMutedListeningAndLongTranscriptStayInsideTheCard() async throws {
        let text = try await render(phase: .listening, muted: true, scheme: .dark,
                                    motion: IslandMotion(reduce: true), name: "muted")
        XCTAssertTrue(text.contains("microphone muted"), text)
        XCTAssertTrue(text.contains("unmute"), text)

        let transcript = "Let's plan the weekend. " + String(repeating: "A long transcript should remain bounded. ", count: 30)
        let transcriptText = try await render(phase: .speaking, transcript: transcript, scheme: .light,
                                              motion: IslandMotion(stills: true), name: "long-transcript")
        XCTAssertTrue(transcriptText.contains("plan the weekend"), transcriptText)
        XCTAssertTrue(transcriptText.contains("end voice"), "The transcript must not push controls outside the card: \(transcriptText)")
    }

    func testSmallOrbRendersForSilentActiveAndInvalidMeterValues() async throws {
        for level in [0.0, 0.8, -1, 5, .nan, .infinity] {
            let view = VoiceOrb(size: 28, active: true, level: level)
                .environment(\.islandMotion, IslandMotion(reduce: true))
                .padding(8)
                .background(.black)
            let renderer = ImageRenderer(content: view)
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 44)
            XCTAssertEqual(image.height, 44)
        }
    }

    private func render(phase: AskVoicePresentation, muted: Bool = false, transcript: String = "",
                        scheme: ColorScheme, motion: IslandMotion, name: String) async throws -> String {
        let size = NSSize(width: 420, height: 360)
        let view = AskVoiceView(phase: phase, muted: muted, level: 0.6, transcript: transcript,
                                onMute: {}, onEnd: {}, onRetry: {}, onMinimize: {})
            .environment(\.colorScheme, scheme)
            .environment(\.islandMotion, motion)
            .background(.black)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        for _ in 0..<4 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        host.displayIfNeeded()
        XCTAssertEqual(host.fittingSize.width, size.width, accuracy: 0.5)
        XCTAssertEqual(host.fittingSize.height, size.height, accuracy: 0.5)

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])

        if let path = ProcessInfo.processInfo.environment["ASK_VOICE_SNAPSHOT_DIR"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("voice-\(name).png"))
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ").lowercased()
    }
}
