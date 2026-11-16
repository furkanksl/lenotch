import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Lenotch

@MainActor
final class ChatGPTVoiceTransportTests: XCTestCase {
    func testSecurityDelegatesAreExposedToObjectiveCWebKit() {
        let transport = WebRTCVoiceTransport()
        XCTAssertTrue(transport.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
        XCTAssertTrue(transport.responds(to: NSSelectorFromString("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")))
        XCTAssertTrue(transport.responds(to: NSSelectorFromString("webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:")))
    }

    func testOwnedOriginRejectsRemoteAndInsecureDocuments() {
        XCTAssertTrue(WebRTCVoiceTransport.isOwnedOrigin(scheme: "https", host: "lenotch.invalid", port: 0))
        XCTAssertTrue(WebRTCVoiceTransport.isOwnedOrigin(scheme: "https", host: "lenotch.invalid", port: 443))
        XCTAssertFalse(WebRTCVoiceTransport.isOwnedOrigin(scheme: "http", host: "lenotch.invalid", port: 0))
        XCTAssertFalse(WebRTCVoiceTransport.isOwnedOrigin(scheme: "https", host: "chatgpt.com", port: 443))
        XCTAssertFalse(WebRTCVoiceTransport.isOwnedOrigin(scheme: "https", host: "lenotch.invalid.evil.test", port: 443))
        XCTAssertFalse(WebRTCVoiceTransport.isOwnedOrigin(scheme: "https", host: "lenotch.invalid", port: 8443))
    }

    func testInlineDocumentDoesNotFetchOrReceiveCredentials() {
        let html = WebRTCVoiceTransport.document(generation: UUID().uuidString)
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertTrue(html.contains("script-src 'nonce-"))
        XCTAssertTrue(html.contains("video: false"))
        XCTAssertTrue(html.contains("echoCancellation: true, noiseSuppression: true"))
        XCTAssertTrue(html.contains("createDataChannel('oai-events')"))
        XCTAssertTrue(html.contains("iceServers: []"))
        XCTAssertFalse(html.contains("<script src="))
        XCTAssertFalse(html.contains("fetch("))
        XCTAssertFalse(html.contains("XMLHttpRequest"))
        XCTAssertFalse(html.contains("Authorization"))
        XCTAssertFalse(html.contains("Bearer"))
        XCTAssertFalse(html.contains("chatgpt.com"))
    }

    func testPublicRealtimeSpeechAndTranscriptEvents() {
        var decoder = ChatGPTVoiceEventDecoder()
        XCTAssertEqual(decoder.decode(["type": "input_audio_buffer.speech_started"]), [.userSpeaking])
        XCTAssertEqual(decoder.decode(["type": "conversation.item.input_audio_transcription.delta", "delta": "Hello"]), [.userTranscript("Hello")])
        XCTAssertEqual(decoder.decode(["type": "conversation.item.input_audio_transcription.delta", "delta": " there"]), [.userTranscript("Hello there")])
        XCTAssertEqual(decoder.decode(["type": "input_audio_buffer.speech_stopped"]), [.userStoppedSpeaking])
        XCTAssertEqual(decoder.decode(["type": "conversation.item.input_audio_transcription.completed", "transcript": "Hello there!"]), [.userTranscript("Hello there!")])
        XCTAssertEqual(decoder.decode(["type": "conversation.item.input_audio_transcription.delta", "delta": "New turn"]), [.userTranscript("New turn")])
        XCTAssertEqual(decoder.decode(["type": "output_audio_buffer.started"]), [.assistantSpeaking])
        XCTAssertEqual(decoder.decode(["type": "response.output_audio_transcript.delta", "delta": "Hi"]), [.assistantTranscript("Hi")])
        XCTAssertEqual(decoder.decode(["type": "response.audio_transcript.delta", "delta": "!"]), [.assistantTranscript("Hi!")])
        XCTAssertEqual(decoder.decode(["type": "response.output_audio_transcript.done", "transcript": "Hi!"]), [.assistantTranscript("Hi!")])
        XCTAssertEqual(decoder.decode(["type": "output_audio_buffer.stopped"]), [.assistantStoppedSpeaking])
        XCTAssertEqual(decoder.decode(["type": "response.audio_transcript.delta", "delta": "Next"]), [.assistantTranscript("Next")])
    }

    func testQuicksilverFramelessTranscriptsAndTurns() {
        var decoder = ChatGPTVoiceEventDecoder()
        XCTAssertEqual(decoder.decode(["type": "input_transcript.added", "item": ["text": "What's "]]), [.userTranscript("What's ")])
        XCTAssertEqual(decoder.decode(["type": "input_transcript.added", "item": ["text": "new?"]]), [.userTranscript("What's new?")])
        XCTAssertEqual(decoder.decode(["type": "turn.done", "turn": ["role": "user", "transcript": "What's new?"]]), [.userTranscript("What's new?"), .userStoppedSpeaking])
        XCTAssertEqual(decoder.decode(["type": "output_transcript.added", "item": ["text": "A new "]]), [.assistantTranscript("A new ")])
        XCTAssertEqual(decoder.decode(["type": "output_transcript.added", "item": ["text": "release."]]), [.assistantTranscript("A new release.")])
        XCTAssertEqual(decoder.decode(["type": "turn.done", "turn": ["role": "assistant", "transcript": "A new release."]]), [.assistantTranscript("A new release.")])
        XCTAssertEqual(decoder.decode(["type": "output_transcript.added", "item": ["text": "Another turn"]]), [.assistantTranscript("Another turn")])
    }

    func testDecoderBoundsUntrustedPayloadsAndIgnoresAudioBytes() {
        var decoder = ChatGPTVoiceEventDecoder()
        XCTAssertEqual(decoder.decode(["type": "output_audio.delta", "audio": "AAE="]), [])
        XCTAssertEqual(decoder.decode(["type": "turn.done", "turn": ["role": "tool", "transcript": "ignored"]]), [])
        XCTAssertEqual(decoder.decode(["type": "input_transcript.added", "item": ["text": 42]]), [])
        XCTAssertEqual(decoder.decode([:]), [])
        XCTAssertEqual(decoder.decode(["type": "error", "error": ["message": "Account access denied"]]), [.failed("Account access denied")])
        let tooLong = String(repeating: "x", count: 20_000)
        XCTAssertEqual(decoder.decode(["type": "input_transcript.added", "item": ["text": tooLong]]), [.userTranscript(String(tooLong.prefix(16_000)))])
        XCTAssertEqual(decoder.decode(["type": "error", "error": ["message": tooLong]]), [.failed(String(tooLong.prefix(500)))])
    }

    func testInterruptedAssistantTranscriptDoesNotLeakIntoTheNextResponse() {
        var decoder = ChatGPTVoiceEventDecoder()
        XCTAssertEqual(decoder.decode(["type": "response.audio_transcript.delta", "delta": "Interrupted"]), [.assistantTranscript("Interrupted")])
        XCTAssertEqual(decoder.decode(["type": "response.created"]), [.assistantThinking])
        XCTAssertEqual(decoder.decode(["type": "response.audio_transcript.delta", "delta": "Fresh"]), [.assistantTranscript("Fresh")])
        XCTAssertEqual(decoder.decode(["type": "response.done"]), [])
        XCTAssertEqual(decoder.decode(["type": "response.audio_transcript.delta", "delta": "Next"]), [.assistantTranscript("Next")])
    }

    func testPreparationUsesARealSecureWebKitDocumentWithoutMicrophoneAccess() async throws {
        _ = NSApplication.shared
        let transport = WebRTCVoiceTransport()
        let window = try present(transport)
        defer { transport.stop(); window.close() }
        XCTAssertNil(transport.webView, "Ordinary construction must not start WebKit or microphone access.")
        let capabilities = try await transport.prepare()
        XCTAssertTrue(capabilities.secureContext, "loadHTMLString must create a secure context on the owned HTTPS base URL.")
        XCTAssertTrue(capabilities.mediaDevices, "This runtime must expose navigator.mediaDevices.getUserMedia.")
        XCTAssertTrue(capabilities.peerConnection, "This runtime must expose RTCPeerConnection.")
        let view = try XCTUnwrap(transport.webView)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(view.microphoneCaptureState, .none)
        XCTAssertFalse(view.window?.isKeyWindow ?? true)
        XCTAssertTrue(view.window === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        let visibility = try await evaluateString("document.visibilityState", in: view)
        XCTAssertEqual(visibility, "visible", "Media capture must not be hosted in an invisible page.")
        let result = try await evaluateString("JSON.stringify({secure: isSecureContext, media: typeof navigator.mediaDevices?.getUserMedia, rtc: typeof RTCPeerConnection, peers: document.querySelectorAll('audio').length})", in: view)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(json["secure"] as? Bool, true)
        XCTAssertEqual(json["media"] as? String, "function")
        XCTAssertEqual(json["rtc"] as? String, "function")
        XCTAssertEqual(json["peers"] as? Int, 0, "A capability check must not construct media or start a call.")
        transport.stop()
        XCTAssertNil(transport.webView)
    }

    func testStopResolvesPendingPreparationAndCanPrepareAgain() async throws {
        _ = NSApplication.shared
        let transport = WebRTCVoiceTransport()
        let window = try present(transport)
        defer { transport.stop(); window.close() }
        let preparation = Task { try await transport.prepare() }
        await Task.yield()
        transport.stop()
        do {
            _ = try await preparation.value
            XCTFail("Stopping must cancel pending readiness, not leave a continuation behind.")
        } catch is CancellationError { }
        XCTAssertNil(transport.webView)
        let capabilities = try await transport.prepare()
        XCTAssertTrue(capabilities.supported)
    }

    func testCancellationResolvesPendingPreparation() async throws {
        _ = NSApplication.shared
        let transport = WebRTCVoiceTransport()
        let window = try present(transport)
        defer { transport.stop(); window.close() }
        let preparation = Task { try await transport.prepare() }
        await Task.yield()
        preparation.cancel()
        do {
            _ = try await preparation.value
            XCTFail("Cancelled readiness must throw.")
        } catch is CancellationError { }
        XCTAssertNil(transport.webView)
    }

    func testAnswerBeforeOfferDoesNotCreateAWebViewOrPromptForMicrophone() async {
        let transport = WebRTCVoiceTransport()
        do {
            try await transport.acceptAnswer("v=0\r\n")
            XCTFail("An answer requires an outstanding offer.")
        } catch { XCTAssertTrue(error is ChatGPTVoiceTransportError) }
        XCTAssertNil(transport.webView)
        transport.setMuted(true)
        transport.stop()
    }

    func testSyntheticAudioCanProduceAnOfferWithoutMicrophoneOrAccountAccess() async throws {
        _ = NSApplication.shared
        let transport = WebRTCVoiceTransport(timeout: 5, syntheticAudio: true)
        let window = try present(transport)
        defer { transport.stop(); window.close() }
        _ = try await transport.prepare()
        let view = try XCTUnwrap(transport.webView)
        let offer = try await transport.makeOffer()
        XCTAssertTrue(offer.hasPrefix("v=0"))
        XCTAssertTrue(offer.contains("m=audio "))
        XCTAssertEqual(view.microphoneCaptureState, .none, "The regression test must never record the microphone.")
        transport.stop()
        XCTAssertNil(transport.webView)
    }

    func testNeverPresentedHostFailsWithoutCreatingWebKitOrRequestingMicrophone() async {
        let transport = WebRTCVoiceTransport()
        let host = NSView()
        transport.attach(to: host)
        do {
            _ = try await transport.makeOffer()
            XCTFail("Invisible hosts must not start media capture")
        } catch { XCTAssertTrue(error.localizedDescription.contains("isn't visible")) }
        XCTAssertNil(transport.webView)
        transport.stop()
    }

    private func present(_ transport: WebRTCVoiceTransport) throws -> NSWindow {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        transport.attach(to: host)
        let window = NotchPanel()
        window.setFrame(NSRect(x: 60, y: 60, width: 16, height: 16), display: false)
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.contentView = NSHostingView(rootView: AskVoiceMediaHost(view: host).frame(width: 16, height: 16))
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        window.display()
        guard window.occlusionState.contains(.visible) else {
            window.close()
            throw XCTSkip("The test desktop does not expose unoccluded windows. WebKit intentionally defers media in occluded windows.")
        }
        XCTAssertFalse(host.visibleRect.isEmpty, "SwiftUI must lay out the real media host before loading WebKit")
        return window
    }

    private func evaluateString(_ script: String, in view: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let string = value as? String { continuation.resume(returning: string) }
                else { continuation.resume(throwing: ChatGPTVoiceTransportError.bridge("Expected a string from the local test document.")) }
            }
        }
    }
}
