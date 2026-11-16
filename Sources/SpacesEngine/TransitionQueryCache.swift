import Foundation
import QuartzCore

/// Main-thread cache for slow WindowServer reads. A frame never waits for a query.
final class TransitionQueryCache<Key: Hashable, Value> {
    typealias Schedule = (@escaping () -> Void) -> Void
    private struct Record {
        let value: Value
        let requestedAt: CFTimeInterval
    }
    private var records: [Key: Record] = [:]
    private var pending: Set<Key> = []
    private var lastRequest: [Key: CFTimeInterval] = [:]
    private var generation = 0
    private let worker: Schedule
    private let deliver: Schedule
    private let clock: () -> CFTimeInterval
    private let refreshInterval: CFTimeInterval
    private let maxAge: CFTimeInterval
    var onUpdate: (() -> Void)?

    init(refreshInterval: CFTimeInterval = 1.0 / 60, maxAge: CFTimeInterval = 0.5,
         worker: @escaping Schedule, deliver: @escaping Schedule = { DispatchQueue.main.async(execute: $0) },
         clock: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
        self.refreshInterval = refreshInterval
        self.maxAge = maxAge
        self.worker = worker
        self.deliver = deliver
        self.clock = clock
    }

    func seed(_ value: Value, for key: Key) {
        records[key] = Record(value: value, requestedAt: clock())
    }

    /// `after` rejects a reply to a query made before a native switch was posted.
    func value(for key: Key, after: CFTimeInterval = 0, fetch: @escaping () -> Value?) -> Value? {
        let now = clock()
        let record = records[key]
        if !pending.contains(key), lastRequest[key].map({ now - $0 >= refreshInterval }) ?? true {
            pending.insert(key)
            lastRequest[key] = now
            let generation = generation
            worker { [weak self] in
                let value = fetch()
                self?.deliver { [weak self] in
                    guard let self else { return }
                    self.pending.remove(key)
                    guard self.generation == generation else { return }
                    self.records[key] = value.map { Record(value: $0, requestedAt: now) }
                    self.onUpdate?()
                }
            }
        }
        guard let record, now - record.requestedAt <= maxAge, record.requestedAt >= after else { return nil }
        return record.value
    }

    func invalidate() {
        generation += 1
        records.removeAll()
        lastRequest.removeAll()
        // Keep pending reads registered until they actually finish. Turning the feature
        // off and on must not enqueue unlimited work behind a blocked WindowServer.
    }
}
