import IslandCore
import XCTest
@testable import Lenotch

@MainActor
final class VoiceEntryPresentationTests: XCTestCase {
    private func director() -> (IslandDirector, ManualScheduler) {
        // Deny capture in-process: these tests exercise the real director/session without
        // opening a microphone, account client, WebRTC transport, or network connection.
        let session = ChatGPTVoiceSession(makeClient: { VoiceEntryCallStub() }, microphoneAccess: { false }, observeAccount: false)
        let director = IslandDirector(askVoice: session, voiceAccountConnected: { true },
                                      chatDefaults: isolatedChatDefaults())
        let scheduler = ManualScheduler()
        director.schedule = scheduler.schedule
        director.frontmostApp = { "" }
        director.askSend = { _, _, _ in }
        return (director, scheduler)
    }

    private func assertVoiceCard(_ director: IslandDirector,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(director.mode, .card, file: file, line: line)
        XCTAssertTrue(director.askVoiceOpen, file: file, line: line)
        XCTAssertNil(director.island.askOpen, "Voice replaces the new Chat composer", file: file, line: line)
        XCTAssertEqual(director.presentationCard(player: Island.askCard), IslandDirector.askVoiceCard,
                       file: file, line: line)
        XCTAssertEqual(director.island.cardActivity?.id, .voice, file: file, line: line)
        XCTAssertTrue(director.groups.activityCard, file: file, line: line)
        XCTAssertNil(director.groups.agentsAsk, file: file, line: line)
        XCTAssertNil(director.groups.agentsCard, file: file, line: line)
        XCTAssertFalse(director.groups.balls.compactMap { $0 }.contains { director.island.instance($0)?.id == .voice },
                       "The open voice controls must not also appear as a minimized bubble", file: file, line: line)
    }

    func testEnteringVoiceReplacesNewChatCardWithAndWithoutMusic() {
        for music in [false, true] {
            let (director, _) = director()
            if music { director.startMusic() }
            director.openAsk(.codex, new: true)
            XCTAssertEqual(director.groups.agentsAsk, .codex)

            director.openAskVoice()

            assertVoiceCard(director)
            XCTAssertEqual(director.island.mediaOn, music)
            director.stopAll()
        }
    }

    func testEnteringVoiceFromRecentChatKeepsTextHistoryWithAndWithoutMusic() throws {
        for music in [false, true] {
            let (director, _) = director()
            if music { director.startMusic() }
            director.openAsk(.codex)
            director.submitAsk("Keep this conversation")
            let chatID = try XCTUnwrap(director.island.agents.sessions.first?.id)
            director.askEvent(chatID, .delta("Saved reply"))
            director.askEvent(chatID, .done(error: nil))
            let history = director.agentChats[chatID]
            director.closeAsk()
            director.openAsk(.codex)
            XCTAssertEqual(director.groups.agentsCard, .ask)

            director.openAskVoice()

            assertVoiceCard(director)
            XCTAssertEqual(director.agentChats[chatID], history, "Starting voice must not clear the text conversation")
            XCTAssertEqual(director.agentShown(.ask)?.id, chatID)
            director.stopAll()
        }
    }

    func testVoiceBecomesMusicBubbleOnlyAfterOutsideClickAndReopensSameCall() throws {
        let (director, _) = director()
        director.startMusic()
        director.openAsk(.codex, new: true)
        director.openAskVoice()
        assertVoiceCard(director)
        let serial = try XCTUnwrap(director.island.cardActivity?.serial)

        director.clickOutside()

        XCTAssertFalse(director.askVoiceOpen)
        XCTAssertTrue(director.askVoiceActive)
        XCTAssertEqual(director.island.arrangement.ears, .media)
        XCTAssertTrue(director.island.arrangement.balls.contains {
            director.island.instance($0)?.serial == serial
        }, "The ongoing call becomes a bubble after its controls lose focus")

        director.openAsk(.codex, new: true)
        director.openAskVoice()

        assertVoiceCard(director)
        XCTAssertEqual(director.island.cardActivity?.serial, serial)
        XCTAssertEqual(director.island.running.filter { $0.id == .voice }.count, 1)
        director.stopAll()
    }

    func testPointerLeavingDuringVoiceEntryDoesNotAutoMinimizeControls() {
        let (director, scheduler) = director()
        director.openAsk(.codex, new: true)
        director.pointerMoved(hit: .card, corridor: false, buttonDown: false)
        director.openAskVoice()

        director.pointerMoved(hit: nil, corridor: false, buttonDown: false)
        scheduler.advance(10)

        assertVoiceCard(director)
        director.stopAll()
    }

    func testOpeningVoiceFromBubblePreservesCurrentSessionWithoutRestartingCapture() async throws {
        var captureRequests = 0
        let session = ChatGPTVoiceSession(makeClient: { VoiceEntryCallStub() }, microphoneAccess: {
            captureRequests += 1
            return false
        }, observeAccount: false)
        let director = IslandDirector(askVoice: session, voiceAccountConnected: { true },
                                      chatDefaults: isolatedChatDefaults())
        director.schedule = ManualScheduler().schedule
        director.openAsk(.codex, new: true)
        director.openAskVoice()
        for _ in 0..<20 {
            if case .failed = session.phase { break }
            await Task.yield()
        }
        XCTAssertEqual(captureRequests, 1)
        guard case .failed = session.phase else {
            director.stopAll()
            return XCTFail("The denied-capture session should finish startup without accessing the account")
        }
        let phase = session.phase
        let serial = try XCTUnwrap(director.island.cardActivity?.serial)
        director.minimizeAskVoice()

        director.openAsk(.codex, new: true)
        director.openAskVoice()
        for _ in 0..<5 { await Task.yield() }

        assertVoiceCard(director)
        XCTAssertEqual(director.island.cardActivity?.serial, serial)
        XCTAssertEqual(session.phase, phase, "Reopening controls must not restart an existing voice call")
        XCTAssertEqual(captureRequests, 1)
        director.stopAll()
    }
}

@MainActor private final class VoiceEntryCallStub: ChatGPTVoiceCalling {
    var onEvent: ((ChatGPTVoiceTransportEvent) -> Void)?
    func prepare() async throws {}
    func connect(offer: String) async throws -> String { "unused" }
    func startEvents() async throws {}
    func sendDelegationResult(id: String, text: String) async throws {}
    func stop() {}
}
