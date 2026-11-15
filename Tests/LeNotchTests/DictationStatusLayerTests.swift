import AppKit
import SwiftUI
import XCTest
@testable import Lenotch

@MainActor
final class DictationStatusLayerTests: XCTestCase {
    private typealias Indicator = DictationCoordinator.Indicator
    private typealias Phase = DictationCoordinator.Phase

    // MARK: What the notch shows per phase

    func testEveryPhaseMapsToTheLeastItNeedsToShow() {
        func indicator(_ phase: Phase, _ progress: Double? = nil, _ notice: DictationCoordinator.Notice? = nil) -> Indicator? {
            DictationCoordinator.indicator(phase: phase, downloadProgress: progress, notice: notice)
        }
        XCTAssertNil(indicator(.idle))
        XCTAssertEqual(indicator(.recording), .listening)
        XCTAssertEqual(indicator(.preparing), .working, "loading a model that is already on the Mac")
        XCTAssertEqual(indicator(.preparing, 0.42), .downloading(0.42))
        XCTAssertEqual(indicator(.transcribing), .working)
        XCTAssertEqual(indicator(.cleaning), .working)
        XCTAssertNil(indicator(.done), "a paste needs no confirmation: the text appearing is it")
        XCTAssertEqual(indicator(.done, nil, .copied), .note(.copied))
        XCTAssertEqual(indicator(.done, nil, .ready), .note(.ready))
        XCTAssertEqual(indicator(.failed, nil, .problem("No microphone")), .problem("No microphone"))
        XCTAssertNil(indicator(.failed), "a failure without words has nothing to show")
    }

    func testOnlyAProblemNeedsTheCard() {
        XCTAssertTrue(Indicator.problem("x").isShelf)
        for indicator in [Indicator.listening, .working, .downloading(0.1), .note(.copied), .note(.ready)] {
            XCTAssertFalse(indicator.isShelf)
        }
    }

    // MARK: Shape

    func testEarsAreFlatOnTopAndRoundedAtTheBottomLikeTheIslandsOwn() {
        let rect = CGRect(x: 0, y: 0, width: 328, height: 40.5)
        let path = DictationEars.shape(radius: 18).path(in: rect)
        XCTAssertTrue(path.contains(CGPoint(x: 1, y: 1)), "square at the top: it meets the screen edge")
        XCTAssertTrue(path.contains(CGPoint(x: 327, y: 1)))
        XCTAssertTrue(path.contains(CGPoint(x: 164, y: 39)))
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 39.5)), "round at the bottom, a pill end")
        XCTAssertFalse(path.contains(CGPoint(x: 327, y: 39.5)))
    }

    func testCardShelfJoinsTheNotchAndWidensBelowIt() {
        let shelf = DictationNotchExtension(topWidth: 208).path(in: CGRect(x: 0, y: 0, width: 300, height: 70))
        XCTAssertTrue(shelf.contains(CGPoint(x: 150, y: 1)), "meets the notch at the center")
        XCTAssertFalse(shelf.contains(CGPoint(x: 1, y: 1)), "its shoulders grow from the notch, not a detached pill")
        XCTAssertTrue(shelf.contains(CGPoint(x: 150, y: 60)))
    }

    func testBarsFollowTheMicrophone() {
        let silence = DictationLevelBars.heights(for: 0)
        let speech = DictationLevelBars.heights(for: 0.7)
        XCTAssertEqual(silence.count, 5)
        for index in silence.indices {
            XCTAssertLessThan(silence[index], speech[index], "Microphone level should drive the bars")
            XCTAssertLessThanOrEqual(DictationLevelBars.heights(for: 1)[index], 20)
        }
    }

    // MARK: Drawing

    /// The notch's row at 2x, black ears on a light wallpaper: what you'd see on screen.
    private func render(_ indicator: Indicator, level: Float = 0.6) throws -> CGImage {
        let view = ZStack(alignment: .topLeading) {
            Color(white: 0.86)
            if indicator.isShelf, case .problem(let message) = indicator {
                DictationShelf(message: message, notchHalfWidth: 104, notchHeight: 37.5)
            } else {
                DictationEars(indicator: indicator, level: level, notchHalfWidth: 104, notchHeight: 37.5, reduceMotion: true)
            }
        }
        .frame(width: 760, height: 120, alignment: .topLeading)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        if let directory = ProcessInfo.processInfo.environment["DICTATION_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(cgImage: image)
            let name = "\(indicator.slotKey)\(indicator.isShelf ? "-card" : "").png"
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        return image
    }

    /// Counts the pixels in a region (in points) that satisfy a test.
    private func count(in image: CGImage, x: ClosedRange<Int>, y: ClosedRange<Int>, where test: (UInt8, UInt8, UInt8) -> Bool) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        var found = 0
        for py in (y.lowerBound * 2)...(y.upperBound * 2) {
            for px in (x.lowerBound * 2)...(x.upperBound * 2) {
                guard let color = rep.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { continue }
                if test(UInt8(color.redComponent * 255), UInt8(color.greenComponent * 255), UInt8(color.blueComponent * 255)) { found += 1 }
            }
        }
        return found
    }

    private let leftEar = 216...276, rightEar = 484...544, row = 4...34   // points; the notch is x 276…484

    func testListeningShowsARedMicOnTheLeftAndWhiteBarsOnTheRight() throws {
        let image = try render(.listening)
        XCTAssertGreaterThan(count(in: image, x: leftEar, y: row) { r, g, b in r > 200 && g < 120 && b < 120 }, 20, "red mic")
        XCTAssertGreaterThan(count(in: image, x: rightEar, y: row) { r, g, b in r > 200 && g > 200 && b > 200 }, 20, "white level bars")
        // Inside the rounded end: the wallpaper shows at the pill's bottom corners.
        XCTAssertEqual(count(in: image, x: 226...276, y: row) { r, g, b in r > 200 && g > 200 && b > 200 }, 0, "the left ear holds only the mic")
    }

    func testTheBarsGrowWithTheVoice() throws {
        let quiet = count(in: try render(.listening, level: 0.05), x: rightEar, y: row) { r, _, _ in r > 200 }
        let loud = count(in: try render(.listening, level: 1), x: rightEar, y: row) { r, _, _ in r > 200 }
        XCTAssertGreaterThan(loud, quiet)
    }

    func testEveryEarStateDrawsOnBothSidesAndStaysInsideTheEars() throws {
        for indicator in [Indicator.listening, .working, .downloading(0.42), .note(.copied), .note(.ready)] {
            let image = try render(indicator)
            let visible: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in max(r, g, b) > 90 }
            XCTAssertGreaterThan(count(in: image, x: leftEar, y: row, where: visible), 8, "\(indicator.slotKey): left ear is empty")
            XCTAssertGreaterThan(count(in: image, x: rightEar, y: row, where: visible), 8, "\(indicator.slotKey): right ear is empty")
            XCTAssertEqual(count(in: image, x: 296...464, y: row, where: visible), 0, "\(indicator.slotKey): nothing is drawn over the notch")
        }
    }

    func testTheCardRendersItsMessage() throws {
        let image = try render(.problem("Allow microphone access in Dictation settings first."))
        XCTAssertGreaterThan(count(in: image, x: 260...500, y: 50...100) { r, g, b in r > 200 && g > 200 && b > 200 }, 50, "message text")
        XCTAssertGreaterThan(count(in: image, x: 260...300, y: 50...100) { r, g, b in r > 200 && g > 120 && b < 80 }, 5, "orange mark")
    }
}
