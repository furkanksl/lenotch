import AppKit
import OSLog
import WebKit

/// SDP and account authentication stay in native code. The local page owns only media.
@MainActor
protocol ChatGPTVoiceTransport: AnyObject {
    var onEvent: ((ChatGPTVoiceTransportEvent) -> Void)? { get set }
    func attach(to host: NSView)
    func makeOffer() async throws -> String
    func acceptAnswer(_ sdp: String) async throws
    func setMuted(_ muted: Bool)
    func stop()
}

enum ChatGPTVoiceTransportEvent: Equatable, Sendable {
    case connected, disconnected
    case userSpeaking, userStoppedSpeaking
    case assistantSpeaking, assistantStoppedSpeaking
    /// Transcript events contain the current turn's complete text, not a delta.
    case userTranscript(String), assistantTranscript(String)
    case level(Double)
    case failed(String)
}

enum ChatGPTVoiceTransportError: LocalizedError {
    case busy, notReady, unsupported, timedOut(String), invalidAnswer, bridge(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "A voice connection is already starting."
        case .notReady: return "Start a new voice conversation before connecting."
        case .unsupported: return "This Mac's WebKit cannot capture audio for voice conversations."
        case .timedOut(let message): return message
        case .invalidAnswer: return "ChatGPT returned an invalid voice connection."
        case .bridge(let message): return message
        }
    }
}

@MainActor
final class WebRTCVoiceTransport: NSObject, ChatGPTVoiceTransport {
    struct Capabilities: Equatable, Sendable {
        let secureContext: Bool
        let mediaDevices: Bool
        let peerConnection: Bool
        var supported: Bool { secureContext && mediaDevices && peerConnection }
    }

    var onEvent: ((ChatGPTVoiceTransportEvent) -> Void)?
    private(set) var capabilities: Capabilities?
    private(set) var webView: WKWebView?
    private weak var hostView: NSView?
    private let logger = Logger(subsystem: "com.lenotch.app", category: "ChatGPTVoice")
    private var startupStage = "Loading the voice engine timed out. Reopen voice mode and try again."
    private var bridge: VoiceScriptBridge?
    private let timeout: TimeInterval
    private let syntheticAudio: Bool
    private var generation = UUID().uuidString
    private var state: State = .idle
    private var microphoneRequested = false
    private var muted = false
    private var firstNavigation = true
    private var navigationFinished = false
    private var readyRequestID: String?
    private var pending: [String: Pending] = [:]
    private var connectionTimeout: Task<Void, Never>?
    private var connected = false
    private var decoder = ChatGPTVoiceEventDecoder()

    private enum State { case idle, loading, ready, offering, offered, answering, active, stopped }
    private struct Pending {
        let continuation: CheckedContinuation<String, Error>
        let timeout: Task<Void, Never>
    }
    static let documentURL = URL(string: "https://lenotch.invalid/")!

    init(timeout: TimeInterval = 25, syntheticAudio: Bool = false) {
        self.timeout = max(0.01, timeout)
        self.syntheticAudio = syntheticAudio
        super.init()
    }

    isolated deinit { tearDown(error: CancellationError()) }

    func attach(to host: NSView) { hostView = host }

    private var hostIsVisible: Bool {
        guard let hostView, let window = hostView.window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
            && !hostView.isHiddenOrHasHiddenAncestor && !hostView.visibleRect.isEmpty
    }

    /// Loads and checks the owned document without requesting microphone access.
    /// Also used by native capability tests. Normal callers use makeOffer().
    @discardableResult
    func prepare() async throws -> Capabilities {
        if state == .ready, let capabilities { return capabilities }
        guard state == .idle || state == .stopped else { throw ChatGPTVoiceTransportError.busy }
        state = .loading
        capabilities = nil
        let current = generation
        do {
            // WebKit defers media capture in invisible windows. Wait for SwiftUI to mount
            // the media host in the real voice card instead of using an offscreen window.
            for _ in 0..<100 {
                if hostIsVisible { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            guard hostIsVisible else {
                throw ChatGPTVoiceTransportError.bridge("The voice view isn't visible. Reopen Chat and try again.")
            }
            startupStage = "Loading the voice engine timed out. Reopen voice mode and try again."
            _ = try await command("prepare")
            try Task.checkCancellation()
            guard generation == current, let capabilities else { throw CancellationError() }
            guard capabilities.supported else { throw ChatGPTVoiceTransportError.unsupported }
            state = .ready
            return capabilities
        } catch {
            if generation == current { tearDown(error: error) }
            throw error
        }
    }

    func makeOffer() async throws -> String {
        guard state == .idle || state == .stopped || state == .ready else {
            throw ChatGPTVoiceTransportError.busy
        }
        _ = try await prepare()
        try Task.checkCancellation()
        state = .offering
        microphoneRequested = true
        let current = generation
        do {
            let offer = try await command("offer", arguments: ["muted": muted, "syntheticAudio": syntheticAudio])
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            guard offer.hasPrefix("v=0"), offer.utf8.count <= 256_000 else {
                throw ChatGPTVoiceTransportError.bridge("WebKit did not create a voice connection.")
            }
            state = .offered
            return offer
        } catch {
            if generation == current { tearDown(error: error) }
            throw error
        }
    }

    func acceptAnswer(_ sdp: String) async throws {
        guard state == .offered else { throw ChatGPTVoiceTransportError.notReady }
        guard sdp.hasPrefix("v=0"), sdp.utf8.count <= 256_000 else {
            tearDown(error: ChatGPTVoiceTransportError.invalidAnswer)
            throw ChatGPTVoiceTransportError.invalidAnswer
        }
        state = .answering
        let current = generation
        do {
            _ = try await command("answer", arguments: ["sdp": sdp])
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            state = .active
            if !connected {
                connectionTimeout = Task { @MainActor [weak self, timeout] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    guard let self, generation == current, !connected else { return }
                    fail("The voice audio connection timed out. Check your network and try again.")
                }
            }
        } catch {
            if generation == current { tearDown(error: error) }
            throw error
        }
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        send(["action": "mute", "muted": muted])
        if muted { onEvent?(.userStoppedSpeaking) }
    }

    func stop() { tearDown(error: CancellationError()) }

    private func command(_ action: String, arguments: [String: Any] = [:]) async throws -> String {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { @MainActor [weak self, timeout] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    guard let self, pending[id] != nil else { return }
                    logger.error("Voice startup timeout: \(self.startupStage, privacy: .public)")
                    fail(ChatGPTVoiceTransportError.timedOut(startupStage).localizedDescription)
                }
                pending[id] = Pending(continuation: continuation, timeout: timer)
                if action == "prepare" {
                    readyRequestID = id
                    createDocument()
                } else {
                    var payload = arguments
                    payload["action"] = action
                    payload["id"] = id
                    send(payload)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, pending[id] != nil else { return }
                tearDown(error: CancellationError())
            }
        }
    }

    private func createDocument() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let handler = VoiceScriptBridge(owner: self)
        bridge = handler
        configuration.userContentController.add(handler, name: "voice")
        let view = WKWebView(frame: hostView?.bounds ?? NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        hostView?.addSubview(view)
        view.loadHTMLString(Self.document(generation: generation), baseURL: Self.documentURL)
    }

    private func send(_ payload: [String: Any]) {
        guard let view = webView,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        let current = generation
        view.evaluateJavaScript("window.lenotchVoice.command(\(json))") { [weak self] _, error in
            guard let self, generation == current, error != nil else { return }
            fail("The local voice engine stopped responding. Try again.")
        }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let view = webView, message.webView === view,
              Self.isOwnedFrame(message.frameInfo),
              let body = message.body as? [String: Any], body["generation"] as? String == generation,
              let kind = body["kind"] as? String else { return }
        switch kind {
        case "stage":
            guard let stage = body["value"] as? String else { return }
            switch stage {
            case "microphone": startupStage = "The microphone didn't start. Check microphone access and your input device, then retry."
            case "audio": startupStage = "The voice audio engine didn't start. Reopen voice mode and try again."
            case "offer": startupStage = "Voice network setup timed out. Check your network and try again."
            default: return
            }
            logger.info("Voice startup: \(stage, privacy: .public)")
        case "ready":
            capabilities = Capabilities(secureContext: body["secureContext"] as? Bool == true,
                                        mediaDevices: body["mediaDevices"] as? Bool == true,
                                        peerConnection: body["peerConnection"] as? Bool == true)
            finishReadiness()
        case "result":
            if let id = body["id"] as? String { resolve(id, result: .success(body["value"] as? String ?? "")) }
        case "commandError":
            let message = String((body["message"] as? String ?? "The voice connection failed.").prefix(500))
            if let id = body["id"] as? String {
                resolve(id, result: .failure(ChatGPTVoiceTransportError.bridge(message)))
            }
        case "failed": fail(String((body["message"] as? String ?? "The voice connection failed.").prefix(500)))
        case "connected":
            connectionTimeout?.cancel()
            connectionTimeout = nil
            if !connected { connected = true; onEvent?(.connected) }
        case "disconnected":
            tearDown(error: ChatGPTVoiceTransportError.bridge("The voice connection closed."))
            onEvent?(.disconnected)
        case "level":
            if let value = body["value"] as? Double, value.isFinite { onEvent?(.level(min(1, max(0, value)))) }
        case "userSpeaking": onEvent?(.userSpeaking)
        case "userStoppedSpeaking": onEvent?(.userStoppedSpeaking)
        case "assistantSpeaking": onEvent?(.assistantSpeaking)
        case "assistantStoppedSpeaking": onEvent?(.assistantStoppedSpeaking)
        case "realtime":
            if let payload = body["payload"] as? [String: Any] {
                for event in decoder.decode(payload) {
                    if case .failed(let message) = event { fail(message); break }
                    onEvent?(event)
                }
            }
        default: break
        }
    }

    private func finishReadiness() {
        guard navigationFinished, capabilities != nil, let id = readyRequestID else { return }
        readyRequestID = nil
        resolve(id, result: .success(""))
    }

    private func resolve(_ id: String, result: Result<String, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func fail(_ message: String) {
        guard state != .stopped else { return }
        tearDown(error: ChatGPTVoiceTransportError.bridge(message))
        onEvent?(.failed(message))
    }

    private func tearDown(error: Error) {
        state = .stopped
        microphoneRequested = false
        connectionTimeout?.cancel()
        connectionTimeout = nil
        connected = false
        generation = UUID().uuidString
        readyRequestID = nil
        firstNavigation = true
        navigationFinished = false
        decoder = ChatGPTVoiceEventDecoder()
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
        if let view = webView {
            // Stop capture natively as well, even if JS is unresponsive or still awaiting permission.
            view.setMicrophoneCaptureState(.none, completionHandler: nil)
            view.pauseAllMediaPlayback(completionHandler: nil)
            view.evaluateJavaScript("window.lenotchVoice?.stop()", completionHandler: nil)
            view.configuration.userContentController.removeScriptMessageHandler(forName: "voice")
            view.stopLoading()
            view.navigationDelegate = nil
            view.uiDelegate = nil
            view.removeFromSuperview()
        }
        webView = nil
        bridge = nil
    }

    private static func isOwnedFrame(_ frame: WKFrameInfo) -> Bool {
        frame.isMainFrame && isOwnedOrigin(scheme: frame.securityOrigin.protocol,
                                          host: frame.securityOrigin.host, port: frame.securityOrigin.port)
    }

    static func isOwnedOrigin(scheme: String, host: String, port: Int) -> Bool {
        scheme == "https" && host == "lenotch.invalid" && (port == 0 || port == 443)
    }
}

@MainActor
private final class VoiceScriptBridge: NSObject, WKScriptMessageHandler {
    weak var owner: WebRTCVoiceTransport?
    init(owner: WebRTCVoiceTransport) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

extension WebRTCVoiceTransport: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let initial = firstNavigation && navigationAction.navigationType == .other
            && navigationAction.targetFrame?.isMainFrame == true
            && (url == Self.documentURL || url?.absoluteString == "about:blank")
        firstNavigation = false
        decisionHandler(initial ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        navigationFinished = true
        finishReadiness()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { fail("The local voice engine could not load. Try again.") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { fail("The local voice engine could not load. Try again.") }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { fail("The local voice engine closed. Try again.") }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let allowed = webView === self.webView && microphoneRequested && state != .stopped
            && type == .microphone && Self.isOwnedFrame(frame)
            && Self.isOwnedOrigin(scheme: origin.protocol, host: origin.host, port: origin.port)
        decisionHandler(allowed ? .grant : .deny)
    }
}

/// Supports the public Realtime events and Codex's Quicksilver frameless transcripts.
/// Audio bytes are never decoded here; WebRTC plays the remote audio track directly.
struct ChatGPTVoiceEventDecoder {
    private var userText = ""
    private var assistantText = ""
    private var userFinished = false
    private var assistantFinished = false
    private static let limit = 16_000

    mutating func decode(_ payload: [String: Any]) -> [ChatGPTVoiceTransportEvent] {
        guard let type = payload["type"] as? String else { return [] }
        switch type {
        case "input_audio_buffer.speech_started":
            userText = ""; userFinished = false
            return [.userSpeaking]
        case "input_audio_buffer.speech_stopped": return [.userStoppedSpeaking]
        case "output_audio_buffer.started": return [.assistantSpeaking]
        case "output_audio_buffer.stopped", "output_audio_buffer.cleared": return [.assistantStoppedSpeaking]
        case "response.created":
            assistantText = ""; assistantFinished = false
            return []
        case "response.done":
            assistantFinished = true
            return []
        case "conversation.item.input_audio_transcription.delta", "input_transcript.added":
            guard let delta = transcriptDelta(payload) else { return [] }
            if userFinished { userText = ""; userFinished = false }
            userText = String((userText + delta).prefix(Self.limit))
            return [.userTranscript(userText)]
        case "conversation.item.input_audio_transcription.completed":
            guard let text = payload["transcript"] as? String else { return [] }
            userText = String(text.prefix(Self.limit)); userFinished = true
            return [.userTranscript(userText)]
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta", "response.output_text.delta", "output_transcript.added":
            guard let delta = transcriptDelta(payload) else { return [] }
            if assistantFinished { assistantText = ""; assistantFinished = false }
            assistantText = String((assistantText + delta).prefix(Self.limit))
            return [.assistantTranscript(assistantText)]
        case "response.audio_transcript.done", "response.output_audio_transcript.done", "response.output_text.done":
            guard let text = (payload["transcript"] ?? payload["text"]) as? String else { return [] }
            assistantText = String(text.prefix(Self.limit)); assistantFinished = true
            return [.assistantTranscript(assistantText)]
        case "turn.done":
            guard let turn = payload["turn"] as? [String: Any], let text = turn["transcript"] as? String else { return [] }
            if turn["role"] as? String == "user" {
                userText = String(text.prefix(Self.limit)); userFinished = true
                return [.userTranscript(userText), .userStoppedSpeaking]
            }
            if turn["role"] as? String == "assistant" {
                assistantText = String(text.prefix(Self.limit)); assistantFinished = true
                return [.assistantTranscript(assistantText)]
            }
            return []
        case "error", "conversation.item.input_audio_transcription.failed":
            let error = payload["error"] as? [String: Any]
            return [.failed(String((error?["message"] as? String ?? "ChatGPT could not continue this voice conversation.").prefix(500)))]
        default: return []
        }
    }

    private func transcriptDelta(_ payload: [String: Any]) -> String? {
        (payload["delta"] as? String) ?? ((payload["item"] as? [String: Any])?["text"] as? String)
    }
}

extension WebRTCVoiceTransport {
    static func document(generation: String) -> String {
        // The only executable script is inline and nonce-bound. No fetch, sockets, tokens,
        // cookies, remote scripts, frames or navigation are needed to exchange SDP.
        let nonce = UUID().uuidString
        let session = String(data: try! JSONSerialization.data(withJSONObject: [generation]), encoding: .utf8)!
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; connect-src 'none'; media-src blob:; style-src 'unsafe-inline'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="referrer" content="no-referrer"><style>html,body{margin:0;background:#000}</style>
        </head><body><script nonce="\(nonce)">
        (() => {
            'use strict';
            const generation = \(session)[0];
            const post = (kind, extra = {}) => window.webkit.messageHandlers.voice.postMessage({kind, generation, ...extra});
            let peer = null, channel = null, local = null, remote = null, audio = null;
            let context = null, sources = [], analysers = [], meter = null, stopped = false;
            let assistantSpeaking = false, lastRemoteVoice = 0;
            let userSpeaking = false, lastLocalVoice = 0, microphoneMuted = false;
            const stopTracks = stream => stream?.getTracks().forEach(track => track.stop());
            const stop = () => {
                stopped = true;
                if (meter) clearInterval(meter);
                meter = null;
                stopTracks(local); stopTracks(remote);
                if (peer) {
                    peer.getSenders().forEach(sender => sender.track?.stop());
                    peer.getReceivers().forEach(receiver => receiver.track?.stop());
                    peer.ontrack = peer.onconnectionstatechange = peer.oniceconnectionstatechange = null;
                }
                if (channel) { channel.onopen = channel.onclose = channel.onerror = channel.onmessage = null; channel.close(); }
                channel = null;
                peer?.close(); peer = null;
                if (audio) { audio.pause(); audio.srcObject = null; audio.remove(); }
                audio = null;
                sources.forEach(source => source.disconnect());
                analysers.forEach(analyser => analyser.disconnect());
                sources = []; analysers = [];
                context?.close().catch(() => {}); context = null;
                local = remote = null;
            };
            const fail = message => { if (!stopped) { stop(); post('failed', {message}); } };
            const addMeter = (stream, isRemote) => {
                const source = context.createMediaStreamSource(stream);
                const analyser = context.createAnalyser();
                analyser.fftSize = 256;
                source.connect(analyser);
                sources.push(source); analysers.push({node: analyser, remote: isRemote, data: new Float32Array(256), disconnect: () => analyser.disconnect()});
            };
            const startMeter = () => {
                meter = setInterval(() => {
                    if (stopped) return;
                    let level = 0, remoteLevel = 0, localLevel = 0;
                    for (const meter of analysers) {
                        meter.node.getFloatTimeDomainData(meter.data);
                        const rms = Math.sqrt(meter.data.reduce((sum, sample) => sum + sample * sample, 0) / meter.data.length);
                        level = Math.max(level, rms);
                        if (meter.remote) remoteLevel = Math.max(remoteLevel, rms);
                        else localLevel = Math.max(localLevel, rms);
                    }
                    post('level', {value: Math.min(1, level * 5)});
                    if (!microphoneMuted && localLevel > 0.015) {
                        lastLocalVoice = Date.now();
                        if (!userSpeaking) { userSpeaking = true; post('userSpeaking'); }
                    } else if (userSpeaking && (microphoneMuted || Date.now() - lastLocalVoice > 350)) {
                        userSpeaking = false; post('userStoppedSpeaking');
                    }
                    // Frameless Quicksilver may omit audio-buffer events. Meter the actual output.
                    if (remoteLevel > 0.008) {
                        lastRemoteVoice = Date.now();
                        if (!assistantSpeaking) { assistantSpeaking = true; post('assistantSpeaking'); }
                    } else if (assistantSpeaking && Date.now() - lastRemoteVoice > 350) {
                        assistantSpeaking = false; post('assistantStoppedSpeaking');
                    }
                }, 66);
            };
            const offer = async (muted, syntheticAudio) => {
                if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia || !window.RTCPeerConnection)
                    throw new Error('This Mac’s WebKit cannot capture audio for voice conversations.');
                microphoneMuted = muted;
                post('stage', {value: 'microphone'});
                const generated = syntheticAudio ? new AudioContext() : null;
                const destination = generated?.createMediaStreamDestination();
                const acquired = destination ? destination.stream : await navigator.mediaDevices.getUserMedia({audio: {echoCancellation: true, noiseSuppression: true}, video: false});
                if (generated) sources.push(destination);
                if (stopped) { stopTracks(acquired); throw new Error('Voice conversation cancelled.'); }
                local = acquired;
                local.getAudioTracks().forEach(track => {
                    track.enabled = !microphoneMuted;
                    track.onended = () => fail('The microphone disconnected. Connect it and start a new conversation.');
                });
                peer = new RTCPeerConnection({iceServers: []});
                audio = document.createElement('audio'); audio.autoplay = true;
                document.body.appendChild(audio);
                post('stage', {value: 'audio'});
                context = generated || new AudioContext();
                await context.resume();
                if (stopped) throw new Error('Voice conversation cancelled.');
                addMeter(local, false); startMeter();
                peer.ontrack = event => {
                    if (stopped || event.track.kind !== 'audio') return;
                    remote = event.streams[0] || new MediaStream([event.track]);
                    audio.srcObject = remote;
                    addMeter(remote, true);
                    audio.play().catch(() => fail('Audio playback was blocked. End the call and try again.'));
                };
                peer.onconnectionstatechange = () => {
                    if (stopped) return;
                    if (peer.connectionState === 'connected') post('connected');
                    if (peer.connectionState === 'failed') fail('The voice audio connection failed. Try again.');
                    else if (peer.connectionState === 'closed' || peer.connectionState === 'disconnected') post('disconnected');
                };
                local.getTracks().forEach(track => peer.addTrack(track, local));
                channel = peer.createDataChannel('oai-events');
                channel.onerror = () => fail('The voice event channel failed. Try again.');
                channel.onclose = () => { if (!stopped) post('disconnected'); };
                channel.onmessage = event => {
                    if (stopped || typeof event.data !== 'string' || event.data.length > 262144) return;
                    try { post('realtime', {payload: JSON.parse(event.data)}); } catch (_) {}
                };
                post('stage', {value: 'offer'});
                await peer.setLocalDescription(await peer.createOffer());
                if (stopped) throw new Error('Voice conversation cancelled.');
                // The server's SDP answer supplies remote ICE candidates. Send the offer
                // immediately, as in the Realtime WebRTC flow; WebKit may keep gathering
                // indefinitely before an answer, even though the offer is already usable.
                if (stopped) throw new Error('Voice conversation cancelled.');
                return peer.localDescription.sdp;
            };
            window.lenotchVoice = {
                stop,
                command: request => {
                    if (request.action === 'mute') {
                        microphoneMuted = request.muted;
                        local?.getAudioTracks().forEach(track => { track.enabled = !microphoneMuted; });
                        return;
                    }
                    Promise.resolve().then(async () => {
                        if (request.action === 'offer') return await offer(request.muted, request.syntheticAudio === true);
                        if (request.action === 'answer') {
                            if (!peer || stopped) throw new Error('Start a new voice conversation before connecting.');
                            await peer.setRemoteDescription({type: 'answer', sdp: request.sdp});
                            return '';
                        }
                        throw new Error('Unknown voice operation.');
                    }).then(value => { if (!stopped) post('result', {id: request.id, value}); })
                      .catch(error => {
                          if (stopped) return;
                          let message = 'The local voice engine could not start. Try again.';
                          if (error.name === 'NotAllowedError') message = 'Microphone access was denied. Allow LeNotch in System Settings → Privacy & Security → Microphone.';
                          else if (error.name === 'NotFoundError') message = 'No microphone is available. Connect one and try again.';
                          else if (error.name === 'NotReadableError') message = 'The microphone is unavailable or in use by another app.';
                          stop(); post('commandError', {id: request.id, message});
                      });
                }
            };
            let announced = false;
            const reportReady = () => {
                if (announced || document.visibilityState !== 'visible') return;
                announced = true;
                post('ready', {secureContext: window.isSecureContext === true,
                    mediaDevices: typeof navigator.mediaDevices?.getUserMedia === 'function',
                    peerConnection: typeof window.RTCPeerConnection === 'function'});
            };
            document.addEventListener('visibilitychange', reportReady);
            reportReady();
        })();
        </script></body></html>
        """
    }
}
