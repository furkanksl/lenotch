import CryptoKit
import Foundation
import IslandCore

/// A notification reply is submitted through the originating app's native Notification Center action.
/// This is not a messaging client: no recipient lookup, chat database, clipboard or global keystrokes.
/// `.submitted` confirms the native action and its UI acknowledgement, never network delivery.
enum NotificationReplyResult: Equatable, Sendable {
    case submitted
    case failed(NotificationReplyFailure)
}

struct NotificationReplySubmission: Equatable, Sendable {
    let displayMessage = "Submitted through macOS. Delivery isn’t confirmed."
}

enum NotificationReplyAvailability: Equatable, Sendable {
    /// The app/record is eligible and Accessibility is already granted. The native action is checked on Send.
    case ready
    case requiresAccessibility
    case unavailable(NotificationReplyFailure)
}

enum NotificationReplyFailure: String, Error, Equatable, Sendable, LocalizedError {
    case unsupportedApp, invalidNotification, staleNotification, emptyMessage, messageTooLong
    case accessibilityRequired, accessibilityUnavailable, notificationUnavailable, notificationChanged
    case ambiguousNotification, unsupportedReply, unsupportedEditor, unsupportedSend, existingDraft
    case busy, cancelled, timedOut, alreadyAttempted, attemptReused, submissionUnconfirmed

    var errorDescription: String? {
        switch self {
        case .unsupportedApp: "Inline reply is only available for Messages and the native WhatsApp app."
        case .invalidNotification: "This notification has no stable reply target. Open the app to reply."
        case .staleNotification: "This notification is too old to reply safely. Open the app to reply."
        case .emptyMessage: "Write a message first."
        case .messageTooLong: "This reply is too long. Open the app to send it."
        case .accessibilityRequired: "Enable Accessibility in Setup to use native notification replies."
        case .accessibilityUnavailable: "macOS could not expose notification controls. Open the app to reply."
        case .notificationUnavailable: "The original notification is no longer available. Open the app to reply."
        case .notificationChanged: "The notification changed. Open the app to check the conversation."
        case .ambiguousNotification: "More than one reply target matched. Open the app to reply safely."
        case .unsupportedReply: "macOS does not expose a supported Reply action here. Open the app to reply."
        case .unsupportedEditor: "macOS did not expose a unique reply field. Open the app to reply."
        case .unsupportedSend: "macOS did not expose a unique Send button. Open the app to reply."
        case .existingDraft: "There is already a draft in this notification. Open Notification Center to review it."
        case .busy: "Another notification reply is in progress."
        case .cancelled: "Reply cancelled before submission."
        case .timedOut: "Notification controls did not respond in time. Open the app to reply."
        case .alreadyAttempted: "This notification has already been submitted. Check the app before sending again."
        case .attemptReused: "This reply attempt was already used for another message. Open the app to reply."
        case .submissionUnconfirmed: "macOS may have submitted this reply. Check the app before sending again."
        }
    }
}

struct NotificationReplyRequest: Sendable {
    /// Keep this ID unchanged when retrying the same explicit Send operation.
    let attemptID: UUID
    let notice: Notice
    let text: String

    init(attemptID: UUID = UUID(), notice: Notice, text: String) {
        self.attemptID = attemptID
        self.notice = notice
        self.text = text
    }
}

/// Immutable binding from NotificationStore's app+record UUID to the native notification.
/// A display name or thread name is deliberately insufficient to construct a target.
struct NotificationReplyTarget: Equatable, Sendable {
    let uuid: String
    let app: String
    let title: String
    let subtitle: String?
    let body: String

    static let supportedApps: Set<String> = ["com.apple.MobileSMS", "net.whatsapp.WhatsApp"]

    init(_ notice: Notice, now: Date) throws {
        guard Self.supportedApps.contains(notice.app) else { throw NotificationReplyFailure.unsupportedApp }
        guard let uuid = Self.canonicalUUID(notice.id, recordID: true),
              let title = notice.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let body = notice.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotificationReplyFailure.invalidNotification
        }
        let age = now.timeIntervalSince(notice.date)
        guard age >= -30, age <= 15 * 60 else { throw NotificationReplyFailure.staleNotification }
        self.uuid = uuid
        app = notice.app
        self.title = title
        subtitle = notice.subtitle?.isEmpty == false ? notice.subtitle : nil
        self.body = body
    }

    static func canonicalUUID(_ identifier: String, recordID: Bool = false) -> String? {
        let raw = recordID && identifier.hasPrefix("nc:") ? String(identifier.dropFirst(3)) : identifier
        let hex = raw.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }) else { return nil }
        // Accept only the UUID's standard spelling or its exact 32-character database spelling.
        if raw.count != 32, UUID(uuidString: raw) == nil { return nil }
        return hex.lowercased()
    }
}

enum NotificationReplyDispatch: Sendable {
    case accepted
    case notDispatched(NotificationReplyFailure)
    /// An AX timeout/error after invoking Send is not proof that the app did not receive it.
    case uncertain
}

protocol NotificationReplyTransport: Sendable {
    func accessibilityTrusted() async -> Bool
    func snapshot() async throws -> NotificationReplySnapshot
    func revealNotificationCenter() async throws
    /// Every mutation must take a fresh snapshot and validate `target` again, on the transport's worker.
    func openReply(for target: NotificationReplyTarget) async throws
    func write(_ text: String, to target: NotificationReplyTarget) async throws
    func dispatch(_ text: String, to target: NotificationReplyTarget) async -> NotificationReplyDispatch
}

/// One service per app session. Submissions are serialized across awaits; availability only reads trust.
/// Call `send`/`submit` only from an explicit user Send action, never from onAppear or availability checks.
actor NotificationReplyService {
    private let transport: any NotificationReplyTransport
    private let now: @Sendable () -> Date
    private let pause: @Sendable () async throws -> Void
    private var working = false
    private var consumedTargets: Set<String> = []
    private struct Attempt {
        let fingerprint: Data
        let result: NotificationReplyResult
    }
    private var attempts: [UUID: Attempt] = [:]

    init(transport: any NotificationReplyTransport = NativeNotificationReplyTransport(),
         now: @escaping @Sendable () -> Date = { Date() },
         pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(80)) }) {
        self.transport = transport
        self.now = now
        self.pause = pause
    }

    nonisolated static func supports(_ notice: Notice) -> Bool {
        NotificationReplyTarget.supportedApps.contains(notice.app)
    }

    /// Never requests permission, opens Notification Center, or changes the focused app.
    func availability(for notice: Notice) async -> NotificationReplyAvailability {
        do { _ = try NotificationReplyTarget(notice, now: now()) }
        catch let failure as NotificationReplyFailure { return .unavailable(failure) }
        catch { return .unavailable(.invalidNotification) }
        return await transport.accessibilityTrusted() ? .ready : .requiresAccessibility
    }

    func send(_ text: String, to notice: Notice, attemptID: UUID = UUID()) async -> NotificationReplyResult {
        await submit(NotificationReplyRequest(attemptID: attemptID, notice: notice, text: text))
    }

    /// Convenience API for the notification composer. Catch LocalizedError and retain the user's draft.
    func send(text: String, to notice: Notice) async throws -> NotificationReplySubmission {
        switch await send(text, to: notice) {
        case .submitted: return NotificationReplySubmission()
        case let .failed(failure): throw failure
        }
    }

    func submit(_ request: NotificationReplyRequest) async -> NotificationReplyResult {
        guard !working else { return .failed(.busy) }
        let target: NotificationReplyTarget
        do { target = try NotificationReplyTarget(request.notice, now: now()) }
        catch let failure as NotificationReplyFailure { return .failed(failure) }
        catch { return .failed(.invalidNotification) }
        // Preserve the user's exact text. Only use trimming to reject an empty reply.
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failed(.emptyMessage) }
        guard request.text.utf8.count <= 16_384 else { return .failed(.messageTooLong) }
        if let attempt = attempts[request.attemptID] {
            return attempt.fingerprint == fingerprint(target, text: request.text) ? attempt.result : .failed(.attemptReused)
        }
        guard !consumedTargets.contains(target.uuid) else { return .failed(.alreadyAttempted) }
        working = true
        defer { working = false }
        guard await transport.accessibilityTrusted() else { return .failed(.accessibilityRequired) }

        do {
            try Task.checkCancellation()
            var tree = try await transport.snapshot()
            if try NotificationReplyPlan.card(for: target, in: tree, allowMissing: true) == nil {
                // Opening the system panel is allowed only here, after the user's explicit Send.
                try await transport.revealNotificationCenter()
                tree = try await waitForCard(target)
            }
            let card = try NotificationReplyPlan.card(for: target, in: tree)!
            let editors = NotificationReplyPlan.editors(in: card)
            if editors.isEmpty {
                try Task.checkCancellation()
                try await transport.openReply(for: target)
            } else {
                guard editors.count == 1 else { throw NotificationReplyFailure.unsupportedEditor }
                // An already open, empty native field is safe; never replace an existing draft.
                guard editors[0].value == "" else { throw NotificationReplyFailure.existingDraft }
            }
            _ = try await waitForEditor(target)
            try Task.checkCancellation()
            try await transport.write(request.text, to: target)
            try Task.checkCancellation()
            switch await transport.dispatch(request.text, to: target) {
            case let .notDispatched(failure): return .failed(failure)
            case .uncertain:
                return record(.failed(.submissionUnconfirmed), request: request, target: target)
            case .accepted:
                // Past this point, cancellation/timeouts must never turn into a retryable failure.
                let acknowledged = await waitForAcknowledgement(target)
                return record(acknowledged ? .submitted : .failed(.submissionUnconfirmed), request: request, target: target)
            }
        } catch is CancellationError { return .failed(.cancelled) }
        catch let failure as NotificationReplyFailure { return .failed(failure) }
        catch { return .failed(.accessibilityUnavailable) }
    }

    private func record(_ result: NotificationReplyResult, request: NotificationReplyRequest,
                        target: NotificationReplyTarget) -> NotificationReplyResult {
        consumedTargets.insert(target.uuid)
        // Keep only UUIDs and digests, never message/draft plaintext. Nothing is logged or persisted.
        // Never evict consumed UUIDs during this process and risk a duplicate send.
        attempts[request.attemptID] = Attempt(fingerprint: fingerprint(target, text: request.text), result: result)
        return result
    }

    private func fingerprint(_ target: NotificationReplyTarget, text: String) -> Data {
        var data = Data()
        for value in [target.uuid, target.app, target.title, target.subtitle ?? "", target.body, text] {
            data.append(contentsOf: "\(value.utf8.count):".utf8)
            data.append(contentsOf: value.utf8)
        }
        return Data(SHA256.hash(data: data))
    }

    private func waitForCard(_ target: NotificationReplyTarget) async throws -> NotificationReplySnapshot {
        for _ in 0..<6 {
            try Task.checkCancellation()
            let tree = try await transport.snapshot()
            if try NotificationReplyPlan.card(for: target, in: tree, allowMissing: true) != nil { return tree }
            try await pause()
        }
        throw NotificationReplyFailure.notificationUnavailable
    }

    private func waitForEditor(_ target: NotificationReplyTarget) async throws -> NotificationReplySnapshot {
        for _ in 0..<8 {
            try Task.checkCancellation()
            let tree = try await transport.snapshot()
            let card = try NotificationReplyPlan.card(for: target, in: tree)!
            let editors = NotificationReplyPlan.editors(in: card)
            if editors.count > 1 { throw NotificationReplyFailure.unsupportedEditor }
            if let editor = editors.first {
                guard editor.value?.isEmpty != false else { throw NotificationReplyFailure.existingDraft }
                return tree
            }
            try await pause()
        }
        throw NotificationReplyFailure.unsupportedEditor
    }

    private func waitForAcknowledgement(_ target: NotificationReplyTarget) async -> Bool {
        for _ in 0..<8 {
            do {
                let tree = try await transport.snapshot()
                guard tree.complete else { return false }
                let matches = tree.nodes.flatMap(\.all).filter {
                    NotificationReplyTarget.canonicalUUID($0.identifier ?? "") == target.uuid
                }
                if matches.isEmpty { return true } // The exact card was removed after native Send succeeded.
                guard matches.count == 1 else { return false }
                let editors = NotificationReplyPlan.editors(in: matches[0])
                if editors.count == 1, editors[0].value == "" { return true }
                try await pause()
            } catch { return false }
        }
        return false
    }
}

// Value-only AX fixtures. No live process, message database, or UI interaction is needed to test routing.
struct NotificationReplyAXAction: Equatable, Sendable {
    let name: String
    var label: String? = nil
}

struct NotificationReplyAXNode: Equatable, Sendable {
    var key = UUID().uuidString
    var identifier: String? = nil
    var role = "AXGroup"
    var title: String? = nil
    var detail: String? = nil
    var value: String? = nil
    var enabled = true
    var valueSettable = false
    var actions: [NotificationReplyAXAction] = []
    var children: [NotificationReplyAXNode] = []
    var all: [NotificationReplyAXNode] { [self] + children.flatMap(\.all) }
}

struct NotificationReplySnapshot: Sendable {
    var nodes: [NotificationReplyAXNode]
    var complete = true
}

enum NotificationReplyPlan {
    struct Action: Sendable {
        let node: NotificationReplyAXNode
        let name: String
    }

    static func card(for target: NotificationReplyTarget, in tree: NotificationReplySnapshot,
                     allowMissing: Bool = false) throws -> NotificationReplyAXNode? {
        guard tree.complete else { throw NotificationReplyFailure.timedOut }
        let matches = tree.nodes.flatMap(\.all).filter {
            NotificationReplyTarget.canonicalUUID($0.identifier ?? "") == target.uuid
        }
        guard matches.count <= 1 else { throw NotificationReplyFailure.ambiguousNotification }
        guard let card = matches.first else {
            if allowMissing { return nil }
            throw NotificationReplyFailure.notificationUnavailable
        }
        guard card.enabled else { throw NotificationReplyFailure.notificationUnavailable }
        // A group containing other records is not an exact reply target, even when its first child matches.
        guard !card.children.flatMap(\.all).contains(where: {
            guard let uuid = NotificationReplyTarget.canonicalUUID($0.identifier ?? "") else { return false }
            return uuid != target.uuid
        }) else { throw NotificationReplyFailure.ambiguousNotification }
        // A reply field or action label must never supply the identity/content evidence for its own target.
        let strings = Set(card.all.filter {
            !["AXTextField", "AXTextArea", "AXButton"].contains($0.role)
        }.flatMap { [$0.title, $0.detail, $0.value].compactMap { $0 } })
        guard strings.contains(target.title), strings.contains(target.body),
              target.subtitle.map({ strings.contains($0) }) ?? true else {
            throw NotificationReplyFailure.notificationChanged
        }
        return card
    }

    static func editors(in card: NotificationReplyAXNode) -> [NotificationReplyAXNode] {
        card.all.filter { ["AXTextField", "AXTextArea"].contains($0.role) && $0.valueSettable && $0.enabled }
    }

    static func editor(in card: NotificationReplyAXNode) throws -> NotificationReplyAXNode {
        let fields = editors(in: card)
        guard fields.count == 1 else { throw NotificationReplyFailure.unsupportedEditor }
        return fields[0]
    }

    /// The UUID is the stable identifier. Reply/Send identifiers are undocumented; do not invent any.
    /// Use the exact native AX action description, or a labelled native button with AXPress.
    /// Unknown/localized descriptions deliberately fail closed until supported and fixture-tested.
    static func action(_ label: String, in card: NotificationReplyAXNode) throws -> Action {
        var matches: [Action] = []
        for node in card.all where node.enabled {
            for action in node.actions {
                let labelledButton = node.role == "AXButton" && action.name == "AXPress"
                    && (node.title == label || node.detail == label)
                let describedAction = action.label == label || action.name == label
                if labelledButton || describedAction { matches.append(Action(node: node, name: action.name)) }
            }
        }
        guard matches.count == 1 else {
            throw label == "Reply" ? NotificationReplyFailure.unsupportedReply : NotificationReplyFailure.unsupportedSend
        }
        return matches[0]
    }
}
