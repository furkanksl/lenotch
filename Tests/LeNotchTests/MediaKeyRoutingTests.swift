import AppKit
import Synchronization
import XCTest
@testable import Lenotch

/// Routes in-memory events only: no event tap is started and nothing is posted to macOS.
final class MediaKeyRoutingTests: XCTestCase {
    func testPlaybackAndUnknownMediaKeysPassThroughUnchanged() throws {
        let callbacks = CallbackCounts()
        let tap = HardwareKeyEventTap(onLevel: { _ in callbacks.recordLevel() }, onAsk: { callbacks.recordAsk() })
        // NX_KEYTYPE_PLAY, NEXT, PREVIOUS, FAST, REWIND, EJECT, and an unknown key.
        for key in [16, 17, 18, 19, 20, 14, 255] {
            for state in [0x0A, 0x0B] {
                for repeating in [false, true] {
                    let event = try mediaEvent(key: key, state: state, repeating: repeating)
                    try assertPassesThrough(tap, type: systemDefined, event: event)
                }
            }
        }
        XCTAssertEqual(callbacks.snapshot, .init())
    }

    @MainActor
    func testPlaybackRoutingWorksOffMainActor() async throws {
        let callbacks = CallbackCounts()
        let tap = HardwareKeyEventTap(onLevel: { _ in callbacks.recordLevel() }, onAsk: { callbacks.recordAsk() })
        try await Task.detached {
            XCTAssertFalse(Thread.isMainThread, "The event callback must be safe away from the UI thread")
            let synthetic = try XCTUnwrap(NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                                           data1: (16 << 16) | (0x0A << 8), data2: -1))
            let event = try XCTUnwrap(synthetic.cgEvent)
            let before = try XCTUnwrap(event.data) as Data
            let routed = try XCTUnwrap(tap.route(CGEventType(rawValue: 14)!, event: event)).takeUnretainedValue()
            XCTAssertTrue(routed === event)
            XCTAssertEqual(try XCTUnwrap(routed.data) as Data, before)
        }.value
        XCTAssertEqual(callbacks.snapshot, .init())
    }

    func testOtherSystemDefinedSubtypesPassThroughUnchanged() throws {
        let callbacks = CallbackCounts()
        let tap = HardwareKeyEventTap(onLevel: { _ in callbacks.recordLevel() }, onAsk: { callbacks.recordAsk() })
        for subtype in [Int16(0), 7, 9] {
            for state in [0x0A, 0x0B] {
                let event = try mediaEvent(key: 16, state: state, subtype: subtype)
                try assertPassesThrough(tap, type: systemDefined, event: event)
            }
        }
        XCTAssertEqual(callbacks.snapshot, .init())
    }

    func testOrdinaryKeysIncludingF8PassThroughUnchanged() throws {
        let callbacks = CallbackCounts()
        let tap = HardwareKeyEventTap(onLevel: { _ in callbacks.recordLevel() }, onAsk: { callbacks.recordAsk() })
        for key in [CGKeyCode(0), 100] { // A and the ordinary F8 key, not an NX playback event.
            for down in [true, false] {
                let event = try keyboardEvent(key: key, down: down)
                try assertPassesThrough(tap, type: down ? .keyDown : .keyUp, event: event)
            }
        }
        XCTAssertEqual(callbacks.snapshot, .init())
    }

    func testSpaceWithoutTheExactAskChordPassesThroughUnchanged() throws {
        let callbacks = CallbackCounts()
        let tap = HardwareKeyEventTap(onLevel: { _ in callbacks.recordLevel() }, onAsk: { callbacks.recordAsk() })
        let modifiers: [CGEventFlags] = [
            [], .maskCommand, .maskControl, .maskShift,
            [.maskAlternate, .maskCommand], [.maskAlternate, .maskControl], [.maskAlternate, .maskShift],
        ]
        for flags in modifiers {
            for down in [true, false] {
                let event = try keyboardEvent(key: 49, down: down, flags: flags)
                try assertPassesThrough(tap, type: down ? .keyDown : .keyUp, event: event)
            }
        }
        XCTAssertEqual(callbacks.snapshot, .init())
    }

    func testAskChordConsumesItsReleaseEvenAfterOptionIsReleased() throws {
        let callbacks = CallbackCounts()
        let tap = HardwareKeyEventTap(onLevel: { _ in callbacks.recordLevel() }, onAsk: { callbacks.recordAsk() })
        let down = try keyboardEvent(key: 49, down: true, flags: .maskAlternate)
        XCTAssertNil(tap.route(.keyDown, event: down))
        XCTAssertEqual(callbacks.snapshot, .init(asks: 1))

        for _ in 0..<3 {
            let repeated = try keyboardEvent(key: 49, down: true, flags: .maskAlternate, repeating: true)
            XCTAssertNil(tap.route(.keyDown, event: repeated))
        }
        XCTAssertEqual(callbacks.snapshot, .init(asks: 1), "Holding the shortcut must not open Ask repeatedly")

        let up = try keyboardEvent(key: 49, down: false)
        XCTAssertNil(tap.route(.keyUp, event: up))
        let unrelatedUp = try keyboardEvent(key: 49, down: false)
        try assertPassesThrough(tap, type: .keyUp, event: unrelatedUp)
        XCTAssertEqual(callbacks.snapshot, .init(asks: 1))

        let nextDown = try keyboardEvent(key: 49, down: true, flags: .maskAlternate)
        XCTAssertNil(tap.route(.keyDown, event: nextDown))
        XCTAssertEqual(callbacks.snapshot, .init(asks: 2), "A new press must still invoke Ask")
    }

    func testUnclaimedSpaceReleaseIsNotConsumedWhenOptionWasPressedLater() throws {
        let callbacks = CallbackCounts()
        let tap = HardwareKeyEventTap(onLevel: { _ in callbacks.recordLevel() }, onAsk: { callbacks.recordAsk() })
        let down = try keyboardEvent(key: 49, down: true)
        try assertPassesThrough(tap, type: .keyDown, event: down)
        let up = try keyboardEvent(key: 49, down: false, flags: .maskAlternate)
        try assertPassesThrough(tap, type: .keyUp, event: up)
        XCTAssertEqual(callbacks.snapshot, .init())
    }

    func testAskChordPassesThroughWhenNoAskHandlerIsInstalled() throws {
        let callbacks = CallbackCounts()
        let tap = HardwareKeyEventTap(onLevel: { _ in callbacks.recordLevel() })
        for repeating in [false, true] {
            let down = try keyboardEvent(key: 49, down: true, flags: .maskAlternate, repeating: repeating)
            try assertPassesThrough(tap, type: .keyDown, event: down)
        }
        let up = try keyboardEvent(key: 49, down: false, flags: .maskAlternate)
        try assertPassesThrough(tap, type: .keyUp, event: up)
        XCTAssertEqual(callbacks.snapshot, .init())
    }

    func testTapDisabledNotificationsPassThroughWithoutAnActiveTap() throws {
        let callbacks = CallbackCounts()
        let tap = HardwareKeyEventTap(onLevel: { _ in callbacks.recordLevel() }, onAsk: { callbacks.recordAsk() })
        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let event = try keyboardEvent(key: 100, down: true)
            try assertPassesThrough(tap, type: type, event: event)
        }
        XCTAssertEqual(callbacks.snapshot, .init())
    }

    private var systemDefined: CGEventType { CGEventType(rawValue: 14)! }

    private func mediaEvent(key: Int, state: Int, subtype: Int16 = 8, repeating: Bool = false) throws -> CGEvent {
        let data1 = (key << 16) | (state << 8) | (repeating ? 1 : 0)
        let event = try XCTUnwrap(NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: 0, context: nil, subtype: subtype,
                                                   data1: data1, data2: -1))
        return try XCTUnwrap(event.cgEvent)
    }

    private func keyboardEvent(key: CGKeyCode, down: Bool, flags: CGEventFlags = [], repeating: Bool = false) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down))
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
        return event
    }

    private func assertPassesThrough(_ tap: HardwareKeyEventTap, type: CGEventType, event: CGEvent,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try XCTUnwrap(event.data, file: file, line: line) as Data
        let routed = try XCTUnwrap(tap.route(type, event: event), file: file, line: line).takeUnretainedValue()
        XCTAssertTrue(routed === event, "The system must receive the original event, not a replacement", file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(routed.data, file: file, line: line) as Data, before,
                       "Passing a key through must not alter its serialized payload", file: file, line: line)
    }
}

private final class CallbackCounts: Sendable {
    struct Snapshot: Equatable, Sendable {
        var levels = 0
        var asks = 0
    }

    private let counts = Mutex(Snapshot())

    var snapshot: Snapshot { counts.withLock { $0 } }
    func recordLevel() { counts.withLock { $0.levels += 1 } }
    func recordAsk() { counts.withLock { $0.asks += 1 } }
}
