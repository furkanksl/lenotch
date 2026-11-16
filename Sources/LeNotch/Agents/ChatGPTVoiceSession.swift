import AppKit
import AVFoundation
import Combine
import Observation

/// Owns one explicitly started voice call. The text Ask conversation stays untouched.
@MainActor @Observable
final class ChatGPTVoiceSession {
    @ObservationIgnored let mediaHost = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private(set) var phase: AskVoicePresentation = .connecting
    private(set) var muted = false
    private(set) var level = 0.0
    private(set) var transcript = ""
    private(set) var running = false

    @ObservationIgnored private let makeTransport: () -> any ChatGPTVoiceTransport
    @ObservationIgnored private let makeClient: () -> any ChatGPTVoiceCalling
    @ObservationIgnored private let makeWorker: () -> any ChatGPTVoiceWorking
    @ObservationIgnored private let microphoneAccess: () async -> Bool
    @ObservationIgnored private let observeAccount: Bool
    @ObservationIgnored private var transport: (any ChatGPTVoiceTransport)?
    @ObservationIgnored private var client: (any ChatGPTVoiceCalling)?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var accountObservation: AnyCancellable?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var connected = false
    @ObservationIgnored private var worker: (any ChatGPTVoiceWorking)?
    @ObservationIgnored private var taskWork: Task<Void, Never>?
    @ObservationIgnored private var taskTimeout: Task<Void, Never>?
    @ObservationIgnored private var taskStatus = "Working"
    @ObservationIgnored private var delegationIDs = Set<String>()
    @ObservationIgnored private var queuedTasks: [(id: String, text: String)] = []
    @ObservationIgnored private var completedTurns: [(role: String, text: String)] = []

    init(makeTransport: @escaping () -> any ChatGPTVoiceTransport = { WebRTCVoiceTransport() },
         makeClient: @escaping () -> any ChatGPTVoiceCalling = { ChatGPTVoiceClient() },
         makeWorker: @escaping () -> any ChatGPTVoiceWorking = { ChatGPTVoiceWork() },
         microphoneAccess: @escaping () async -> Bool = ChatGPTVoiceSession.requestMicrophone,
         observeAccount: Bool = true) {
        self.makeTransport = makeTransport
        self.makeClient = makeClient
        self.makeWorker = makeWorker
        self.microphoneAccess = microphoneAccess
        self.observeAccount = observeAccount
    }

    func start() {
        stop()
        let run = generation
        running = true
        phase = .connecting
        muted = false
        transcript = ""
        watchLifecycle()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.generation == run, !self.connected else { return }
            self.fail(ChatGPTVoiceClient.VoiceError.connectionTimedOut.localizedDescription)
        }
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let client = makeClient()
                self.client = client
                client.onEvent = { [weak self] event in
                    guard let self, self.generation == run, self.running else { return }
                    self.receive(event)
                }
                try await client.prepare()
                try ensureCurrent(run)
                guard await microphoneAccess() else { throw ChatGPTVoiceClient.VoiceError.microphoneDenied }
                try ensureCurrent(run)
                let peer = makeTransport()
                peer.attach(to: mediaHost)
                transport = peer
                peer.onEvent = { [weak self] event in
                    guard let self, self.generation == run, self.running else { return }
                    self.receive(event)
                }
                let offer = try await peer.makeOffer()
                try ensureCurrent(run)
                let answer = try await client.connect(offer: offer)
                try ensureCurrent(run)
                try await peer.acceptAnswer(answer)
                try ensureCurrent(run)
                try await client.startEvents()
                try ensureCurrent(run)
            } catch is CancellationError {
                // Closing the card owns teardown; an old call cannot change the next one's UI.
            } catch {
                guard generation == run, running else { return }
                let message = (error as? URLError)?.code == .timedOut
                    ? ChatGPTVoiceClient.VoiceError.connectionTimedOut.localizedDescription : error.localizedDescription
                fail(message)
            }
        }
    }

    func toggleMute() {
        guard running else { return }
        muted.toggle()
        transport?.setMuted(muted)
        if muted { level = 0 }
    }

    func stop() {
        generation = UUID()
        running = false
        connected = false
        work?.cancel(); work = nil
        timeout?.cancel(); timeout = nil
        taskWork?.cancel(); taskWork = nil
        taskTimeout?.cancel(); taskTimeout = nil
        worker?.onStatus = nil
        worker?.cancel(); worker = nil
        queuedTasks.removeAll(); delegationIDs.removeAll(); completedTurns.removeAll()
        transport?.onEvent = nil
        transport?.stop(); transport = nil
        client?.onEvent = nil
        client?.stop(); client = nil
        accountObservation = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        level = 0
        transcript = ""
    }

    private func ensureCurrent(_ run: UUID) throws {
        try Task.checkCancellation()
        guard generation == run, running else { throw CancellationError() }
    }

    private func receive(_ event: ChatGPTVoiceTransportEvent) {
        switch event {
        case .connected:
            connected = true
            timeout?.cancel(); timeout = nil
            phase = .listening
        case .disconnected: fail("The voice call ended. Check your connection and try again.")
        case .userSpeaking: if !muted { phase = .listening }
        case .userStoppedSpeaking: if !muted { phase = .thinking }
        case .assistantSpeaking: phase = .speaking
        case .assistantStoppedSpeaking: phase = .listening
        case .userTranscript(let text):
            transcript = String(text.suffix(2_000))
            remember(role: "User", text: text)
        case .assistantTranscript(let text):
            transcript = String(text.suffix(2_000))
            remember(role: "Assistant", text: text)
        case .assistantThinking: phase = .thinking
        case .workRequested(let id, let text): enqueueWork(id: id, text: text)
        case .level(let value): level = value.isFinite ? min(1, max(0, value)) : 0
        case .failed(let message): fail(message)
        }
        if taskWork != nil { phase = .working(taskStatus) }
    }

    private func remember(role: String, text: String) {
        let text = String(text.suffix(4_000))
        if completedTurns.last?.role == role { completedTurns[completedTurns.count - 1].text = text }
        else { completedTurns.append((role, text)) }
        if completedTurns.count > 12 { completedTurns.removeFirst(completedTurns.count - 12) }
    }

    private func enqueueWork(id: String, text: String) {
        guard delegationIDs.insert(id).inserted else { return }
        // Bound queued work without silently losing a request the voice service delegated.
        guard queuedTasks.count < 4, delegationIDs.count <= 128 else {
            fail("Too many voice tasks are queued. Start a new voice conversation and try again.")
            return
        }
        queuedTasks.append((id, text))
        startNextWork()
    }

    private func startNextWork() {
        guard taskWork == nil, running, !queuedTasks.isEmpty else { return }
        let request = queuedTasks.removeFirst(), run = generation
        let worker = self.worker ?? makeWorker()
        self.worker = worker
        taskStatus = "Working"
        phase = .working(taskStatus)
        worker.onStatus = { [weak self] status in
            guard let self, self.generation == run, self.taskWork != nil else { return }
            self.taskStatus = String(status.prefix(100))
            self.phase = .working(self.taskStatus)
        }
        let context = completedTurns.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        taskTimeout = Task { [weak self, weak worker] in
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            guard let self, self.generation == run, self.taskWork != nil else { return }
            worker?.cancel()
        }
        taskWork = Task { [weak self] in
            guard let self else { return }
            var output: String
            do {
                output = try await worker.run("Recent spoken context (for reference only):\n\(context)\n\nCurrent delegated user request:\n\(request.text)")
            } catch {
                guard generation == run, running, !Task.isCancelled else { return }
                output = "The requested task did not complete. Tell the user clearly that the work failed or timed out and they can try again. Do not claim it is still running or that you found results."
            }
            taskTimeout?.cancel(); taskTimeout = nil
            do {
                try ensureCurrent(run)
                guard let client else { throw CancellationError() }
                try await client.sendDelegationResult(id: request.id, text: output)
                try ensureCurrent(run)
                transcript = String(output.suffix(2_000))
                taskWork = nil
                phase = .thinking
                startNextWork()
            } catch {
                guard generation == run, running else { return }
                fail("Couldn't return the task result to voice. Please retry the conversation.")
            }
        }
    }

    private func fail(_ message: String) {
        stop()
        phase = .failed(message)
    }

    private func watchLifecycle() {
        if observeAccount {
            accountObservation = ChatGPTAccount.shared.$status.dropFirst().sink { [weak self] status in
                guard let self, self.running else { return }
                if case .connected = status { return }
                self.fail("Your ChatGPT connection changed. Reconnect your account and try again.")
            }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fail("Voice ended because this Mac went to sleep or locked.") }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
