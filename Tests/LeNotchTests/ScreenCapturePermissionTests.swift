import XCTest
@testable import Lenotch

@MainActor
final class ScreenCapturePermissionTests: XCTestCase {
    func testCheckingPermissionNeverRequestsAccess() {
        var requests = 0
        let access = SetupScreenCaptureAccess(preflight: { false }, request: { requests += 1; return false })
        XCTAssertEqual(access.state, .notAsked)
        XCTAssertEqual(access.state, .notAsked)
        XCTAssertEqual(requests, 0)
    }

    func testDeniedRequestOffersSystemSettingsAndExternalGrantIsRechecked() {
        var granted = false
        var requests = 0
        var access = SetupScreenCaptureAccess(preflight: { granted }, request: { requests += 1; return false })
        access.ask()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(access.state, .denied)
        XCTAssertEqual(access.state.actionTitle, "Open Settings")

        granted = true
        XCTAssertEqual(access.state, .allowed)
        XCTAssertNil(access.state.actionTitle)
        granted = false
        XCTAssertEqual(access.state, .denied, "revoking access in System Settings must not leave a stale Allowed state")
        XCTAssertEqual(requests, 1, "refreshing access must never request it again")
    }

    func testExplicitRequestUsesRealAuthorizationResult() {
        var granted = false
        var access = SetupScreenCaptureAccess(preflight: { granted }, request: { granted = true; return true })
        access.ask()
        XCTAssertEqual(access.state, .allowed)
    }
}
