import Foundation

/// Main-queue request ownership. The deadline includes metadata discovery, not just the screenshot.
/// Retiring before calling clients permits a failed/timed-out request to be retried immediately.
final class CaptureRequestLifecycle<Key: Hashable, Value> {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void
    static var timeout: TimeInterval { 2 }

    private final class Request {
        let ticket = UUID()
        var callbacks: [(Value?) -> Void]
        var cancelDeadline: (() -> Void)?
        init(_ completion: @escaping (Value?) -> Void) { callbacks = [completion] }
    }

    private let schedule: Schedule
    private let onRetire: (Key, UUID) -> Void
    private var requests: [Key: Request] = [:]
    private var cancelled = false

    init(schedule: @escaping Schedule = { delay, action in
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }, onRetire: @escaping (Key, UUID) -> Void = { _, _ in }) {
        self.schedule = schedule
        self.onRetire = onRetire
    }

    /// nil means either coalesced into an existing request or terminally cancelled.
    func begin(_ key: Key, completion: @escaping (Value?) -> Void) -> UUID? {
        guard !cancelled else { return nil }
        if let request = requests[key] {
            request.callbacks.append(completion)
            return nil
        }
        let request = Request(completion)
        requests[key] = request
        let ticket = request.ticket
        request.cancelDeadline = schedule(Self.timeout) { [weak self] in
            self?.finish(key, ticket: ticket, value: nil)
        }
        return ticket
    }

    func contains(_ key: Key, ticket: UUID) -> Bool {
        !cancelled && requests[key]?.ticket == ticket
    }

    func finish(_ key: Key, ticket: UUID, value: Value?) {
        guard contains(key, ticket: ticket), let request = requests.removeValue(forKey: key) else { return }
        request.cancelDeadline?()
        onRetire(key, ticket)
        for callback in request.callbacks {
            guard !cancelled else { break }
            callback(value)
        }
    }

    /// Do not invoke clients while tearing down the engine, including already queued callbacks.
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        let retired = requests
        requests.removeAll()
        for (key, request) in retired {
            request.cancelDeadline?()
            onRetire(key, request.ticket)
        }
    }
}

/// Filter individual windows, not their application: the Dock also owns desktop wallpaper.
enum CaptureWindowPolicy {
    static func excludes(layer: Int, ownerPID: pid_t?, ownPID: pid_t, below layerLimit: Int) -> Bool {
        ownerPID == ownPID || layer >= layerLimit
    }
}
