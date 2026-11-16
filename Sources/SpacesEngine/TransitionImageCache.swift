import Foundation

/// Main-thread request bookkeeping for background snapshot decoding. A Space can have at most one decode
/// in flight; a newer packed image waits for that worker rather than starting a second decode beside it.
final class TransitionImageUnpacker<Key: Hashable, Source, Image> {
    typealias Schedule = (@escaping () -> Void) -> Void
    private struct Request {
        let source: Source
        let decode: (Source) -> Image
        let completion: (Image) -> Void
    }
    private final class Job {
        let source: Source
        var completion: ((Image) -> Void)?
        var next: Request?

        init(_ request: Request) {
            source = request.source
            completion = request.completion
        }
    }

    private let worker: Schedule
    private let deliver: Schedule
    private let sameSource: (Source, Source) -> Bool
    private var jobs: [Key: Job] = [:]

    init(worker: @escaping Schedule, deliver: @escaping Schedule,
         sameSource: @escaping (Source, Source) -> Bool) {
        self.worker = worker
        self.deliver = deliver
        self.sameSource = sameSource
    }

    /// Never decodes synchronously. Repeated card lookups replace the waiter, not the worker.
    func request(_ key: Key, source: Source, decode: @escaping (Source) -> Image,
                 completion: @escaping (Image) -> Void) {
        let request = Request(source: source, decode: decode, completion: completion)
        if let job = jobs[key] {
            if sameSource(job.source, source) {
                job.completion = completion
                job.next = nil
            } else {
                job.completion = nil
                job.next = request
            }
            return
        }
        start(key, request)
    }

    private func start(_ key: Key, _ request: Request) {
        let job = Job(request)
        jobs[key] = job
        let deliver = deliver
        worker { [weak self] in
            let image = request.decode(request.source)
            deliver { [weak self] in
                guard let self, self.jobs[key] === job else { return }
                self.jobs[key] = nil
                if let next = job.next { self.start(key, next) }
                else { job.completion?(image) }
            }
        }
    }

    /// A finished transition cannot repaint a later one. Keep workers tracked so a rapid reopen can
    /// attach a fresh waiter to the same decode instead of duplicating full-resolution image work.
    func invalidateCallbacks() {
        for job in jobs.values { job.completion = nil; job.next = nil }
    }

    /// Shutdown/cache replacement also retires worker identities; late deliveries become no-ops.
    func removeAll() {
        invalidateCallbacks()
        jobs.removeAll()
    }
}
