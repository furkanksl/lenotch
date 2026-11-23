import XCTest
@testable import Lenotch

final class UpdatesTests: XCTestCase {
    func testBundledFeedUsesLenotchRepository() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let feed = try XCTUnwrap(info["SUFeedURL"] as? String)
        let publicKey = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(feed, "https://github.com/furkanksl/lenotch/releases/latest/download/appcast.xml")
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32, "Sparkle needs a valid Ed25519 public key")
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertTrue(Updates.isConfigured(feedURL: feed, publicKey: publicKey))
        XCTAssertFalse(Updates.isConfigured(feedURL: feed, publicKey: nil),
                       "a repository URL alone must not enable unsigned updates")
    }

    func testUpdatesRequireBothAnHTTPSFeedAndSigningKey() {
        let feed = "https://example.com/appcast.xml"
        let key = "configured-signing-key"
        XCTAssertTrue(Updates.isConfigured(feedURL: feed, publicKey: key))
        XCTAssertFalse(Updates.isConfigured(feedURL: nil, publicKey: key))
        XCTAssertFalse(Updates.isConfigured(feedURL: "", publicKey: key))
        XCTAssertFalse(Updates.isConfigured(feedURL: feed, publicKey: nil))
        XCTAssertFalse(Updates.isConfigured(feedURL: feed, publicKey: ""))
        XCTAssertFalse(Updates.isConfigured(feedURL: feed, publicKey: " \n\t "))
        for invalidFeed in ["http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https:///appcast.xml", "not a URL"] {
            XCTAssertFalse(Updates.isConfigured(feedURL: invalidFeed, publicKey: key), invalidFeed)
        }
    }
}
