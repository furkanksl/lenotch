import Foundation
import XCTest
@testable import Lenotch

@MainActor
final class ChatGPTVoiceWorkTests: XCTestCase {
    func testAccumulatesFragmentsButReturnsOnlyAfterSuccessfulDone() async throws {
        let (work, factory) = worker()
        defer { work.cancel() }
        let run = VoiceWorkRun(work, "Check today's forecast")
        await settle()
        let backend = try XCTUnwrap(factory.backends.first)

        backend.emit(.delta("  The forecast "))
        backend.emit(.delta("is sunny."))
        await settle()
        XCTAssertNil(run.result, "A partial response is not a completed delegated task")

        backend.emit(.done(error: nil))
        await settle()
        XCTAssertEqual(run.answer, "The forecast is sunny.")
        XCTAssertEqual(backend.stops, 0)
        let question = try XCTUnwrap(backend.questions.first)
        XCTAssertTrue(question.contains("Use web_search"))
        XCTAssertTrue(question.contains("cannot run commands"))
        XCTAssertTrue(question.hasSuffix("Check today's forecast"))
    }

    func testSynchronousAskCompletionDoesNotLoseTheContinuation() async {
        let (work, factory) = worker()
        factory.eventsOnAsk = [.delta("A complete answer."), .done(error: nil)]
        defer { work.cancel() }

        let run = VoiceWorkRun(work)
        await settle()
        XCTAssertEqual(run.answer, "A complete answer.")
        XCTAssertEqual(factory.backends.count, 1)
    }

    func testToolStatusesUseActualTitlesWithWhitespaceFallbackAndCharacterLimit() async throws {
        let (work, factory) = worker()
        defer { work.cancel() }
        var statuses: [String] = []
        work.onStatus = { statuses.append($0) }
        let run = VoiceWorkRun(work)
        await settle()
        let backend = try XCTUnwrap(factory.backends.first)

        backend.emit(.tool("Searching the web"))
        backend.emit(.tool("  Reading\n\tsources  "))
        backend.emit(.tool(" \n\t "))
        backend.emit(.tool(String(repeating: "👩🏽‍💻", count: 130)))
        XCTAssertEqual(Array(statuses.prefix(4)), ["Thinking", "Searching the web", "Reading sources", "Working"])
        XCTAssertEqual(statuses.last, String(repeating: "👩🏽‍💻", count: 120))
        backend.emit(.tool("WebSearch"))
        backend.emit(.tool("WebFetch"))
        backend.emit(.tool("WebFind"))
        XCTAssertEqual(Array(statuses.suffix(3)), ["Searching the web", "Reading a web page", "Checking a web page"])
        XCTAssertNil(run.result)

        backend.emit(.delta("Done."))
        backend.emit(.done(error: nil))
        await settle()
        XCTAssertEqual(run.answer, "Done.")
    }

    func testBackendErrorDiscardsPartialAnswerAndLateEventsCannotFinishNextTask() async throws {
        let (work, factory) = worker()
        defer { work.cancel() }
        var statuses: [String] = []
        work.onStatus = { statuses.append($0) }
        let first = VoiceWorkRun(work)
        await settle()
        let old = try XCTUnwrap(factory.backends.first)
        old.emit(.delta("Unfinished research"))
        old.emit(.done(error: "Server debug detail with private credentials"))
        await settle()
        let error = try XCTUnwrap(first.error as? any LocalizedError)
        XCTAssertTrue(error.errorDescription?.contains("couldn't complete") == true)
        XCTAssertFalse(error.localizedDescription.contains("private credentials"))
        XCTAssertNil(first.answer)
        XCTAssertEqual(old.stops, 1)

        let second = VoiceWorkRun(work, "A different task")
        await settle()
        XCTAssertEqual(factory.backends.count, 2)
        let current = try XCTUnwrap(factory.backends.last)
        let beforeLateEvents = statuses
        old.emit(.delta("Stale reply"))
        old.emit(.tool("Stale status"))
        old.emit(.done(error: nil))
        await settle()
        XCTAssertNil(second.result)
        XCTAssertEqual(statuses, beforeLateEvents)

        current.emit(.delta("Fresh reply"))
        current.emit(.done(error: nil))
        await settle()
        XCTAssertEqual(second.answer, "Fresh reply")
    }

    func testCancelStopsBackendAndInvalidatesSynchronousAndLateCompletion() async throws {
        let (work, factory) = worker()
        factory.eventsOnStop = [.delta("Stopped reply"), .done(error: nil)]
        defer { work.cancel() }
        let first = VoiceWorkRun(work)
        await settle()
        let old = try XCTUnwrap(factory.backends.first)

        work.cancel()
        work.cancel()
        await settle()
        XCTAssertTrue(first.error is CancellationError)
        XCTAssertEqual(old.stops, 1, "Repeated cancellation must not stop the old backend twice")

        let second = VoiceWorkRun(work)
        await settle()
        let current = try XCTUnwrap(factory.backends.last)
        XCTAssertFalse(current === old)
        current.emit(.delta("Current "))
        old.emit(.delta("stale"))
        old.emit(.done(error: "Late failure"))
        old.emit(.done(error: nil))
        await settle()
        XCTAssertNil(second.result)
        current.emit(.delta("answer"))
        current.emit(.done(error: nil))
        await settle()
        XCTAssertEqual(second.answer, "Current answer")
    }

    func testTaskCancellationStopsBackendAndResumesCaller() async throws {
        let (work, factory) = worker()
        defer { work.cancel() }
        let run = VoiceWorkRun(work)
        await settle()
        let backend = try XCTUnwrap(factory.backends.first)

        run.cancel()
        await settle()
        XCTAssertTrue(run.error is CancellationError)
        XCTAssertEqual(backend.stops, 1)
        backend.emit(.delta("Too late"))
        backend.emit(.done(error: nil))
        await settle()
        XCTAssertTrue(run.error is CancellationError)
    }

    func testStartingAnotherTaskCancelsTheFirstAndRejectsItsLateCompletion() async throws {
        let (work, factory) = worker()
        defer { work.cancel() }
        let first = VoiceWorkRun(work)
        await settle()
        let old = try XCTUnwrap(factory.backends.first)

        let second = VoiceWorkRun(work)
        await settle()
        XCTAssertTrue(first.error is CancellationError)
        XCTAssertEqual(old.stops, 1)
        XCTAssertEqual(factory.backends.count, 2)
        old.emit(.delta("Old result"))
        old.emit(.done(error: nil))
        await settle()
        XCTAssertNil(second.result)

        let current = try XCTUnwrap(factory.backends.last)
        current.emit(.delta("New result"))
        current.emit(.done(error: nil))
        await settle()
        XCTAssertEqual(second.answer, "New result")
    }

    func testSuccessiveSuccessfulHandoffsReuseBackendButNotReplyOrSources() async throws {
        let (work, factory) = worker()
        defer { work.cancel() }
        let first = VoiceWorkRun(work, "Find the launch date")
        await settle()
        let backend = try XCTUnwrap(factory.backends.first)
        let citation = source(1)
        backend.emit(.delta("It launches tomorrow."))
        backend.emit(.sources([citation]))
        backend.emit(.done(error: nil))
        await settle()
        XCTAssertTrue(first.answer?.contains(citation.url.absoluteString) == true)

        let second = VoiceWorkRun(work, "What did you find?")
        await settle()
        XCTAssertEqual(factory.backends.count, 1, "The same chat must retain context across successful tasks")
        XCTAssertEqual(backend.questions.count, 2)
        XCTAssertTrue(backend.questions[0].hasSuffix("Find the launch date"))
        XCTAssertTrue(backend.questions[1].hasSuffix("What did you find?"))
        XCTAssertEqual(backend.stops, 0)
        backend.emit(.delta("Tomorrow."))
        backend.emit(.done(error: nil))
        await settle()
        XCTAssertEqual(second.answer, "Tomorrow.")
    }

    func testSourcesAreDeduplicatedBoundedAndNotRepeatedWhenAlreadyInAnswer() async throws {
        let (work, factory) = worker()
        defer { work.cancel() }
        let run = VoiceWorkRun(work)
        await settle()
        let backend = try XCTUnwrap(factory.backends.first)
        let sources = (1...7).map(source)
        let included = sources[0].url.absoluteString
        backend.emit(.delta("Read \(included) for the details."))
        backend.emit(.sources([sources[0], sources[0], sources[1]]))
        backend.emit(.sources(Array(sources.dropFirst())))
        XCTAssertNil(run.result, "Citations alone must not finish the task")
        backend.emit(.done(error: nil))
        await settle()

        let answer = try XCTUnwrap(run.answer)
        for source in sources.prefix(5) {
            XCTAssertEqual(answer.components(separatedBy: source.url.absoluteString).count - 1, 1)
        }
        for source in sources.suffix(2) {
            XCTAssertFalse(answer.contains(source.url.absoluteString))
        }
    }

    func testOutputLimitCountsUnicodeCharactersAndAcceptsExactBoundary() async throws {
        let (work, factory) = worker()
        defer { work.cancel() }
        let run = VoiceWorkRun(work)
        await settle()
        let backend = try XCTUnwrap(factory.backends.first)
        let answer = String(repeating: "e\u{301}", count: 24_000)
        XCTAssertGreaterThan(answer.utf8.count, 24_000)
        backend.emit(.delta(String(answer.prefix(12_000))))
        backend.emit(.delta(String(answer.suffix(12_000))))
        XCTAssertNil(run.result)
        backend.emit(.done(error: nil))
        await settle()
        XCTAssertEqual(run.answer, answer)
        XCTAssertEqual(backend.stops, 0)
    }

    func testOversizedStreamFailsBeforeDoneAndStopsBackend() async throws {
        let (work, factory) = worker()
        defer { work.cancel() }
        let run = VoiceWorkRun(work)
        await settle()
        let backend = try XCTUnwrap(factory.backends.first)
        backend.emit(.delta(String(repeating: "x", count: 24_000)))
        backend.emit(.delta("x"))
        await settle()
        XCTAssertTrue(run.error?.localizedDescription.contains("too long") == true)
        XCTAssertNil(run.answer)
        XCTAssertEqual(backend.stops, 1)
    }

    func testAppendedSourcesCannotExceedOutputLimit() async throws {
        let (work, factory) = worker()
        defer { work.cancel() }
        let run = VoiceWorkRun(work)
        await settle()
        let backend = try XCTUnwrap(factory.backends.first)
        backend.emit(.delta(String(repeating: "x", count: 24_000)))
        backend.emit(.sources([source(1)]))
        backend.emit(.done(error: nil))
        await settle()
        XCTAssertTrue(run.error?.localizedDescription.contains("too long") == true)
        XCTAssertNil(run.answer)
        XCTAssertEqual(backend.stops, 1)
    }

    func testEmptyAnswerFailsInsteadOfReturningProgressOrSources() async throws {
        let (work, factory) = worker()
        defer { work.cancel() }
        let run = VoiceWorkRun(work)
        await settle()
        let backend = try XCTUnwrap(factory.backends.first)
        backend.emit(.tool("Searching"))
        backend.emit(.delta(" \n\t "))
        backend.emit(.sources([source(1)]))
        backend.emit(.done(error: nil))
        await settle()
        XCTAssertTrue(run.error?.localizedDescription.contains("without an answer") == true)
        XCTAssertNil(run.answer)
        XCTAssertEqual(backend.stops, 1)
    }

    func testEmptyAndAlreadyCancelledTasksNeverCreateBackend() async {
        let (work, factory) = worker()
        defer { work.cancel() }
        let empty = VoiceWorkRun(work, " \n\t ")
        await settle()
        XCTAssertNotNil(empty.error as? any LocalizedError)
        XCTAssertTrue(factory.backends.isEmpty)

        let cancelled = VoiceWorkRun(work)
        cancelled.cancel()
        await settle()
        XCTAssertTrue(cancelled.error is CancellationError)
        XCTAssertTrue(factory.backends.isEmpty)
    }

    func testSynchronousFactoryFailureStopsReturnedBackendAndDoesNotReuseIt() async throws {
        let (work, factory) = worker()
        factory.eventsOnCreate = [.done(error: "Startup failure")]
        defer { work.cancel() }
        let first = VoiceWorkRun(work)
        await settle()
        let old = try XCTUnwrap(factory.backends.first)
        XCTAssertNotNil(first.error)
        XCTAssertEqual(old.stops, 1)
        XCTAssertTrue(old.questions.isEmpty)

        factory.eventsOnCreate = []
        factory.eventsOnAsk = [.delta("Recovered."), .done(error: nil)]
        let second = VoiceWorkRun(work)
        await settle()
        XCTAssertEqual(factory.backends.count, 2)
        XCTAssertEqual(second.answer, "Recovered.")
    }

    func testCancellationFromInitialStatusDoesNotStartAnAsk() async throws {
        let (work, factory) = worker()
        defer { work.cancel() }
        work.onStatus = { [weak work] _ in work?.cancel() }
        let run = VoiceWorkRun(work)
        await settle()
        let backend = try XCTUnwrap(factory.backends.first)
        XCTAssertTrue(run.error is CancellationError)
        XCTAssertTrue(backend.questions.isEmpty)
        XCTAssertEqual(backend.stops, 1)
    }

    private func worker() -> (ChatGPTVoiceWork, VoiceWorkBackendFactory) {
        let factory = VoiceWorkBackendFactory()
        return (ChatGPTVoiceWork(makeChat: factory.make), factory)
    }

    private func source(_ index: Int) -> WebSource {
        WebSource(title: "Source \(index)", url: URL(string: "https://example.com/source/\(index)")!)
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }
}

@MainActor
private final class VoiceWorkBackendFactory {
    var backends: [VoiceWorkBackendStub] = []
    var eventsOnCreate: [QuickAsk.Event] = []
    var eventsOnAsk: [QuickAsk.Event] = []
    var eventsOnStop: [QuickAsk.Event] = []

    func make(emit: @escaping @MainActor (QuickAsk.Event) -> Void) -> any ChatGPTVoiceWorkBackend {
        let backend = VoiceWorkBackendStub(emit: emit)
        backend.eventsOnAsk = eventsOnAsk
        backend.eventsOnStop = eventsOnStop
        backends.append(backend)
        for event in eventsOnCreate { emit(event) }
        return backend
    }
}

@MainActor
private final class VoiceWorkBackendStub: ChatGPTVoiceWorkBackend {
    let emit: @MainActor (QuickAsk.Event) -> Void
    var questions: [String] = []
    var stops = 0
    var eventsOnAsk: [QuickAsk.Event] = []
    var eventsOnStop: [QuickAsk.Event] = []

    init(emit: @escaping @MainActor (QuickAsk.Event) -> Void) { self.emit = emit }

    func ask(_ question: String) {
        questions.append(question)
        for event in eventsOnAsk { emit(event) }
    }

    func stop() {
        stops += 1
        for event in eventsOnStop { emit(event) }
    }
}

@MainActor
private final class VoiceWorkRun {
    var result: Result<String, any Error>?
    private var task: Task<Void, Never>?

    init(_ work: ChatGPTVoiceWork, _ instructions: String = "Research this question") {
        task = Task { @MainActor [weak self] in
            do {
                let answer = try await work.run(instructions)
                self?.result = .success(answer)
            } catch {
                self?.result = .failure(error)
            }
        }
    }

    var answer: String? {
        guard case .success(let value)? = result else { return nil }
        return value
    }

    var error: (any Error)? {
        guard case .failure(let error)? = result else { return nil }
        return error
    }

    func cancel() { task?.cancel() }
}
