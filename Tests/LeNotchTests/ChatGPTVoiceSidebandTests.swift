import Foundation
import XCTest
@testable import Lenotch

final class ChatGPTVoiceSidebandTests: XCTestCase {
    func testExistingCallSidebandMatchesPinnedFramelessRouteAndCapturedChatGPTAuth() throws {
        let request = try ChatGPTVoiceSideband.request(callID: "rtc_test-123", token: "test-token", accountID: "test-account")
        XCTAssertEqual(request.url?.absoluteString, "wss://api.openai.com/v1/live/rtc_test-123")
        XCTAssertNil(request.url?.query, "Frameless websocket_intent returns None; call-creation query parameters do not belong here")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "test-account")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Alpha"), "quicksilver=v2")
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    func testCallIDCannotAlterHostPathOrQueryOrExposeCredentialsInURL() throws {
        for id in ["", ".", "..", "a/b", "a?token=x", "a#fragment", "//evil.example", "a%2Fb", "a\nb", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try ChatGPTVoiceSideband.request(callID: id, token: "secret", accountID: "account"), id)
        }
        let request = try ChatGPTVoiceSideband.request(callID: "call_123", token: "secret", accountID: "account")
        XCTAssertFalse(try XCTUnwrap(request.url?.absoluteString).contains("secret"))
        XCTAssertNil(request.url?.user)
        XCTAssertNil(request.url?.password)
    }
}

@MainActor
final class ChatGPTVoiceSidebandOpeningTests: XCTestCase {
    func testDidOpenFinishesWithoutPingAndIgnoresLaterCompletion() async throws {
        let opening = ChatGPTVoiceSideband.Opening()
        var cancelled = 0
        try await opening.wait(timeout: .milliseconds(20), start: { opening.didOpen() }, cancel: { cancelled += 1 })
        opening.didFail(status: 503)
        opening.cancel()
        XCTAssertEqual(cancelled, 0)
    }

    func testMissingCallbacksTimesOutAndCancelsExactlyOnce() async {
        let opening = ChatGPTVoiceSideband.Opening()
        var cancelled = 0
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await opening.wait(timeout: .milliseconds(20), start: {}, cancel: { cancelled += 1 })
            XCTFail("An absent delegate callback must not hang opening")
        } catch {
            XCTAssertEqual(error as? ChatGPTVoiceSideband.Failure, .openingTimedOut)
        }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
        opening.didOpen()
        opening.didFail(status: 401)
        opening.cancel()
        XCTAssertEqual(cancelled, 1)
    }

    func testUpgradeFailureKeepsOnlyHTTPStatus() async {
        let opening = ChatGPTVoiceSideband.Opening()
        var cancelled = 0
        do {
            try await opening.wait(start: { opening.didFail(status: 403) }, cancel: { cancelled += 1 })
            XCTFail("An upgrade failure must fail opening")
        } catch {
            XCTAssertEqual(error as? ChatGPTVoiceSideband.Failure, .openingFailed(status: 403))
            XCTAssertTrue(error.localizedDescription.contains("HTTP 403"))
        }
        opening.didOpen()
        XCTAssertEqual(cancelled, 1)
    }

    func testStopWhileOpeningResumesImmediatelyAndIgnoresLaterCallbacks() async {
        let opening = ChatGPTVoiceSideband.Opening()
        var cancelled = 0
        do {
            try await opening.wait(start: { opening.cancel() }, cancel: { cancelled += 1 })
            XCTFail("Stop must cancel the pending opening")
        } catch { XCTAssertTrue(error is CancellationError) }
        opening.didOpen()
        opening.didFail(status: nil)
        XCTAssertEqual(cancelled, 1)
    }

    func testParentTaskCancellationDoesNotWaitForDelegate() async {
        let opening = ChatGPTVoiceSideband.Opening()
        var cancelled = 0
        let task = Task { @MainActor in
            try await opening.wait(start: {}, cancel: { cancelled += 1 })
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled opening must finish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cancelled, 1)
    }
}
