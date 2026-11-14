import AppKit
import ApplicationServices

/// Uses only the public Accessibility API against Notification Center. It does not activate Messages,
/// resolve contacts, synthesize keys, or invoke another app's private notification service.
final class NativeNotificationReplyTransport: NotificationReplyTransport, @unchecked Sendable {
    private let worker = DispatchQueue(label: "com.lenotch.app.notification-reply", qos: .userInitiated)
    private static let centerID = "com.apple.notificationcenterui"

    func accessibilityTrusted() async -> Bool {
        // Read only. Permission requests belong exclusively to the explicit Setup action.
        (try? await onWorker { AXIsProcessTrusted() }) ?? false
    }

    func snapshot() async throws -> NotificationReplySnapshot {
        try await onWorker { try self.readTree(bundleID: Self.centerID).tree }
    }

    func revealNotificationCenter() async throws {
        try await onWorker {
            let read = try self.readTree(bundleID: "com.apple.controlcenter")
            let tree = read.tree
            let references = read.references
            guard tree.complete else { throw NotificationReplyFailure.timedOut }
            let clocks = tree.nodes.flatMap(\.all).filter {
                $0.identifier == "com.apple.menuextra.clock" && $0.role == "AXMenuBarItem" && $0.enabled
                    && $0.actions.contains(where: { $0.name == "AXPress" })
            }
            guard clocks.count == 1, let element = references[clocks[0].key] else {
                throw NotificationReplyFailure.notificationUnavailable
            }
            guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
                throw NotificationReplyFailure.accessibilityUnavailable
            }
        }
    }

    func openReply(for target: NotificationReplyTarget) async throws {
        try await onWorker {
            let read = try self.readTree(bundleID: Self.centerID)
            let tree = read.tree
            let references = read.references
            let card = try NotificationReplyPlan.card(for: target, in: tree)!
            guard NotificationReplyPlan.editors(in: card).isEmpty else { throw NotificationReplyFailure.existingDraft }
            let reply = try NotificationReplyPlan.action("Reply", in: card)
            guard let element = references[reply.node.key] else { throw NotificationReplyFailure.notificationChanged }
            guard AXUIElementPerformAction(element, reply.name as CFString) == .success else {
                throw NotificationReplyFailure.accessibilityUnavailable
            }
        }
    }

    func write(_ text: String, to target: NotificationReplyTarget) async throws {
        try await onWorker {
            let read = try self.readTree(bundleID: Self.centerID)
            let tree = read.tree
            let references = read.references
            let card = try NotificationReplyPlan.card(for: target, in: tree)!
            let field = try NotificationReplyPlan.editor(in: card)
            // Never replace an existing draft, even if its contents happen to match our text.
            guard field.value == "" else { throw NotificationReplyFailure.existingDraft }
            guard let element = references[field.key] else { throw NotificationReplyFailure.notificationChanged }
            guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success,
                  try self.stringAttribute(element, kAXValueAttribute as CFString) == text else {
                throw NotificationReplyFailure.unsupportedEditor
            }
        }
    }

    func dispatch(_ text: String, to target: NotificationReplyTarget) async -> NotificationReplyDispatch {
        do {
            return try await onWorker {
                let read = try self.readTree(bundleID: Self.centerID)
                let tree = read.tree
                let references = read.references
                let card = try NotificationReplyPlan.card(for: target, in: tree)!
                let field = try NotificationReplyPlan.editor(in: card)
                guard field.value == text else { return .notDispatched(.notificationChanged) }
                let send = try NotificationReplyPlan.action("Send", in: card)
                guard let element = references[send.node.key] else { return .notDispatched(.notificationChanged) }
                // No Return/AXConfirm fallback: only the exact Send action in the exact notification.
                let result = AXUIElementPerformAction(element, send.name as CFString)
                return result == .success ? .accepted : .uncertain
            }
        } catch let failure as NotificationReplyFailure { return .notDispatched(failure) }
        catch { return .notDispatched(.accessibilityUnavailable) }
    }

    private func onWorker<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private struct ReadTree {
        let tree: NotificationReplySnapshot
        let references: [String: AXUIElement]
    }

    private func readTree(bundleID: String) throws -> ReadTree {
        guard AXIsProcessTrusted() else { throw NotificationReplyFailure.accessibilityRequired }
        let processes = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard processes.count == 1, let process = processes.first else {
            throw NotificationReplyFailure.accessibilityUnavailable
        }
        let root = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.12)
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        var references: [String: AXUIElement] = [:]
        var visited: [AXUIElement] = []
        var complete = true

        func visit(_ element: AXUIElement, depth: Int) throws -> NotificationReplyAXNode? {
            guard depth <= 20, references.count < 1_200,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                complete = false
                return nil
            }
            if visited.contains(where: { CFEqual($0, element) }) { return nil }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, 0.12)
            var node = NotificationReplyAXNode()
            references[node.key] = element
            node.identifier = try self.stringAttribute(element, kAXIdentifierAttribute as CFString)
            node.role = try self.stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
            node.title = try self.stringAttribute(element, kAXTitleAttribute as CFString)
            node.detail = try self.stringAttribute(element, kAXDescriptionAttribute as CFString)
            node.value = try self.stringAttribute(element, kAXValueAttribute as CFString)
            node.enabled = try self.attribute(element, kAXEnabledAttribute as CFString) as? Bool ?? true
            if ["AXTextField", "AXTextArea"].contains(node.role) {
                var settable: DarwinBoolean = false
                let error = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
                try self.check(error)
                node.valueSettable = error == .success && settable.boolValue
            }
            var names: CFArray?
            let actionError = AXUIElementCopyActionNames(element, &names)
            try self.check(actionError)
            for name in (names as? [String] ?? []) {
                var label: CFString?
                let error = AXUIElementCopyActionDescription(element, name as CFString, &label)
                try self.check(error)
                node.actions.append(NotificationReplyAXAction(name: name, label: label as String?))
            }
            // Application windows and menu bars are not consistently present in AXChildren on all OS versions.
            var children = try self.attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
            if depth == 0 {
                children += try self.attribute(element, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
                if let menu = try self.attribute(element, kAXMenuBarAttribute as CFString),
                   CFGetTypeID(menu) == AXUIElementGetTypeID() {
                    children.append(unsafeDowncast(menu, to: AXUIElement.self))
                }
            }
            for child in children {
                if let childNode = try visit(child, depth: depth + 1) { node.children.append(childNode) }
                if !complete { break }
            }
            return node
        }

        let node = try visit(root, depth: 0)
        if ProcessInfo.processInfo.systemUptime >= deadline { complete = false }
        return ReadTree(tree: NotificationReplySnapshot(nodes: node.map { [$0] } ?? [], complete: complete), references: references)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: CFString) throws -> String? {
        try attribute(element, name) as? String
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        try check(error)
        return error == .success ? value : nil
    }

    private func check(_ error: AXError) throws {
        switch error {
        case .success, .attributeUnsupported, .actionUnsupported, .noValue, .notImplemented: break
        case .cannotComplete: throw NotificationReplyFailure.timedOut
        default: throw NotificationReplyFailure.accessibilityUnavailable
        }
    }
}
