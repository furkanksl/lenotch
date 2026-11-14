import Foundation
import IslandCore
import Observation

/// A bounded, session-only view of Notification Center. Message contents never go to UserDefaults.
@MainActor @Observable
final class NotificationInbox {
    static let capacity = 40
    private(set) var items: [Notice] = []
    private(set) var selectedID: String?
    var expanded = false
    var composing = false
    var draft = ""
    var feedback: String?
    var submitting = false
    @ObservationIgnored private var dismissed: Set<String> = []
    private var replyTarget: Notice?

    var selected: Notice? {
        if let replyTarget, replyTarget.id == selectedID { return replyTarget }
        return items.first { $0.id == selectedID } ?? items.first
    }

    func receive(_ notice: Notice) {
        guard !dismissed.contains(notice.id) else { return }
        items.removeAll { $0.id == notice.id }
        items.append(notice)
        items.sort { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
        while items.count > Self.capacity {
            let index = items.lastIndex { !composing || $0.id != selectedID } ?? items.count - 1
            items.remove(at: index)
        }
        if selectedID == nil { selectedID = items.first?.id }
    }

    /// Notification Center retains historical records; a snapshot is not an unread list.
    /// Admit only live arrivals. Later snapshots may update or remove those entries, never backfill history.
    func synchronize(_ snapshot: [Notice], arrived: [Notice] = []) {
        let tracked = Set(items.map(\.id))
        let incoming = Set(arrived.map(\.id))
        let available = Set(snapshot.map(\.id))
        dismissed.formIntersection(available)
        items.removeAll { !available.contains($0.id) }
        for notice in snapshot where tracked.contains(notice.id) || incoming.contains(notice.id) {
            receive(notice)
        }
        if let selectedID, !items.contains(where: { $0.id == selectedID }) {
            // Native Send commonly removes its source notification. Keep its exact target and outcome visible.
            if replyTarget?.id == selectedID { return }
            self.selectedID = items.first?.id
            cancelComposition()
        }
    }

    @discardableResult func select(_ notice: Notice) -> Bool {
        guard !submitting, items.contains(notice) else { return false }
        if selectedID != notice.id { cancelComposition() }
        replyTarget = nil
        selectedID = notice.id
        return true
    }

    func beginReply(to notice: Notice) {
        guard select(notice) else { return }
        expanded = false
        composing = true
        feedback = nil
    }

    func beginSubmission() -> Notice? {
        guard composing, !submitting, let target = selected, items.contains(target) else { return nil }
        replyTarget = target
        submitting = true
        feedback = nil
        return target
    }

    func cancelComposition() {
        guard !submitting else { return }
        composing = false
        draft = ""
        feedback = nil
        replyTarget = nil
    }

    func dismiss(_ id: String) {
        guard !submitting else { return }
        dismissed.insert(id)
        items.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = items.first?.id
            cancelComposition()
        }
    }

    func clear() {
        guard !submitting else { return }
        dismissed.formUnion(items.map(\.id))
        items.removeAll()
        selectedID = nil
        expanded = false
        cancelComposition()
    }
}
