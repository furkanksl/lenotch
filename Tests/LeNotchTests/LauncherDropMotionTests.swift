import AppKit
import SwiftUI
import XCTest
@testable import Lenotch

@MainActor final class LauncherDropMotionTests: XCTestCase {
    func testDropsReleaseRightToLeftRatherThanAllRadiatingAtOnce() {
        var motion = LauncherDropMotion()
        motion.transition(opening: true, count: 5, at: 10)
        let early = (0..<5).map { motion.progress(index: $0, count: 5, at: 10.1, settled: false) }
        XCTAssertEqual(early[0], 0)
        XCTAssertEqual(early[3], 0)
        XCTAssertGreaterThan(early[4], 0.3)
        let middle = (0..<5).map { motion.progress(index: $0, count: 5, at: 10.32, settled: false) }
        XCTAssertEqual(middle[0], 0)
        XCTAssertGreaterThan(middle[3], middle[2])
        XCTAssertGreaterThan(middle[4], middle[3])
        for index in 0..<5 {
            XCTAssertEqual(motion.progress(index: index, count: 5, at: 12, settled: false), 1, accuracy: 0.001)
        }
    }

    func testInterruptingOpeningPreservesDropPositionsAndVelocities() {
        var motion = LauncherDropMotion()
        motion.transition(opening: true, count: 5, at: 0)
        let before = (0..<5).map { motion.sample(index: $0, count: 5, at: 0.3) }
        motion.transition(opening: false, count: 5, at: 0.3)
        for index in 0..<5 {
            let after = motion.sample(index: index, count: 5, at: 0.3)
            XCTAssertEqual(after.value, before[index].value, accuracy: 0.00001)
            XCTAssertEqual(after.velocity, before[index].velocity, accuracy: 0.00001)
        }
        for index in 0..<5 {
            XCTAssertEqual(motion.progress(index: index, count: 5, at: 2, settled: false), 0, accuracy: 0.001)
        }
    }

    func testDropStartsInsideNotchAndContentsAppearOnlyAfterLiquidStretch() {
        let layout = LauncherFanLayout()
        for index in 0..<5 {
            let hidden = LauncherDropPose(layout: layout, index: index, count: 5, progress: 0)
            XCTAssertLessThan(hidden.center.y, layout.notchHeight)
            XCTAssertEqual(hidden.reveal, 0)
            let neck = LauncherDropPose(layout: layout, index: index, count: 5, progress: 0.25)
            XCTAssertEqual(neck.reveal, 0)
            XCTAssertTrue(neck.isFluid)
            XCTAssertEqual(neck.trailingDrops(layout: layout, index: index, count: 5).count, 2)
            let detached = LauncherDropPose(layout: layout, index: index, count: 5, progress: 1)
            XCTAssertEqual(detached.reveal, 1)
            XCTAssertFalse(detached.isFluid)
            XCTAssertTrue(detached.trailingDrops(layout: layout, index: index, count: 5).isEmpty)
            XCTAssertEqual(detached.radius, LauncherFanLayout.diameter / 2)
        }
    }

    func testReducedMotionSkipsTravelAndAnimatedClockStopsAtRest() throws {
        let model = LauncherModel(defaults: nil)
        try model.addLink("https://example.com", title: "Example")
        let state = LauncherFanState(model: model)
        state.setPresented(true, at: 0)
        XCTAssertTrue(state.animating)
        let moving = state.pose(index: 0, at: 0.06)
        XCTAssertLessThan(moving.progress, 0.3)
        XCTAssertEqual(state.pose(index: 0, at: 0.06, reduceMotion: true).progress, 1)
        state.finishTransition()
        XCTAssertFalse(state.animating)
        XCTAssertEqual(state.pose(index: 0, at: 0.06).progress, 1)
        state.setPresented(false, at: 0.2)
        XCTAssertEqual(state.pose(index: 0, at: 0.21, reduceMotion: true).center, state.layout.center(index: 0, count: 1),
                       "Reduce Motion must fade in place on close too, not travel back toward the notch")
    }

    func testLiquidNeckIsConnectedToNotchBeforeReleaseAndGoneAtRest() throws {
        let layout = LauncherFanLayout()
        let connected = LauncherDropPose(layout: layout, index: 0, count: 1, progress: 0.3)
        let layer = LauncherLiquidLayer(layout: layout, poses: [connected], fluid: true)
        let bitmap = try render(layer)
        for y in Int(layout.notchHeight - 2)...Int(connected.center.y) {
            let alpha = try XCTUnwrap(bitmap.colorAt(x: Int(layout.width), y: y * 2)).alphaComponent
            XCTAssertGreaterThan(alpha, 0.85, "Liquid neck disconnected at y=\(y)")
        }
        let resting = try render(LauncherLiquidLayer(layout: layout,
            poses: [LauncherDropPose(layout: layout, index: 0, count: 1, progress: 1)], fluid: false))
        for y in [layout.notchHeight + 20, layout.notchHeight + 60, layout.notchHeight + 100] {
            XCTAssertLessThan(try XCTUnwrap(resting.colorAt(x: Int(layout.width), y: Int(y * 2))).alphaComponent, 0.01)
        }
    }

    func testNativeAnimationStoryboardHasLiquidThenSharpDrops() throws {
        let model = LauncherModel(defaults: nil)
        for index in 0..<5 { try model.addLink("https://example.com/\(index)", title: "App \(index + 1)") }
        let layout = LauncherFanLayout()
        let state = LauncherFanState(model: model)
        state.setPresented(true, at: 0)
        let times = [0.0, 0.08, 0.19, 0.3, 0.42, 0.56, 0.78, 1.2]
        let width = Int(layout.width), height = Int(LauncherFanLayout.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width * 2, height: height * 4,
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (index, time) in times.enumerated() {
            let frame = LauncherView(state: state, reduceMotion: false, onClose: {}, onConfigure: {}, onLaunch: { _ in })
                .animationFrame(at: time)
            let renderer = ImageRenderer(content: frame
                .background(Color(red: 0.65, green: 0.7, blue: 0.8)))
            let image = try XCTUnwrap(renderer.cgImage)
            context.draw(image, in: CGRect(x: (index % 2) * width, y: (3 - index / 2) * height, width: width, height: height))
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("lenotch-drop-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("liquid-drop-storyboard.png"))
    }

    private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }
}
