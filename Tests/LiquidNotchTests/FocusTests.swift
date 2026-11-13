import XCTest
import IslandCore
@testable import Lenotch

@MainActor
final class FocusTests: XCTestCase {
    func testClickingActiveModeRequestsOffAndClickingAgainRequestsOn() async {
        let tray = TrayModel()
        tray.systemFocus("Work")
        var requests: [Bool] = []
        tray.setFocus = { mode, enabled in
            XCTAssertEqual(mode, .work)
            requests.append(enabled)
            return .changed
        }

        await tray.pick(.work)
        XCTAssertEqual(requests, [false])
        XCTAssertNil(tray.focus)
        XCTAssertNil(tray.focusName)
        await tray.pick(.work)
        XCTAssertEqual(requests, [false, true])
        XCTAssertEqual(tray.focus, .work)
        XCTAssertEqual(tray.focusName, "Work")
    }

    func testFailureKeepsTheActiveModeAndShowsAnError() async {
        let tray = TrayModel()
        tray.systemFocus("Personal")
        tray.setFocus = { _, _ in .failed("Allow Accessibility in System Settings.") }

        await tray.pick(.work)
        XCTAssertEqual(tray.focus, .personal)
        XCTAssertEqual(tray.focusName, "Personal")
        XCTAssertEqual(tray.focusError, "Allow Accessibility in System Settings.")
        XCTAssertNil(tray.focusPending)

        await tray.pick(.personal)
        XCTAssertEqual(tray.focus, .personal, "a failed off request must not clear the active mode")
    }

    func testOverlappingClicksAreIgnoredAndUIStateWaitsForCompletion() async {
        let tray = TrayModel()
        var completion: CheckedContinuation<FocusSwitchResult, Never>?
        var started: CheckedContinuation<Void, Never>?
        var requests = 0
        tray.setFocus = { _, _ in
            requests += 1
            return await withCheckedContinuation {
                completion = $0
                started?.resume()
            }
        }
        let task = Task { await tray.pick(.work) }
        await withCheckedContinuation { started = $0 }
        XCTAssertEqual(tray.focusPending, .work)
        XCTAssertNil(tray.focus, "don't claim macOS changed before automation finishes")
        await tray.pick(.personal)
        await tray.pick(.work)
        XCTAssertEqual(requests, 1)

        completion?.resume(returning: .changed)
        await task.value
        XCTAssertEqual(tray.focus, .work)
        XCTAssertNil(tray.focusPending)
        XCTAssertNil(tray.focusError)
    }

    func testRetryClearsErrorAndCanSwitchFromACustomMode() async {
        let tray = TrayModel()
        await tray.pick(.work)
        XCTAssertNotNil(tray.focusError)
        tray.systemFocus("Reading")
        tray.setFocus = { mode, enabled in
            XCTAssertEqual(mode, .sleep)
            XCTAssertTrue(enabled)
            return .changed
        }
        await tray.pick(.sleep)
        XCTAssertEqual(tray.focus, .sleep)
        XCTAssertNil(tray.focusError)
    }

    func testFailureDoesNotOverwriteASystemChangeDuringTheRequest() async {
        let tray = TrayModel()
        tray.systemFocus("Work")
        tray.setFocus = { _, _ in
            tray.systemFocus("Reading")
            return .failed("Control Center didn't respond.")
        }
        await tray.pick(.work)
        XCTAssertNil(tray.focus)
        XCTAssertEqual(tray.focusName, "Reading")
    }

    func testUnnamedActiveSystemFocusClearsAStalePill() {
        let director = IslandDirector()
        director.tray.systemFocus("Work")
        director.systemContextChanged(DesktopContext(focusOn: true))
        XCTAssertNil(director.tray.focus)
        XCTAssertNil(director.tray.focusName)
    }

    func testUnknownDatabaseSchemaDoesNotReportConfirmedOff() {
        let unknown: [Any] = [[:], ["data": []], ["data": [["futureAssertions": []]]],
                              ["data": [["storeAssertionRecords": [["futureModeKey": "Work"]]]]]]
        for assertions in unknown {
            XCTAssertTrue(FocusDatabase.status(assertions: assertions, configurations: nil) == nil)
        }
        let off = FocusDatabase.status(assertions: ["data": [["storeAssertionRecords": []]]], configurations: nil)
        XCTAssertTrue(off != nil, "a recognized empty store confirms off, not unknown")
        XCTAssertNil(off!)
    }
}
