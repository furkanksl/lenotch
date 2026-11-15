import AVFoundation
import Foundation

/// What the mic hears right now: its loudness, and the same four bands the music bars show (`AudioSpectrum`), so the
/// notch's voice bars move the way its music bars do.
struct DictationMeter: Equatable, Sendable {
    /// Loudness, 0…1 (RMS with a gain that puts speech near the top).
    var level: Float
    /// One per bar, 0…1, each normalized against the voice's own loudness.
    var bands: [Float]

    static let bandCount = 4
    static let silent = DictationMeter(level: 0, bands: [Float](repeating: 0, count: bandCount))
}

/// The input tap runs on AVAudio's realtime queue, not the main actor.
/// Owns only audio buffers and guards the samples shared with the UI thread.
final class DictationAudioCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let sourceRate: Double
    private var samples: [Float] = []
    private var currentLevel: Float = 0
    private var currentBands = DictationMeter.silent.bands
    /// The voice's four bands, 100 Hz to 6 kHz: where speech is. Only the tap's thread touches it.
    private var spectrum = AudioSpectrum(sampleRate: 16_000, bars: DictationMeter.bandCount, low: 100, high: 6_000)

    init?(inputFormat: AVAudioFormat) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: format) else { return nil }
        self.outputFormat = format
        self.converter = converter
        self.sourceRate = inputFormat.sampleRate
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / sourceRate) + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, status != .error, let channels = output.floatChannelData,
              output.frameLength > 0 else { return }
        let count = Int(output.frameLength)
        let channel = channels[0]
        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        currentLevel = min(1, sqrt(sum / Float(count)) * 8)
        let latest = Array(samples.suffix(spectrum.size))
        lock.unlock()
        // The FFT runs outside the lock: the main thread never waits on it.
        let bands = latest.withUnsafeBufferPointer { spectrum.process($0, dt: Float(count) / 16_000) }
        lock.lock()
        currentBands = bands
        lock.unlock()
    }

    func level() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return currentLevel
    }

    func meter() -> DictationMeter {
        lock.lock()
        defer { lock.unlock() }
        return DictationMeter(level: currentLevel, bands: currentBands)
    }

    func take() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func samples(since index: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard index < samples.count else { return [] }
        return Array(samples[index...])
    }

    nonisolated static func tapHandler(for capture: DictationAudioCapture) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [capture] buffer, _ in capture.append(buffer) }
    }
}

/// Records microphone audio only while dictation is active. Nothing is written to disk.
@MainActor
final class DictationAudioRecorder {

    enum RecordingError: LocalizedError {
        case noInput
        case noAudio
        case conversion

        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone input is available."
            case .noAudio: "No audio was captured."
            case .conversion: "Could not convert the microphone audio."
            }
        }
    }

    /// How often the mic's level reaches the notch: each one scrolls the bars by one.
    nonisolated static let meterInterval = 0.07

    private var engine: AVAudioEngine?
    private var capture: DictationAudioCapture?
    private var meter: Timer?
    private var readIndex = 0

    func start(onMeter: @escaping @MainActor @Sendable (DictationMeter) -> Void) throws {
        stopWithoutAudio()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingError.noInput
        }
        guard let capture = DictationAudioCapture(inputFormat: format) else { throw RecordingError.conversion }
        input.installTap(onBus: 0, bufferSize: 2048, format: format,
                         block: DictationAudioCapture.tapHandler(for: capture))
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.capture = capture
        self.engine = engine
        readIndex = 0
        meter = Timer.scheduledTimer(withTimeInterval: Self.meterInterval, repeats: true) { [weak capture] _ in
            let reading = capture?.meter() ?? .silent
            Task { @MainActor in onMeter(reading) }
        }
    }

    /// Returns mono, 16 kHz PCM for local speech models.
    func stop() throws -> [Float] {
        let capture = self.capture
        stopWithoutAudio()
        guard let samples = capture?.take(), !samples.isEmpty else { throw RecordingError.noAudio }
        return samples
    }

    /// Stops the mic, then returns the whole recording and the part `readNewSamples` hasn't handed out yet. Stopping
    /// first means nothing the tap adds afterwards can be missing from the streamed text but present in the recording.
    func finish() throws -> (all: [Float], unread: [Float]) {
        let capture = self.capture, read = readIndex
        stopWithoutAudio()
        guard let all = capture?.take(), !all.isEmpty else { throw RecordingError.noAudio }
        return (all, read < all.count ? Array(all[read...]) : [])
    }

    func readNewSamples() -> [Float] {
        guard let capture else { return [] }
        let samples = capture.samples(since: readIndex)
        readIndex += samples.count
        return samples
    }

    func cancel() { stopWithoutAudio() }

    private func stopWithoutAudio() {
        meter?.invalidate()
        meter = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        capture = nil
        readIndex = 0
    }
}
