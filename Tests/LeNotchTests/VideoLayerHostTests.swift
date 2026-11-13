import AppKit
import XCTest
@testable import Lenotch

@MainActor
final class VideoLayerHostTests: XCTestCase {
    func testAppKitLayoutSizesAnInitiallyEmptyHostAndResizesIt() {
        let video = CALayer()
        let host = VideoLayerHostView(videoLayer: video)
        XCTAssertEqual(video.frame, .zero)

        layout(host, size: NSSize(width: 544, height: 306))
        XCTAssertEqual(video.frame, host.bounds)
        layout(host, size: NSSize(width: 720, height: 405))
        XCTAssertEqual(video.frame, host.bounds)
        XCTAssertNil(video.animation(forKey: "bounds"), "layout must not animate a stale video size")
    }

    func testOldHostLayoutAndDetachDoNotStealVideoFromNewHost() {
        let video = CALayer()
        let island = VideoLayerHostView(videoLayer: video)
        layout(island, size: NSSize(width: 544, height: 306))
        let pip = VideoLayerHostView(videoLayer: video)
        layout(pip, size: NSSize(width: 448, height: 252))

        layout(island, size: NSSize(width: 600, height: 338))
        XCTAssertTrue(video.superlayer === pip.layer)
        XCTAssertEqual(video.frame, pip.bounds)
        island.detach()
        XCTAssertTrue(video.superlayer === pip.layer)
        XCTAssertEqual(video.frame, pip.bounds)
    }

    func testExplicitAttachMovesVideoBackAndOldPiPCleanupIsSafe() {
        let video = CALayer()
        let island = VideoLayerHostView(videoLayer: video)
        layout(island, size: NSSize(width: 544, height: 306))
        let pip = VideoLayerHostView(videoLayer: video)
        layout(pip, size: NSSize(width: 448, height: 252))

        island.attach(video)
        XCTAssertTrue(video.superlayer === island.layer)
        XCTAssertEqual(video.frame, island.bounds)
        pip.detach()
        XCTAssertTrue(video.superlayer === island.layer)
    }

    func testReplacingAndDetachingLayerLeavesNoStaleSublayer() {
        let old = CALayer(), replacement = CALayer()
        let host = VideoLayerHostView(videoLayer: old)
        layout(host, size: NSSize(width: 320, height: 180))
        host.attach(replacement)
        XCTAssertNil(old.superlayer)
        XCTAssertTrue(replacement.superlayer === host.layer)
        XCTAssertEqual(replacement.frame, host.bounds)
        host.attach(replacement)
        XCTAssertEqual(host.layer?.sublayers?.count, 1)
        host.detach()
        XCTAssertNil(replacement.superlayer)
        XCTAssertNil(host.videoLayer)
    }

    func testSyntheticVideoImageSurvivesReparentingAndRendersAfterResize() throws {
        let video = CALayer()
        video.contentsGravity = .resizeAspect
        // This local image goes out of scope before reparenting, like a delivered frame.
        try autoreleasepool { video.contents = try redImage() }
        let island = VideoLayerHostView(videoLayer: video)
        layout(island, size: NSSize(width: 64, height: 36))
        let pip = VideoLayerHostView(videoLayer: video)
        layout(pip, size: NSSize(width: 128, height: 72))
        island.detach()
        let contents = try XCTUnwrap(video.contents)
        XCTAssertEqual(CFGetTypeID(contents as CFTypeRef), CGImage.typeID)

        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 72, bitsPerComponent: 8,
                                              bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        video.render(in: context)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for (x, y) in [(8, 8), (64, 36), (120, 64)] {
            let offset = y * context.bytesPerRow + x * 4
            XCTAssertGreaterThan(pixels[offset], 240, "the frame must render red, not a black/empty host")
            XCTAssertLessThan(pixels[offset + 1], 10)
            XCTAssertLessThan(pixels[offset + 2], 10)
            XCTAssertGreaterThan(pixels[offset + 3], 240)
        }
    }

    private func layout(_ host: VideoLayerHostView, size: NSSize) {
        host.setFrameSize(size)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
    }

    private func redImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8,
                                              bytesPerRow: 16 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        return try XCTUnwrap(context.makeImage())
    }
}
