import Foundation
import IslandCore
import XCTest
@testable import Lenotch

@MainActor final class NotificationInboxTests: XCTestCase {
    private func notice(_ n: Int, date: TimeInterval? = nil) -> Notice {
        Notice(id: "nc:\(n)", app: "com.apple.MobileSMS", appName: "Messages", title: "Person \(n)",
               body: "Message \(n)", date: Date(timeIntervalSince1970: date ?? Double(n)))
    }

    func testBoundedNewestFirstAndDeduplication() {
        let inbox = NotificationInbox()
        for n in 0..<65 { inbox.receive(notice(n)) }
        XCTAssertEqual(inbox.items.count, 40)
        XCTAssertEqual(inbox.items.first?.id, "nc:64")
        inbox.receive(notice(64))
        XCTAssertEqual(inbox.items.count, 40)
    }

    func testDismissedNotificationsDoNotReappearOnPoll() {
        let inbox = NotificationInbox(), snapshot = [notice(1), notice(2)]
        inbox.synchronize(snapshot)
        inbox.dismiss("nc:2")
        inbox.synchronize(snapshot)
        XCTAssertEqual(inbox.items.map(\.id), ["nc:1"])
        inbox.synchronize([])
        inbox.synchronize(snapshot)
        XCTAssertEqual(inbox.items.count, 2, "A removed notification may later arrive anew")
    }

    func testNewArrivalDoesNotStealAnActiveReply() {
        let inbox = NotificationInbox()
        inbox.receive(notice(1))
        inbox.beginReply(to: notice(1))
        inbox.draft = "A draft"
        inbox.receive(notice(2))
        XCTAssertEqual(inbox.selected?.id, "nc:1")
        XCTAssertEqual(inbox.draft, "A draft")
        XCTAssertTrue(inbox.composing)
        inbox.select(notice(2))
        XCTAssertFalse(inbox.composing)
        XCTAssertEqual(inbox.draft, "")
    }

    func testSnapshotRemovalAndClearDiscardSensitiveDrafts() {
        let inbox = NotificationInbox()
        inbox.synchronize([notice(1), notice(2)])
        inbox.beginReply(to: notice(1)); inbox.draft = "Private"
        inbox.synchronize([notice(2)])
        XCTAssertEqual(inbox.selected?.id, "nc:2")
        XCTAssertEqual(inbox.draft, "")
        inbox.clear(); inbox.synchronize([notice(2)])
        XCTAssertTrue(inbox.items.isEmpty)
    }

    func testStaleRowCannotStartAReplyAgainstAnotherNotification() {
        let inbox = NotificationInbox()
        inbox.synchronize([notice(1), notice(2)])
        inbox.select(notice(2))
        inbox.synchronize([notice(2)])
        inbox.beginReply(to: notice(1))
        XCTAssertFalse(inbox.composing)
        XCTAssertEqual(inbox.selected?.id, "nc:2")
    }

    func testRemovingSourceAfterSendKeepsPinnedTargetAndSubmissionState() {
        let inbox = NotificationInbox()
        inbox.synchronize([notice(1)])
        inbox.beginReply(to: notice(1)); inbox.draft = "A reply"
        XCTAssertEqual(inbox.beginSubmission()?.id, "nc:1")
        inbox.synchronize([notice(2)])
        inbox.beginReply(to: notice(2))
        inbox.clear()
        XCTAssertTrue(inbox.submitting)
        XCTAssertEqual(inbox.selected?.id, "nc:1")
        XCTAssertEqual(inbox.draft, "A reply")
        inbox.submitting = false
        inbox.feedback = "Submitted through macOS."
        inbox.synchronize([notice(2)])
        XCTAssertEqual(inbox.selected?.id, "nc:1")
        XCTAssertEqual(inbox.feedback, "Submitted through macOS.")
    }
}
