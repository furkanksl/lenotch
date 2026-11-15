import AVFoundation
import XCTest
@testable import Lenotch

/// Opt in with LENOTCH_DICTATION_TEST_AUDIO pointing to a local 16 kHz mono audio file containing:
/// “Please move the design review to Thursday morning. I will send the updated notes tomorrow afternoon.”
/// Uses only the app's installed model caches, never downloads models, records audio, or pastes text.
@MainActor
final class DictationStreamingTests: XCTestCase {
    func testFluidSpeechProProducesAPartialBeforeTheFinalAudioAndKeepsTheEnding() async throws {
        try await checkStreaming(.fluidSpeechPro)
    }

    func testNemotronProducesAPartialBeforeTheFinalAudioAndKeepsTheEnding() async throws {
        try await checkStreaming(.nemotronStreaming)
    }

    private func checkStreaming(_ model: DictationModel) async throws {
        guard let path = ProcessInfo.processInfo.environment["LENOTCH_DICTATION_TEST_AUDIO"] else {
            throw XCTSkip("Set LENOTCH_DICTATION_TEST_AUDIO to opt in to cached-model transcription tests.")
        }
        guard NSString(string: path).isAbsolutePath else {
            XCTFail("LENOTCH_DICTATION_TEST_AUDIO must be an absolute local audio-file path.")
            return
        }
        let samples = try loadSamples(from: URL(fileURLWithPath: path))
        let chunkSize = 8_000
        guard samples.count > DictationSpeechModels.minimumSamples + chunkSize else {
            XCTFail("The fixture must contain more than 1.5 seconds of the expected sentence.")
            return
        }

        let speech = DictationSpeechModels()
        guard speech.isInstalled(model) else {
            XCTFail("\(model.name) must already be installed when the offline integration test is enabled.")
            return
        }
        try await speech.prepare(model, allowDownload: false)
        XCTAssertTrue(speech.isReady(model))
        try await speech.beginStreaming()
        defer { speech.discardStreaming() }

        // Keep the final half-second unread, exercising the same tail handoff as stopping a real recording.
        let streamedCount = samples.count - chunkSize
        var offset = 0
        var partials: [String] = []
        while offset < streamedCount {
            let end = min(offset + chunkSize, streamedCount)
            if let partial = try await speech.stream(Array(samples[offset..<end])),
               !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                partials.append(partial)
            }
            offset = end
        }
        XCTAssertFalse(partials.isEmpty, "\(model.name) must produce live text before receiving the final audio.")
        XCTAssertLessThan(offset, samples.count, "The partial assertion must precede the unread tail.")

        let final = try await speech.finishStreaming(unread: Array(samples[offset...]), all: samples)
        XCTAssertNotNil(final.range(of: "Thursday", options: .caseInsensitive), "\(model.name): \(final)")
        XCTAssertNotNil(final.range(of: "afternoon", options: .caseInsensitive), "\(model.name) lost the ending: \(final)")
        print("[DictationStreamingTests] \(model.name): \(partials.count) nonempty partials before the tail; final: \(final)")
    }

    private func loadSamples(from url: URL) throws -> [Float] {
        // Decode either WAV or CAF into planar Float32; the fixture generator supplies the sample rate/channels.
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else {
            XCTFail("The offline fixture must be 16 kHz mono, not \(file.processingFormat).")
            return []
        }
        guard file.length > 0, file.length <= Int64(AVAudioFrameCount.max) else {
            XCTFail("The offline fixture must have a nonempty, supported frame count.")
            return []
        }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
