import XCTest
@testable import SpacesEngine

final class DesktopTransitionIPCTests: XCTestCase {
    func testCommandsRoundTripInArbitraryPipeChunks() throws {
        let commands: [DesktopTransitionCommand] = [.suspend(true), .start(.init(style: .magnetic)),
                                                    .update(.init(style: .stack, moveDock: false)), .suspend(false), .stop]
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

    func testAllPermissionAndLifecycleStatusesRoundTrip() throws {
        let statuses: [DesktopTransitionStatus] = [.off, .systemDefault, .needsAccessibility, .needsScreenRecording,
            .unsupported, .paused, .active(keyboard: true, trackpad: true), .active(keyboard: false, trackpad: true)]
        var decoder = DesktopTransitionWireDecoder<DesktopTransitionEvent>()
        for status in statuses {
            XCTAssertEqual(try decoder.append(DesktopTransitionWire.encode(DesktopTransitionEvent.status(status))), [.status(status)])
        }
        try decoder.finish()
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
