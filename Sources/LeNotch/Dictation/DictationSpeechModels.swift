import AVFoundation
import FluidAudio
import Foundation
import Hub

enum DictationModel: String, Sendable {
    case fluidSpeechPro
    case nemotronStreaming

    var name: String {
        switch self {
        case .fluidSpeechPro: "Fluid Speech Pro"
        case .nemotronStreaming: "Nemotron 3.5 Streaming"
        }
    }

    var repository: String {
        switch self {
        case .fluidSpeechPro: "FluidVoice-Labs/fluid-speech-pro-coreml"
        case .nemotronStreaming: "BarathwajAnandan/nemotron-3.5-asr-streaming320-int8-CoreML"
        }
    }

    // Pin the exact artifacts we reviewed, rather than silently changing the model on users.
    var revision: String {
        switch self {
        case .fluidSpeechPro: "3b9d38a93d606f84011e5a0a669b7ea146375a22"
        case .nemotronStreaming: "d5fa1694dd2a257fdb7027557bccc6364b0c02ba"
        }
    }

    var requiredFile: String {
        switch self {
        case .fluidSpeechPro: "Preprocessor.mlmodelc"
        case .nemotronStreaming: "metadata.json"
        }
    }
}

@MainActor
final class DictationSpeechModels {
    enum ModelError: LocalizedError {
        case notDownloaded
        case emptyTranscript
        case notLoaded
        case unsupportedHardware

        var errorDescription: String? {
            switch self {
            case .notDownloaded: "Download the selected speech model in Dictation settings first."
            case .emptyTranscript: "No speech was recognized. Please try again."
            case .notLoaded: "The selected speech model is not ready."
            case .unsupportedHardware: "These local speech models require an Apple Silicon Mac."
            }
        }
    }

    private var loaded: DictationModel?
    private var asr: AsrManager?
    private var streamer: NemotronStreamingAsrManager?

    func isReady(_ model: DictationModel) -> Bool { loaded == model }

    static func modelsDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appending(path: "LeNotch/DictationModels", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func location(for model: DictationModel) throws -> URL {
        try Self.modelsDirectory().appending(path: "models/\(model.repository)", directoryHint: .isDirectory)
    }

    private func marker(for model: DictationModel) throws -> URL {
        try location(for: model).appending(path: ".lenotch-complete")
    }

    func isInstalled(_ model: DictationModel) -> Bool {
        guard let marker = try? marker(for: model),
              let version = try? String(contentsOf: marker, encoding: .utf8),
              version == model.revision,
              let directory = try? location(for: model) else { return false }
        return FileManager.default.fileExists(atPath: directory.appending(path: model.requiredFile).path)
    }

    func prepare(_ model: DictationModel, allowDownload: Bool,
                 onProgress: @escaping @Sendable (Double) -> Void = { _ in },
                 onDownloadComplete: @MainActor () -> Void = {}) async throws {
        #if !arch(arm64)
        throw ModelError.unsupportedHardware
        #else
        if loaded == model { return }
        var directory = try location(for: model)
        guard isInstalled(model) || allowDownload else { throw ModelError.notDownloaded }
        if !isInstalled(model) {
            let hub = HubApi(downloadBase: try Self.modelsDirectory())
            directory = try await hub.snapshot(from: HubApi.Repo(id: model.repository), revision: model.revision) { @Sendable progress in
                onProgress(progress.fractionCompleted)
            }
            guard FileManager.default.fileExists(atPath: directory.appending(path: model.requiredFile).path) else {
                throw ModelError.notDownloaded
            }
            try model.revision.write(to: marker(for: model), atomically: true, encoding: .utf8)
        }

        onDownloadComplete()

        // Only one speech model stays in memory. Core ML may compile the Nemotron pack on first load.
        loaded = nil
        asr = nil
        streamer = nil
        switch model {
        case .fluidSpeechPro:
            let models = try await AsrModels.loadLocalOnly(from: directory, version: .fluidParakeetPro)
            let manager = AsrManager()
            try await manager.initialize(models: models)
            asr = manager
        case .nemotronStreaming:
            let manager = NemotronStreamingAsrManager()
            try await manager.loadModels(modelDir: directory)
            // This published export defaults to Portuguese (pt-BR). Use its multilingual
            // prompt instead of forcing every utterance through that locale.
            try await manager.setTargetLanguage("auto")
            streamer = manager
        }
        loaded = model
        #endif
    }

    func beginStreaming() async throws {
        guard let streamer, loaded == .nemotronStreaming else { throw ModelError.notLoaded }
        await streamer.reset()
    }

    func stream(_ samples: [Float]) async throws -> String {
        guard let streamer, loaded == .nemotronStreaming else { throw ModelError.notLoaded }
        if let audio = Self.buffer(for: samples) {
            _ = try await streamer.process(audioBuffer: audio)
        }
        return await streamer.getPartialTranscript()
    }

    func finishStreaming(_ trailingSamples: [Float]) async throws -> String {
        guard let streamer, loaded == .nemotronStreaming else { throw ModelError.notLoaded }
        if let audio = Self.buffer(for: trailingSamples) {
            _ = try await streamer.process(audioBuffer: audio)
        }
        let text = try await streamer.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        await streamer.reset()
        guard !text.isEmpty else { throw ModelError.emptyTranscript }
        return text
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let asr, loaded == .fluidSpeechPro else { throw ModelError.notLoaded }
        let result = try await asr.transcribe(samples)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ModelError.emptyTranscript }
        return text
    }

    private nonisolated static func buffer(for samples: [Float]) -> sending AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
