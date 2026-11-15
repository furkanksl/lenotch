import AppKit
import AVFoundation
import Carbon.HIToolbox
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

    /// What the notch shows (`IslandDirector.dictation`). Short on purpose: dictation is glanced at, not read.
    enum Indicator: Equatable {
        /// The mic is open: your voice moves the bars.
        case listening
        /// Loading the model, transcribing, polishing.
        case working
        /// A moment's word after a run, then the notch closes.
        case note(Note)
        /// Needs words: the ears grow a lip under the notch for them.
        case problem(String)

        enum Note: Equatable {
            /// The text went into the app you were typing in.
            case pasted
            /// On the clipboard only: there was nothing to paste into.
            case copied
            /// A model finished preparing.
            case ready

            var text: String {
                switch self {
                case .pasted: "Pasted"
                case .copied: "Copied"
                case .ready: "Ready"
                }
            }
        }
    }

    /// What lingers after a run, shown by the notch until it hides.
    enum Notice: Equatable {
        case note(Indicator.Note)
        case problem(String)
    }

    /// Everything the notch needs from dictation: what to show, and the words heard so far.
    struct Display: Equatable {
        var indicator: Indicator?
        /// What the model has heard so far, while it listens and works. Empty otherwise.
        var transcript: String
    }

    private(set) var phase: Phase = .idle { didSet { stateChanged() } }
    private(set) var notice: Notice? { didSet { stateChanged() } }
    /// A dictation run: from ⌥D starting it until its text is delivered, it fails, or it's cancelled. Setup's model
    /// downloads aren't runs: they show their progress in Setup, not in the notch.
    private(set) var running = false { didSet { stateChanged() } }
    private(set) var statusMessage = ""
    private(set) var downloadProgress: Double?
    private(set) var preparingSpeechModel: DictationModel?
    private(set) var preparingCleanup = false
    /// The mic's loudness and the voice's four bands, for the bars; a new reading every `DictationAudioRecorder.meterInterval`.
    private(set) var meter = DictationMeter.silent
    /// What the model has heard so far in this run (both models stream).
    private(set) var liveText = "" { didSet { stateChanged() } }
    private(set) var lastTranscript: String?
    var shortcutUnavailable = false
    var indicator: Indicator? { Self.indicator(phase: phase, running: running, notice: notice) }
    var display: Display { Self.display(indicator: indicator, liveText: liveText) }

    /// Your words go with the run while it listens and works; a note or a problem has its own.
    nonisolated static func display(indicator: Indicator?, liveText: String) -> Display {
        Display(indicator: indicator, transcript: indicator == .listening || indicator == .working ? liveText : "")
    }
    /// Esc or the menu can cancel now.
    var canCancel: Bool { Self.escapeCancels(phase: phase, running: running) }
    var selectedModelInstalled: Bool { speech.isInstalled(selectedModel) }
    var selectedModelReady: Bool { speech.isReady(selectedModel) }
    var cleanupModelInstalled: Bool { cleanup.isInstalled() }
    var cleanupModelReady: Bool { cleanup.isReady }

    /// Told whenever what the notch shows changes (the app sends it to `IslandDirector.dictationChanged`).
    var onDisplayChange: ((Display) -> Void)? {
        didSet {
            published = display
            onDisplayChange?(display)
        }
    }

    /// Fluid Speech Pro previews by transcribing what it has heard so far: about twice a second keeps the words close
    /// behind your voice without running the model all the time.
    nonisolated static let previewInterval = 0.5

    private let audio = DictationAudioRecorder()
    private let speech = DictationSpeechModels()
    private let cleanup = DictationCleanup()
    private var model: DictationModel = .fluidSpeechPro
    private var recordingTimer: Timer?
    private var streamTask: Task<Void, Never>?
    /// Core ML may finish a suspended inference after cancellation. Wait before resetting the reused models.
    private var cancelledWork: Task<Void, Never>?
    private var currentTask: Task<Void, Never>?
    private var session = 0
    private var startedAt = Date()
    private let logger = Logger(subsystem: "LeNotch", category: "Dictation")
    @ObservationIgnored private var published = Display(indicator: nil, transcript: "")
    @ObservationIgnored private var lastStreamedAt = Date.distantPast
    /// Esc, taken from every app only while a run can be cancelled (`escapeCancels`).
    @ObservationIgnored private var escapeKey: HotKey?

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
            notice = .note(.ready)
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
            notice = .note(.ready)
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
            meter = .silent
            liveText = ""
            running = true
            // Straight from the last run's note into this one's work: the notch never closes in between.
            phase = .preparing
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
        let previous = cancelledWork, pendingStream = streamTask, pendingRun = currentTask
        streamTask?.cancel()
        currentTask?.cancel()
        cancelledWork = Task {
            await previous?.value
            await pendingStream?.value
            await pendingRun?.value
        }
        audio.cancel()
        speech.discardStreaming()
        streamTask = nil
        lastTranscript = nil
        notice = nil
        running = false
        phase = .idle
        downloadProgress = nil
        preparingSpeechModel = nil
        preparingCleanup = false
        meter = .silent
        liveText = ""
        statusMessage = ""
    }

    func copyLastTranscript() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
        statusMessage = "Transcript copied · paste into your app"
        notice = .note(.copied)
        phase = .done
        hideAfterDelay(1.6)
    }

    private var selectedModel: DictationModel {
        DictationModel(rawValue: UserDefaults.standard.string(forKey: "lenotch.dictation.model") ?? "") ?? .fluidSpeechPro
    }

    private func start(id: Int) async {
        guard id == session, !Task.isCancelled else { return }
        await cancelledWork?.value
        guard id == session, !Task.isCancelled else { return }
        cancelledWork = nil
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
            try await speech.beginStreaming()
            guard id == session else { return }
            lastStreamedAt = .distantPast
            try audio.start { [weak self] reading in self?.heard(reading) }
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
        } else {
            pollStreaming()
        }
    }

    /// Hands the model what the mic heard since last time; its text so far shows in the notch.
    private func pollStreaming() {
        guard streamTask == nil else { return }
        // Nemotron streams on every tick; Fluid re-reads what it has heard, so it previews less often.
        if model == .fluidSpeechPro, Date().timeIntervalSince(lastStreamedAt) < Self.previewInterval { return }
        let samples = audio.readNewSamples()
        guard !samples.isEmpty else { return }
        lastStreamedAt = Date()
        let activeSession = session
        streamTask = Task {
            defer { if activeSession == session { streamTask = nil } }
            do {
                let partial = try await speech.stream(samples)
                if activeSession == session, phase == .recording, let partial, !partial.isEmpty { liveText = partial }
            } catch is CancellationError {
                // Cancelled with the run.
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
        let recording: (all: [Float], unread: [Float])
        do {
            recording = try audio.finish()
        } catch {
            fail(error.localizedDescription)
            return
        }
        meter = .silent
        phase = .transcribing
        statusMessage = "Processing on this Mac…"
        logger.info("Captured \(recording.all.count, privacy: .public) audio samples for \(self.model.name, privacy: .public)")
        let activeSession = session
        let pendingStream = streamTask
        currentTask = Task {
            do {
                // The last preview first: the session takes its samples in order.
                if let pendingStream { await pendingStream.value }
                guard activeSession == session else { return }
                var text = try await speech.finishStreaming(unread: recording.unread, all: recording.all)
                guard activeSession == session else { return }
                logger.info("Recognized \(text.count, privacy: .public) characters")
                if DictationCleanup.isEnabled(), cleanup.isInstalled() {
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
                liveText = ""
                running = false
                switch result {
                case .cancelled:
                    cancel()
                    return
                case .pasted:
                    // A beat of the check as the text lands, then the ears go back into the notch.
                    statusMessage = "Pasted"
                    notice = .note(.pasted)
                    phase = .done
                    hideAfterDelay(0.9)
                case .copied(.needsAccessibility):
                    statusMessage = "Copied to clipboard · allow Accessibility to paste automatically"
                    notice = .problem("Copied to the clipboard. Allow Accessibility in Setup to paste it for you.")
                    phase = .done
                    hideAfterDelay(5)
                case .copied(.noTargetApp):
                    statusMessage = "Copied to clipboard · paste into your app"
                    notice = .note(.copied)
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

    /// A run's failure is the notch's to say; a model that won't prepare from Setup says so in Setup.
    private func fail(_ message: String) {
        downloadProgress = nil
        statusMessage = message
        notice = running ? .problem(message) : nil
        meter = .silent
        liveText = ""
        running = false
        phase = .failed
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

    /// A new reading from the mic, for the bars.
    private func heard(_ reading: DictationMeter) {
        guard phase == .recording else { return }
        meter = reading
    }

    /// The notch and Esc follow the run.
    private func stateChanged() {
        let wantsEscape = Self.escapeCancels(phase: phase, running: running)
        if wantsEscape, escapeKey == nil {
            escapeKey = HotKey(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.cancel() }
            if escapeKey == nil { logger.notice("Esc is taken by another app; cancel from the notch menu instead") }
        } else if !wantsEscape, let key = escapeKey {
            key.unregister()
            escapeKey = nil
        }
        let now = display
        guard now != published else { return }
        published = now
        onDisplayChange?(now)
    }

    /// Esc cancels a run from ⌥D until its text is delivered. Only then: everywhere else Esc stays the apps'.
    nonisolated static func escapeCancels(phase: Phase, running: Bool) -> Bool {
        guard running else { return false }
        switch phase {
        case .preparing, .recording, .transcribing, .cleaning: return true
        case .idle, .done, .failed: return false
        }
    }

    /// The phase as the notch shows it. Finished runs show only what's worth a look: the check as the text lands, a
    /// copy, a ready model, a problem.
    nonisolated static func indicator(phase: Phase, running: Bool, notice: Notice?) -> Indicator? {
        switch phase {
        case .idle: return nil
        case .recording: return .listening
        // A model loading for a run is the run's work; a download started from Setup shows its progress there.
        case .preparing: return running ? .working : nil
        case .transcribing, .cleaning: return .working
        case .done, .failed:
            switch notice {
            case .note(let note)?: return .note(note)
            case .problem(let message)?: return .problem(message)
            case nil: return nil
            }
        }
    }
}
