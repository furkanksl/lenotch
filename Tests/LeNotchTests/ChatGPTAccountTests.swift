import Foundation
import XCTest
@testable import Lenotch

final class ChatGPTAccountTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(ChatGPTOAuth.challenge(verifier: verifier),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(ChatGPTOAuth.verifier(bytes: [0xfb, 0xff, 0x00]), "-_8A")
        let url = ChatGPTOAuth.authorizeURL(state: "a state", verifier: verifier)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(items?.first(where: { $0.name == "state" })?.value, "a state")
        XCTAssertEqual(items?.first(where: { $0.name == "redirect_uri" })?.value, ChatGPTOAuth.redirectURI)
        XCTAssertEqual(items?.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
        XCTAssertEqual(items?.first(where: { $0.name == "code_challenge" })?.value,
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testCallbackRequiresMatchingSingleStateAndCodeFromExpectedHost() {
        let host = "localhost:1455"
        let success = ChatGPTOAuth.callback("GET /auth/callback?code=one%2Btwo&state=secret HTTP/1.1",
                                           host: host, expectedState: "secret")
        guard case .success(let code) = success else { return XCTFail("Expected a verified callback") }
        XCTAssertEqual(code, "one+two")
        for line in [
            "GET /auth/callback?code=one&state=wrong HTTP/1.1",
            "GET /auth/callback?code=one&state=secret&state=secret HTTP/1.1",
            "GET /auth/callback?code=one&code=two&state=secret HTTP/1.1",
            "GET /other?code=one&state=secret HTTP/1.1",
            "POST /auth/callback?code=one&state=secret HTTP/1.1"
        ] {
            let result = ChatGPTOAuth.callback(line, host: host, expectedState: "secret")
            switch result {
            case .success: XCTFail("Unexpected successful callback: \(line)")
            case .failure, .none: break
            }
        }
        XCTAssertNil(ChatGPTOAuth.callback("GET /auth/callback?code=one&state=secret HTTP/1.1",
                                           host: "malicious.example:1455", expectedState: "secret"))
        XCTAssertFalse(ChatGPTOAuth.matches(state: "secret", expected: "secreT"))
        XCTAssertFalse(ChatGPTOAuth.matches(state: "", expected: ""))
    }

    func testTokenClaimsDecodeAndRefreshTokenRotation() throws {
        let issued = Date(timeIntervalSince1970: 1_000_000)
        let namespace = "https://api.openai.com/auth"
        let idToken = jwt(["email": "a@example.com", namespace: [
            "chatgpt_account_id": "account-A", "chatgpt_plan_type": "plus"
        ]])
        let first = try ChatGPTStoredCredentials(tokenData: json([
            "access_token": "access-1", "refresh_token": "refresh-1",
            "id_token": idToken, "expires_in": 3600
        ]), previous: nil, now: issued)
        XCTAssertEqual(first.publicCredentials.accessToken, "access-1")
        XCTAssertEqual(first.publicCredentials.accountID, "account-A")
        XCTAssertEqual(first.email, "a@example.com")
        XCTAssertEqual(first.plan, "plus")
        XCTAssertFalse(first.needsRefresh(at: issued.addingTimeInterval(3299)))
        XCTAssertTrue(first.needsRefresh(at: issued.addingTimeInterval(3300)))

        let rotated = try ChatGPTStoredCredentials(tokenData: json([
            "access_token": "access-2", "refresh_token": "refresh-2", "expires_in": 3600
        ]), previous: first, now: issued.addingTimeInterval(10))
        XCTAssertEqual(rotated.refreshToken, "refresh-2")
        XCTAssertEqual(rotated.accountID, "account-A")
        XCTAssertEqual(rotated.email, "a@example.com")
        XCTAssertEqual(try ChatGPTStoredCredentials(tokenData: json([
            "access_token": "access-3", "expires_in": 3600
        ]), previous: rotated).refreshToken, "refresh-2")
    }

    func testTokenDecodeRequiresAccountAndRefreshTokenAndRejectsAccountSwitch() throws {
        XCTAssertThrowsError(try ChatGPTStoredCredentials(tokenData: json([
            "access_token": "access", "refresh_token": "refresh"
        ]), previous: nil))
        let old = try ChatGPTStoredCredentials(tokenData: json([
            "access_token": "access", "refresh_token": "refresh", "id_token": jwt(["chatgpt_account_id": "one"])
        ]), previous: nil)
        XCTAssertThrowsError(try ChatGPTStoredCredentials(tokenData: json([
            "access_token": "access", "id_token": jwt(["chatgpt_account_id": "two"])
        ]), previous: old))
        XCTAssertThrowsError(try ChatGPTStoredCredentials(tokenData: json([
            "access_token": "access", "id_token": jwt(["chatgpt_account_id": "one"])
        ]), previous: nil))
        let withoutExpiry = try ChatGPTStoredCredentials(tokenData: json([
            "access_token": "access", "refresh_token": "refresh", "id_token": jwt(["chatgpt_account_id": "one"])
        ]), previous: nil)
        XCTAssertTrue(withoutExpiry.needsRefresh(at: Date()))
    }

    func testAccessTokenExpiryFallbackAndDeniedCallback() throws {
        let expiry = Date(timeIntervalSince1970: 1_004_000)
        let saved = try ChatGPTStoredCredentials(tokenData: json([
            "access_token": jwt(["exp": expiry.timeIntervalSince1970]),
            "refresh_token": "refresh", "id_token": jwt(["chatgpt_account_id": "one"])
        ]), previous: nil, now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(saved.expiresAt, expiry)
        XCTAssertFalse(saved.needsRefresh(at: expiry.addingTimeInterval(-301)))
        XCTAssertTrue(saved.needsRefresh(at: expiry.addingTimeInterval(-300)))
        let denied = ChatGPTOAuth.callback("GET /auth/callback?error=access_denied&state=secret HTTP/1.1",
                                          host: "localhost:1455", expectedState: "secret")
        guard case .failure(.cancelled) = denied else { return XCTFail("Expected a denied callback") }
    }

    func testCallbackPageIsReadablePrivateAndSizedForBothOutcomes() throws {
        for success in [true, false] {
            let response = String(decoding: ChatGPTCallbackPage.response(success: success), as: UTF8.self)
            let parts = response.components(separatedBy: "\r\n\r\n")
            XCTAssertEqual(parts.count, 2)
            let headers = try XCTUnwrap(parts.first)
            let page = try XCTUnwrap(parts.last)
            XCTAssertTrue(headers.hasPrefix(success ? "HTTP/1.1 200 OK" : "HTTP/1.1 400 Bad Request"))
            XCTAssertTrue(headers.components(separatedBy: "\r\n").contains("Content-Length: \(page.utf8.count)"))
            XCTAssertTrue(headers.contains("Cache-Control: no-store"))
            XCTAssertTrue(headers.contains("Referrer-Policy: no-referrer"))
            XCTAssertTrue(headers.contains("default-src 'none'; style-src 'unsafe-inline'"))
            XCTAssertTrue(page.contains("<main>"))
            XCTAssertTrue(page.contains("<h1>\(success ? "Continue in LeNotch" : "Sign-in couldn't finish")</h1>"))
            XCTAssertTrue(page.contains("prefers-color-scheme: dark"))
            XCTAssertTrue(page.contains("You can close this tab."))
            XCTAssertFalse(page.contains("code="))
            XCTAssertFalse(page.contains("state="))
            XCTAssertFalse(page.contains("<script"))
            XCTAssertFalse(page.contains("<img"))
        }
    }

    private func jwt(_ claims: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: claims)
        return "header.\(ChatGPTOAuth.verifier(bytes: Array(data))).signature"
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
