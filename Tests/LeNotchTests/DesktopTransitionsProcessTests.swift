import Darwin
import Foundation
import Synchronization
import XCTest
@testable import Lenotch
import SpacesEngine

@MainActor
final class DesktopTransitionsProcessTests: XCTestCase {
    private final class Transport: DesktopTransitionsProcessTransport {
        var onOutput: ((Data) -> Void)?
        var onExit: (() -> Void)?
        var onFailure: (() -> Void)?
        var launchError: Error?
        var launches = 0
        var writes: [Data] = []
        var shutdowns: [Data?] = []

        func launch() throws {
            launches += 1
            if let launchError { throw launchError }
        }
        func send(_ data: Data) { writes.append(data) }
        func shutdown(finalCommand: Data?) { shutdowns.append(finalCommand) }
        func emit(_ status: DesktopTransitionStatus) throws {
            onOutput?(try DesktopTransitionWire.encode(DesktopTransitionEvent.status(status)))
        }
        var commands: [DesktopTransitionCommand] {
            get throws {
                try writes.map { data in
                    XCTAssertEqual(data.last, 10, "Commands must be newline terminated for an incremental reader")
                    return try JSONDecoder().decode(DesktopTransitionCommand.self, from: data)
                }
            }
        }
    }

    func testTransitionActivityIsForwardedAndAlwaysEndsWhenTheHelperGoes() throws {
        let child = Transport()
        let driver = DesktopTransitionsProcess { child }
        var activity: [Bool] = []
        driver.onTransition = { activity.append($0) }
        driver.start(.init(style: .instant))
        child.onOutput?(try DesktopTransitionWire.encode(DesktopTransitionEvent.transition(true)))
        child.onOutput?(try DesktopTransitionWire.encode(DesktopTransitionEvent.transition(true)))
        XCTAssertEqual(activity, [true], "Repeats are not forwarded")
        // A helper that dies mid-transition must not leave LeNotch's window reads paused.
        child.onExit?()
        XCTAssertEqual(activity, [true, false])
        driver.stop()
        XCTAssertEqual(activity, [true, false])
    }

    func testConstructionAndInactiveUpdatesNeverLaunchAChild() {
        var constructions = 0
        let driver = DesktopTransitionsProcess {
            constructions += 1
            return Transport()
        }
        driver.update(.init(style: .instant))
        driver.setSuspended(true)
        driver.stop()
        XCTAssertEqual(constructions, 0)
    }

    func testStartLaunchesOnceWithCurrentOptionsAndSuspensionBeforeInputHooks() throws {
        let child = Transport()
        var constructions = 0
        let driver = DesktopTransitionsProcess { constructions += 1; return child }
        let options = DesktopTransitionOptions(style: .instant, sensitivity: 1.3)
        driver.setSuspended(true)
        driver.start(options)
        driver.start(options)
        XCTAssertEqual(constructions, 1)
        XCTAssertEqual(child.launches, 1)
        XCTAssertEqual(try child.commands, [.suspend(true), .start(options)])
        driver.stop()
    }

    func testUpdatesAndSuspensionStayOnTheExistingChild() throws {
        let child = Transport()
        let driver = DesktopTransitionsProcess { child }
        let initial = DesktopTransitionOptions(style: .instant)
        let changed = DesktopTransitionOptions(style: .instant, sensitivity: 1.2)
        driver.start(initial)
        driver.update(changed)
        driver.update(changed)
        driver.setSuspended(true)
        driver.setSuspended(true)
        driver.setSuspended(false)
        XCTAssertEqual(child.launches, 1)
        XCTAssertEqual(try child.commands, [.suspend(false), .start(initial), .update(changed), .suspend(true), .suspend(false)])
        driver.stop()
    }

    func testStopRequestsGracefulExitOnceAndDisconnectsAllCallbacks() throws {
        let child = Transport()
        let driver = DesktopTransitionsProcess { child }
        var statuses: [DesktopTransitionStatus] = []
        driver.onStatus = { statuses.append($0) }
        driver.start(.init(style: .instant))
        try child.emit(.active(keyboard: true, trackpad: true))
        driver.stop()
        driver.stop()
        XCTAssertEqual(child.shutdowns.count, 1)
        let message = try XCTUnwrap(child.shutdowns.first.flatMap { $0 })
        XCTAssertEqual(try JSONDecoder().decode(DesktopTransitionCommand.self, from: message), .stop)
        XCTAssertNil(child.onOutput)
        XCTAssertNil(child.onExit)
        XCTAssertNil(child.onFailure)
        XCTAssertEqual(statuses, [.active(keyboard: true, trackpad: true), .off])
    }

    func testLateOutputExitAndFailureCannotChangeANewerGeneration() throws {
        let first = Transport(), second = Transport()
        var count = 0
        let driver = DesktopTransitionsProcess { count += 1; return count == 1 ? first : second }
        var statuses: [DesktopTransitionStatus] = []
        driver.onStatus = { statuses.append($0) }
        driver.start(.init(style: .instant))
        let oldOutput = try XCTUnwrap(first.onOutput)
        let oldExit = try XCTUnwrap(first.onExit)
        let oldFailure = try XCTUnwrap(first.onFailure)
        driver.stop()
        driver.start(.init(style: .instant, sensitivity: 1.5))
        try second.emit(.needsAccessibility)
        oldOutput(try DesktopTransitionWire.encode(DesktopTransitionEvent.status(.active(keyboard: true, trackpad: true))))
        oldExit()
        oldFailure()
        XCTAssertEqual(statuses, [.needsAccessibility])
        XCTAssertTrue(second.shutdowns.isEmpty)
        XCTAssertEqual(count, 2)
        driver.stop()
    }

    func testLaunchFailureCleansUpAndRequiresAnExplicitRestart() throws {
        let failed = Transport(), replacement = Transport()
        failed.launchError = DesktopTransitionsProcessError.noExecutable
        var count = 0
        let driver = DesktopTransitionsProcess { count += 1; return count == 1 ? failed : replacement }
        var statuses: [DesktopTransitionStatus] = []
        driver.onStatus = { statuses.append($0) }
        driver.start(.init(style: .instant))
        driver.start(.init(style: .instant))
        driver.update(.init(style: .instant, sensitivity: 1.5))
        XCTAssertEqual(count, 1, "A failing helper must not enter an automatic relaunch loop")
        XCTAssertEqual(failed.shutdowns.count, 1)
        XCTAssertTrue(failed.writes.isEmpty)
        XCTAssertEqual(statuses, [.unsupported])
        driver.stop()
        driver.start(.init(style: .instant, sensitivity: 1.5))
        XCTAssertEqual(count, 2)
        XCTAssertEqual(replacement.launches, 1)
        driver.stop()
    }

    func testTransportConstructionFailureIsUnsupportedWithoutRetrying() {
        var count = 0
        let driver = DesktopTransitionsProcess {
            count += 1
            throw DesktopTransitionsProcessError.noExecutable
        }
        var statuses: [DesktopTransitionStatus] = []
        driver.onStatus = { statuses.append($0) }
        driver.start(.init(style: .instant))
        driver.start(.init(style: .instant))
        XCTAssertEqual(statuses, [.unsupported])
        XCTAssertEqual(count, 1)
        driver.stop()
    }

    func testUnexpectedExitOrBrokenPipeStopsOnlyItsTransportWithoutRelaunching() throws {
        for brokenPipe in [false, true] {
            let child = Transport()
            var count = 0
            let driver = DesktopTransitionsProcess { count += 1; return child }
            var statuses: [DesktopTransitionStatus] = []
            driver.onStatus = { statuses.append($0) }
            driver.start(.init(style: .instant))
            try child.emit(.active(keyboard: true, trackpad: false))
            if brokenPipe { child.onFailure?() } else { child.onExit?() }
            driver.start(.init(style: .instant))
            XCTAssertEqual(count, 1)
            XCTAssertEqual(child.shutdowns.count, 1)
            XCTAssertEqual(statuses.last, .unsupported)
            driver.stop()
        }
    }

    func testStatusFramingHandlesSplitAndMultipleRecordsAndIgnoresInvalidCompleteLines() throws {
        let child = Transport()
        let driver = DesktopTransitionsProcess { child }
        var statuses: [DesktopTransitionStatus] = []
        driver.onStatus = { statuses.append($0) }
        driver.start(.init(style: .instant))
        let first = try DesktopTransitionWire.encode(DesktopTransitionEvent.status(.needsAccessibility))
        let second = try DesktopTransitionWire.encode(DesktopTransitionEvent.status(.active(keyboard: true, trackpad: false)))
        child.onOutput?(first.prefix(8))
        XCTAssertTrue(statuses.isEmpty)
        child.onOutput?(first.dropFirst(8) + Data("not-json\n\n{\"futureEvent\":{}}\n".utf8) + second)
        XCTAssertEqual(statuses, [.needsAccessibility, .active(keyboard: true, trackpad: false)])
        XCTAssertTrue(child.shutdowns.isEmpty)
        driver.stop()
    }

    func testOversizedOutputFailsClosedEvenWithoutANewline() {
        for terminated in [false, true] {
            let child = Transport()
            let driver = DesktopTransitionsProcess { child }
            var statuses: [DesktopTransitionStatus] = []
            driver.onStatus = { statuses.append($0) }
            driver.start(.init(style: .instant))
            var bytes = Data(repeating: 0x20, count: DesktopTransitionEventLines.maximumLineBytes + 1)
            if terminated { bytes.append(10) }
            child.onOutput?(bytes)
            XCTAssertEqual(statuses, [.unsupported])
            XCTAssertEqual(child.shutdowns.count, 1)
            driver.stop()
        }
    }

    func testStoppingFromAStatusCallbackDiscardsTheRestOfThatRead() throws {
        let child = Transport()
        let driver = DesktopTransitionsProcess { child }
        var statuses: [DesktopTransitionStatus] = []
        driver.onStatus = { [weak driver] status in
            statuses.append(status)
            if status == .needsAccessibility { driver?.stop() }
        }
        driver.start(.init(style: .instant))
        let first = try DesktopTransitionWire.encode(DesktopTransitionEvent.status(.needsAccessibility))
        let second = try DesktopTransitionWire.encode(DesktopTransitionEvent.status(.active(keyboard: true, trackpad: true)))
        child.onOutput?(first + second)
        XCTAssertEqual(statuses, [.needsAccessibility, .off])
        XCTAssertEqual(child.shutdowns.count, 1)
    }

    func testDroppingTheDriverClosesItsParentLifetimeLease() {
        let child = Transport()
        var driver: DesktopTransitionsProcess? = DesktopTransitionsProcess { child }
        driver?.start(.init(style: .instant))
        driver = nil
        XCTAssertEqual(child.shutdowns.count, 1, "Dropping an owner must not orphan its input-hook helper")
        XCTAssertNil(child.shutdowns[0], "EOF alone is a valid shutdown when the owner is deinitializing")
    }

    /// Exercises the actual short-read behavior relied on by both IPC readers. This is a syscall
    /// regression, not an integration test of the private Process transport's read implementation.
    func testPOSIXPipeReadDeliversOneShortStatusWhileWriterRemainsOpen() throws {
        let pipe = Pipe()
        let received = expectation(description: "short record arrives without EOF or an 8 KB buffer fill")
        let drained = expectation(description: "reader exits after EOF, including on regression failure")
        let readResult = Mutex<Data?>(nil)
        let status = DesktopTransitionStatus.active(keyboard: true, trackpad: true)
        let bytes = try DesktopTransitionWire.encode(DesktopTransitionEvent.status(status))

        DispatchQueue.global(qos: .userInitiated).async {
            defer { drained.fulfill() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            var count: Int
            repeat {
                count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            } while count < 0 && errno == EINTR
            if count > 0 {
                readResult.withLock { $0 = Data(buffer.prefix(count)) }
                received.fulfill()
            }
        }

        try pipe.fileHandleForWriting.write(contentsOf: bytes)
        let result = XCTWaiter.wait(for: [received], timeout: 1)
        let deliveredBeforeEOF = readResult.withLock { $0 }
        // Only now close the writer. Even if the assertion fails, release any blocked reader.
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(XCTWaiter.wait(for: [drained], timeout: 1), .completed)
        try pipe.fileHandleForReading.close()

        XCTAssertEqual(result, .completed, "Reading a short IPC record must not wait for more bytes or EOF")
        XCTAssertEqual(deliveredBeforeEOF, bytes)
        let child = Transport()
        let driver = DesktopTransitionsProcess { child }
        var statuses: [DesktopTransitionStatus] = []
        driver.onStatus = { statuses.append($0) }
        driver.start(.init(style: .instant))
        child.onOutput?(try XCTUnwrap(deliveredBeforeEOF))
        XCTAssertEqual(statuses, [status], "The record read from a real pipe must reach the status callback")
        driver.stop()
    }
}
