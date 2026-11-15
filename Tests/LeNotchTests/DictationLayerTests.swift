import AppKit
import IslandCore
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

/// Dictation in the notch: the run's states, Esc, the liquid's own ears, and what they draw.
@MainActor
final class DictationLayerTests: XCTestCase {
    private typealias Indicator = DictationCoordinator.Indicator
    private typealias Phase = DictationCoordinator.Phase
    private typealias Coordinator = DictationCoordinator

    // MARK: What the notch shows

    func testOnlyARunShowsInTheNotch() {
        func shown(_ phase: Phase, running: Bool = true, _ notice: Coordinator.Notice? = nil) -> Indicator? {
            Coordinator.indicator(phase: phase, running: running, notice: notice)
        }
        XCTAssertNil(shown(.idle))
        XCTAssertEqual(shown(.preparing), .working, "loading the model for a run is the run's work")
        XCTAssertNil(shown(.preparing, running: false), "a model download started from Setup shows its progress there")
        XCTAssertEqual(shown(.recording), .listening)
        XCTAssertEqual(shown(.transcribing), .working)
        XCTAssertEqual(shown(.cleaning), .working)
        XCTAssertEqual(shown(.done, running: false, .note(.pasted)), .note(.pasted), "a beat of the check as the text lands")
        XCTAssertEqual(shown(.done, running: false, .note(.copied)), .note(.copied))
        XCTAssertEqual(shown(.done, running: false, .note(.ready)), .note(.ready))
        XCTAssertEqual(shown(.failed, running: false, .problem("No microphone")), .problem("No microphone"))
        XCTAssertNil(shown(.done, running: false), "nothing to say: the notch closes")
        XCTAssertNil(shown(.failed, running: false), "Setup's own failures stay in Setup")
    }

    // MARK: Esc

    func testEscCancelsOnlyWhileARunIsListeningOrWorking() {
        for phase in [Phase.preparing, .recording, .transcribing, .cleaning] {
            XCTAssertTrue(Coordinator.escapeCancels(phase: phase, running: true), "\(phase)")
            XCTAssertFalse(Coordinator.escapeCancels(phase: phase, running: false), "\(phase): not a run, Esc stays the apps'")
        }
        for phase in [Phase.idle, .done, .failed] {
            XCTAssertFalse(Coordinator.escapeCancels(phase: phase, running: true), "\(phase): nothing left to cancel")
        }
    }

    func testCancellingLeavesNothingInTheNotchAndGivesEscBack() {
        let c = Coordinator.shared
        var seen: [Indicator?] = []
        let before = c.onIndicatorChange
        defer { c.onIndicatorChange = before }
        c.onIndicatorChange = { seen.append($0) }
        c.cancel()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertFalse(c.canCancel)
        XCTAssertNil(c.indicator)
        XCTAssertEqual(c.levels, Coordinator.silentLevels)
        XCTAssertEqual(seen.last ?? .listening, nil, "the director hears that dictation left the notch")
    }

    // MARK: The voice

    func testLevelsScrollByOneAndStayInRange() {
        var levels = Coordinator.silentLevels
        levels = Coordinator.shifted(levels, adding: 0.5)
        XCTAssertEqual(levels.count, Coordinator.levelCount)
        XCTAssertEqual(levels.last, 0.5, "the newest is on the right")
        let next = Coordinator.shifted(levels, adding: 0.2)
        XCTAssertEqual(Array(next.dropLast()), Array(levels.dropFirst()), "the rest move one to the left")
        XCTAssertEqual(Coordinator.shifted(levels, adding: 3).last, 1)
        XCTAssertEqual(Coordinator.shifted(levels, adding: -1).last, 0)
        XCTAssertEqual(Coordinator.shifted(levels, adding: .nan).last, 0)
    }

    func testBarsFollowTheVoiceAndTheWorkingWaveStaysLow() {
        XCTAssertEqual(DictationVoice.height(0), DictationVoice.floor, "silence is a row of dots")
        XCTAssertEqual(DictationVoice.height(1), DictationVoice.ceiling)
        XCTAssertLessThan(DictationVoice.height(0.1), DictationVoice.height(0.6))
        XCTAssertEqual(DictationVoice.height(.nan), DictationVoice.floor)
        for t in stride(from: 0.0, to: 2.0, by: 0.13) {
            let wave = DictationVoice.wave(at: t, count: Coordinator.levelCount)
            XCTAssertEqual(wave.count, Coordinator.levelCount)
            XCTAssertTrue(wave.allSatisfy { $0 >= DictationVoice.floor && $0 <= DictationVoice.waveCrest })
            XCTAssertGreaterThan(wave.max()! - wave.min()!, 2, "a wave, not a flat line")
        }
        let tuning = Tuning()
        // The right ear's slot runs from 8 pt past the notch to 13 pt short of the ear's end.
        XCTAssertLessThanOrEqual(DictationVoice.width(count: Coordinator.levelCount), tuning.dictationExtent - 8 - 13)
    }

    // MARK: The liquid's own shape

    func testDictationIsTheLiquidsEarsAndAMessageGrowsALip() {
        let tuning = Tuning()
        var targets = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: tuning)
        let ears = targets.resting(.dictation)
        XCTAssertEqual(ears.mainHalfWidth, 104 + tuning.dictationExtent)
        XCTAssertEqual(ears.mainHeight, 37.5, "the ears sit in the menu bar beside the notch")
        XCTAssertEqual(ears.cardHalfWidth, targets.resting(.compact).cardHalfWidth, "no card hung under the notch")

        let (first, stages) = targets.transition(from: .idle, to: .dictation)
        XCTAssertFalse(stages.isEmpty, "out of the empty notch it pours, like the song's ears")
        XCTAssertGreaterThan(first.mainHeight, ears.mainHeight, "the notch sags first")
        XCTAssertLessThan(first.mainHalfWidth, ears.mainHalfWidth, "then the ears run out")

        targets.context.dictationMessage = true
        let lip = targets.resting(.dictation)
        XCTAssertEqual(lip.mainHeight, 37.5 + tuning.dictationLip, "the same blob grows a lip for the words")
        XCTAssertGreaterThan(lip.mainHalfWidth, ears.mainHalfWidth)
    }

    // MARK: The director

    private func director() -> (IslandDirector, ManualScheduler) {
        let d = IslandDirector(), s = ManualScheduler()
        d.schedule = s.schedule
        d.frontmostApp = { "" }
        return (d, s)
    }

    func testDictationTakesTheEarsThroughTheDirectorAndLeavesThem() {
        let (d, s) = director()
        XCTAssertEqual(d.mode, .idle)
        d.dictationChanged(.working)
        XCTAssertEqual(d.mode, .dictation)
        XCTAssertTrue(d.groups.dictation)
        XCTAssertFalse(d.dictationMessage)
        d.dictationChanged(.listening)
        XCTAssertEqual(d.dictation, .listening)
        XCTAssertEqual(d.mode, .dictation)

        // A press on its ears belongs to the island and opens nothing.
        d.pointerDown(at: .zero, hit: .ears)
        d.pointerUp(at: .zero, hit: .ears, corridor: false)
        XCTAssertFalse(d.island.opened)
        XCTAssertEqual(d.mode, .dictation)

        // The volume shows over it for a moment and hands it back.
        d.levelChanged(brightness: false, level: 0.4)
        XCTAssertEqual(d.mode, .hud)
        s.advance(IslandDirector.hudLinger + 0.1)
        XCTAssertEqual(d.mode, .dictation)

        d.dictationChanged(.problem("Allow microphone access in Dictation settings first."))
        XCTAssertTrue(d.dictationMessage, "the ears grow a lip for the words")
        XCTAssertEqual(d.mode, .dictation)

        d.dictationChanged(nil)
        XCTAssertEqual(d.mode, .idle)
        XCTAssertFalse(d.groups.dictation)
        XCTAssertFalse(d.dictationMessage)
    }

    func testTheSongComesBackAfterDictation() {
        let (d, _) = director()
        d.startMusic()
        XCTAssertTrue(d.groups.musicEars)
        d.dictationChanged(.listening)
        XCTAssertFalse(d.groups.musicEars, "the mic and the voice have the ears")
        d.dictationChanged(nil)
        XCTAssertTrue(d.groups.musicEars)
    }

    // MARK: Drawing

    /// The dictation ears on the liquid, as on screen: a black island on a light wallpaper, the content clipped to it.
    private func render(_ indicator: Indicator, levels: [Float] = [0.1, 0.3, 0.6, 0.9, 0.7, 0.5, 0.8, 0.4, 0.6],
                        lip: Double = 0, name: String) throws -> CGImage {
        let frame = FrameModel()
        frame.halfWidth = 104 + Tuning().dictationExtent + (lip > 0 ? Tuning().peekExtra : 0)
        frame.height = 37.5 + lip
        frame.radius = lip > 0 ? Tuning().peekRadius : 18
        let island = UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: frame.radius, bottomTrailing: frame.radius),
                                            style: .continuous)
            .path(in: CGRect(x: frame.left, y: -1, width: frame.right - frame.left, height: frame.height + 1))
        let view = ZStack(alignment: .topLeading) {
            Color(white: 0.86)
            island.fill(Color.black)
            DictationEarsView(frame: frame, indicator: indicator, levels: levels)
                .mask(alignment: .topLeading) { island.fill(Color.white) }
        }
        .frame(width: NotchContentView.size.width, height: 120, alignment: .topLeading)
        .environment(\.islandMotion, IslandMotion(reduce: true, stills: true))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        if let directory = ProcessInfo.processInfo.environment["DICTATION_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return image
    }

    /// Counts the pixels in a region (in points, top-left origin) that pass a test, in sRGB.
    private func count(in image: CGImage, x: ClosedRange<Int>, y: ClosedRange<Int>,
                       where test: (Int, Int, Int) -> Bool) -> Int {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var found = 0
        for py in (y.lowerBound * 2)...(y.upperBound * 2) where py < image.height {
            for px in (x.lowerBound * 2)...(x.upperBound * 2) where px < image.width {
                let o = (py * image.width + px) * 4
                if test(Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2])) { found += 1 }
            }
        }
        return found
    }

    // Points. The island spans 208…552 (the ears 68 pt past the 104 pt half notch); the notch is 276…484. The ears' boxes
    // stop short of the pill's rounded ends, where the wallpaper shows.
    private let leftEar = 222...272, rightEar = 488...538, row = 2...35, overNotch = 290...470
    private let white: (Int, Int, Int) -> Bool = { r, g, b in r > 200 && g > 200 && b > 200 }
    private let red: (Int, Int, Int) -> Bool = { r, g, b in r > 200 && g < 120 && b < 120 }

    func testListeningIsARedMicLeftAndYourVoiceRight() throws {
        let image = try render(.listening, name: "listening")
        XCTAssertGreaterThan(count(in: image, x: leftEar, y: row, where: red), 30, "the red mic")
        XCTAssertEqual(count(in: image, x: rightEar, y: row, where: red), 0)
        XCTAssertGreaterThan(count(in: image, x: rightEar, y: row, where: white), 60, "the voice's bars")
        XCTAssertEqual(count(in: image, x: overNotch, y: row) { r, g, b in max(r, g, b) > 40 }, 0,
                       "nothing is drawn over the notch")
    }

    func testTheBarsRiseWithYourVoice() throws {
        let quiet = count(in: try render(.listening, levels: Coordinator.silentLevels, name: "listening-silent"),
                          x: rightEar, y: row, where: white)
        let loud = count(in: try render(.listening, levels: [Float](repeating: 0.9, count: 9), name: "listening-loud"),
                         x: rightEar, y: row, where: white)
        XCTAssertGreaterThan(quiet, 0, "silence still shows a row of dots")
        XCTAssertGreaterThan(loud, quiet * 3)
    }

    func testWorkingDimsTheMicAndSettlesTheBars() throws {
        let image = try render(.working, name: "working")
        XCTAssertEqual(count(in: image, x: leftEar, y: row, where: red), 0, "the mic is closed")
        XCTAssertGreaterThan(count(in: image, x: leftEar, y: row) { r, g, b in (70...160).contains(r) && abs(r - b) < 12 }, 20,
                             "the mic, dimmed")
        XCTAssertEqual(count(in: image, x: rightEar, y: row, where: white), 0, "no voice bars at full white")
        XCTAssertGreaterThan(count(in: image, x: rightEar, y: row) { r, g, b in (70...160).contains(r) && abs(r - g) < 12 }, 20,
                             "the low, dim wave")
    }

    func testPastedIsAGreenCheckWithItsWord() throws {
        let image = try render(.note(.pasted), name: "pasted")
        XCTAssertGreaterThan(count(in: image, x: leftEar, y: row) { r, g, b in g > 170 && r < 120 && b < 140 }, 30, "the green check")
        XCTAssertGreaterThan(count(in: image, x: rightEar, y: row, where: white), 30, "\"Pasted\"")
        XCTAssertEqual(count(in: image, x: overNotch, y: row) { r, g, b in max(r, g, b) > 40 }, 0)
    }

    func testAProblemsWordsShowInTheLipUnderTheNotch() throws {
        let message = "Allow microphone access in Dictation settings first."
        let image = try render(.problem(message), lip: Tuning().dictationLip, name: "problem")
        XCTAssertGreaterThan(count(in: image, x: 200...280, y: row) { r, g, b in r > 230 && (120...190).contains(g) && b < 80 }, 20,
                             "the orange mark in the left ear")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let lipRows = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 2 * 38, width: image.width, height: 2 * 50)))
        try VNImageRequestHandler(cgImage: lipRows).perform([request])
        let read = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        XCTAssertTrue(read.contains("microphone access"), "the words are under the notch, in the lip. Read: \(read)")
    }
}
