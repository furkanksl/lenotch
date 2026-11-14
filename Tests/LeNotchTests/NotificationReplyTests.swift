import Foundation
import IslandCore
import XCTest
@testable import Lenotch

/// Pure AX fixtures only. These tests never inspect a user's notifications or dispatch a native action.
final class NotificationReplyTests: XCTestCase, @unchecked Sendable {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let uuid = "0123456789abcdef0123456789abcdef"

    private func notice(id: String? = nil, app: String = "com.apple.MobileSMS", body: String = "Meet at six?",
                        age: TimeInterval = 0) -> Notice {
        Notice(id: id ?? uuid, app: app, appName: "Messages", title: "Alex", body: body,
               thread: "Alex", date: instant.addingTimeInterval(-age))
    }

    private func card(id: String? = nil, body: String = "Meet at six?", editor: String? = nil,
                      reply: Bool = true, send: Bool = false) -> NotificationReplyAXNode {
        var children = [NotificationReplyAXNode(role: "AXStaticText", value: "Alex"),
                        NotificationReplyAXNode(role: "AXStaticText", value: body)]
        if reply {
            children.append(NotificationReplyAXNode(role: "AXButton", title: "Reply",
                                                     actions: [.init(name: "AXPress")]))
        }
        if let editor {
            children.append(NotificationReplyAXNode(role: "AXTextField", value: editor, valueSettable: true))
        }
        if send {
            children.append(NotificationReplyAXNode(role: "AXButton", detail: "Send",
                                                     actions: [.init(name: "AXPress")]))
        }
        return NotificationReplyAXNode(identifier: id ?? uuid, children: children)
    }

    private func service(_ transport: FixtureReplyTransport) -> NotificationReplyService {
        let instant = self.instant
        return NotificationReplyService(transport: transport, now: { instant }, pause: {})
    }

    func testOnlyExplicitNativeMessagingBundleIdentifiersAreSupported() {
        XCTAssertTrue(NotificationReplyService.supports(notice()))
        XCTAssertTrue(NotificationReplyService.supports(notice(app: "net.whatsapp.WhatsApp")))
        for app in ["com.apple.mail", "com.apple.MobileSMS.fake", "com.google.Chrome", "WhatsApp", "desktop.WhatsApp"] {
            XCTAssertFalse(NotificationReplyService.supports(notice(app: app)), app)
        }
    }

    func testUUIDAcceptsStoreSpellingAndPrefixedRecordIDsButNotContainsMatches() throws {
        XCTAssertEqual(try NotificationReplyTarget(notice(id: "nc:01234567-89AB-CDEF-0123-456789ABCDEF"), now: instant).uuid, uuid)
        XCTAssertEqual(NotificationReplyTarget.canonicalUUID("01234567-89AB-CDEF-0123-456789ABCDEF"), uuid)
        for identifier in ["sample-message", "dismiss-\(uuid)", "prefix\(uuid)", "nc:\(uuid)", "\(uuid)-extra"] {
            XCTAssertNil(NotificationReplyTarget.canonicalUUID(identifier), identifier)
        }
    }

    func testDisplayNameThreadAndMatchingContentNeverReplaceAStableUUID() throws {
        let target = try NotificationReplyTarget(notice(), now: instant)
        let wrongID = card(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertThrowsError(try NotificationReplyPlan.card(for: target, in: .init(nodes: [wrongID]))) {
            XCTAssertEqual($0 as? NotificationReplyFailure, .notificationUnavailable)
        }
        XCTAssertThrowsError(try NotificationReplyTarget(notice(id: "Alex"), now: instant)) {
            XCTAssertEqual($0 as? NotificationReplyFailure, .invalidNotification)
        }
    }

    func testExactUUIDDisambiguatesIdenticalIncomingMessages() throws {
        let target = try NotificationReplyTarget(notice(), now: instant)
        let expected = card()
        let found = try NotificationReplyPlan.card(for: target, in: .init(nodes: [
            card(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), expected,
        ]))
        XCTAssertEqual(found?.key, expected.key)
    }

    func testDuplicateUUIDAndGroupedDifferentNotificationBothFailClosed() throws {
        let target = try NotificationReplyTarget(notice(), now: instant)
        XCTAssertThrowsError(try NotificationReplyPlan.card(for: target, in: .init(nodes: [card(), card()]))) {
            XCTAssertEqual($0 as? NotificationReplyFailure, .ambiguousNotification)
        }
        var grouped = card()
        grouped.children.append(card(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        XCTAssertThrowsError(try NotificationReplyPlan.card(for: target, in: .init(nodes: [grouped]))) {
            XCTAssertEqual($0 as? NotificationReplyFailure, .ambiguousNotification)
        }
    }

    func testUUIDStillRequiresExactOriginalContentAndCompleteSnapshot() throws {
        let target = try NotificationReplyTarget(notice(), now: instant)
        XCTAssertThrowsError(try NotificationReplyPlan.card(for: target, in: .init(nodes: [card(body: "Another message")]))) {
            XCTAssertEqual($0 as? NotificationReplyFailure, .notificationChanged)
        }
        XCTAssertThrowsError(try NotificationReplyPlan.card(for: target, in: .init(nodes: [card()], complete: false))) {
            XCTAssertEqual($0 as? NotificationReplyFailure, .timedOut)
        }
    }

    func testEditableReplyTextCannotMasqueradeAsOriginalNotificationContent() throws {
        let target = try NotificationReplyTarget(notice(), now: instant)
        let fixture = card(body: "A different incoming message", editor: "Meet at six?", send: true)
        XCTAssertThrowsError(try NotificationReplyPlan.card(for: target, in: .init(nodes: [fixture]))) {
            XCTAssertEqual($0 as? NotificationReplyFailure, .notificationChanged)
        }
    }

    func testNativeLabelledButtonAndDescribedCustomActionAreSupported() throws {
        XCTAssertEqual(try NotificationReplyPlan.action("Reply", in: card()).name, "AXPress")
        var custom = card(reply: false)
        custom.actions = [.init(name: "opaque-native-action", label: "Reply")]
        XCTAssertEqual(try NotificationReplyPlan.action("Reply", in: custom).name, "opaque-native-action")
    }

    func testUnknownLocalizedDisabledAndAmbiguousActionsDoNotGuess() {
        var fixture = card(reply: false)
        fixture.children.append(.init(role: "AXButton", title: "Répondre", actions: [.init(name: "AXPress")]))
        fixture.children.append(.init(role: "AXButton", title: "Reply", enabled: false, actions: [.init(name: "AXPress")]))
        XCTAssertThrowsError(try NotificationReplyPlan.action("Reply", in: fixture))
        fixture.children += card().children.suffix(1)
        fixture.children += card().children.suffix(1)
        XCTAssertThrowsError(try NotificationReplyPlan.action("Reply", in: fixture))
        XCTAssertThrowsError(try NotificationReplyPlan.action("Send", in: card()))
    }

    func testAvailabilityDoesNotOpenUIOrRequestPermission() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: []), trusted: false)
        let reply = service(transport)
        let availability = await reply.availability(for: notice())
        XCTAssertEqual(availability, .requiresAccessibility)
        let calls = await transport.calls
        XCTAssertEqual(calls, ["trusted"])
    }

    func testUnsupportedStaleMalformedAndEmptySubmissionsHaveNoTransportSideEffects() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: [card()]))
        let reply = service(transport)
        for (n, text, expected) in [
            (notice(app: "com.apple.mail"), "Yes", NotificationReplyFailure.unsupportedApp),
            (notice(age: 16 * 60), "Yes", .staleNotification),
            (notice(age: -60), "Yes", .staleNotification),
            (notice(id: "sample"), "Yes", .invalidNotification),
            (notice(), " \n ", .emptyMessage),
            (notice(), String(repeating: "a", count: 16_385), .messageTooLong),
        ] {
            let result = await reply.send(text, to: n)
            XCTAssertEqual(result, .failed(expected))
        }
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testMissingAccessibilityNeverPromptsOrOpensNotificationCenter() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: [card()]), trusted: false)
        let result = await service(transport).send("Yes", to: notice())
        XCTAssertEqual(result, .failed(.accessibilityRequired))
        let calls = await transport.calls
        XCTAssertEqual(calls, ["trusted"])
    }

    func testMissingCardCanRevealOnlyAfterExplicitSendAndNeverDispatchesMissingTarget() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: []))
        let reply = service(transport)
        let availability = await reply.availability(for: notice())
        XCTAssertEqual(availability, .ready)
        let before = await transport.calls
        XCTAssertEqual(before, ["trusted"])
        let result = await reply.send("Yes", to: notice())
        XCTAssertEqual(result, .failed(.notificationUnavailable))
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0 == "reveal" }.count, 1)
        XCTAssertFalse(calls.contains("dispatch"))
    }

    func testExactCardCanAppearAfterExplicitNativePanelReveal() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: []),
                                             afterReveal: .init(nodes: [card(editor: "", send: true)]))
        let result = await service(transport).send("Yes", to: notice())
        XCTAssertEqual(result, .submitted)
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0 == "reveal" }.count, 1)
    }

    func testSuccessfulNativeDispatchMustHaveUIAcknowledgement() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: [card()]), afterReply: .init(nodes: [card(editor: "", send: true)]))
        let reply = service(transport)
        let result = await reply.send("Yes, see you then!", to: notice())
        XCTAssertEqual(result, .submitted)
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0 == "dispatch" }.count, 1)
        XCTAssertTrue(calls.contains("write"))
        let text = await transport.writtenText
        XCTAssertEqual(text, "Yes, see you then!")
    }

    func testAlreadyOpenEmptyReplyFieldIsUsableWithoutAnotherReplyAction() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: [card(editor: "", reply: false, send: true)]))
        let result = await service(transport).send("Yes", to: notice())
        XCTAssertEqual(result, .submitted)
        let calls = await transport.calls
        XCTAssertFalse(calls.contains("reply"))
    }

    func testAnExistingNativeDraftIsNeverOverwritten() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: [card(editor: "My unfinished draft", send: true)]))
        let result = await service(transport).send("Yes", to: notice())
        XCTAssertEqual(result, .failed(.existingDraft))
        let calls = await transport.calls
        XCTAssertFalse(calls.contains("write"))
        XCTAssertFalse(calls.contains("dispatch"))
    }

    func testASecondEditorNeverGetsGuessed() async {
        var fixture = card(editor: "", send: true)
        fixture.children.append(.init(role: "AXTextArea", value: "", valueSettable: true))
        let transport = FixtureReplyTransport(initial: .init(nodes: [fixture]))
        let result = await service(transport).send("Yes", to: notice())
        XCTAssertEqual(result, .failed(.unsupportedEditor))
        let calls = await transport.calls
        XCTAssertFalse(calls.contains("write"))
    }

    func testTargetChangeAtTheMutationBoundaryStopsBeforeSend() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: [card()]),
                                             afterReply: .init(nodes: [card(editor: "", send: true)]),
                                             changeBeforeDispatch: .init(nodes: [card(body: "A new message", editor: "Yes", send: true)]))
        let result = await service(transport).send("Yes", to: notice())
        XCTAssertEqual(result, .failed(.notificationChanged))
        let count = await transport.nativeSendCount
        XCTAssertEqual(count, 0)
    }

    func testNativeActionAcceptanceAloneDoesNotClaimSubmission() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: [card(editor: "", send: true)]), acknowledge: false)
        let reply = service(transport)
        let first = await reply.send("Yes", to: notice())
        let retry = await reply.send("Yes", to: notice())
        XCTAssertEqual(first, .failed(.submissionUnconfirmed))
        XCTAssertEqual(retry, .failed(.alreadyAttempted))
        let count = await transport.nativeSendCount
        XCTAssertEqual(count, 1)
    }

    func testUncertainAXTimeoutIsNeverRetriedEvenWithANewAttemptToken() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: [card(editor: "", send: true)]), uncertain: true)
        let reply = service(transport)
        let request = NotificationReplyRequest(notice: notice(), text: "Yes")
        let first = await reply.submit(request)
        let sameToken = await reply.submit(request)
        let newToken = await reply.send("Yes", to: notice())
        XCTAssertEqual(first, .failed(.submissionUnconfirmed))
        XCTAssertEqual(sameToken, first)
        XCTAssertEqual(newToken, .failed(.alreadyAttempted))
        let count = await transport.nativeSendCount
        XCTAssertEqual(count, 1)
    }

    func testSuccessfulRetryIsIdempotentAndAttemptCannotBeReusedForAnotherMessage() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: [card(editor: "", send: true)]))
        let reply = service(transport)
        let request = NotificationReplyRequest(notice: notice(), text: "Yes")
        let first = await reply.submit(request)
        let second = await reply.submit(request)
        let changed = await reply.submit(.init(attemptID: request.attemptID, notice: notice(), text: "No"))
        XCTAssertEqual(first, .submitted)
        XCTAssertEqual(second, .submitted)
        XCTAssertEqual(changed, .failed(.attemptReused))
        let count = await transport.nativeSendCount
        XCTAssertEqual(count, 1)
    }

    func testAChangedDraftImmediatelyBeforeDispatchIsNotSubmitted() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: [card(editor: "", send: true)]),
                                             changeBeforeDispatch: .init(nodes: [card(editor: "Someone edited this", send: true)]))
        let result = await service(transport).send("Yes", to: notice())
        XCTAssertEqual(result, .failed(.notificationChanged))
        let count = await transport.nativeSendCount
        XCTAssertEqual(count, 0)
    }

    func testOverlappingSubmissionsAreRejectedAcrossAwaitBoundaries() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: [card(editor: "", send: true)]), blockFirstSnapshot: true)
        let reply = service(transport)
        let n = notice()
        let first = Task { await reply.send("Yes", to: n) }
        await transport.waitForBlockedSnapshot()
        let overlapping = await reply.send("No", to: n)
        XCTAssertEqual(overlapping, .failed(.busy))
        await transport.releaseSnapshot()
        let result = await first.value
        XCTAssertEqual(result, .submitted)
        let count = await transport.nativeSendCount
        XCTAssertEqual(count, 1)
    }

    func testCancellationWhileReadingTheTargetNeverOpensReplyOrSends() async {
        let transport = FixtureReplyTransport(initial: .init(nodes: [card()]), blockFirstSnapshot: true)
        let reply = service(transport)
        let n = notice()
        let task = Task { await reply.send("Yes", to: n) }
        await transport.waitForBlockedSnapshot()
        task.cancel()
        await transport.releaseSnapshot()
        let result = await task.value
        XCTAssertEqual(result, .failed(.cancelled))
        let calls = await transport.calls
        XCTAssertFalse(calls.contains("reply"))
        XCTAssertFalse(calls.contains("dispatch"))
    }

    func testThrowingComposerAPIProvidesHonestDeliveryWording() async throws {
        let transport = FixtureReplyTransport(initial: .init(nodes: [card(editor: "", send: true)]))
        let submission = try await service(transport).send(text: "Yes", to: notice())
        XCTAssertTrue(submission.displayMessage.contains("Submitted"))
        XCTAssertTrue(submission.displayMessage.contains("isn’t confirmed"))
    }
}

private actor FixtureReplyTransport: NotificationReplyTransport {
    private var tree: NotificationReplySnapshot
    private let trusted: Bool
    private let afterReveal: NotificationReplySnapshot?
    private let afterReply: NotificationReplySnapshot?
    private let changeBeforeDispatch: NotificationReplySnapshot?
    private let acknowledge: Bool
    private let uncertain: Bool
    private var blockFirstSnapshot: Bool
    private var snapshotRelease: CheckedContinuation<Void, Never>?
    private var blockedObserver: CheckedContinuation<Void, Never>?
    private(set) var calls: [String] = []
    private(set) var writtenText: String?
    private(set) var nativeSendCount = 0

    init(initial: NotificationReplySnapshot, trusted: Bool = true, afterReveal: NotificationReplySnapshot? = nil,
         afterReply: NotificationReplySnapshot? = nil, changeBeforeDispatch: NotificationReplySnapshot? = nil,
         acknowledge: Bool = true, uncertain: Bool = false, blockFirstSnapshot: Bool = false) {
        tree = initial
        self.trusted = trusted
        self.afterReveal = afterReveal
        self.afterReply = afterReply
        self.changeBeforeDispatch = changeBeforeDispatch
        self.acknowledge = acknowledge
        self.uncertain = uncertain
        self.blockFirstSnapshot = blockFirstSnapshot
    }

    func accessibilityTrusted() -> Bool { calls.append("trusted"); return trusted }
    func snapshot() async -> NotificationReplySnapshot {
        calls.append("snapshot")
        if blockFirstSnapshot {
            blockFirstSnapshot = false
            await withCheckedContinuation { continuation in
                snapshotRelease = continuation
                blockedObserver?.resume()
                blockedObserver = nil
            }
        }
        return tree
    }

    func waitForBlockedSnapshot() async {
        if snapshotRelease != nil { return }
        await withCheckedContinuation { blockedObserver = $0 }
    }

    func releaseSnapshot() {
        snapshotRelease?.resume()
        snapshotRelease = nil
    }

    func revealNotificationCenter() {
        calls.append("reveal")
        if let afterReveal { tree = afterReveal }
    }

    func openReply(for target: NotificationReplyTarget) throws {
        calls.append("reply")
        let card = try NotificationReplyPlan.card(for: target, in: tree)!
        _ = try NotificationReplyPlan.action("Reply", in: card)
        if let afterReply { tree = afterReply }
    }

    func write(_ text: String, to target: NotificationReplyTarget) throws {
        calls.append("write")
        let card = try NotificationReplyPlan.card(for: target, in: tree)!
        let field = try NotificationReplyPlan.editor(in: card)
        guard field.value == "" else { throw NotificationReplyFailure.existingDraft }
        writtenText = text
        func replace(_ node: NotificationReplyAXNode) -> NotificationReplyAXNode {
            var copy = node
            if node.key == field.key { copy.value = text }
            copy.children = node.children.map(replace)
            return copy
        }
        tree.nodes = tree.nodes.map(replace)
    }

    func dispatch(_ text: String, to target: NotificationReplyTarget) -> NotificationReplyDispatch {
        calls.append("dispatch")
        if let changeBeforeDispatch { tree = changeBeforeDispatch }
        do {
            let card = try NotificationReplyPlan.card(for: target, in: tree)!
            let field = try NotificationReplyPlan.editor(in: card)
            guard field.value == text else { return .notDispatched(.notificationChanged) }
            _ = try NotificationReplyPlan.action("Send", in: card)
        } catch let failure as NotificationReplyFailure { return .notDispatched(failure) }
        catch { return .notDispatched(.accessibilityUnavailable) }
        nativeSendCount += 1
        if uncertain { return .uncertain }
        if acknowledge { tree = .init(nodes: []) }
        return .accepted
    }
}
