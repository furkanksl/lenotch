import Foundation
import Hub
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Optional, local-only transcript polishing. The raw transcription is always the fallback.
@MainActor
final class DictationCleanup {
    private static let repository = "mlx-community/Qwen3.5-0.8B-4bit"
    private static let revision = "da28692b5f139cb0ec58a356b437486b7dac7462"
    private var model: ModelContainer?

    var isReady: Bool { model != nil }

    enum CleanupError: LocalizedError {
        case notDownloaded
        case unsupportedHardware

        var errorDescription: String? {
            switch self {
            case .notDownloaded: "Download the optional cleanup model in Dictation settings first."
            case .unsupportedHardware: "On-device cleanup requires an Apple Silicon Mac."
            }
        }
    }

    private func location() throws -> URL {
        try DictationSpeechModels.modelsDirectory()
            .appending(path: "models/\(Self.repository)", directoryHint: .isDirectory)
    }

    private func marker() throws -> URL { try location().appending(path: ".lenotch-complete") }

    func isInstalled() -> Bool {
        guard let marker = try? marker(), let version = try? String(contentsOf: marker, encoding: .utf8),
              version == Self.revision, let location = try? location() else { return false }
        return FileManager.default.fileExists(atPath: location.appending(path: "config.json").path)
    }

    func prepare(allowDownload: Bool,
                 onProgress: @escaping @Sendable (Double) -> Void = { _ in },
                 onDownloadComplete: @MainActor () -> Void = {}) async throws {
        #if arch(arm64)
        if model != nil { return }
        var directory = try location()
        guard isInstalled() || allowDownload else { throw CleanupError.notDownloaded }
        if !isInstalled() {
            let hub = HubApi(downloadBase: try DictationSpeechModels.modelsDirectory())
            directory = try await hub.snapshot(from: HubApi.Repo(id: Self.repository), revision: Self.revision) { @Sendable progress in
                onProgress(progress.fractionCompleted)
            }
            guard FileManager.default.fileExists(atPath: directory.appending(path: "config.json").path) else {
                throw CleanupError.notDownloaded
            }
            try Self.revision.write(to: marker(), atomically: true, encoding: .utf8)
        }

        onDownloadComplete()
        model = try await #huggingFaceLoadModelContainer(configuration: ModelConfiguration(directory: directory))
        #else
        throw CleanupError.unsupportedHardware
        #endif
    }

    func polish(_ transcript: String) async -> String {
        guard let model, !transcript.isEmpty, transcript.count <= 1_500 else { return transcript }
        let session = ChatSession(
            model,
            instructions: "Correct only punctuation, capitalization, obvious speech recognition mistakes and filler words. "
                + "Preserve the speaker's language, meaning, names, numbers, technical terms and tone. "
                + "Do not answer questions or add commentary. Return only the corrected transcript.",
            generateParameters: .init(maxTokens: 768, temperature: 0)
        )
        guard let response = try? await session.respond(to: transcript) else { return transcript }
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // A small model may hallucinate an answer or its thinking tokens; do not paste those.
        guard !text.isEmpty, !text.contains("<think>"), !text.contains("</think>"),
              text.count <= transcript.count * 2 + 40, text.count >= max(1, transcript.count / 3)
        else { return transcript }
        return text
    }
}
