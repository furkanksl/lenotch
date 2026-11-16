import AppKit
import WebKit

/// Opt-in real-account handshake probe. Uses silent generated audio, never the microphone.
/// Logs only stages and sanitized failures, not credentials, SDP, audio, or account identity.
@MainActor
final class ChatGPTVoiceDiagnostic: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var transport: WebRTCVoiceTransport?
    private var client: ChatGPTVoiceClient?
    private var work: Task<Void, Never>?
    private var connected = false
    private var failure: String?
    private let worker = ChatGPTVoiceWork()
    private var delegatedWork: Task<Void, Never>?
    private var receivedDelegation = false
    private var submittedResult = false
    private var receivedFinalTranscript = false
    private var receivedFinalAudio = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 420, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Lenotch voice diagnostic — synthetic audio"
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 360))
        window.contentView = host
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let peer = WebRTCVoiceTransport(syntheticAudio: true)
        peer.attach(to: host)
        transport = peer
        peer.onEvent = { [weak self] event in
            switch event {
            case .connected: self?.connected = true; Self.report("WebRTC connected")
            case .failed(let message): self?.failure = message; Self.report("Transport failed: \(message)")
            case .disconnected: self?.failure = "WebRTC disconnected"
            case .workRequested(let id, let text):
                guard let self, !self.receivedDelegation else { return }
                self.receivedDelegation = true
                Self.report("Realtime delegated a task to the client")
                self.delegatedWork = Task {
                    do {
                        self.worker.onStatus = { Self.report("Worker: \($0)") }
                        let result = try await self.worker.run(text)
                        Self.report("Worker completed; returning its actual result to voice")
                        guard let client = self.client else { throw CancellationError() }
                        try await client.sendDelegationResult(id: id, text: result)
                        self.submittedResult = true
                        Self.report("Task result returned to realtime")
                    } catch { self.failure = "Delegated task did not complete: \(error.localizedDescription)" }
                }
            case .assistantTranscript:
                if self?.submittedResult == true { self?.receivedFinalTranscript = true; Self.report("Received a spoken-result transcript after task completion") }
            case .assistantSpeaking:
                if self?.submittedResult == true { self?.receivedFinalAudio = true; Self.report("Received result audio after task completion") }
            default: break
            }
        }
        work = Task {
            do {
                Self.report("Starting real ChatGPT-account handshake with generated silent audio; no microphone capture")
                let client = ChatGPTVoiceClient()
                self.client = client
                client.onEvent = peer.onEvent
                client.onDiagnostic = { Self.report("Backend: \($0)") }
                try await client.prepare()
                Self.report("Connected-account credentials ready")
                let inspection = Task { [weak self = self] in
                    for _ in 0..<8 {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        await self?.inspect()
                    }
                }
                defer { inspection.cancel() }
                let offer = try await peer.makeOffer()
                Self.report("Synthetic-audio SDP offer created; sending the production voice request")
                let answer = try await client.connect(offer: offer)
                Self.report("ChatGPT accepted the voice request and returned an audio SDP answer")
                try await peer.acceptAnswer(answer)
                try await client.startEvents()
                Self.report("Native voice work/event sideband connected")
                for _ in 0..<100 {
                    if connected || failure != nil { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                Self.report(connected ? "RESULT: real voice handshake connected" : "RESULT: call accepted but WebRTC did not connect")
                if connected, CommandLine.arguments.contains("--voice-research-diagnostic") {
                    if let flag = CommandLine.arguments.firstIndex(of: "--voice-diagnostic-audio"), flag + 1 < CommandLine.arguments.count {
                        let audio = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                        try await peer.playGeneratedAudio(audio)
                        Self.report("Sent a generated spoken research request over real WebRTC audio; no microphone capture")
                    } else {
                        try await client.sendText("Please delegate to your client assistant to search the web for the current stable Python release on python.org, then tell me the verified result. Do not answer from memory.")
                        Self.report("Sent a public-information research request over the native voice sideband")
                    }
                    for _ in 0..<600 {
                        if receivedFinalTranscript && receivedFinalAudio || failure != nil { break }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    Self.report("RESEARCH RESULT: delegated=\(receivedDelegation), resultSent=\(submittedResult), transcript=\(receivedFinalTranscript), audio=\(receivedFinalAudio)")
                    if let failure { Self.report(failure) }
                }
            } catch { Self.report("RESULT: \(error.localizedDescription)") }
            delegatedWork?.cancel(); worker.cancel()
            client?.stop()
            peer.stop()
            Self.report("Stopped generated audio and closed the call")
            window.close()
            NSApp.terminate(nil)
        }
    }

    private func inspect() async {
        guard let peer = transport else { return }
        Self.report("Native host: visible=\(window?.isVisible == true), unoccluded=\(window?.occlusionState.contains(.visible) == true), webView=\(peer.webView != nil)")
        guard let view = peer.webView else { return }
        let script = "JSON.stringify({visibility:document.visibilityState,readyState:document.readyState,secure:window.isSecureContext,bridge:typeof window.lenotchVoice})"
        if let info = try? await view.evaluateJavaScript(script) as? String { Self.report("Local page: \(info)") }
    }

    private static func report(_ message: String) {
        print("[voice-diagnostic] \(message)")
        fflush(stdout)
    }
}
