import AppKit
import AVFoundation
import Observation
import OSLog

@MainActor @Observable
final class DictationCoordinator {
    static let shared = DictationCoordinator()

    enum Phase: Equatable {
        case idle, preparing, recording, transcribing, cleaning, done, failed

        var title: String {
            switch self {
            case .idle: "Dictation"
            case .preparing: "Preparing dictation"
            case .recording: "Listening"
            case .transcribing: "Transcribing"
            case .cleaning: "Cleaning up"
            case .done: "Dictation complete"
            case .failed: "Dictation unavailable"
            }
        }
    }

    /// What the notch shows for the current phase. Short on purpose: dictation is something you glance at, not read.
    enum Indicator: Equatable {
        case listening
        /// Loading the model, transcribing, polishing.
        case working
        case downloading(Double)
        case note(Note)
        /// Needs words: shown as a small card under the notch.
        case problem(String)

        enum Note: Equatable {
            case ready, copied

            var text: String { self == .ready ? "Ready" : "Copied" }
        }
    }

    /// What lingers after a run, shown by the notch until it hides.
    enum Notice: Equatable {
        case ready, copied
        case problem(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var notice: Notice?
    private(set) var statusMessage = ""
    private(set) var downloadProgress: Double?
    private(set) var preparingSpeechModel: DictationModel?
    private(set) var preparingCleanup = false
    private(set) var level: Float = 0
    private(set) var lastTranscript: String?
    var shortcutUnavailable = false
    var indicator: Indicator? { Self.indicator(phase: phase, downloadProgress: downloadProgress, notice: notice) }
    var isVisible: Bool { indicator != nil }
    var selectedModelInstalled: Bool { speech.isInstalled(selectedModel) }
    var selectedModelReady: Bool { speech.isReady(selectedModel) }
    var cleanupModelInstalled: Bool { cleanup.isInstalled() }
    var cleanupModelReady: Bool { cleanup.isReady }

    private let audio = DictationAudioRecorder()
    private let speech = DictationSpeechModels()
    private let cleanup = DictationCleanup()
    private var model: DictationModel = .fluidSpeechPro
    private var recordingTimer: Timer?
    private var streamTask: Task<Void, Never>?
    private var currentTask: Task<Void, Never>?
    private var session = 0
    private var startedAt = Date()
    private let logger = Logger(subsystem: "LeNotch", category: "Dictation")

    private init() {}

    func prepareSelectedModel() async {
        guard phase == .idle || phase == .done || phase == .failed else { return }
        session += 1
        let id = session
        let selected = selectedModel
        notice = nil
        phase = .preparing
        preparingSpeechModel = selected
        preparingCleanup = false
        downloadProgress = speech.isInstalled(selected) ? nil : 0
        statusMessage = downloadProgress == nil ? "Loading \(selected.name) on this Mac…" : "Downloading \(selected.name)…"
        do {
            try await speech.prepare(selected, allowDownload: true, onProgress: { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.reportDownloadProgress(fraction, name: selected.name, sessionID: id)
                }
            }, onDownloadComplete: { [weak self] in
                self?.downloadFinished(name: selected.name, sessionID: id)
            })
            guard id == session else { return }
            downloadProgress = nil
            phase = .done
            notice = .ready
            statusMessage = "\(selected.name) is ready. Press ⌥D to dictate."
            hideAfterDelay(1.6)
        } catch {
            guard id == session else { return }
            fail(error.localizedDescription)
        }
    }

    func prepareCleanupModel() async {
        guard phase == .idle || phase == .done || phase == .failed else { return }
        session += 1
        let id = session
        notice = nil
        phase = .preparing
        preparingSpeechModel = nil
        preparingCleanup = true
        downloadProgress = cleanup.isInstalled() ? nil : 0
        statusMessage = downloadProgress == nil ? "Loading Qwen 0.8B on this Mac…" : "Downloading Qwen 0.8B…"
        do {
            try await cleanup.prepare(allowDownload: true, onProgress: { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.reportDownloadProgress(fraction, name: "Qwen 0.8B", sessionID: id)
                }
            }, onDownloadComplete: { [weak self] in
                self?.downloadFinished(name: "Qwen 0.8B", sessionID: id)
            })
            guard id == session else { return }
            downloadProgress = nil
            phase = .done
            notice = .ready
            statusMessage = "Cleanup model is ready."
            hideAfterDelay(1.6)
        } catch {
            guard id == session else { return }
            fail(error.localizedDescription)
        }
    }

    private func reportDownloadProgress(_ fraction: Double, name: String, sessionID: Int) {
        guard sessionID == session, phase == .preparing, let current = downloadProgress,
              fraction.isFinite else { return }
        let progress = max(current, min(1, max(0, fraction)))
        downloadProgress = progress
        statusMessage = "Downloading \(name)…"
    }

    private func downloadFinished(name: String, sessionID: Int) {
        guard sessionID == session, phase == .preparing else { return }
        downloadProgress = nil
        statusMessage = "Loading \(name) on this Mac…"
    }

    func toggle() {
        switch phase {
        case .idle, .done, .failed:
            session += 1
            let id = session
            lastTranscript = nil
            notice = nil
            currentTask = Task { await start(id: id) }
        case .recording:
            finish()
        case .preparing, .transcribing, .cleaning:
            break
        }
    }

    func cancel() {
        session += 1
        recordingTimer?.invalidate()
        recordingTimer = nil
        streamTask?.cancel()
        currentTask?.cancel()
        audio.cancel()
        lastTranscript = nil
        notice = nil
        phase = .idle
        downloadProgress = nil
        preparingSpeechModel = nil
        preparingCleanup = false
        level = 0
        statusMessage = ""
    }

    func copyLastTranscript() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
        statusMessage = "Transcript copied · paste into your app"
        notice = .copied
        phase = .done
        hideAfterDelay(1.6)
    }

    private var selectedModel: DictationModel {
        DictationModel(rawValue: UserDefaults.standard.string(forKey: "lenotch.dictation.model") ?? "") ?? .fluidSpeechPro
    }

    private func start(id: Int) async {
        model = selectedModel
        phase = .preparing
        downloadProgress = nil
        preparingSpeechModel = model
        preparingCleanup = false
        statusMessage = "Loading \(model.name)…"
        do {
            try await speech.prepare(model, allowDownload: false)
            guard id == session else { return }
            let access = AVCaptureDevice.authorizationStatus(for: .audio)
            let allowed: Bool
            if access == .notDetermined {
                allowed = await AVCaptureDevice.requestAccess(for: .audio)
            } else {
                allowed = access == .authorized
            }
            guard allowed else {
                fail("Allow microphone access in Dictation settings first.")
                return
            }
            guard id == session else { return }
            if model == .nemotronStreaming { try await speech.beginStreaming() }
            guard id == session else { return }
            try audio.start { [weak self] newLevel in self?.level = newLevel }
            startedAt = Date()
            phase = .recording
            statusMessage = "Press ⌥D again to finish"
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tickRecording() }
            }
        } catch {
            guard id == session else { return }
            fail(error.localizedDescription)
        }
    }

    private func tickRecording() {
        guard phase == .recording else { return }
        if Date().timeIntervalSince(startedAt) >= 90 {
            finish()
        } else if model == .nemotronStreaming {
            pollStreaming()
        }
    }

    private func pollStreaming() {
        guard streamTask == nil else { return }
        let samples = audio.readNewSamples()
        guard !samples.isEmpty else { return }
        let activeSession = session
        streamTask = Task {
            defer { if activeSession == session { streamTask = nil } }
            do {
                let partial = try await speech.stream(samples)
                if activeSession == session, phase == .recording, !partial.isEmpty { statusMessage = partial }
            } catch {
                if activeSession == session, phase == .recording {
                    audio.cancel()
                    recordingTimer?.invalidate()
                    recordingTimer = nil
                    fail(error.localizedDescription)
                }
            }
        }
    }

    private func finish() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        let remaining = audio.readNewSamples()
        let samples: [Float]
        do {
            samples = try audio.stop()
        } catch {
            fail(error.localizedDescription)
            return
        }
        level = 0
        phase = .transcribing
        statusMessage = "Processing on this Mac…"
        logger.info("Captured \(samples.count, privacy: .public) audio samples for \(self.model.name, privacy: .public)")
        let activeSession = session
        let pendingStream = streamTask
        currentTask = Task {
            do {
                if let pendingStream { await pendingStream.value }
                guard activeSession == session else { return }
                var text: String
                if model == .nemotronStreaming {
                    text = try await speech.finishStreaming(remaining)
                } else {
                    text = try await speech.transcribe(samples)
                }
                guard activeSession == session else { return }
                logger.info("Recognized \(text.count, privacy: .public) characters")
                if UserDefaults.standard.bool(forKey: "lenotch.dictation.cleanup"), cleanup.isInstalled() {
                    phase = .cleaning
                    statusMessage = "Polishing transcript on this Mac…"
                    do {
                        try await cleanup.prepare(allowDownload: false)
                        text = await cleanup.polish(text)
                    } catch {
                        // Keep the raw local transcript if the optional model cannot load.
                    }
                }
                guard activeSession == session else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    fail("Didn't catch anything. Try again.")
                    return
                }
                lastTranscript = text
                let result = await DictationTextInserter.deliver(text)
                guard activeSession == session else { return }
                logger.info("Delivery: \(String(describing: result), privacy: .public)")
                switch result {
                case .pasted:
                    // The text appearing in the app is the confirmation; the indicator just goes away.
                    statusMessage = "Pasted"
                    notice = nil
                    phase = .done
                    hideAfterDelay(0.3)
                case .copied(.needsAccessibility):
                    statusMessage = "Copied to clipboard · allow Accessibility to paste automatically"
                    notice = .problem("Copied. Allow Accessibility in Setup to paste automatically.")
                    phase = .done
                    hideAfterDelay(5)
                case .copied(.noTargetApp):
                    statusMessage = "Copied to clipboard · paste into your app"
                    notice = .copied
                    phase = .done
                    hideAfterDelay(1.6)
                }
            } catch {
                guard activeSession == session else { return }
                logger.error("Transcription failed: \(error.localizedDescription, privacy: .private)")
                fail(error.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        phase = .failed
        downloadProgress = nil
        statusMessage = message
        notice = .problem(message)
        level = 0
        hideAfterDelay(5)
    }

    private func hideAfterDelay(_ seconds: Double) {
        let id = session
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if id == session, (phase == .done || phase == .failed) {
                phase = .idle
                notice = nil
            }
        }
    }

    /// The phase as the notch shows it. Finished runs show only what's worth a look: a problem, a copy, a ready model.
    nonisolated static func indicator(phase: Phase, downloadProgress: Double?, notice: Notice?) -> Indicator? {
        switch phase {
        case .idle: return nil
        case .recording: return .listening
        case .preparing: return downloadProgress.map(Indicator.downloading) ?? .working
        case .transcribing, .cleaning: return .working
        case .done, .failed:
            switch notice {
            case .ready?: return .note(.ready)
            case .copied?: return .note(.copied)
            case .problem(let message)?: return .problem(message)
            case nil: return nil
            }
        }
    }
}
