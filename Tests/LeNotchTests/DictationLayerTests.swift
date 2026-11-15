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

    func testHiddenCleanupIgnoresOldOptInsWithoutDeletingThePreference() throws {
        let name = "lenotch.test.cleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(DictationCleanup.isEnabled(in: defaults))
        defaults.set(true, forKey: "lenotch.dictation.cleanup")
        XCTAssertFalse(DictationCleanup.isEnabled(in: defaults), "Hidden cleanup must not run after an old opt-in")
        XCTAssertTrue(defaults.bool(forKey: "lenotch.dictation.cleanup"), "Keep the preference for a future model")
    }

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
        var seen: [Coordinator.Display] = []
        let before = c.onDisplayChange
        defer { c.onDisplayChange = before }
        c.onDisplayChange = { seen.append($0) }
        c.cancel()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertFalse(c.canCancel)
        XCTAssertNil(c.indicator)
        XCTAssertEqual(c.meter, .silent)
        XCTAssertEqual(c.liveText, "")
        XCTAssertEqual(seen.last, Coordinator.Display(indicator: nil, transcript: ""),
                       "the director hears that dictation left the notch")
    }

    func testYourWordsShowOnlyWhileListeningAndWorking() {
        let words = "move the launch to Thursday"
        XCTAssertEqual(Coordinator.display(indicator: .listening, liveText: words).transcript, words)
        XCTAssertEqual(Coordinator.display(indicator: .working, liveText: words).transcript, words,
                       "they stay while the final text is worked out")
        XCTAssertEqual(Coordinator.display(indicator: .note(.pasted), liveText: words).transcript, "",
                       "once pasted, the lip goes with them")
        XCTAssertEqual(Coordinator.display(indicator: .problem("No microphone"), liveText: words).transcript, "")
        XCTAssertEqual(Coordinator.display(indicator: nil, liveText: words).transcript, "")
    }

    // MARK: The voice: the music ears' four bars

    func testTheVoiceHasTheMusicBarsFourBarsAndTheirGeometry() {
        XCTAssertEqual(DictationMeter.bandCount, 4)
        XCTAssertEqual(DictationMeter.silent.bands.count, 4)
        XCTAssertEqual(DictationVoice.size, CGSize(width: 18, height: 13), "the music ears' bars' frame")
        let rects = BarsView.rects(in: DictationVoice.size, heights: DictationVoice.heights(DictationMeter.silent))
        XCTAssertEqual(rects.count, 4)
        XCTAssertEqual(rects.map(\.width), [3, 3, 3, 3])
        XCTAssertEqual(rects[1].minX - rects[0].maxX, 2, accuracy: 0.001)
        XCTAssertTrue(rects.allSatisfy { abs($0.maxY - 13) < 0.001 }, "from a shared baseline, like the music bars")
    }

    func testEachBarFollowsItsBandWhileYouSpeakAndRestsInSilence() {
        let floor = EqualizerBars.floor
        XCTAssertEqual(DictationVoice.heights(.silent), [floor, floor, floor, floor])
        let speaking = DictationVoice.heights(DictationMeter(level: 0.6, bands: [0.2, 1, 0.5, 0]))
        XCTAssertEqual(speaking.count, 4)
        XCTAssertEqual(speaking[1], 1, accuracy: 0.001, "the loudest band fills its bar")
        XCTAssertEqual(speaking[3], floor, accuracy: 0.001)
        XCTAssertLessThan(speaking[0], speaking[2], "each bar is its own band")
        let room = DictationVoice.heights(DictationMeter(level: 0.02, bands: [0.9, 0.9, 0.9, 0.9]))
        XCTAssertEqual(room, [floor, floor, floor, floor], "the room's hiss doesn't move them; your voice does")
        let broken = DictationVoice.heights(DictationMeter(level: .nan, bands: [.nan, .infinity, -1, 3]))
        XCTAssertTrue(broken.allSatisfy { $0 >= floor && $0 <= 1 })
        for t in stride(from: 0.0, to: 2.0, by: 0.13) {
            let wave = DictationVoice.wave(at: t)
            XCTAssertEqual(wave.count, 4)
            XCTAssertTrue(wave.allSatisfy { $0 >= floor && $0 <= DictationVoice.waveCrest + 0.0001 })
            XCTAssertGreaterThan(wave.max()! - wave.min()!, 0.1, "a wave, not a flat line")
        }
    }

    // MARK: The words under the notch

    func testTheLipIsOneLineOrTwoAndKeepsTheNewestWords() {
        let width = 324.0
        XCTAssertEqual(DictationText.lines("", width: width), 0)
        XCTAssertEqual(DictationText.lines("Let's move the launch", width: width), 1)
        XCTAssertEqual(DictationText.lines(String(repeating: "and then another thought ", count: 3), width: width), 2)
        XCTAssertEqual(DictationText.lines(String(repeating: "and then another thought ", count: 40), width: width), 2,
                       "never taller than two lines: a long run shows its last two")
        XCTAssertGreaterThan(DictationText.lineHeight, 14)
        XCTAssertLessThan(DictationText.lineHeight, 20)

        let long = (0..<120).map { "word\($0)" }.joined(separator: " ")
        let tail = DictationText.tail(long)
        XCTAssertTrue(tail.hasSuffix("word119"), "the newest words are kept")
        XCTAssertTrue(tail.hasPrefix("word"), "cut at a word, not inside one")
        XCTAssertLessThanOrEqual(tail.count, 280)
        XCTAssertEqual(DictationText.tail("short"), "short")
    }

    // MARK: The liquid's own shape

    func testDictationIsTheLiquidsEarsAndItsWordsGrowALip() {
        let tuning = Tuning()
        XCTAssertEqual(tuning.dictationExtent, tuning.earExtent, "the music ears' width")
        var targets = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: tuning)
        let ears = targets.resting(.dictation)
        XCTAssertEqual(ears.mainHalfWidth, 104 + tuning.dictationExtent)
        XCTAssertEqual(ears.mainHeight, 37.5, "the ears sit in the menu bar beside the notch")
        XCTAssertEqual(ears.cardHalfWidth, targets.resting(.compact).cardHalfWidth, "no card hung under the notch")

        let (first, stages) = targets.transition(from: .idle, to: .dictation)
        XCTAssertFalse(stages.isEmpty, "out of the empty notch it pours, like the song's ears")
        XCTAssertGreaterThan(first.mainHeight, ears.mainHeight, "the notch sags first")
        XCTAssertLessThan(first.mainHalfWidth, ears.mainHalfWidth, "then the ears run out")

        targets.context.dictationLipLines = 2
        let two = targets.resting(.dictation)
        XCTAssertEqual(two.mainHeight, 37.5 + tuning.dictationLip, "the same blob grows a lip for the words")
        XCTAssertGreaterThan(two.mainHalfWidth, ears.mainHalfWidth)
        targets.context.dictationLipLines = 1
        let one = targets.resting(.dictation)
        XCTAssertEqual(one.mainHeight, 37.5 + tuning.dictationLip - DictationText.lineHeight, accuracy: 0.001,
                       "one line, a shorter lip")
        targets.context.dictationLipLines = 7
        XCTAssertEqual(targets.resting(.dictation).mainHeight, two.mainHeight, "never more than two lines")
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
        XCTAssertNil(d.dictationLipText)
        XCTAssertEqual(d.dictationLipLines, 0)
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
        XCTAssertEqual(d.dictationLipText, "Allow microphone access in Dictation settings first.",
                       "the ears grow a lip for the words")
        XCTAssertEqual(d.mode, .dictation)

        d.dictationChanged(nil)
        XCTAssertEqual(d.mode, .idle)
        XCTAssertFalse(d.groups.dictation)
        XCTAssertNil(d.dictationLipText)
    }

    func testYourWordsFillTheLipAsTheyreHeardButNotWhilePresenting() {
        let (d, _) = director()
        d.dictationChanged(.listening)
        XCTAssertNil(d.dictationLipText, "nothing heard yet: just the ears")
        d.dictationChanged(.listening, transcript: "Let's move the launch")
        XCTAssertEqual(d.dictationLipText, "Let's move the launch")
        XCTAssertEqual(d.dictationLipLines, 1)
        d.dictationChanged(.listening, transcript: "Let's move the launch to Thursday so the design review has a full day and the notes")
        XCTAssertEqual(d.dictationLipLines, 2, "the lip grows a line as you keep talking")
        d.dictationChanged(.working, transcript: "Let's move the launch to Thursday")
        XCTAssertEqual(d.dictationLipText, "Let's move the launch to Thursday", "still there while it's worked out")
        d.dictationChanged(.note(.pasted))
        XCTAssertNil(d.dictationLipText, "pasted: the words went into the app")

        d.dictationChanged(.listening, transcript: "a private thought")
        d.setContext(DesktopContext(sharing: true))
        XCTAssertNil(d.dictationLipText, "presenting: your words stay off the notch")
        XCTAssertEqual(d.dictationLipLines, 0)
        XCTAssertEqual(d.mode, .dictation, "the ears still show you're being heard")
        d.dictationChanged(.problem("No microphone"))
        XCTAssertEqual(d.dictationLipText, "No microphone", "a problem isn't private")
        d.dictationChanged(nil)
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

    private let textWidth = 2 * (104 + Tuning().dictationExtent + Tuning().peekExtra) - 2 * DictationText.inset

    /// The dictation ears on the liquid, as on screen: a black island on a light wallpaper, the content clipped to it.
    private func render(_ indicator: Indicator, meter: DictationMeter = DictationMeter(level: 0.6, bands: [0.5, 0.9, 0.7, 0.35]),
                        lipText: String? = nil, name: String) throws -> CGImage {
        let tuning = Tuning()
        let lines = lipText.map { DictationText.lines($0, width: textWidth) } ?? 0
        var targets = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: tuning)
        targets.context.dictationLipLines = lines
        let shape = targets.resting(.dictation)
        let frame = FrameModel()
        frame.halfWidth = shape.mainHalfWidth
        frame.height = shape.mainHeight
        frame.radius = shape.mainRadius
        let island = UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: frame.radius, bottomTrailing: frame.radius),
                                            style: .continuous)
            .path(in: CGRect(x: frame.left, y: -1, width: frame.right - frame.left, height: frame.height + 1))
        let view = ZStack(alignment: .topLeading) {
            Color(white: 0.86)
            island.fill(Color.black)
            DictationEarsView(frame: frame, indicator: indicator, meter: meter, lipText: lipText, lipLines: lines,
                              textWidth: textWidth)
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

    private func read(_ image: CGImage, top: Int, height: Int) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let rows = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 2 * top, width: image.width, height: 2 * height)))
        try VNImageRequestHandler(cgImage: rows).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
    }

    // Points. The island spans 216…544 (the ears 60 pt past the 104 pt half notch); the notch is 276…484. The mic sits
    // where the music's cover does (227…249), the bars where the music's bars do (515…533).
    // Stop before the rounded ear's bottom corner, where the light wallpaper is visible.
    private let mic = 225...251, bars = 514...533, row = 2...35, overNotch = 290...470
    private let white: (Int, Int, Int) -> Bool = { r, g, b in r > 200 && g > 200 && b > 200 }
    private let red: (Int, Int, Int) -> Bool = { r, g, b in r > 200 && g < 120 && b < 120 }

    func testListeningIsARedMicWhereTheCoverSitsAndFourBarsWhereTheMusicBarsSit() throws {
        let image = try render(.listening, name: "listening")
        XCTAssertGreaterThan(count(in: image, x: mic, y: row, where: red), 30, "the red mic")
        XCTAssertGreaterThan(count(in: image, x: bars, y: row, where: white), 30, "the voice's bars")
        XCTAssertEqual(count(in: image, x: 488...510, y: row, where: white), 0, "nothing between the notch and the bars")
        XCTAssertEqual(count(in: image, x: overNotch, y: row) { r, g, b in max(r, g, b) > 40 }, 0,
                       "nothing is drawn over the notch")
        // Four separate bars: count the columns where one starts.
        var starts = 0, inside = false
        for x in bars {
            let lit = count(in: image, x: x...x, y: row, where: white) > 0
            if lit && !inside { starts += 1 }
            inside = lit
        }
        XCTAssertEqual(starts, 4, "four bars, like the music's")
    }

    func testTheBarsRiseWithYourVoice() throws {
        let quiet = count(in: try render(.listening, meter: .silent, name: "listening-silent"), x: bars, y: row, where: white)
        let loud = count(in: try render(.listening, meter: DictationMeter(level: 0.8, bands: [1, 1, 1, 1]), name: "listening-loud"),
                         x: bars, y: row, where: white)
        XCTAssertGreaterThan(quiet, 0, "silence rests them at the music bars' floor")
        XCTAssertGreaterThan(loud, quiet * 3)
    }

    func testWorkingDimsTheMicAndSettlesTheBars() throws {
        let image = try render(.working, name: "working")
        XCTAssertEqual(count(in: image, x: mic, y: row, where: red), 0, "the mic is closed")
        XCTAssertGreaterThan(count(in: image, x: mic, y: row) { r, g, b in (70...160).contains(r) && abs(r - b) < 12 }, 20,
                             "the mic, dimmed")
        XCTAssertEqual(count(in: image, x: bars, y: row, where: white), 0, "no voice bars at full white")
        XCTAssertGreaterThan(count(in: image, x: bars, y: row) { r, g, b in (70...160).contains(r) && abs(r - g) < 12 }, 10,
                             "the low, dim wave")
    }

    func testPastedIsAGreenCheckWithItsWord() throws {
        let image = try render(.note(.pasted), name: "pasted")
        XCTAssertGreaterThan(count(in: image, x: mic, y: row) { r, g, b in g > 170 && r < 120 && b < 140 }, 30, "the green check")
        XCTAssertGreaterThan(count(in: image, x: 488...540, y: row, where: white), 30, "\"Pasted\"")
        XCTAssertEqual(count(in: image, x: overNotch, y: row) { r, g, b in max(r, g, b) > 40 }, 0)
    }

    func testYourWordsShowUnderTheNotchAsTheyreHeard() throws {
        let image = try render(.listening, lipText: "Let's move the launch to Thursday", name: "words-one-line")
        XCTAssertTrue(try read(image, top: 37, height: 30).contains("move the launch to thursday"),
                      "the words are in the lip under the notch")
        XCTAssertGreaterThan(count(in: image, x: mic, y: row, where: red), 30, "still listening")
    }

    func testALongRunShowsItsNewestWordsOnTheLastLine() throws {
        let text = "Thanks for the notes on the draft. I went through all of them this morning and folded most of them in, and the two about the onboarding flow I want to talk through"
        let image = try render(.listening, lipText: text, name: "words-long")
        let lip = try read(image, top: 37, height: 46)
        XCTAssertTrue(lip.contains("onboarding flow"), "the newest words show. Read: \(lip)")
        XCTAssertTrue(lip.contains("talk through"), "including the last ones. Read: \(lip)")
        XCTAssertFalse(lip.contains("thanks for the notes"), "the first words have scrolled away. Read: \(lip)")
    }

    func testAProblemsWordsShowInTheLipUnderTheNotch() throws {
        let message = "Allow microphone access in Dictation settings first."
        let image = try render(.problem(message), lipText: message, name: "problem")
        XCTAssertGreaterThan(count(in: image, x: 205...260, y: row) { r, g, b in r > 230 && (120...190).contains(g) && b < 80 }, 20,
                             "the orange mark in the left ear")
        let lip = try read(image, top: 37, height: 46)
        XCTAssertTrue(lip.contains("microphone access"), "the words are under the notch, in the lip. Read: \(lip)")
    }
}
