import XCTest
@testable import Lenotch

@MainActor
final class SetupSportsTests: XCTestCase {
    func testSearchRequiresTwoCharactersAfterTrimming() async {
        let search = SetupSportsSearch(debounce: .zero) { _ in
            XCTFail("Short queries must not make a network request")
            return []
        }
        let request = SetupSportsSearch.Request(query: " a \n", sport: .soccer)
        XCTAssertEqual(request.query, "a")

        await search.load(request)

        XCTAssertTrue(search.results.isEmpty)
        XCTAssertFalse(search.isSearching)
        XCTAssertFalse(search.didSearch)
    }

    func testResultsUseSelectedSportAndAreLimitedToSix() async {
        let football = (1...8).map { team($0, sport: .soccer) }
        let mixed = [team(1, sport: .nfl)] + football + [team(2, sport: .nba)]
        let search = SetupSportsSearch(debounce: .zero) { _ in mixed }

        await search.load(.init(query: "team", sport: .soccer))

        XCTAssertEqual(search.results, Array(football.prefix(6)))
        XCTAssertTrue(search.didSearch)
        XCTAssertFalse(search.isSearching)
    }

    func testClearingQueryResetsLoadingAndRejectsLateResults() async {
        let gate = SportsSearchGate()
        let search = SetupSportsSearch(debounce: .zero) { _ in await gate.search() }
        let task = Task { await search.load(.init(query: "team", sport: .soccer)) }
        await gate.waitUntilStarted()
        XCTAssertTrue(search.isSearching)

        task.cancel()
        await search.load(.init(query: "", sport: .soccer))
        XCTAssertFalse(search.isSearching)
        XCTAssertFalse(search.didSearch)
        await gate.finish([team(1, sport: .soccer)])
        await task.value

        XCTAssertTrue(search.results.isEmpty)
        XCTAssertFalse(search.isSearching)
        XCTAssertFalse(search.didSearch)
    }

    func testCancelledRequestCannotClearNewSportsLoadingState() async {
        let firstGate = SportsSearchGate()
        let nextGate = SportsSearchGate()
        let search = SetupSportsSearch(debounce: .zero) { query in
            if query == "first" { return await firstGate.search() }
            return await nextGate.search()
        }
        let first = Task { await search.load(.init(query: "first", sport: .soccer)) }
        await firstGate.waitUntilStarted()
        first.cancel()

        let next = Task { await search.load(.init(query: "next", sport: .nba)) }
        await nextGate.waitUntilStarted()
        await firstGate.finish([team(1, sport: .soccer)])
        await first.value
        XCTAssertTrue(search.isSearching, "The cancelled request must not hide the new request's spinner")
        XCTAssertTrue(search.results.isEmpty)

        let basketball = team(1, sport: .nba)
        await nextGate.finish([basketball])
        await next.value
        XCTAssertEqual(search.results, [basketball])
        XCTAssertTrue(search.didSearch)
        XCTAssertFalse(search.isSearching)
    }

    func testPageDisappearanceInvalidatesInFlightSearch() async {
        let gate = SportsSearchGate()
        let search = SetupSportsSearch(debounce: .zero) { _ in await gate.search() }
        let task = Task { await search.load(.init(query: "team", sport: .nfl)) }
        await gate.waitUntilStarted()
        search.cancel()
        await gate.finish([team(1, sport: .nfl)])
        await task.value

        XCTAssertTrue(search.results.isEmpty)
        XCTAssertFalse(search.isSearching)
        XCTAssertFalse(search.didSearch)
    }

    private func team(_ id: Int, sport: Sport) -> FootballTeam {
        FootballTeam(id: id, abbr: "T\(id)", name: "Team \(id)", colorHex: "#123456", sport: sport)
    }
}

/// Keeps a request open until the test responds, including after task cancellation.
private actor SportsSearchGate {
    private var continuation: CheckedContinuation<[FootballTeam], Never>?
    private var started = false
    private var startObservers: [CheckedContinuation<Void, Never>] = []

    func search() async -> [FootballTeam] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            startObservers.forEach { $0.resume() }
            startObservers.removeAll()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startObservers.append($0) }
    }

    func finish(_ teams: [FootballTeam]) {
        continuation?.resume(returning: teams)
        continuation = nil
    }
}
