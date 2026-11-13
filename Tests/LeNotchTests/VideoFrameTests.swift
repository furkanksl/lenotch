import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import Synchronization
import XCTest
@testable import Lenotch

/// Synthetic ScreenCaptureKit-shaped frames exercise the actual decode path without requesting screen access.
@MainActor
final class VideoFrameTests: XCTestCase {
    func testCompleteFrameBecomesAnOwnedRenderableImageWithoutAnIOSurface() throws {
        let images = Mutex<[CGImage]>([])
        let output = VideoMirror.Output(cells: (4, 3), onFrame: { image in images.withLock { $0.append(image) } })
        let buffer = try makeBuffer()
        fill(buffer, red: 255, green: 0, blue: 0)
        let sample = try makeSample(buffer, status: .complete)
        XCTAssertNil(CVPixelBufferGetIOSurface(buffer), "the decoder must not depend on a shared IOSurface")

        output.receive(sample)
        let image = try XCTUnwrap(images.withLock { $0.first })
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 18)
        // Capture pools overwrite/reuse their pixel buffers. The displayed image must keep the original frame.
        fill(buffer, red: 0, green: 0, blue: 255)
        let color = try centerPixel(image)
        XCTAssertGreaterThan(color[0], 220)
        XCTAssertLessThan(color[1], 20)
        XCTAssertLessThan(color[2], 20)
    }

    func testIdleBlankAndSuspendedFramesDoNotReplaceTheLastGoodImage() throws {
        let images = Mutex<[CGImage]>([])
        let output = VideoMirror.Output(cells: (4, 3), onFrame: { image in images.withLock { $0.append(image) } })
        let buffer = try makeBuffer()
        fill(buffer, red: 20, green: 180, blue: 40)
        output.receive(try makeSample(buffer, status: .complete))
        for status in [SCFrameStatus.idle, .blank, .suspended, .started, .stopped] {
            output.receive(try makeSample(buffer, status: status))
        }
        XCTAssertEqual(images.withLock { $0.count }, 1)
    }

    func testPausedFirstFrameIsDeliveredDuringMotionSearch() throws {
        let images = Mutex<[CGImage]>([])
        let output = VideoMirror.Output(cells: (4, 3), onFrame: { image in images.withLock { $0.append(image) } })
        let buffer = try makeBuffer()
        fill(buffer, red: 40, green: 90, blue: 160)
        XCTAssertTrue(output.finding)
        output.receive(try makeSample(buffer, status: .complete))
        XCTAssertEqual(images.withLock { $0.count }, 1, "don't discard the only frame of a paused video while looking for motion")
        XCTAssertNil(output.movingBox())
    }

    func testFinishedMotionSearchStillDeliversVideoFrames() throws {
        let images = Mutex<[CGImage]>([])
        let output = VideoMirror.Output(cells: (4, 3), onFrame: { image in images.withLock { $0.append(image) } })
        output.finding = false
        let buffer = try makeBuffer()
        fill(buffer, red: 90, green: 60, blue: 30)
        output.receive(try makeSample(buffer, status: .complete))
        XCTAssertEqual(images.withLock { $0.count }, 1)
        XCTAssertNil(output.movingBox())
    }

    func testFrameWithoutCaptureStatusIsIgnored() throws {
        let images = Mutex<[CGImage]>([])
        let output = VideoMirror.Output(cells: (4, 3), onFrame: { image in images.withLock { $0.append(image) } })
        output.receive(try makeSample(makeBuffer(), status: nil))
        XCTAssertTrue(images.withLock { $0.isEmpty })
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 18, kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func fill(_ buffer: CVPixelBuffer, red: UInt8, green: UInt8, blue: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                let i = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                base[i] = blue; base[i + 1] = green; base[i + 2] = red; base[i + 3] = 255
            }
        }
    }

    private func makeSample(_ buffer: CVPixelBuffer, status: SCFrameStatus?) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                  imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                               formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
                                                               sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        if let status {
            let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true))
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
            dictionary[SCStreamFrameInfo.status.rawValue] = status.rawValue
        }
        return result
    }

    private func centerPixel(_ image: CGImage) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                 bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }
}
