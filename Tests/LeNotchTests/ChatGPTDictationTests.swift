import Foundation
import XCTest
@testable import Lenotch

final class ChatGPTDictationTests: XCTestCase {
    func testExistingAndUnknownPreferencesKeepLocalDictation() throws {
        let suite = "lenotch.test.dictation.provider.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DictationProvider.selected(in: defaults), .local)
        defaults.set("unknown", forKey: DictationProvider.preferenceKey)
        XCTAssertEqual(DictationProvider.selected(in: defaults), .local)
        defaults.set("chatGPT", forKey: DictationProvider.preferenceKey)
        XCTAssertEqual(DictationProvider.selected(in: defaults), .chatGPT)
        XCTAssertFalse(DictationProvider.chatGPT.isAvailable(chatGPTConnected: false))
        XCTAssertTrue(DictationProvider.chatGPT.isAvailable(chatGPTConnected: true))
        XCTAssertTrue(DictationProvider.local.isAvailable(chatGPTConnected: false))
    }

    func testWAVIsMono24kHzPCMAndKeepsTheRecordingDuration() throws {
        let wav = try ChatGPTDictation.wav(Array(repeating: 0, count: 16_000))
        XCTAssertEqual(wav.count, 44 + 24_000 * 2)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(uint32(wav, 4), UInt32(wav.count - 8))
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(uint32(wav, 16), 16)
        XCTAssertEqual(uint16(wav, 20), 1, "PCM")
        XCTAssertEqual(uint16(wav, 22), 1, "Mono")
        XCTAssertEqual(uint32(wav, 24), 24_000)
        XCTAssertEqual(uint32(wav, 28), 48_000)
        XCTAssertEqual(uint16(wav, 32), 2)
        XCTAssertEqual(uint16(wav, 34), 16)
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(uint32(wav, 40), 48_000)
        XCTAssertTrue(wav.dropFirst(44).allSatisfy { $0 == 0 })
    }

    func testResamplingInterpolatesAndClipsInsteadOfOverflowing() throws {
        let wav = try ChatGPTDictation.wav([-2, 0, 2, 0])
        let samples = stride(from: 44, to: wav.count, by: 2).map { Int16(bitPattern: uint16(wav, $0)) }
        XCTAssertEqual(samples, [-32_767, -10_922, 10_922, 32_767, 10_922, 0])
    }

    func testEmptyOversizedAndNonfiniteAudioAreRejected() {
        for samples: [Float] in [[], [.nan], [.infinity], [-.infinity], Array(repeating: 0, count: 91 * 16_000 + 1)] {
            XCTAssertThrowsError(try ChatGPTDictation.wav(samples))
        }
    }

    func testMultipartMatchesTheConnectedAccountTranscriptionEndpoint() throws {
        let audio = try ChatGPTDictation.wav([0, 0.5])
        let request = ChatGPTDictation.request(audio: audio, token: "test-token", accountID: "test-account")
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/transcribe")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "test-account")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=lenotch-"))
        let body = try XCTUnwrap(request.httpBody)
        let header = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        XCTAssertTrue(body.starts(with: header))
        XCTAssertEqual(body.subdata(in: header.count..<(header.count + audio.count)), audio)
        XCTAssertTrue(body.suffix(Data("\r\n--\(boundary)--\r\n".utf8).count).elementsEqual(Data("\r\n--\(boundary)--\r\n".utf8)))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-token"))
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testTranscriptRequiresNonemptyTextAndPreservesUnicode() throws {
        let data = Data("{\"text\":\"  Merhaba dünya.  \"}".utf8)
        XCTAssertEqual(try ChatGPTDictation.transcript(data), "Merhaba dünya.")
        for json in ["{}", #"{"text":42}"#, #"{"text":" \n "}"#, #"{"error":"private backend message"}"#, "not JSON"] {
            XCTAssertThrowsError(try ChatGPTDictation.transcript(Data(json.utf8)))
        }
        XCTAssertThrowsError(try ChatGPTDictation.transcript(Data(repeating: 32, count: ChatGPTDictation.maxResponseBytes + 1)))
    }

    func testCancellationStopsEncoding() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ChatGPTDictation.wav([0, 1])
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled audio must not be uploaded")
        } catch is CancellationError {
            // Expected.
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    private func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(uint16(data, offset)) | UInt32(uint16(data, offset + 2)) << 16
    }
}
