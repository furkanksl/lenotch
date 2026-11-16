import Foundation

/// macOS can stop drawing beneath an opaque fullscreen window after a long swipe. Match Interspace: remove that
/// window in one step instead of fading stale pixels into a black desktop.
enum TransitionHandoff {
    static func canFade(coveredFor duration: TimeInterval) -> Bool {
        duration >= 0 && duration < Config.fadeSafeTime
    }
}

/// A release must finish even if WindowServer never calls back with the requested screenshot. This deadline runs
/// independently of capture callbacks and the display link. Cancellation also invalidates already-queued callbacks.
final class TransitionCompletionDeadline {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void
    static let timeout: TimeInterval = 3
    private let schedule: Schedule
    private var token = UUID()
    private var cancelScheduled: (() -> Void)?

    init(schedule: @escaping Schedule = { delay, action in
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }) {
        self.schedule = schedule
    }

    func arm(_ action: @escaping () -> Void) {
        cancel()
        let ticket = token
        cancelScheduled = schedule(Self.timeout) { [weak self] in
            guard let self, self.token == ticket else { return }
            self.token = UUID()
            self.cancelScheduled = nil
            action()
        }
    }

    func cancel() {
        token = UUID()
        cancelScheduled?()
        cancelScheduled = nil
    }
}
