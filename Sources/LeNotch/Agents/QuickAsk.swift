import Foundation
import IslandCore
import os

/// Quick ask (agents phase 3, docs/superpowers/specs/2026-11-06-quick-ask-native-design.md): questions the notch asks on
/// the owner's own plans (no API keys). Claude uses `claude -p`; ChatGPT uses the
/// signed-in account over HTTPS, without starting or borrowing credentials from the Codex CLI.
@MainActor
final class QuickAsk {
    enum Event: Equatable {
        /// Text as it arrives from the selected provider.
        case delta(String)
        /// A tool started (web search, a fetch).
        case tool(String)
        case done(error: String?)
    }

    /// The working folder distinguishes the notch's own Claude questions from agent hooks.
    nonisolated static var workspace: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("lenotch/Ask", isDirectory: true)
    }

    nonisolated static let systemPrompt = """
        You answer quick text questions asked from the Mac's notch (LeNotch). Be brief and direct: one to four short \
        sentences unless more is asked for, plain text, light Markdown at most. No preamble.
        """

    static var claudeExecutable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var onEvent: ((String, Event) -> Void)?
    private var claude: [String: ClaudeProcess] = [:]
    private var chatGPT: [String: ChatGPTChat] = [:]

    /// Asks `text` in session `id` (a new one, or a follow-up).
    func ask(_ id: String, provider: AgentProvider, text: String) {
        let emit: (Event) -> Void = { [weak self] e in self?.onEvent?(id, e) }
        switch provider {
        case .claude, .ask:
            try? FileManager.default.createDirectory(at: Self.workspace, withIntermediateDirectories: true)
            let p = claude[id] ?? ClaudeProcess(emit: emit)
            claude[id] = p
            p.ask(text)
        case .codex:
            let c = chatGPT[id] ?? ChatGPTChat(emit: emit)
            chatGPT[id] = c
            c.ask(text)
        }
    }

    /// The session left the island: its process goes too.
    func end(_ id: String) {
        claude.removeValue(forKey: id)?.stop()
        chatGPT.removeValue(forKey: id)?.stop()
    }

    func stopAll() {
        for id in Array(claude.keys) + Array(chatGPT.keys) { end(id) }
    }
}

// MARK: - Claude

@MainActor
private final class ClaudeProcess {
    private let emit: (QuickAsk.Event) -> Void
    private var proc: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var idle: Timer?
    private var sawText = false
    private var needsBreak = false
    private var outstanding = 0
    private var generation = 0
    private var sessionID: String?
    nonisolated private static let log = Logger(subsystem: "com.lenotch.app", category: "ask")

    init(emit: @escaping (QuickAsk.Event) -> Void) { self.emit = emit }

    func ask(_ text: String) {
        if proc?.isRunning != true { start() }
        guard proc?.isRunning == true else { return }
        idle?.invalidate()
        outstanding += 1
        sawText = false
        let content: [[String: Any]] = [["type": "text", "text": text]]
        write(["type": "user", "message": ["role": "user", "content": content]])
    }

    func stop() {
        idle?.invalidate()
        try? stdin?.close()
        stdin = nil
        let p = proc
        proc = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p?.isRunning == true { p?.terminate() } }
    }

    private func start() {
        guard let exe = QuickAsk.claudeExecutable else {
            emit(.done(error: "Can't find the claude command on this Mac (install Claude Code to ask Claude)."))
            return
        }
        let p = Process()
        p.executableURL = exe
        p.currentDirectoryURL = QuickAsk.workspace
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--model", "sonnet", "--setting-sources", "", "--strict-mcp-config",
                    "--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch", "WebFetch",
                    "--system-prompt", QuickAsk.systemPrompt]
        if let sessionID { args += ["--resume", sessionID] }
        p.arguments = args
        p.environment = Self.environment
        let i = Pipe(), o = Pipe(), e = Pipe()
        generation += 1
        let gen = generation
        p.standardInput = i
        p.standardOutput = o
        p.standardError = e
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.generation == gen { self?.consume(d) } } }
        }
        e.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            Self.log.debug("claude stderr: \(String(decoding: d.prefix(400), as: UTF8.self), privacy: .public)")
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(proc, gen) } }
        }
        do {
            try p.run()
            proc = p
            stdin = i.fileHandleForWriting
        } catch {
            emit(.done(error: "Couldn't start claude: \(error.localizedDescription)"))
        }
    }

    nonisolated static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        return env
    }

    private func write(_ obj: [String: Any]) {
        guard let stdin, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        try? stdin.write(contentsOf: data)
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            for e in Self.parse(Data(line), sawText: &sawText, needsBreak: &needsBreak, session: &sessionID) { handle(e) }
        }
    }

    private func handle(_ e: QuickAsk.Event) {
        if case .done = e {
            outstanding = max(0, outstanding - 1)
            guard outstanding == 0 else { return }
            armIdle()
        }
        emit(e)
    }

    private func armIdle() {
        idle?.invalidate()
        let t = Timer(timeInterval: 15 * 60, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        RunLoop.main.add(t, forMode: .common)
        idle = t
    }

    private func exited(_ p: Process, _ gen: Int) {
        guard gen == generation else { return }
        proc = nil
        if outstanding > 0 {
            outstanding = 0
            emit(.done(error: "Claude stopped unexpectedly."))
        }
    }

    /// One stream-json line → events (tested): the session id, text deltas (a paragraph break between text blocks),
    /// tool starts, the result.
    nonisolated static func parse(_ line: Data, sawText: inout Bool, needsBreak: inout Bool, session: inout String?) -> [QuickAsk.Event] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = obj["type"] as? String else { return [] }
        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let sid = obj["session_id"] as? String { session = sid }
        case "stream_event":
            if let parent = obj["parent_tool_use_id"], !(parent is NSNull) { return [] }
            guard let ev = obj["event"] as? [String: Any], let evType = ev["type"] as? String else { return [] }
            if evType == "content_block_start", let block = ev["content_block"] as? [String: Any] {
                if block["type"] as? String == "tool_use", let name = block["name"] as? String { return [.tool(name)] }
                if block["type"] as? String == "text", sawText { needsBreak = true }
            } else if evType == "content_block_delta", let delta = ev["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta", var text = delta["text"] as? String {
                if needsBreak { text = "\n\n" + text; needsBreak = false }
                sawText = true
                return [.delta(text)]
            }
        case "result":
            let isError = obj["is_error"] as? Bool ?? false, subtype = obj["subtype"] as? String ?? ""
            return [.done(error: isError || subtype.hasPrefix("error") ? (obj["result"] as? String ?? subtype) : nil)]
        default: break
        }
        return []
    }
}

/// Tests reach the parsers through these.
enum QuickAskParsing {
    static func claude(_ lines: [String]) -> [QuickAsk.Event] {
        var saw = false, brk = false, sid: String?
        return lines.flatMap { ClaudeProcess.parse(Data($0.utf8), sawText: &saw, needsBreak: &brk, session: &sid) }
    }

}
