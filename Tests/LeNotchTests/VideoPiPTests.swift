import AppKit
import XCTest
@testable import Lenotch

@MainActor
final class VideoPiPTests: XCTestCase {
    func testNativeWindowDisplaysSyntheticVideoFrameAcrossItsContent() async throws {
        _ = NSApplication.shared
        let video = try redVideoLayer()
        let pip = VideoPiP()
        defer { pip.hide() }

        pip.show(layer: video, aspect: 16.0 / 9.0)
        let panel = try XCTUnwrap(pip.panel)
        await settleLayout(panel)
        let root = try XCTUnwrap(panel.contentView)
        let host = try XCTUnwrap(videoHost(in: root))

        XCTAssertTrue(pip.isShown)
        XCTAssertEqual(root.bounds.width, 448, accuracy: 1)
        XCTAssertEqual(root.bounds.height, 252, accuracy: 1)
        assertVideoFillsContent(video, host: host, root: root)
        XCTAssertTrue(host.allowsWindowDragging, "the real PiP window must opt into video dragging")
        XCTAssertTrue(root.hitTest(NSPoint(x: root.bounds.midX, y: root.bounds.midY)) === host,
                      "SwiftUI overlays must leave the video available for native dragging")
        try assertNativeFrameIsRed(root)
    }

    func testResizingNativeWindowKeepsVideoFillingItsContent() async throws {
        _ = NSApplication.shared
        let video = try redVideoLayer()
        let pip = VideoPiP()
        defer { pip.hide() }

        pip.show(layer: video, aspect: 16.0 / 9.0)
        let panel = try XCTUnwrap(pip.panel)
        await settleLayout(panel)
        panel.setContentSize(NSSize(width: 640, height: 360))
        await settleLayout(panel)
        let root = try XCTUnwrap(panel.contentView)
        let host = try XCTUnwrap(videoHost(in: root))

        XCTAssertEqual(root.bounds.width, 640, accuracy: 1)
        XCTAssertEqual(root.bounds.height, 360, accuracy: 1)
        assertVideoFillsContent(video, host: host, root: root)
        try assertNativeFrameIsRed(root)
    }

    func testHideAndReopenRetainsVideoWithoutTakingKeyboardFocus() async throws {
        let app = NSApplication.shared
        let previousKeyWindow = app.keyWindow
        let video = try redVideoLayer()
        let pip = VideoPiP()
        defer { pip.hide() }

        pip.show(layer: video, aspect: 16.0 / 9.0)
        let panel = try XCTUnwrap(pip.panel)
        await settleLayout(panel)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(panel.contentAspectRatio.width / panel.contentAspectRatio.height, 16.0 / 9.0,
                       accuracy: 0.001)
        XCTAssertTrue(app.keyWindow === previousKeyWindow)

        pip.hide()
        XCTAssertFalse(pip.isShown)
        XCTAssertNil(panel.contentView)

        pip.show(layer: video, aspect: 16.0 / 9.0)
        await settleLayout(panel)
        let root = try XCTUnwrap(panel.contentView)
        let host = try XCTUnwrap(videoHost(in: root))
        XCTAssertTrue(pip.panel === panel)
        XCTAssertTrue(pip.isShown)
        assertVideoFillsContent(video, host: host, root: root)
        try assertNativeFrameIsRed(root)
        pip.hide()
        XCTAssertFalse(pip.isShown)
    }

    func testRetiringIslandUpdateDoesNotTakeVideoAwayFromPiP() async throws {
        _ = NSApplication.shared
        let mirror = VideoMirror()
        mirror.display(try image(red: 1, green: 0, blue: 0))
        let island = VideoLayerHostView(videoLayer: mirror.layer)
        island.frame = NSRect(x: 0, y: 0, width: 544, height: 306)
        island.layoutSubtreeIfNeeded()
        let pip = VideoPiP()
        defer { pip.hide() }
        pip.show(layer: mirror.pipLayer, aspect: 16.0 / 9.0)
        let panel = try XCTUnwrap(pip.panel)
        await settleLayout(panel)
        let root = try XCTUnwrap(panel.contentView)
        try assertNativeFrameIsRed(root)

        // A retiring SwiftUI view can still receive an update after the handoff.
        // Its representable must not move the only live video layer out of PiP.
        island.attach(mirror.layer)
        island.frame.size = NSSize(width: 600, height: 338)
        island.layoutSubtreeIfNeeded()
        await settleLayout(panel)
        let host = try XCTUnwrap(videoHost(in: root))
        XCTAssertFalse(mirror.layer === mirror.pipLayer)
        XCTAssertTrue(mirror.layer.superlayer === island.layer)
        assertVideoFillsContent(mirror.pipLayer, host: host, root: root)
        try assertNativeFrameIsRed(root)

        // Actual capture uses the same delivery seam; new frames must reach PiP,
        // not just leave its initial still image visible after the handoff.
        mirror.display(try image(red: 0, green: 0, blue: 1))
        await settleLayout(panel)
        try assertNativeFrame(root, expectedRGB: (0, 0, 1))
        island.detach()
        XCTAssertTrue(mirror.pipLayer.superlayer === host.layer)
        try assertNativeFrame(root, expectedRGB: (0, 0, 1))
    }

    func testStoppingVideoClearsBothNotchAndPiPFrames() throws {
        let mirror = VideoMirror()
        mirror.display(try image(red: 1, green: 0, blue: 0))
        XCTAssertNotNil(mirror.layer.contents)
        XCTAssertNotNil(mirror.pipLayer.contents)
        mirror.stop()
        XCTAssertNil(mirror.layer.contents)
        XCTAssertNil(mirror.pipLayer.contents)
    }

    private func settleLayout(_ panel: NSPanel) async {
        // SwiftUI mounts the representable during a later main-actor turn.
        for _ in 0..<5 {
            await Task.yield()
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
        }
        CATransaction.flush()
    }

    private func videoHost(in view: NSView) -> VideoLayerHostView? {
        if let host = view as? VideoLayerHostView { return host }
        return view.subviews.lazy.compactMap { self.videoHost(in: $0) }.first
    }

    private func assertVideoFillsContent(_ video: CALayer, host: VideoLayerHostView, root: NSView,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let placement = host.convert(host.bounds, to: root)
        XCTAssertEqual(placement.minX, root.bounds.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(placement.minY, root.bounds.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(placement.width, root.bounds.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(placement.height, root.bounds.height, accuracy: 1, file: file, line: line)
        XCTAssertTrue(video.superlayer === host.layer, file: file, line: line)
        XCTAssertEqual(video.frame, host.bounds, file: file, line: line)
    }

    private func assertNativeFrameIsRed(_ root: NSView,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        try assertNativeFrame(root, expectedRGB: (1, 0, 0), file: file, line: line)
    }

    private func assertNativeFrame(_ root: NSView, expectedRGB: (CGFloat, CGFloat, CGFloat),
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds), file: file, line: line)
        root.cacheDisplay(in: root.bounds, to: bitmap)
        for (x, y) in [(0.25, 0.4), (0.5, 0.5), (0.75, 0.6)] {
            let pixel = try XCTUnwrap(bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * x),
                                                    y: Int(Double(bitmap.pixelsHigh) * y))?
                .usingColorSpace(.sRGB), file: file, line: line)
            // Native window caching color-manages the source image. Verify the displayed frame's dominant primary,
            // rather than requiring unmanaged RGB bytes: this still rejects black, stale red, and missing regions.
            let components = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
            let expected = [expectedRGB.0, expectedRGB.1, expectedRGB.2]
            let primary = try XCTUnwrap(expected.firstIndex(of: 1), file: file, line: line)
            XCTAssertGreaterThan(components[primary], 0.75,
                                 "PiP must display the current video frame, not a black panel", file: file, line: line)
            for other in components.indices where other != primary {
                XCTAssertGreaterThan(components[primary] - components[other], 0.4,
                                     "PiP must show the current frame rather than a stale color", file: file, line: line)
            }
            XCTAssertGreaterThan(pixel.alphaComponent, 0.9, file: file, line: line)
        }
    }

    private func redVideoLayer() throws -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.contents = try image(red: 1, green: 0, blue: 0)
        return layer
    }

    private func image(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8,
                                              bytesPerRow: 16 * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [red, green, blue, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        return try XCTUnwrap(context.makeImage())
    }
}
