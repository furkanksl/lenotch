import AVFoundation
import XCTest
@testable import Lenotch

final class DictationAudioCaptureTests: XCTestCase {
    func testInputTapCanConvertAudioOnANonMainQueue() async throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let capture = try XCTUnwrap(DictationAudioCapture(inputFormat: inputFormat))
        let handler = DictationAudioCapture.tapHandler(for: capture)

        // AVAudioEngine calls this callback on its own queue; a main-actor-isolated
        // callback crashes with a Swift executor assertion on the first buffer.
        await Task.detached {
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            for index in 0..<4_800 { buffer.floatChannelData![0][index] = 0.25 }
            handler(buffer, AVAudioTime(hostTime: 0))
        }.value

        let samples = capture.take()
        XCTAssertGreaterThan(samples.count, 1_000)
        XCTAssertLessThan(samples.count, 1_800)
        XCTAssertGreaterThan(capture.level(), 0)
    }
}
