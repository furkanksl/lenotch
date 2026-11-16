import AppKit
import Foundation
import IslandCore
import SwiftUI
import XCTest
@testable import Lenotch

final class ChatGPTVoiceClientTests: XCTestCase {
    private let offer = "v=0\r\ns=voice\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"

    func testCallUsesChatGPTAccountJSONRouteNotTheAPIKeyEndpoint() throws {
        let request = try ChatGPTVoiceClient.request(offer: offer, token: "test-token", accountID: "test-account")
        XCTAssertEqual(request.url?.host, "chatgpt.com")
        XCTAssertEqual(request.url?.path, "/backend-api/codex/realtime/calls")
        XCTAssertEqual(request.url?.query, "intent=quicksilver&architecture=avas")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "test-account")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Alpha"), "quicksilver=v2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["sdp"] as? String, offer)
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        XCTAssertNil(session["type"], "Frameless quicksilver v2 does not send the retired v1 session type")
        XCTAssertNil(session["model"], "Codex quicksilver lets the backend choose its voice model")
        XCTAssertEqual((session["delegation"] as? [String: Any])?["type"] as? String, "client")
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        XCTAssertEqual((audio["output"] as? [String: Any])?["voice"] as? String, "cove")
        let instructions = try XCTUnwrap(session["instructions"] as? String)
        XCTAssertTrue(instructions.contains("delegate the task to the client"))
        XCTAssertTrue(instructions.contains("Wait for its returned result"))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-token"))
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testSDPValidationRejectsErrorPagesVideoOnlyAndOversizedPayloads() throws {
        XCTAssertEqual(try ChatGPTVoiceClient.answer(Data(offer.utf8)), offer)
        for invalid in ["", "<html>Private service error</html>", "{\"error\":\"failed\"}", "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96", String(repeating: "x", count: ChatGPTVoiceClient.maximumSDPBytes + 1)] {
            XCTAssertThrowsError(try ChatGPTVoiceClient.answer(Data(invalid.utf8)))
            XCTAssertThrowsError(try ChatGPTVoiceClient.request(offer: invalid, token: "test", accountID: "test"))
        }
    }

    func testSelectedVoicePersistsAndFallsBackToCoveForMissingOrUnknownSettings() throws {
        let suite = "lenotch.test.voice.selection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ChatGPTVoice.selected(in: defaults), .cove)
        for voice in ChatGPTVoice.allCases {
            defaults.set(voice.rawValue, forKey: ChatGPTVoice.preferenceKey)
            XCTAssertEqual(ChatGPTVoice.selected(in: defaults), voice)
        }
        defaults.set("no-longer-supported", forKey: ChatGPTVoice.preferenceKey)
        XCTAssertEqual(ChatGPTVoice.selected(in: defaults), .cove)
    }

    func testCallLocationIsValidatedBeforeSidebandAuthentication() throws {
        XCTAssertEqual(try ChatGPTVoiceClient.callID("/v1/realtime/calls/rtc_test-1"), "rtc_test-1")
        XCTAssertEqual(try ChatGPTVoiceClient.callID("https://chatgpt.com/backend-api/codex/realtime/calls/rtc_test"), "rtc_test")
        for invalid: String? in [nil, "", "/calls", "/calls/..", "/calls/%2fprivate", "/calls/rtc%3ftoken"] {
            XCTAssertThrowsError(try ChatGPTVoiceClient.callID(invalid))
        }
    }

    func testEverySelectableVoiceIsSentAsTheSessionOutputVoice() throws {
        for voice in ChatGPTVoice.allCases {
            let request = try ChatGPTVoiceClient.request(offer: offer, token: "test", accountID: "test", voice: voice)
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let session = try XCTUnwrap(json["session"] as? [String: Any])
            let audio = try XCTUnwrap(session["audio"] as? [String: Any])
            XCTAssertEqual((audio["output"] as? [String: Any])?["voice"] as? String, voice.rawValue)
        }
    }

    func testAccountEntitlementAndRateLimitHaveDifferentRecoveryMessages() {
        XCTAssertTrue(ChatGPTVoiceClient.VoiceError.http(403).localizedDescription.contains("account"))
        XCTAssertTrue(ChatGPTVoiceClient.VoiceError.http(429).localizedDescription.contains("limit"))
        XCTAssertTrue(ChatGPTVoiceClient.VoiceError.http(401).localizedDescription.contains("Reconnect"))
    }

    func testBackendDiagnosticsIncludeTheProtocolErrorButNotRawResponseData() {
        let body = Data(#"{"error":{"type":"invalid_request_error","code":"invalid_quicksilver_alpha_header","message":"private account@example.com bearer-value","param":null}}"#.utf8)
        let summary = ChatGPTVoiceClient.errorSummary(status: 400, data: body)
        XCTAssertTrue(summary.contains("HTTP 400"))
        XCTAssertTrue(summary.contains("invalid_quicksilver_alpha_header"))
        XCTAssertFalse(summary.contains("account@example.com"))
        XCTAssertFalse(summary.contains("bearer-value"))
    }
}

@MainActor
final class ChatGPTVoiceSessionTests: XCTestCase {
    func testCallMovesThroughRealTransportEventsAndMuteControlsTheMicrophone() async {
        let peer = VoicePeerStub(), client = VoiceClientStub()
        let voice = session(peer, client)
        voice.start()
        await settle()
        XCTAssertEqual(client.prepareCount, 1)
        XCTAssertEqual(client.offer, "offer")
        XCTAssertEqual(peer.answer, "answer")
        XCTAssertEqual(voice.phase, .connecting, "An accepted SDP isn't proof of working audio")
        peer.onEvent?(.connected)
        XCTAssertEqual(voice.phase, .listening)
        peer.onEvent?(.userStoppedSpeaking)
        XCTAssertEqual(voice.phase, .thinking)
        peer.onEvent?(.assistantSpeaking)
        XCTAssertEqual(voice.phase, .speaking)
        peer.onEvent?(.assistantTranscript("Hello there"))
        XCTAssertEqual(voice.transcript, "Hello there")
        voice.toggleMute()
        XCTAssertTrue(voice.muted)
        XCTAssertEqual(peer.mutedValues, [true])
        voice.stop()
        XCTAssertTrue(peer.stopped)
        XCTAssertNil(peer.onEvent)
        XCTAssertFalse(voice.running)
        XCTAssertTrue(voice.transcript.isEmpty)
    }

    func testDeniedMicrophoneNeverCreatesOrUploadsAnOffer() async {
        let peer = VoicePeerStub(), client = VoiceClientStub()
        let voice = ChatGPTVoiceSession(makeTransport: { peer }, makeClient: { client }, microphoneAccess: { false }, observeAccount: false)
        voice.start()
        await settle()
        guard case .failed(let message) = voice.phase else { return XCTFail("Permission denial needs a visible error") }
        XCTAssertTrue(message.contains("Microphone"))
        XCTAssertNil(client.offer)
        XCTAssertFalse(peer.started)
        XCTAssertFalse(voice.running)
    }

    func testClosingDuringConnectionStopsTracksAndIgnoresLateEvents() async {
        let peer = VoicePeerStub(), client = VoiceClientStub()
        client.suspend = true
        let voice = session(peer, client)
        voice.start()
        await settle()
        let late = peer.onEvent
        voice.stop()
        client.resume()
        late?(.assistantSpeaking)
        await settle()
        XCTAssertFalse(voice.running)
        XCTAssertTrue(peer.stopped)
        XCTAssertNil(peer.answer)
        XCTAssertNotEqual(voice.phase, .speaking)
    }

    func testFailureStopsTheMicrophoneAndRetryCreatesANewCall() async {
        let peer = VoicePeerStub(), client = VoiceClientStub()
        let voice = session(peer, client)
        voice.start()
        await settle()
        peer.onEvent?(.failed("Voice is unavailable for this account"))
        XCTAssertTrue(peer.stopped)
        XCTAssertFalse(voice.running)
        XCTAssertEqual(voice.phase, .failed("Voice is unavailable for this account"))
        voice.start()
        await settle()
        XCTAssertEqual(client.prepareCount, 2)
        XCTAssertTrue(voice.running)
        voice.stop()
    }

    func testDisconnectAndInvalidLevelsAreHandledWithoutLeavingAudioRunning() async {
        let peer = VoicePeerStub(), client = VoiceClientStub()
        let voice = session(peer, client)
        voice.start()
        await settle()
        peer.onEvent?(.level(.nan))
        XCTAssertEqual(voice.level, 0)
        peer.onEvent?(.level(9))
        XCTAssertEqual(voice.level, 1)
        peer.onEvent?(.disconnected)
        XCTAssertTrue(peer.stopped)
        XCTAssertFalse(voice.running)
    }

    func testOutsideClickMinimizesAndReopensTheSameCallWithoutDisconnecting() async throws {
        let peer = VoicePeerStub(), client = VoiceClientStub()
        let voice = session(peer, client)
        let director = IslandDirector(askVoice: voice, voiceAccountConnected: { true }, chatDefaults: isolatedChatDefaults())
        defer { director.stopAll() }
        director.openAsk(.codex)
        director.openAskVoice()
        await settle()
        peer.onEvent?(.connected)
        peer.onEvent?(.assistantTranscript("A conversation in progress"))
        let serial = try XCTUnwrap(director.island.running.first { $0.id == .voice }?.serial)

        director.clickOutside()

        XCTAssertFalse(director.askVoiceOpen)
        XCTAssertTrue(director.askVoiceActive)
        XCTAssertTrue(voice.running)
        XCTAssertFalse(peer.stopped)
        XCTAssertEqual(voice.transcript, "A conversation in progress")
        XCTAssertEqual(director.island.activity?.id, .voice)
        director.openAskVoice()
        await settle()
        XCTAssertTrue(director.askVoiceOpen)
        XCTAssertEqual(director.island.cardActivity?.serial, serial)
        XCTAssertEqual(client.prepareCount, 1, "Reopening must not create a second voice conversation")
        XCTAssertFalse(peer.stopped)

        director.endAskVoice()
        XCTAssertFalse(director.askVoiceActive)
        XCTAssertFalse(voice.running)
        XCTAssertTrue(peer.stopped)
        XCTAssertEqual(director.island.askOpen, .codex)
    }

    func testMinimizedVoiceSurvivesOtherToolsAndProviderSwitches() async throws {
        let peer = VoicePeerStub(), client = VoiceClientStub()
        let voice = session(peer, client)
        let director = IslandDirector(askVoice: voice, voiceAccountConnected: { true }, chatDefaults: isolatedChatDefaults())
        defer { director.stopAll() }
        director.openAsk(.codex)
        director.openAskVoice()
        await settle()
        let serial = try XCTUnwrap(director.island.running.first { $0.id == .voice }?.serial)
        director.minimizeAskVoice()
        director.show(.timer, opened: true, sample: false)
        director.openAsk(.claude)
        XCTAssertTrue(voice.running)
        XCTAssertFalse(peer.stopped)
        director.openAsk(.codex)
        director.openAskVoice()
        XCTAssertEqual(director.island.cardActivity?.serial, serial)
        XCTAssertEqual(client.prepareCount, 1)
        director.end(serial: serial)
        XCTAssertTrue(peer.stopped)
        XCTAssertFalse(director.askVoiceActive)
    }

    func testLockingStopsAMinimizedVoiceForPrivacy() async {
        let peer = VoicePeerStub(), client = VoiceClientStub()
        let voice = session(peer, client)
        let director = IslandDirector(askVoice: voice, voiceAccountConnected: { true }, chatDefaults: isolatedChatDefaults())
        defer { director.stopAll() }
        director.openAsk(.codex)
        director.openAskVoice()
        await settle()
        director.minimizeAskVoice()
        var context = director.island.context
        context.locked = true
        director.setContext(context)
        XCTAssertFalse(director.askVoiceActive)
        XCTAssertFalse(voice.running)
        XCTAssertTrue(peer.stopped)
    }

    func testNativeMediaHostStaysAttachedWhenVoiceControlsAreMinimized() async throws {
        let peer = VoicePeerStub(), client = VoiceClientStub()
        let voice = session(peer, client)
        let director = IslandDirector(askVoice: voice, voiceAccountConnected: { true }, chatDefaults: isolatedChatDefaults())
        let model = NotchContentModel(), frame = FrameModel()
        model.stills = true
        let host = NSHostingView(rootView: NotchContentView(model: model, frame: frame, director: director))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NotchContentView.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { director.stopAll(); window.close() }
        director.openAsk(.codex)
        director.openAskVoice()
        model.groups = director.groups
        model.mode = director.mode
        for _ in 0..<8 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        XCTAssertTrue(voice.mediaHost.window === window)
        let parent = try XCTUnwrap(voice.mediaHost.superview)
        director.clickOutside()
        model.groups = director.groups
        model.mode = director.mode
        for _ in 0..<8 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        XCTAssertTrue(voice.mediaHost.window === window)
        XCTAssertTrue(voice.mediaHost.superview === parent, "Minimizing must not reparent or detach WebKit's audio host")
        XCTAssertFalse(voice.mediaHost.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(voice.running)
        XCTAssertFalse(peer.stopped)
    }

    func testMutedCallFailureStillOffersRetryWhenMinimized() async {
        let peer = VoicePeerStub(), client = VoiceClientStub()
        let voice = session(peer, client)
        let director = IslandDirector(askVoice: voice, voiceAccountConnected: { true }, chatDefaults: isolatedChatDefaults())
        defer { director.stopAll() }
        director.openAsk(.codex)
        director.openAskVoice()
        await settle()
        voice.toggleMute()
        director.minimizeAskVoice()
        peer.onEvent?(.failed("The call disconnected"))
        XCTAssertEqual(director.askVoiceStatus, "Tap to retry")
        XCTAssertTrue(director.askVoiceActive, "A failed minimized call must remain reachable for retry or End")
        XCTAssertFalse(voice.running)
    }

    private func session(_ peer: VoicePeerStub, _ client: VoiceClientStub) -> ChatGPTVoiceSession {
        ChatGPTVoiceSession(makeTransport: { peer }, makeClient: { client }, microphoneAccess: { true }, observeAccount: false)
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }
}

@MainActor
private final class VoicePeerStub: ChatGPTVoiceTransport {
    var results: [(id: String, text: String)] = []
    func sendDelegationResult(id: String, text: String) async throws { results.append((id, text)) }
    func attach(to host: NSView) {}
    var onEvent: ((ChatGPTVoiceTransportEvent) -> Void)?
    var started = false
    var stopped = false
    var answer: String?
    var mutedValues: [Bool] = []
    func makeOffer() async throws -> String { started = true; return "offer" }
    func acceptAnswer(_ sdp: String) async throws { answer = sdp }
    func setMuted(_ muted: Bool) { mutedValues.append(muted) }
    func stop() { stopped = true }
}

@MainActor
private final class VoiceClientStub: ChatGPTVoiceCalling {
    var onEvent: ((ChatGPTVoiceTransportEvent) -> Void)?
    func startEvents() async throws {}
    func sendDelegationResult(id: String, text: String) async throws {}
    func stop() {}
    var prepareCount = 0
    var offer: String?
    var suspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    func prepare() async throws { prepareCount += 1 }
    func connect(offer: String) async throws -> String {
        self.offer = offer
        if suspend { await withCheckedContinuation { continuation = $0 } }
        return "answer"
    }
    func resume() { continuation?.resume(); continuation = nil }
}
