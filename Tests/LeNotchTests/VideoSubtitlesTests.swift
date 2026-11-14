import Foundation
import XCTest
@testable import Lenotch

final class SubtitleParserTests: XCTestCase {
    func testSRTNormalizesBOMAndLineEndingsAndSortsCues() {
        let input = "\u{FEFF}2\r\n00:00:05,250 --> 00:00:07,000\r\nLater\r\n \t\r\n1\r\n00:00:01,000 --> 00:00:03,500\r\nFirst line\r\nSecond line"
        XCTAssertEqual(SubtitleParser.parse(input), [
            SubtitleCue(start: 1, end: 3.5, text: "First line\nSecond line"),
            SubtitleCue(start: 5.25, end: 7, text: "Later"),
        ])
    }

    func testWebVTTHasOptionalIdentifiersCueSettingsAndHourTimestamps() {
        let input = """
        WEBVTT - English
        Kind: captions
        Language: en

        opening
        00:01.250 --> 00:03.500 align:start position:10% line:90%
        Welcome.

        01:02:03.004 --> 01:02:05.006 size:80%
        An hour later.
        """
        XCTAssertEqual(SubtitleParser.parse(input), [
            SubtitleCue(start: 1.25, end: 3.5, text: "Welcome."),
            SubtitleCue(start: 3_723.004, end: 3_725.006, text: "An hour later."),
        ])
    }

    func testWebVTTNotesStylesAndRegionsAreNotCaptions() {
        let input = """
        WEBVTT

        NOTE This is not spoken
        00:00.000 --> 00:20.000
        Ignore this note.

        STYLE
        00:00.000 --> 00:20.000
        ::cue { color: lime; }

        REGION
        id:bottom

        NOTE
        Another comment.

        dialogue
        00:00.000 --> 00:02.000
        Actual speech.
        """
        XCTAssertEqual(SubtitleParser.parse(input), [
            SubtitleCue(start: 0, end: 2, text: "Actual speech."),
        ])
    }

    func testMalformedNegativeNonfiniteAndNonpositiveIntervalsAreSkipped() {
        let invalidTimings = [
            "-00:00:01,000 --> 00:00:02,000",
            "00:00:02,000 --> 00:00:02,000",
            "00:00:03,000 --> 00:00:02,000",
            "00:60:01,000 --> 01:01:02,000",
            "00:00:60,000 --> 00:01:02,000",
            "00:00:01,12 --> 00:00:02,000",
            "00:00:01, --> 00:00:02,000",
            "00:00:01..000 --> 00:00:02,000",
            "00:00:01.000.000 --> 00:00:02,000",
            "nan --> inf",
            "00:01.000 --> 00:02.000 --> 00:03.000",
            "\(String(repeating: "9", count: 400)):00:00.000 --> 00:02.000",
        ]
        let input = invalidTimings.enumerated().map { index, timing in
            "\(index + 1)\n\(timing)\nNot a caption."
        }.joined(separator: "\n\n")
        XCTAssertEqual(SubtitleParser.parse(input), [])
    }

    func testMarkupIsPlainTextWithoutScriptStyleOrCommentContents() {
        let input = """
        00:01.000 --> 00:03.000
        <v Jane><c.green><b>Hello</b> <i>there</i>.</c></v><br/>Next line.
        <00:01.500><u>Timed word.</u>
        <SCRIPT>alert('not speech');</SCRIPT><style>body { display: none; }</style>
        <!-- this is not speech -->
        """
        XCTAssertEqual(SubtitleParser.parse(input).first?.text, "Hello there.\nNext line.\nTimed word.")
    }

    func testCommonAndNumericEntitiesDecodeOnceAndEncodedTextStaysReadable() {
        let input = """
        00:01.000 --> 00:03.000
        &lt;literal&gt; &amp; &quot;quoted&quot; &apos;yes&apos; &#39;also&#39;
        non&nbsp;breaking &#x1F44B; &#128075; &amp;lt;b&amp;gt; &#x110000;
        """
        XCTAssertEqual(
            SubtitleParser.parse(input).first?.text,
            "<literal> & \"quoted\" 'yes' 'also'\nnon breaking 👋 👋 &lt;b&gt; &#x110000;"
        )
    }

    func testEmptyAndUntimedInputProduceNoCues() {
        for input in ["", "WEBVTT\n\n", "Just plain text.", "00:01.000 --> 00:02.000\n<i></i>"] {
            XCTAssertTrue(SubtitleParser.parse(input).isEmpty, input)
        }
    }

    func testSimultaneousCuesKeepSourceOrder() {
        let input = """
        00:01.000 --> 00:04.000
        First speaker.

        00:01.000 --> 00:02.000
        Second speaker.
        """
        XCTAssertEqual(SubtitleParser.parse(input).map(\.text), ["First speaker.", "Second speaker."])
    }
}

@MainActor
final class VideoSubtitlesTests: XCTestCase {
    private let sample = "1\n00:00:01,000 --> 00:00:03,000\nHello.\n\n2\n00:00:04,000 --> 00:00:05,000\nGoodbye.\n"

    private func temporaryFile(_ data: Data, suffix: String = "srt") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lenotch-subtitles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("captions.\(suffix)")
        try data.write(to: file)
        return file
    }

    private func loaded(_ text: String? = nil) throws -> VideoSubtitles {
        let model = VideoSubtitles()
        model.load(from: try temporaryFile(Data((text ?? sample).utf8)))
        XCTAssertNil(model.error)
        return model
    }

    func testModelStartsEmptyAndLoadExposesOnlyTheFileName() throws {
        let model = VideoSubtitles()
        XCTAssertNil(model.name)
        XCTAssertTrue(model.cues.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertNil(model.text(at: 1))

        let file = try temporaryFile(Data(sample.utf8), suffix: "SRT")
        model.load(from: file)
        XCTAssertEqual(model.name, "captions.SRT")
        XCTAssertEqual(model.cues.count, 2)
        XCTAssertNil(model.error)
    }

    func testCaptionBoundariesAreStartInclusiveAndEndExclusiveAndSupportSeeks() throws {
        let model = try loaded()
        XCTAssertNil(model.text(at: 0.999))
        XCTAssertEqual(model.text(at: 1), "Hello.")
        XCTAssertEqual(model.text(at: 2.999), "Hello.")
        XCTAssertNil(model.text(at: 3))
        XCTAssertNil(model.text(at: 3.5))
        XCTAssertEqual(model.text(at: 4), "Goodbye.")
        XCTAssertNil(model.text(at: 5))
        XCTAssertEqual(model.text(at: 1.5), "Hello.")
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertNil(model.text(at: invalid))
        }
    }

    func testOverlappingCaptionsCombineUniqueActiveLines() throws {
        let model = try loaded("""
        00:01.000 --> 00:10.000
        Long caption.
        Shared line.

        00:02.000 --> 00:04.000
        Shared line.
        Other speaker.

        00:03.000 --> 00:03.500
        Brief caption.
        """)
        XCTAssertEqual(model.text(at: 2.5), "Long caption.\nShared line.\nOther speaker.")
        XCTAssertEqual(model.text(at: 3), "Long caption.\nShared line.\nOther speaker.\nBrief caption.")
        XCTAssertEqual(model.text(at: 4), "Long caption.\nShared line.")
        XCTAssertEqual(model.text(at: 9.999), "Long caption.\nShared line.")
        XCTAssertNil(model.text(at: 10))
    }

    func testLongLivedCueIsNotLostWhenLaterCuesHaveEnded() throws {
        var input = "00:00.000 --> 00:59.000\nLong-lived caption.\n\n"
        for second in 1..<50 {
            input += String(format: "00:%02d.000 --> 00:%02d.500\nCue %d\n\n", second, second, second)
        }
        let model = try loaded(input)
        XCTAssertEqual(model.text(at: 48.25), "Long-lived caption.\nCue 48")
        XCTAssertEqual(model.text(at: 49.75), "Long-lived caption.")
        XCTAssertEqual(model.text(at: 1.25), "Long-lived caption.\nCue 1")
        XCTAssertNil(model.text(at: 59))
    }

    func testFailedImportRetainsCurrentCuesAndNameThenSuccessfulImportClearsError() throws {
        let model = try loaded()
        let original = model.cues
        let originalName = model.name
        model.load(from: try temporaryFile(Data("Not a subtitle file.".utf8)))
        XCTAssertEqual(model.cues, original)
        XCTAssertEqual(model.name, originalName)
        XCTAssertEqual(model.text(at: 1), "Hello.")
        XCTAssertTrue(model.error?.contains("No timed captions") == true)

        model.load(from: try temporaryFile(Data("WEBVTT\n\n00:00.000 --> 00:01.000\nReplacement.\n".utf8), suffix: "vtt"))
        XCTAssertNil(model.error)
        XCTAssertEqual(model.name, "captions.vtt")
        XCTAssertEqual(model.text(at: 0), "Replacement.")
        XCTAssertNil(model.text(at: 1))
    }

    func testOversizedFileIsRejectedWithoutLosingCaptions() throws {
        let model = try loaded()
        let original = model.cues
        model.load(from: try temporaryFile(Data(repeating: 0x61, count: 2_000_001)))
        XCTAssertEqual(model.cues, original)
        XCTAssertTrue(model.error?.contains("2 MB") == true)
    }

    func testFileAtSizeLimitIsAccepted() throws {
        var data = Data(sample.utf8)
        data.append(contentsOf: "\n".utf8)
        data.append(Data(repeating: 0x20, count: 2_000_000 - data.count))
        let model = VideoSubtitles()
        model.load(from: try temporaryFile(data))
        XCTAssertNil(model.error)
        XCTAssertEqual(model.text(at: 1), "Hello.")
    }

    func testUnsupportedFileAndRemoteURLAreRejected() throws {
        let model = try loaded()
        let original = model.cues
        model.load(from: try temporaryFile(Data(sample.utf8), suffix: "txt"))
        XCTAssertEqual(model.cues, original)
        XCTAssertTrue(model.error?.contains(".srt or .vtt") == true)
        model.load(from: try XCTUnwrap(URL(string: "https://example.invalid/captions.srt")))
        XCTAssertEqual(model.cues, original)
        XCTAssertTrue(model.error?.contains("local") == true)
    }

    func testInvalidEncodingAndMissingFilesHaveActionableErrorsWithoutPaths() throws {
        let model = try loaded()
        let original = model.cues
        model.load(from: try temporaryFile(Data([0xC3, 0x28])))
        XCTAssertEqual(model.cues, original)
        XCTAssertTrue(model.error?.contains("UTF-8 or UTF-16") == true)

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-subtitles-\(UUID().uuidString).srt")
        model.load(from: missing)
        XCTAssertEqual(model.cues, original)
        XCTAssertTrue(model.error?.contains("Check its permissions") == true)
        XCTAssertFalse(model.error?.contains(missing.path) == true)
        XCTAssertFalse(model.error?.contains(missing.lastPathComponent) == true)
    }

    func testUTF8BOMAndUTF16ByteOrdersImportNonASCIIText() throws {
        let text = "WEBVTT\n\n00:00.000 --> 00:01.500\nBonjour, 世界.\n"
        let encodings: [(String.Encoding, [UInt8])] = [
            (.utf8, [0xEF, 0xBB, 0xBF]),
            (.utf16LittleEndian, [0xFF, 0xFE]),
            (.utf16BigEndian, [0xFE, 0xFF]),
        ]
        for (encoding, bom) in encodings {
            var data = Data(bom)
            data.append(try XCTUnwrap(text.data(using: encoding)))
            let model = VideoSubtitles()
            model.load(from: try temporaryFile(data, suffix: "vtt"))
            XCTAssertNil(model.error, "\(encoding)")
            XCTAssertEqual(model.text(at: 0), "Bonjour, 世界.")
        }
    }

    func testClearRemovesCaptionsNameAndImportError() throws {
        let model = try loaded()
        model.load(from: try temporaryFile(Data("Invalid".utf8)))
        XCTAssertNotNil(model.error)
        model.clear()
        XCTAssertNil(model.name)
        XCTAssertTrue(model.cues.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertNil(model.text(at: 1))
    }
}
