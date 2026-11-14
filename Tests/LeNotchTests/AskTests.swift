import IslandCore
import XCTest
@testable import Lenotch

/// Quick ask (agents phase 3): the card (ASK1), a question becoming a session with its answer streaming (ASK2–ASK3),
/// follow-ups and the 10-minute stay (ASK4), the notch's own hooks ignored (ASK5), the parsers (ASK6), the barrel roll.
@MainActor
final class AskTests: XCTestCase {
    private func director() -> (IslandDirector, ManualScheduler, [(String, AgentProvider, String)]) {
        let d = IslandDirector(), s = ManualScheduler()
        d.schedule = s.schedule
        d.frontmostApp = { "" }
        var sent: [(String, AgentProvider, String)] = []
        d.askSend = { sent.append(($0, $1, $2)) }
        sentBox = { sent }
        return (d, s, sent)
    }
    private var sentBox: () -> [(String, AgentProvider, String)] = { [] }

    // ASK1: the text-only ask card opens at 420 × 112, asks the chosen provider, and closes like a card.
    func testASK1TheAskCard() {
        let (d, _, _) = director()
        d.openAsk()
        XCTAssertEqual(d.mode, .card)
        XCTAssertEqual(d.island.askOpen, .claude)
        XCTAssertEqual(d.groups.agentsAsk, .claude)
        XCTAssertEqual(d.island.cardSize(player: CardSize(width: 372, height: 168, radius: 40)), CardSize(width: 420, height: 112, radius: 34))
        d.setAskProvider(.codex)
        XCTAssertEqual(d.island.askOpen, .codex)
        d.closeAsk()
        XCTAssertNil(d.island.askOpen)
        XCTAssertEqual(d.mode, .idle)
    }

    func testAskArrowConnectsChatGPTUntilSignInFinishes() {
        XCTAssertEqual(AskPrimaryAction.forProvider(.codex, status: .disconnected), .connect)
        XCTAssertEqual(AskPrimaryAction.forProvider(.codex, status: .error("Retry")), .connect)
        XCTAssertEqual(AskPrimaryAction.forProvider(.codex, status: .connecting), .wait)
        XCTAssertEqual(AskPrimaryAction.forProvider(.codex, status: .connected(email: nil, plan: nil)), .send)
        XCTAssertEqual(AskPrimaryAction.forProvider(.claude, status: .disconnected), .send,
                       "Claude does not depend on ChatGPT sign-in")
    }

    // ASK2: Return makes a session (project Ask) and its chat card; the question goes to the chosen provider.
    func testASK2AQuestionBecomesASession() {
        let (d, _, _) = director()
        d.openAsk(.claude)
        d.submitAsk("What's this error?")
        let s = d.island.agents.sessions.first
        XCTAssertEqual(s?.project, "Ask")
        XCTAssertEqual(s?.state, .working)
        XCTAssertNil(d.island.askOpen)
        XCTAssertEqual(s?.provider, .ask, "the notch's own conversation, apart from the sessions it watches")
        XCTAssertEqual(d.groups.agentsCard, .ask, "the card grows into the chat")
        XCTAssertEqual(d.agentShown(.ask)?.id, s?.id)
        XCTAssertEqual(d.askBackend[s!.id], .claude)
        XCTAssertEqual(d.agentChats[s!.id], [.you("What's this error?")])
        XCTAssertEqual(sentBox().map(\.2), ["What's this error?"])
        XCTAssertEqual(d.replyRoute(s!), .ask)
        XCTAssertEqual(d.agentTitle(s!), "What's this error?")
        XCTAssertEqual(AgentsCardLayer.pendingStatus(for: s!, messages: d.agentChats[s!.id] ?? []), "Working…",
                       "Show activity as soon as Ask sends, before the first streamed token")
    }

    // ASK3: deltas stream into one message; the end settles it (read at once while its chat shows); errors show in it.
    func testASK3TheAnswerStreams() {
        let (d, _, _) = director()
        d.openAsk(.claude)
        d.submitAsk("hi")
        let id = d.island.agents.sessions[0].id
        d.askEvent(id, .delta("Hello"))
        XCTAssertNil(AgentsCardLayer.pendingStatus(for: d.island.agents.sessions[0], messages: d.agentChats[id] ?? []),
                     "The activity indicator should yield to the streamed reply")
        d.askEvent(id, .delta(" there"))
        XCTAssertEqual(d.agentChats[id]?.last, .agent("Hello there"))
        d.askEvent(id, .tool("WebSearch"))
        XCTAssertEqual(d.agentChats[id]?.last, .tools("Searched the web", []))
        XCTAssertEqual(d.island.agents.sessions[0].step, "Searching the web…")
        let source = WebSource(title: "Example", url: URL(string: "https://example.com/guide")!)
        d.askEvent(id, .sources([source]))
        XCTAssertEqual(d.agentChats[id]?.last, .sources([source]))
        d.askEvent(id, .done(error: nil))
        XCTAssertEqual(d.island.agents.sessions[0].state, .ready, "its chat was showing: read")
        XCTAssertTrue(d.island.arrangement.all.contains(.agents(.ask)), "read, it keeps its ball: that's where you type")
    }

    // ASK4: a follow-up goes to the same session; a read Ask session leaves 10 minutes later, a new turn keeps it.
    func testASK4FollowUpAndStay() {
        let (d, s, _) = director()
        d.openAsk(.codex)
        d.submitAsk("first")
        let session = d.island.agents.sessions[0]
        d.askEvent(session.id, .done(error: nil))
        d.replyAgent(d.island.agents.sessions[0], "and then?")
        XCTAssertEqual(sentBox().map(\.2), ["first", "and then?"])
        XCTAssertEqual(sentBox().last?.0, session.id)
        XCTAssertEqual(sentBox().last?.1, .codex, "answered by the conversation's own backend")
        XCTAssertEqual(d.island.agents.sessions[0].state, .working)
        s.advance(700)
        XCTAssertEqual(d.island.agents.sessions.count, 1, "working: it stays")
        d.askEvent(session.id, .done(error: nil))
        d.closeAsk()
        d.selectAgent(d.island.agents.sessions[0])
        if d.island.agents.sessions[0].state == .done { d.selectAgent(d.island.agents.sessions[0]) }
        s.advance(599)
        XCTAssertEqual(d.island.agents.sessions.count, 1)
        s.advance(2)
        XCTAssertTrue(d.island.agents.sessions.isEmpty, "10 minutes after it was read, it leaves")
    }

    // ASK5: Codex's hooks fire for the notch's own questions: lines from the Ask folder are ignored.
    func testASK5OwnHooksIgnored() {
        let (d, _, _) = director()
        let json = #"{"session_id":"t1","cwd":"\#(QuickAsk.workspace.path)"}"#
        d.agentHook(AgentSocket.Line(provider: "codex", event: "UserPromptSubmit", host: "", raw: Data(json.utf8)), reply: nil)
        XCTAssertTrue(d.island.agents.sessions.isEmpty)
    }

    // ASK6: the stream parsers.
    func testASK6Parsers() {
        let claude = QuickAskParsing.claude([
            #"{"type":"system","subtype":"init","session_id":"abc"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"WebSearch"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Found it"}}}"#,
            #"{"type":"result","subtype":"success","is_error":false}"#,
        ])
        XCTAssertEqual(claude, [.delta("Hi"), .tool("WebSearch"), .delta("\n\nFound it"), .done(error: nil)])
        XCTAssertEqual(ChatGPTChat.parseEvent(#"{"type":"response.output_text.delta","delta":"Hi"}"#), .delta("Hi"))
        XCTAssertEqual(ChatGPTChat.parseEvent(#"{"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"Hi"}]}]}}"#), .completed("Hi"))
        XCTAssertEqual(ChatGPTChat.parseEvent(#"{"type":"response.failed","response":{"error":{"message":"Try again"}}}"#), .failed("Try again"))
        XCTAssertEqual(ChatGPTChat.parseEvent("[DONE]"), .finished)
        XCTAssertEqual(ChatGPTChat.parseEvent(#"{"type":"response.output_item.done","item":{"type":"message","content":[{"type":"output_text","text":"Hello"}]}}"#), .outputItem("Hello"))
        XCTAssertEqual(ChatGPTChat.parseEvent(#"{"type":"response.output_item.added","item":{"type":"web_search_call","action":{"type":"search"}}}"#), .tool("WebSearch"))
        XCTAssertEqual(ChatGPTChat.parseEvent(#"{"type":"response.output_item.added","item":{"type":"web_search_call","action":{"type":"open_page"}}}"#), .tool("WebFetch"))
        XCTAssertEqual(ChatGPTChat.parseEvent(#"{"type":"response.output_item.added","item":{"type":"web_search_call","action":{"type":"find_in_page"}}}"#), .tool("WebFind"))
        XCTAssertEqual(ChatGPTChat.parseEvent(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#), .failed("ChatGPT stopped the reply early (max_output_tokens)."))
        XCTAssertEqual(ChatGPTChat.parseEvent("not json"), .ignored)
        XCTAssertEqual(ChatGPTChat.errorMessage(from: Data(#"{"error":{"message":"Too many requests"}}"#.utf8)),
                       "Too many requests")
        XCTAssertEqual(ChatGPTChat.errorMessage(from: Data(#"{"detail":"Unsupported request field"}"#.utf8)),
                       "Unsupported request field")
        XCTAssertEqual(ChatGPTChat.errorMessage(from: Data(#"{"error":"Invalid model"}"#.utf8)),
                       "Invalid model")
        XCTAssertEqual(ChatGPTChat.parseEvent(#"{"type":"response.failed","response":{"error":{"message":"Retry later"}}}"#),
                       .failed("Retry later"))
    }

    func testWebSearchSourcesAreBoundedDeduplicatedAndPublicLinksOnly() {
        let payload = #"{"type":"response.output_item.done","item":{"type":"message","content":[{"type":"output_text","text":"Answer","annotations":[{"type":"url_citation","url":"https://example.com/story","title":"Example story"},{"type":"url_citation","url":"https://example.com/story","title":"Duplicate"},{"type":"url_citation","url":"file:///etc/hosts","title":"File"},{"type":"url_citation","url":"https://user:pass@example.com/secret","title":"Credentials"},{"type":"url_citation","url":"javascript:alert(1)","title":"Script"},{"type":"url_citation","url":"http://example.org/guide","title":""}]}]}}"#
        XCTAssertEqual(ChatGPTChat.sources(from: payload), [
            WebSource(title: "Example story", url: URL(string: "https://example.com/story")!),
            WebSource(title: "example.org", url: URL(string: "http://example.org/guide")!),
        ])
        let activity = #"{"type":"response.output_item.done","item":{"type":"web_search_call","action":{"type":"open_page","sources":[{"url":"https://example.com/page","title":"Read page"}]}}}"#
        XCTAssertEqual(ChatGPTChat.sources(from: activity), [WebSource(title: "Read page", url: URL(string: "https://example.com/page")!)])
        let final = #"{"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","annotations":[{"type":"url_citation","url":"https://example.com/final","title":"Final"}]}]}]}}"#
        XCTAssertEqual(ChatGPTChat.sources(from: final).first?.title, "Final")
    }

    func testChatGPTStreamFramesEventsAcrossCRLFUTF8AndMissingFinalBlankLine() throws {
        let wire = "\u{FEFF}: comment\r\nevent: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"café\"}\r\n\r\ndata: {\"type\":\"response.completed\"}"
        let bytes = Array(wire.utf8)
        for split in 1..<bytes.count {
            var decoder = ChatGPTSSEDecoder()
            var events: [String] = []
            for byte in bytes[..<split] { if let event = try decoder.push(byte) { events.append(event) } }
            for byte in bytes[split...] { if let event = try decoder.push(byte) { events.append(event) } }
            if let event = try decoder.finish() { events.append(event) }
            XCTAssertEqual(events.map(ChatGPTChat.parseEvent), [.delta("café"), .completed(nil)], "Split at \(split)")
        }
    }

    func testChatGPTStreamAcceptsExplicitDoneAndRejectsMalformedUTF8() throws {
        var decoder = ChatGPTSSEDecoder()
        var events: [String] = []
        for byte in "data: [DONE]\n\n".utf8 {
            if let event = try decoder.push(byte) { events.append(event) }
        }
        XCTAssertEqual(events.map(ChatGPTChat.parseEvent), [.finished])
        var invalid = ChatGPTSSEDecoder()
        for byte: UInt8 in [0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0xC3] { _ = try invalid.push(byte) }
        XCTAssertThrowsError(try invalid.push(0x0A))
    }

    func testChatGPTRequestRetainsOnlyCompletedConversationAndNeverUsesCodexCLI() throws {
        let credentials = ChatGPTCredentials(accessToken: "test-only-token", accountID: "test-account")
        let request = try ChatGPTChat.makeRequest(
            question: "next?", history: [("first?", "answer")],
            sessionID: "ask-session", credentials: credentials
        )
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "session_id"), "ask-session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "test-account")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "lenotch")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        let data = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["store"] as? Bool, false)
        XCTAssertNil(object["session_id"], "The session_id belongs in the HTTP header, not the JSON body")
        XCTAssertEqual(object["prompt_cache_key"] as? String, "ask-session")
        let reasoning = try XCTUnwrap(object["reasoning"] as? [String: String])
        XCTAssertEqual(reasoning["effort"], "low")
        XCTAssertEqual(reasoning["summary"], "auto")
        XCTAssertEqual(object["include"] as? [String], ["reasoning.encrypted_content"])
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let last = try XCTUnwrap(input.last?["content"] as? [[String: String]])
        XCTAssertEqual(last.first?["text"], "next?")
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1, "Only the hosted web tool, never shell or local-file tools")
        XCTAssertEqual(tools[0]["type"] as? String, "web_search")
        XCTAssertEqual(tools[0]["external_web_access"] as? Bool, true)
        XCTAssertEqual(object["tool_choice"] as? String, "auto")
        XCTAssertEqual(object["parallel_tool_calls"] as? Bool, false)
        let overflow = Array(repeating: ("question", "reply"), count: 12)
        let bounded = try ChatGPTChat.requestBody(question: "latest", history: overflow, sessionID: "bounded")
        let boundedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: bounded) as? [String: Any])
        let boundedInput = try XCTUnwrap(boundedObject["input"] as? [[String: Any]])
        XCTAssertEqual(boundedInput.count, 17, "Send at most eight completed turns plus the new question")
    }

    // ASK7: ask for a barrel roll and the ball does one.
    func testASK7BarrelRoll() {
        let (d, s, _) = director()
        d.openAsk()
        d.submitAsk("do a barrel roll")
        XCTAssertEqual(d.barrelRolls, 0)
        s.advance(0.9)
        XCTAssertEqual(d.barrelRolls, 1)
    }

    // AG2: Claude's question waits for your pick while its app is elsewhere; the pick answers through updatedInput.answers.
    func testAG2AnswerAQuestion() throws {
        let (d, _, _) = director()
        let input = #"{"questions":[{"question":"Port it now?","options":[{"label":"Now"},{"label":"Later"}]}]}"#
        let json = #"{"session_id":"q1","cwd":"/tmp/x","tool_name":"AskUserQuestion","tool_input":\#(input)}"#
        let line = AgentSocket.Line(provider: "claude", event: "PreToolUse", host: "", raw: Data(json.utf8))
        XCTAssertTrue(line.waits)
        var answer: String??
        d.agentHook(line, reply: { answer = .some($0) })
        XCTAssertTrue(d.answerable.contains("q1"))
        XCTAssertNil(answer, "held for your pick")
        d.answerQuestion("q1", "Later")
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((answer!!).utf8)) as? [String: Any])
        let hso = try XCTUnwrap(out["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hso["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hso["permissionDecision"] as? String, "allow")
        let updated = try XCTUnwrap(hso["updatedInput"] as? [String: Any])
        XCTAssertEqual((updated["answers"] as? [String: String])?["Port it now?"], "Later")
        XCTAssertNotNil(updated["questions"], "the tool's own input goes back with it")
        XCTAssertEqual(d.island.agents.sessions.first?.state, .working)
    }

    // AG2b: opening the session in its app while its question waits here lets the app ask it at once.
    func testAG2bGoingToTheAppReleasesIt() {
        let (d, _, _) = director()
        let json = #"{"session_id":"q2","cwd":"/tmp/x","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?","options":[{"label":"A"}]}]}}"#
        var answered = false
        d.agentHook(AgentSocket.Line(provider: "claude", event: "PreToolUse", host: "", raw: Data(json.utf8)), reply: { _ in answered = true })
        XCTAssertFalse(answered)
        d.setContext(DesktopContext(frontmostApp: Agents.app(.claude)))
        XCTAssertFalse(answered, "in the app on another session: still answerable from the notch")
        d.setContext(DesktopContext(frontmostApp: Agents.app(.claude), viewedSession: "q2"))
        XCTAssertTrue(answered, "opening that session lets the app ask it")
        XCTAssertFalse(d.answerable.contains("q2"))
    }

    // IDLE1: sessions you've stopped using leave by themselves (owner, 11-07); one that needs you never does; a new
    // event re-arms the timer, and a gone session comes back with its next event.
    func testIDLE1IdleSessionsLeave() {
        let (d, s, _) = director()
        func hook(_ event: String, _ id: String, _ extra: String = "") {
            let json = #"{"session_id":"\#(id)","cwd":"/tmp/p"\#(extra)}"#
            d.agentHook(AgentSocket.Line(provider: "claude", event: event, host: "", raw: Data(json.utf8)), reply: nil)
        }
        hook("UserPromptSubmit", "a"); hook("Stop", "a")                  // done, unread: 30 minutes
        hook("UserPromptSubmit", "b")                                   // working: an hour of silence
        hook("UserPromptSubmit", "c"); hook("PreToolUse", "c", #","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?","options":[]}]}"#)
        s.advance(1700)
        XCTAssertEqual(Set(d.island.agents.sessions.map(\.id)), ["a", "b", "c"])
        hook("UserPromptSubmit", "a"); hook("Stop", "a")                  // used again: the clock restarts
        s.advance(200)
        XCTAssertTrue(d.island.agents.sessions.contains { $0.id == "a" })
        s.advance(1700)
        XCTAssertFalse(d.island.agents.sessions.contains { $0.id == "a" }, "30 minutes after its last event")
        s.advance(2000)
        XCTAssertFalse(d.island.agents.sessions.contains { $0.id == "b" }, "silent for an hour")
        XCTAssertTrue(d.island.agents.sessions.contains { $0.id == "c" }, "it needs you: it stays")
        hook("UserPromptSubmit", "a")
        XCTAssertTrue(d.island.agents.sessions.contains { $0.id == "a" }, "back with its next event")
        XCTAssertEqual(IslandDirector.idleLimit(.ready), 600)
    }

    // CLOSE1 (owner, 11-07: "put an x here so I can close some sessions"): the × on a chip drops that session; its later
    // events are ignored, until it needs you (an approval brings it back).
    func testCLOSE1ClosingASessionFromItsChip() throws {
        let (d, _, _) = director()
        func hook(_ event: String, _ id: String, _ extra: String = "") {
            let json = #"{"session_id":"\#(id)","cwd":"/tmp/p"\#(extra)}"#
            d.agentHook(AgentSocket.Line(provider: "claude", event: event, host: "", raw: Data(json.utf8)), reply: nil)
        }
        hook("UserPromptSubmit", "a"); hook("UserPromptSubmit", "b")
        let a = try XCTUnwrap(d.island.agents.sessions.first { $0.id == "a" })
        d.closeSession(a)
        XCTAssertEqual(d.island.agents.sessions.map(\.id), ["b"])
        hook("PreToolUse", "a", #","tool_name":"Bash""#); hook("Stop", "a")
        XCTAssertFalse(d.island.agents.sessions.contains { $0.id == "a" }, "no longer followed")
        hook("PermissionRequest", "a", #","tool_name":"Bash""#)
        XCTAssertEqual(d.island.agents.sessions.first { $0.id == "a" }?.state, .needs, "it needs you: back")
    }

    // ASK8: the Ask chat stays open while you use the screen (owner, 11-07); Esc / × close it; asking again opens the
    // conversation you have, the `+` a new one.
    func testASK8StaysOpenAndContinues() {
        let (d, s, _) = director()
        d.openAsk(); d.submitAsk("first")
        XCTAssertTrue(d.island.holdsOpen)
        d.pointerMoved(hit: nil, corridor: false, buttonDown: false)
        s.advance(5)
        d.clickOutside()
        XCTAssertTrue(d.island.opened, "leaving and clicking elsewhere keep it open")
        d.closeAsk()
        XCTAssertFalse(d.island.opened)
        let focus = d.askFocusTick
        d.openAsk()
        XCTAssertEqual(d.groups.agentsCard, .ask, "asking again opens the conversation you have")
        XCTAssertNil(d.island.askOpen)
        XCTAssertGreaterThan(d.askFocusTick, focus, "with its field ready")
        d.openAsk(new: true)
        XCTAssertNotNil(d.island.askOpen, "the + starts a new one")
    }

    // ASK9: initial questions and follow-ups send text immediately, with no attachment steps or setup prompts.
    func testASK9TextOnlyQuestionsAndFollowUps() throws {
        for backend in [AgentProvider.claude, .codex] {
            let (d, _, _) = director()
            var setupRequests = 0
            d.onNeedsSetup = { setupRequests += 1 }
            let question = "Explain this Swift error:\nvalue of type 'Int' has no member 'count'."
            let followUp = "Show the correction.\nKeep the example short."
            let answer = "Use count on the collection instead of its element."

            d.openAsk(backend)
            XCTAssertEqual(setupRequests, 0, "opening Ask never requests permissions")
            XCTAssertTrue(sentBox().isEmpty)
            d.submitAsk(" \n\(question)\n ")

            let session = try XCTUnwrap(d.island.agents.sessions.first)
            XCTAssertEqual(sentBox().count, 1, "the question sends before submitAsk returns")
            XCTAssertEqual(sentBox().first?.0, session.id)
            XCTAssertEqual(sentBox().first?.1, backend)
            XCTAssertEqual(sentBox().first?.2, question)
            XCTAssertEqual(d.agentChats[session.id], [.you(question)], "no attachment or tool messages are inserted")
            XCTAssertEqual(setupRequests, 0, "submitting text never opens Setup")

            d.askEvent(session.id, .delta(answer))
            d.askEvent(session.id, .done(error: nil))
            d.closeAsk()
            d.openAsk()
            XCTAssertEqual(setupRequests, 0, "reopening the conversation never requests permissions")
            XCTAssertEqual(d.replyPlaceholder(session), "Ask a follow-up")
            d.replyAgent(session, " \n\(followUp)\n ")

            XCTAssertEqual(sentBox().count, 2, "the follow-up also sends synchronously")
            XCTAssertEqual(sentBox().last?.0, session.id)
            XCTAssertEqual(sentBox().last?.1, backend, "the original backend handles the follow-up")
            XCTAssertEqual(sentBox().last?.2, followUp)
            XCTAssertEqual(d.agentChats[session.id], [.you(question), .agent(answer), .you(followUp)])
            XCTAssertEqual(setupRequests, 0, "follow-ups never open Setup")
            XCTAssertEqual(d.island.agents.sessions.count, 1)
        }
    }

    func testASK9EmptyTextDoesNotSend() throws {
        let (d, _, _) = director()
        var setupRequests = 0
        d.onNeedsSetup = { setupRequests += 1 }
        d.openAsk(.claude)
        d.submitAsk(" \n\t ")
        XCTAssertTrue(sentBox().isEmpty)
        XCTAssertTrue(d.island.agents.sessions.isEmpty)
        XCTAssertEqual(d.island.askOpen, .claude)

        d.submitAsk("A text-only question")
        let session = try XCTUnwrap(d.island.agents.sessions.first)
        d.askEvent(session.id, .done(error: nil))
        d.replyAgent(session, " \n\t ")
        XCTAssertEqual(sentBox().count, 1, "an empty follow-up does not start another turn")
        XCTAssertEqual(d.agentChats[session.id], [.you("A text-only question")])
        XCTAssertEqual(setupRequests, 0)
    }

    // KEY1: ⌥Space alone opens Ask; with ⌘, ⌃ or ⇧ it's someone else's.
    func testKEY1AskChord() {
        XCTAssertTrue(MediaKeyTap.isAskChord([.maskAlternate]))
        XCTAssertFalse(MediaKeyTap.isAskChord([.maskAlternate, .maskCommand]))
        XCTAssertFalse(MediaKeyTap.isAskChord([.maskAlternate, .maskShift]))
        XCTAssertFalse(MediaKeyTap.isAskChord([]))
    }

    // ASK10: the shortcut toggles Ask; it opens into the last conversation only within 10 minutes of its last message.
    func testASK10ToggleAndContinueWindow() {
        let (d, _, _) = director()
        var now = Date(timeIntervalSinceReferenceDate: 5000)
        d.date = { now }
        d.toggleAsk()
        XCTAssertNotNil(d.island.askOpen, "nothing going: the ask card")
        d.toggleAsk()
        XCTAssertFalse(d.island.opened, "again: it closes")
        d.toggleAsk(); d.submitAsk("first")
        d.toggleAsk()
        XCTAssertFalse(d.island.opened, "the chat closes too")
        now += 300
        d.toggleAsk()
        XCTAssertEqual(d.groups.agentsCard, .ask, "5 minutes later: the same conversation")
        d.toggleAsk()
        now += 700
        d.toggleAsk()
        XCTAssertNotNil(d.island.askOpen, "15 minutes since its last message: a fresh question")
    }

    // INTENT1: passing over the island fast opens nothing; settling on it opens the preview.
    func testINTENT1PassingThrough() {
        let (d, _, _) = director()
        d.startMusic()
        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false, settled: false)
        XCTAssertFalse(d.island.hovered, "just passing through")
        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false, settled: true)
        XCTAssertTrue(d.island.hovered)
    }

    // VIEW2: the viewed Claude session is the record focused last; a record is read again only when it changes.
    func testVIEW2FocusedSessionReader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ln-view2-\(UUID().uuidString)/acct/org")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func record(_ name: String, _ cli: String, _ focused: Double) throws {
            let json = #"{"cliSessionId":"\#(cli)","lastFocusedAt":\#(focused),"title":"t"}"#
            try Data(json.utf8).write(to: root.appendingPathComponent("local_\(name).json"))
        }
        try record("a", "cli-a", 1000)
        try record("b", "cli-b", 2000)
        let dir = AgentDirectory(claudeSessions: root.deletingLastPathComponent().deletingLastPathComponent(), codexHome: root)
        let cache = FocusedSessionCache()
        XCTAssertEqual(dir.focusedClaudeSession(cache: cache), "cli-b")
        try record("a", "cli-a", 3000)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: root.appendingPathComponent("local_a.json").path)
        XCTAssertEqual(dir.focusedClaudeSession(cache: cache), "cli-a", "switching sessions in the app")
        // The window's title wins at once (the record's focus time lands ~3 s later).
        let json = #"{"cliSessionId":"cli-c","lastFocusedAt":10,"title":"Mac suite lid click behavior"}"#
        try Data(json.utf8).write(to: root.appendingPathComponent("local_c.json"))
        XCTAssertEqual(dir.focusedClaudeSession(title: "Mac suite lid click behavior", cache: cache), "cli-c")
        XCTAssertEqual(ClaudeWindowTitle.session("Mac suite lid click behavior - Claude Code"), "Mac suite lid click behavior")
        XCTAssertNil(ClaudeWindowTitle.session("Claude"))
    }

    // VIEW3: watched (the Claude app in front), the folder is listed once; after that a read touches only the records
    // FSEvents names, so switching, a new session and a removed one still land, and nothing else is listed or stat'ed.
    func testVIEW3WatchedReadsOnlyChangedRecords() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ln-view3-\(UUID().uuidString)")
        let root = base.appendingPathComponent("acct/org")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func record(_ name: String, _ cli: String, _ focused: Double, _ title: String) throws {
            let json = #"{"cliSessionId":"\#(cli)","lastFocusedAt":\#(focused),"title":"\#(title)"}"#
            try Data(json.utf8).write(to: root.appendingPathComponent("local_\(name).json"), options: .atomic)
        }
        func soon(_ check: () -> Bool) -> Bool {
            for _ in 0..<150 { if check() { return true }; Thread.sleep(forTimeInterval: 0.02) }
            return false
        }
        try record("a", "cli-a", 1000, "Alpha")
        try record("b", "cli-b", 2000, "Beta")
        let dir = AgentDirectory(claudeSessions: base, codexHome: base)
        let cache = FocusedSessionCache()
        cache.watch(base)
        defer { cache.watch(nil) }
        XCTAssertEqual(dir.focusedClaudeSession(cache: cache), "cli-b")
        XCTAssertEqual(dir.focusedClaudeSession(title: "Alpha", cache: cache), "cli-a")
        XCTAssertEqual(cache.listings, 1, "listed once, then read from memory")
        try record("a", "cli-a", 3000, "Alpha")
        XCTAssertTrue(soon { dir.focusedClaudeSession(cache: cache) == "cli-a" }, "switching sessions in the app")
        try record("c", "cli-c", 10, "Gamma")
        XCTAssertTrue(soon { dir.focusedClaudeSession(title: "Gamma", cache: cache) == "cli-c" }, "a new session")
        try FileManager.default.removeItem(at: root.appendingPathComponent("local_a.json"))
        XCTAssertTrue(soon { dir.focusedClaudeSession(cache: cache) == "cli-b" }, "a removed session")
        XCTAssertEqual(cache.listings, 1)
        // Unwatched (the app not in front), every read lists the folder, as before.
        cache.watch(nil)
        XCTAssertEqual(dir.focusedClaudeSession(cache: cache), "cli-b")
        XCTAssertEqual(cache.listings, 2)
    }
}
