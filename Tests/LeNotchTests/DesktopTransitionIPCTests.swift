import XCTest
@testable import SpacesEngine

final class DesktopTransitionIPCTests: XCTestCase {
    func testCommandsRoundTripInArbitraryPipeChunks() throws {
        let commands: [DesktopTransitionCommand] = [.suspend(true), .start(.init(style: .instant)),
                                                    .update(.init(style: .liveSlide, sensitivity: 1.5, slideDuration: 0.475)),
                                                    .suspend(false), .stop]
        var bytes = Data()
        for command in commands { bytes.append(try DesktopTransitionWire.encode(command)) }
        for chunkSize in [1, 3, 17, bytes.count] {
            var decoder = DesktopTransitionWireDecoder<DesktopTransitionCommand>()
            var received: [DesktopTransitionCommand] = []
            for offset in stride(from: 0, to: bytes.count, by: chunkSize) {
                received += try decoder.append(bytes.subdata(in: offset..<min(bytes.count, offset + chunkSize)))
            }
            try decoder.finish()
            XCTAssertEqual(received, commands)
        }
    }

    func testStyleWireValuesStayStableAndLegacyOrUnknownStylesDecodeAsSystem() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let styles: [(DesktopTransitionStyle, String)] = [(.system, "default"), (.instant, "instant"),
                                                         (.liveSlide, "liveSlide")]
        for (style, wireValue) in styles {
            let data = Data("\"\(wireValue)\"".utf8)
            XCTAssertEqual(try encoder.encode(style), data)
            XCTAssertEqual(try decoder.decode(DesktopTransitionStyle.self, from: data), style)
        }
        for wireValue in ["lightweight", "magnetic", "hexagon", "stack", "curtain", "future-style"] {
            let data = Data("\"\(wireValue)\"".utf8)
            XCTAssertEqual(try decoder.decode(DesktopTransitionStyle.self, from: data), .system, wireValue)
        }
    }

    func testLegacyOptionsDecodeWithDefaultSlideDurationAndDropObsoleteFields() throws {
        let legacy = Data(#"{"style":"hexagon","sensitivity":1.5,"speed":1.8,"roundedCorners":false,"moveDock":true}"#.utf8)
        let options = try JSONDecoder().decode(DesktopTransitionOptions.self, from: legacy)
        XCTAssertEqual(options, DesktopTransitionOptions(style: .system, sensitivity: 1.5))
        XCTAssertEqual(options.slideDuration, 0.35)

        let encoded = try JSONEncoder().encode(options)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["style", "sensitivity", "slideDuration"])
        XCTAssertEqual(fields["style"] as? String, "default")
        XCTAssertEqual(fields["sensitivity"] as? Double, 1.5)
        XCTAssertEqual(fields["slideDuration"] as? Double, 0.35)
    }

    func testOlderCommandsWithoutSlideDurationStillDecode() throws {
        let olderStart = #"{"start":{"_0":{"style":"instant","sensitivity":1.2}}}"# + "\n"
        var decoder = DesktopTransitionWireDecoder<DesktopTransitionCommand>()
        let commands = try decoder.append(Data(olderStart.utf8))
        try decoder.finish()
        XCTAssertEqual(commands, [.start(.init(style: .instant, sensitivity: 1.2, slideDuration: 0.35))])
    }

    func testSensitivityIsValidatedWhenConstructedAndDecoded() throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        let cases: [(input: Double, json: String, expected: Double)] = [
            (-5, "-5", 0.5), (0.5, "0.5", 0.5), (1.25, "1.25", 1.25), (2, "2", 2), (5, "5", 2),
            (.infinity, #""+inf""#, 1), (-.infinity, #""-inf""#, 1), (.nan, #""nan""#, 1),
        ]
        XCTAssertEqual(DesktopTransitionOptions(), DesktopTransitionOptions(style: .system, sensitivity: 1))
        for (input, json, expected) in cases {
            XCTAssertEqual(DesktopTransitionOptions(sensitivity: input).sensitivity, expected, json)
            let data = Data(#"{"style":"instant","sensitivity":\#(json)}"#.utf8)
            let options = try decoder.decode(DesktopTransitionOptions.self, from: data)
            XCTAssertEqual(options.style, .instant, json)
            XCTAssertEqual(options.sensitivity, expected, json)
        }
    }

    func testAccessibilityAndLifecycleStatusesRoundTrip() throws {
        let statuses: [DesktopTransitionStatus] = [.off, .systemDefault, .needsAccessibility,
            .unsupported, .paused, .active(keyboard: true, trackpad: true), .active(keyboard: false, trackpad: true)]
        var decoder = DesktopTransitionWireDecoder<DesktopTransitionEvent>()
        for status in statuses {
            XCTAssertEqual(try decoder.append(DesktopTransitionWire.encode(DesktopTransitionEvent.status(status))), [.status(status)])
        }
        try decoder.finish()
    }

    func testSlideDurationIsValidatedWhenConstructedAndDecoded() throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        let cases: [(input: Double, json: String, expected: Double)] = [
            (-1, "-1", 0.15), (0.15, "0.15", 0.15), (0.4, "0.4", 0.4), (0.75, "0.75", 0.75), (2, "2", 0.75),
            (.infinity, #""+inf""#, 0.35), (-.infinity, #""-inf""#, 0.35), (.nan, #""nan""#, 0.35),
        ]
        for (input, json, expected) in cases {
            XCTAssertEqual(DesktopTransitionOptions(slideDuration: input).slideDuration, expected, json)
            let data = Data(#"{"style":"liveSlide","sensitivity":1.5,"slideDuration":\#(json)}"#.utf8)
            let options = try decoder.decode(DesktopTransitionOptions.self, from: data)
            XCTAssertEqual(options.style, .liveSlide, json)
            XCTAssertEqual(options.sensitivity, 1.5, json)
            XCTAssertEqual(options.slideDuration, expected, json)
        }
    }

    func testObsoleteScreenRecordingStatusIsNotSupported() {
        let data = Data(#"{"status":{"_0":{"needsScreenRecording":{}}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DesktopTransitionEvent.self, from: data))
    }

    func testTransitionActivityRoundTrips() throws {
        var decoder = DesktopTransitionWireDecoder<DesktopTransitionEvent>()
        for active in [true, false] {
            XCTAssertEqual(try decoder.append(DesktopTransitionWire.encode(DesktopTransitionEvent.transition(active))), [.transition(active)])
        }
        try decoder.finish()
    }

    func testMalformedTruncatedAndOversizedMessagesFailClosed() throws {
        var malformed = DesktopTransitionWireDecoder<DesktopTransitionCommand>()
        XCTAssertThrowsError(try malformed.append(Data("not a command\n".utf8)))
        var truncated = DesktopTransitionWireDecoder<DesktopTransitionCommand>()
        XCTAssertEqual(try truncated.append(Data("{\"stop\":".utf8)), [])
        XCTAssertThrowsError(try truncated.finish())
        var oversized = DesktopTransitionWireDecoder<DesktopTransitionCommand>()
        XCTAssertThrowsError(try oversized.append(Data(repeating: 65, count: 4097)))
    }

    func testManyShortRecordsAreNotRejectedAsOneOversizedMessage() throws {
        var decoder = DesktopTransitionWireDecoder<DesktopTransitionCommand>()
        let frame = try DesktopTransitionWire.encode(DesktopTransitionCommand.stop)
        var bytes = Data()
        for _ in 0..<1000 { bytes.append(frame) }
        XCTAssertEqual(try decoder.append(bytes).count, 1000)
        try decoder.finish()
    }
}
