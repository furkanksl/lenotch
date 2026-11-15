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

    /// Feeds `seconds` of a tone (0 Hz: silence) through the tap, a buffer at a time, as the mic would.
    private func meter(tone hz: Double, seconds: Double = 0.6) throws -> DictationMeter {
        let rate = 48_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let capture = try XCTUnwrap(DictationAudioCapture(inputFormat: format))
        let frames = 2_048
        var phase = 0.0
        for _ in 0..<Int(seconds * rate) / frames {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames {
                buffer.floatChannelData![0][i] = hz > 0 ? Float(0.2 * sin(phase)) : 0
                phase += 2 * .pi * hz / rate
            }
            capture.append(buffer)
        }
        return capture.meter()
    }

    func testTheMicsFourBandsAreTheVoicesLowToHigh() throws {
        let silence = try meter(tone: 0)
        XCTAssertEqual(silence.bands.count, DictationMeter.bandCount)
        XCTAssertEqual(silence.level, 0)
        XCTAssertTrue(silence.bands.allSatisfy { $0 < 0.05 }, "silence moves no bar: \(silence.bands)")

        let low = try meter(tone: 160)
        let high = try meter(tone: 3_500)
        XCTAssertGreaterThan(low.level, 0.5, "a voice-loud tone reads as speaking")
        XCTAssertEqual(low.bands.firstIndex(of: low.bands.max()!), 0, "a low voice lights the first bar: \(low.bands)")
        XCTAssertEqual(high.bands.firstIndex(of: high.bands.max()!), 3, "a high one the last: \(high.bands)")
    }
}
