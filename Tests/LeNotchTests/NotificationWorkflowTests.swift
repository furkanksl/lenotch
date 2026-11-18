import AppKit
import IslandCore
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

@MainActor final class NotificationWorkflowTests: XCTestCase {
    private let player = CardSize(width: 520, height: 240, radius: 32)
    private func director() -> (IslandDirector, ManualScheduler) {
        let director = IslandDirector(), scheduler = ManualScheduler()
        director.schedule = scheduler.schedule
        director.clock = { 0 }
        director.frontmostApp = { "" }
        return (director, scheduler)
    }

    private func notice(_ index: Int, app: String = "com.apple.MobileSMS") -> Notice {
        Notice(id: "nc:00000000-0000-4000-8000-\(String(format: "%012d", index))", app: app,
               appName: app == "com.apple.MobileSMS" ? "Messages" : "Mail", title: "Person \(index)",
               body: "Message \(index)", date: Date().addingTimeInterval(Double(index) - 100))
    }

    func testStartupAndRepeatedPollsDoNotImportStoredHistory() {
        let (d, _) = director(), history = (1...80).map { notice($0) }
        d.noticesChanged(all: history, arrived: [])
        XCTAssertTrue(d.notificationInbox.items.isEmpty, "Stored records are not an unread count")
        XCTAssertFalse(d.island.opened)
        d.noticesChanged(all: history, arrived: [])
        XCTAssertTrue(d.notificationInbox.items.isEmpty, "Polling must not import historical records either")
        d.showTool(.notifications)
        XCTAssertTrue(d.notificationInbox.items.isEmpty, "Opening Inbox must not seed it from history")
    }

    func testOnlyNewArrivalsEnterInboxEvenWhileAnotherToolIsOpen() {
        let (d, _) = director(), history = (1...80).map { notice($0) }, fresh = notice(81)
        d.noticesChanged(all: history, arrived: [])
        d.showTool(.notifications)
        d.noticesChanged(all: history + [fresh], arrived: [fresh])
        XCTAssertEqual(d.notificationInbox.items.map(\.id), [fresh.id])
        XCTAssertEqual(d.tray.page, .notifications)
        d.noticesChanged(all: history + [fresh], arrived: [])
        XCTAssertEqual(d.notificationInbox.items.map(\.id), [fresh.id])
        d.noticesChanged(all: history, arrived: [])
        XCTAssertTrue(d.notificationInbox.items.isEmpty, "A removed live notification must not be replaced with history")
    }

    func testRestartingOrReenablingDoesNotCountExistingSessionHistoryAgain() {
        let (d, _) = director(), first = notice(1)
        d.noticesChanged(all: [first], arrived: [first])
        XCTAssertEqual(d.notificationInbox.items.count, 1)
        d.noticesChanged(all: [], arrived: [])
        d.noticesChanged(all: [first], arrived: [])
        XCTAssertTrue(d.notificationInbox.items.isEmpty)
        let (restarted, _) = director()
        restarted.noticesChanged(all: [first], arrived: [])
        XCTAssertTrue(restarted.notificationInbox.items.isEmpty)
    }

    func testCapacityDoesNotRefillFromOlderRecordsAfterClear() {
        let (d, _) = director(), arrivals = (1...65).map { notice($0) }
        d.showTool(.notifications)
        d.noticesChanged(all: arrivals, arrived: arrivals)
        XCTAssertEqual(d.notificationInbox.items.count, NotificationInbox.capacity)
        d.clearNotificationInbox()
        d.noticesChanged(all: arrivals, arrived: [])
        XCTAssertTrue(d.notificationInbox.items.isEmpty, "The older 25 records must not refill the cleared list")
    }

    func testBannerExpiresButInboxRetainsArrival() {
        let (d, scheduler) = director(), n = notice(1)
        d.noticesChanged(all: [n], arrived: [n])
        XCTAssertTrue(d.island.opened)
        scheduler.advance(8)
        XCTAssertFalse(d.island.opened)
        XCTAssertEqual(d.notificationInbox.items.map(\.id), [n.id])
    }

    func testStackRetainsAllWhileAReplyIsBeingWritten() {
        let (d, scheduler) = director(), first = notice(1), second = notice(2)
        d.noticesChanged(all: [first], arrived: [first])
        d.beginNoticeReply(first)
        d.notificationInbox.draft = "Private draft"
        d.noticesChanged(all: [first, second], arrived: [second])
        scheduler.advance(8)
        XCTAssertTrue(d.island.opened)
        XCTAssertEqual(d.notificationInbox.items.count, 2)
        XCTAssertEqual(d.notificationInbox.selected?.id, first.id)
        XCTAssertEqual(d.notificationInbox.draft, "Private draft")
        d.cancelNoticeReply()
    }

    func testExpandedStackKeepsBannerOpenAndUsesTheListSize() {
        let (d, scheduler) = director(), first = notice(1), second = notice(2)
        d.noticesChanged(all: [first, second], arrived: [first, second])
        d.expandNotices(true)
        scheduler.advance(8)
        XCTAssertTrue(d.island.opened)
        XCTAssertEqual(d.presentationCard(player: player), CardSize(width: 420, height: 348, radius: 36))
        d.selectInboxNotice(first)
        XCTAssertFalse(d.notificationInbox.expanded)
        XCTAssertEqual(d.presentationCard(player: player), CardSize(width: 420, height: 206, radius: 36))
        XCTAssertEqual(d.notice(for: try! XCTUnwrap(d.island.activity)).id, first.id)
    }

    func testClearDoesNotResurrectNotificationsOnNextSnapshot() {
        let (d, _) = director(), first = notice(1)
        d.noticesChanged(all: [first], arrived: [first])
        d.clearNotificationInbox()
        d.noticesChanged(all: [first], arrived: [])
        XCTAssertTrue(d.notificationInbox.items.isEmpty)
    }

    func testEachNewToolHasAnIndependentCard() {
        let (d, _) = director()
        for (page, size) in [(TrayModel.Page.usage, CardSize(width: 480, height: 266, radius: 36)),
                             (.notifications, CardSize(width: 420, height: 348, radius: 36))] {
            d.showTool(page)
            XCTAssertTrue(d.island.trayShows)
            XCTAssertEqual(d.tray.page, page)
            XCTAssertEqual(d.presentationCard(player: player), size)
        }
        d.tray.go(.main)
        XCTAssertEqual(d.presentationCard(player: player),
                       CardSize(width: Island.trayOnly.width, height: d.toolMenu.cardHeight, radius: Island.trayOnly.radius))
    }

    func testExplicitSubmitUsesPinnedNotificationAndDoesNotAutoRetry() async {
        let (d, _) = director(), first = notice(1), second = notice(2)
        d.noticesChanged(all: [first], arrived: [first])
        d.beginNoticeReply(first); d.notificationInbox.draft = "  A reply  "
        var sent: [(String, String)] = []
        d.sendNotificationReply = { target, text in
            sent.append((target.id, text))
            await Task.yield()
            return "Submitted through macOS. Delivery isn’t confirmed."
        }
        d.submitNoticeReply(); d.submitNoticeReply()
        d.noticesChanged(all: [first, second], arrived: [second])
        for _ in 0..<100 where d.notificationInbox.submitting { await Task.yield() }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, first.id)
        XCTAssertEqual(sent.first?.1, "A reply")
        XCTAssertFalse(d.notificationInbox.composing)
        XCTAssertEqual(d.notificationInbox.draft, "")
        XCTAssertTrue(d.notificationInbox.feedback?.contains("Delivery") == true)
    }

    func testFailedReplyRetainsDraftAndDoesNotClaimSuccess() async {
        let (d, _) = director(), n = notice(1)
        d.noticesChanged(all: [n], arrived: [n]); d.beginNoticeReply(n)
        d.notificationInbox.draft = "Keep this"
        d.sendNotificationReply = { _, _ in throw NotificationReplyFailure.accessibilityRequired }
        d.submitNoticeReply()
        for _ in 0..<100 where d.notificationInbox.submitting { await Task.yield() }
        XCTAssertEqual(d.notificationInbox.draft, "Keep this")
        XCTAssertTrue(d.notificationInbox.composing)
        XCTAssertNotNil(d.notificationInbox.feedback)
    }

    func testNativeNotificationDetailAndExpandedColumnRenderReadableContent() async throws {
        let (d, _) = director(), first = notice(1), second = notice(2)
        d.noticesChanged(all: [first, second], arrived: [first, second])
        for expanded in [false, true] {
            d.expandNotices(expanded)
            let height = expanded ? 348.0 : 206.0
            let view = NoticeCard(notice: second, director: d)
                .frame(width: 384, height: height - 36).padding(18).background(.black)
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            defer { window.close() }
            for _ in 0..<4 { await Task.yield(); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains(expanded ? "notifications" : "messages"), text)
            XCTAssertTrue(text.contains("person 2"), text)
            if expanded { XCTAssertTrue(text.contains("person 1"), text) }
            else { XCTAssertTrue(text.contains("reply"), text) }
        }
    }
}
