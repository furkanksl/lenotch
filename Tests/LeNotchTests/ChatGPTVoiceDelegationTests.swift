import AppKit
import XCTest
@testable import Lenotch

final class ChatGPTVoiceDelegationTests: XCTestCase {
    func testFramelessWorkRequestsRequireClientDelegationAndPreserveAllText() {
        var decoder = ChatGPTVoiceEventDecoder()
        let item: [String: Any] = ["id": "task-1", "type": "delegation", "target": "client",
            "content": [["type": "input_text", "text": "Search "], ["type": "image", "text": "ignored"], ["type": "input_text", "text": "the web"]]]
        XCTAssertEqual(decoder.decode(["type": "delegation.created", "item": item]), [.workRequested(id: "task-1", text: "Search the web")])
        for change in [["target": "server"], ["type": "message"], ["id": ""]] {
            let invalid = item.merging(change) { _, new in new }
            XCTAssertTrue(decoder.decode(["type": "delegation.created", "item": invalid]).isEmpty)
        }
        XCTAssertTrue(decoder.decode(["type": "delegation.created"]).isEmpty)
        XCTAssertEqual(decoder.decode(["type": "response.created"]), [.assistantThinking])
    }

    func testResultWireFormatMatchesFramelessAndChunksUnicodeAt500UTF8Bytes() throws {
        let answer = String(repeating: "Found: İstanbul 🌍 e\u{301}. ", count: 100)
        let messages = try ChatGPTVoiceDelegation.messages(id: "task-1", text: answer)
        XCTAssertGreaterThan(messages.count, 1)
        var recovered = ""
        for message in messages {
            XCTAssertEqual(message["type"] as? String, "delegation.context.append")
            XCTAssertEqual(message["delegation_item_id"] as? String, "task-1")
            XCTAssertEqual(message["channel"] as? String, "speakable")
            XCTAssertNil(message["call_id"])
            let content = try XCTUnwrap(message["content"] as? [[String: String]])
            XCTAssertEqual(content.first?["type"], "input_text")
            let text = try XCTUnwrap(content.first?["text"])
            XCTAssertLessThanOrEqual(text.utf8.count, 500)
            XCTAssertFalse(text.isEmpty)
            recovered += text
        }
        XCTAssertEqual(recovered, answer)
        XCTAssertThrowsError(try ChatGPTVoiceDelegation.messages(id: "", text: "answer"))
        XCTAssertThrowsError(try ChatGPTVoiceDelegation.messages(id: "task", text: ""))
    }
}

@MainActor
final class ChatGPTVoiceWorkLifecycleTests: XCTestCase {
    func testActualDelegationStaysWorkingDuringListeningAndSendsTheCompletedResult() async {
        let peer = DelegatingVoicePeer(), worker = VoiceWorkerStub()
        let voice = session(peer, worker)
        defer { voice.stop() }
        voice.start()
        await settle()
        peer.onEvent?(.connected)
        peer.onEvent?(.userTranscript("What is the current release?"))
        peer.onEvent?(.workRequested(id: "research", text: "Search for the current release"))
        await settle()
        XCTAssertEqual(worker.requests.count, 1)
        XCTAssertTrue(worker.requests[0].contains("What is the current release?"))
        worker.onStatus?("Searching the web")
        XCTAssertEqual(voice.phase, .working("Searching the web"))
        peer.onEvent?(.assistantStoppedSpeaking)
        peer.onEvent?(.userSpeaking)
        XCTAssertEqual(voice.phase, .working("Searching the web"), "Audio going quiet must not hide running work")
        XCTAssertTrue(peer.results.isEmpty, "Filler speech isn't a completed task")
        worker.finish("I checked the release notes. The result is X.")
        await settle()
        XCTAssertEqual(peer.results.count, 1)
        XCTAssertEqual(peer.results.first?.id, "research")
        XCTAssertTrue(peer.results.first?.text.contains("release notes") == true)
        XCTAssertEqual(voice.phase, .thinking)
        peer.onEvent?(.assistantSpeaking)
        XCTAssertEqual(voice.phase, .speaking)
    }

    func testDuplicateDelegationsDoNotRunTwiceAndNewTasksQueue() async {
        let peer = DelegatingVoicePeer(), worker = VoiceWorkerStub()
        let voice = session(peer, worker)
        defer { voice.stop() }
        voice.start(); await settle()
        peer.onEvent?(.workRequested(id: "one", text: "first"))
        peer.onEvent?(.workRequested(id: "one", text: "duplicate"))
        peer.onEvent?(.workRequested(id: "two", text: "second"))
        await settle()
        XCTAssertEqual(worker.requests.count, 1)
        worker.finish("first result"); await settle()
        XCTAssertEqual(worker.requests.count, 2)
        worker.finish("second result"); await settle()
        XCTAssertEqual(peer.results.map(\.id), ["one", "two"])
    }

    func testEndingTheCallCancelsWorkAndDoesNotSendAStaleResult() async {
        let peer = DelegatingVoicePeer(), worker = VoiceWorkerStub()
        let voice = session(peer, worker)
        voice.start(); await settle()
        peer.onEvent?(.workRequested(id: "one", text: "search")); await settle()
        voice.stop(); await settle()
        XCTAssertTrue(worker.cancelled)
        XCTAssertTrue(peer.results.isEmpty)
        XCTAssertFalse(voice.running)
    }

    func testWorkerFailureReturnsATruthfulFailureInsteadOfPretendingToStillWork() async {
        let peer = DelegatingVoicePeer(), worker = VoiceWorkerStub()
        let voice = session(peer, worker)
        defer { voice.stop() }
        voice.start(); await settle()
        peer.onEvent?(.workRequested(id: "one", text: "search")); await settle()
        worker.cancel(); await settle()
        XCTAssertEqual(peer.results.first?.id, "one")
        XCTAssertTrue(peer.results.first?.text.contains("did not complete") == true)
        XCTAssertTrue(peer.results.first?.text.contains("Do not claim it is still running") == true)
    }

    private func session(_ peer: DelegatingVoicePeer, _ worker: VoiceWorkerStub) -> ChatGPTVoiceSession {
        ChatGPTVoiceSession(makeTransport: { peer }, makeClient: { VoiceWorkCallStub(peer: peer) },
                           makeWorker: { worker }, microphoneAccess: { true }, observeAccount: false)
    }
    private func settle() async { for _ in 0..<40 { await Task.yield() } }
}

@MainActor private final class DelegatingVoicePeer: ChatGPTVoiceTransport {
    var onEvent: ((ChatGPTVoiceTransportEvent) -> Void)?
    var results: [(id: String, text: String)] = []
    func attach(to host: NSView) {}
    func makeOffer() async throws -> String { "offer" }
    func acceptAnswer(_ sdp: String) async throws {}
    func setMuted(_ muted: Bool) {}
    func sendDelegationResult(id: String, text: String) async throws { results.append((id, text)) }
    func stop() {}
}
@MainActor private final class VoiceWorkCallStub: ChatGPTVoiceCalling {
    var onEvent: ((ChatGPTVoiceTransportEvent) -> Void)?
    let peer: DelegatingVoicePeer
    init(peer: DelegatingVoicePeer) { self.peer = peer }
    func startEvents() async throws {}
    func sendDelegationResult(id: String, text: String) async throws { peer.results.append((id, text)) }
    func stop() {}
    func prepare() async throws {}
    func connect(offer: String) async throws -> String { "answer" }
}
@MainActor private final class VoiceWorkerStub: ChatGPTVoiceWorking {
    var onStatus: ((String) -> Void)?
    var requests: [String] = []
    var cancelled = false
    private var pending: CheckedContinuation<String, any Error>?
    func run(_ instructions: String) async throws -> String {
        requests.append(instructions)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ text: String) { let previous = pending; pending = nil; previous?.resume(returning: text) }
    func cancel() { cancelled = true; let previous = pending; pending = nil; previous?.resume(throwing: CancellationError()) }
}
