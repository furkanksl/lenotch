import XCTest
import IslandCore

/// Tools always occupy their own card, even while media and other activities remain active.
final class TrayTests: XCTestCase {
    private let player = CardSize(width: 372, height: 168, radius: 34)

    private func assertToolsOnly(_ i: Island, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(i.mode, .card, file: file, line: line)
        XCTAssertTrue(i.opened, file: file, line: line)
        XCTAssertTrue(i.trayOpen, file: file, line: line)
        XCTAssertTrue(i.trayShows, file: file, line: line)
        let g = i.groups(.card)
        XCTAssertTrue(g.tray, file: file, line: line)
        XCTAssertFalse(g.player, file: file, line: line)
        XCTAssertFalse(g.musicEars, file: file, line: line)
        XCTAssertFalse(g.playerFocus, file: file, line: line)
        XCTAssertFalse(g.videoFocus, file: file, line: line)
        XCTAssertFalse(g.activityCard, file: file, line: line)
        XCTAssertFalse(g.moreList, file: file, line: line)
        XCTAssertNil(g.agentsCard, file: file, line: line)
        XCTAssertNil(g.agentsAsk, file: file, line: line)
        // A wider custom player must not stretch the explicitly opened tools menu.
        let size = i.cardSize(player: CardSize(width: 520, height: 240, radius: 32))
        XCTAssertEqual(size.width, 372, file: file, line: line)
        XCTAssertEqual(size.height, 168, file: file, line: line)
    }

    func testEmptyNotchOpensOnlyTheTools() {
        var i = Island()
        XCTAssertTrue(i.canOpenEmptyTray)
        i.apply(.openTray)
        XCTAssertTrue(i.trayOpen)
        XCTAssertEqual(i.mode, .card)
        let g = i.groups(.card)
        XCTAssertTrue(g.tray)
        XCTAssertFalse(g.player)
        assertToolsOnly(i)
        i.apply(.close)
        XCTAssertFalse(i.trayOpen)
        XCTAssertEqual(i.mode, .idle)
    }

    func testMediaHiddenByItsOwnAppDoesNotImmediatelyCloseTheTools() {
        var i = Island()
        i.apply(.startMedia)
        i.apply(.context(DesktopContext(frontmostApp: BundleID.music)))
        XCTAssertEqual(i.mode, .idle)
        XCTAssertTrue(i.canOpenEmptyTray)

        i.apply(.openTray)
        XCTAssertTrue(i.opened)
        XCTAssertTrue(i.trayShows)
        XCTAssertEqual(i.mode, .card)
        XCTAssertTrue(i.groups(i.mode).tray)
        XCTAssertFalse(i.groups(i.mode).player)
        assertToolsOnly(i)

        i.apply(.context(DesktopContext(frontmostApp: BundleID.music)))
        XCTAssertTrue(i.trayShows, "a context refresh must leave the explicitly opened tools available")
        i.apply(.context(DesktopContext()))
        XCTAssertTrue(i.trayShows)
        assertToolsOnly(i)
    }

    func testOneClickOpensThePlayerAloneASecondReplacesItWithTools() {
        var i = Island()
        i.apply(.startMedia)
        i.apply(.open(.media))
        XCTAssertFalse(i.groups(.card).tray)
        XCTAssertEqual(i.cardSize(player: player), player)
        i.apply(.openTray)
        assertToolsOnly(i)
        i.apply(.close)
        XCTAssertFalse(i.trayOpen)
        i.apply(.open(.media))             // it closes back to the player alone
        XCTAssertFalse(i.groups(.card).tray)
        XCTAssertTrue(i.groups(.card).player)
    }

    func testPlayingAndPausedMusicKeepTheirPlaybackStateWhenToolsOpen() {
        for playing in [false, true] {
            var i = Island()
            i.apply(.startMedia)
            i.apply(.playback(playing))
            XCTAssertFalse(i.canOpenEmptyTray)
            i.apply(.openTray)
            assertToolsOnly(i)
            XCTAssertTrue(i.mediaOn)
            XCTAssertEqual(i.mediaPlaying, playing)
        }
    }

    func testLyricsAndVideoGiveWayToTheToolsWithoutStoppingMedia() {
        for video in [false, true] {
            var i = Island()
            i.apply(.startMedia)
            i.apply(.focusMedia)
            i.focusVideo = video
            XCTAssertEqual(i.groups(.card).videoFocus, video)
            XCTAssertEqual(i.groups(.card).playerFocus, !video)
            i.apply(.openTray)
            assertToolsOnly(i)
            XCTAssertFalse(i.mediaFocus)
            XCTAssertTrue(i.mediaOn)
            XCTAssertTrue(i.mediaPlaying)
        }
    }

    func testMediaStoppingKeepsTheToolsOpenAtTheSameSize() {
        var i = Island()
        i.apply(.startMedia)
        i.apply(.openTray)
        let before = i.cardSize(player: player)
        i.apply(.stopMedia)
        assertToolsOnly(i)
        XCTAssertFalse(i.mediaOn)
        XCTAssertEqual(i.cardSize(player: player), before)
    }

    func testSelectingTheMusicBubbleReturnsToThePlayer() {
        var i = Island()
        i.apply(.startMedia)
        i.apply(.openTray)
        XCTAssertTrue(i.trayOver)
        XCTAssertTrue(i.bubbleParties(.card).contains(.media))
        i.apply(.showCard(.media))
        XCTAssertTrue(i.opened)
        XCTAssertFalse(i.trayOpen)
        XCTAssertFalse(i.trayShows)
        XCTAssertFalse(i.groups(.card).tray)
        XCTAssertTrue(i.groups(.card).player)
        XCTAssertEqual(i.cardSize(player: player), player)
    }

    // The double-click on the notch opens the tools whatever is in the ears (owner, 11-11); the activity waits in a ball.
    func testTheToolsOpenOverAnActivityInTheEars() {
        var i = Island()
        i.apply(.show(.timer))
        i.apply(.openTray)
        XCTAssertTrue(i.opened)
        assertToolsOnly(i)
        XCTAssertTrue(i.trayOver)
        XCTAssertTrue(i.bubbleParties(.card).contains(.activity))
        i.apply(.close)
        XCTAssertFalse(i.trayOver)
        XCTAssertEqual(i.mode, .compact)    // the timer is back in the ears
    }

    // The first press of a double-click opened the activity's card; the second (on the notch) brings the tools.
    func testTheToolsTakeAnOpenCardsPlace() {
        var i = Island()
        i.apply(.show(.timer, opened: false))
        i.apply(.open(.activity))
        XCTAssertFalse(i.trayShows)
        i.apply(.openTray)
        assertToolsOnly(i)

        var j = Island()
        j.apply(.startMedia)
        j.apply(.show(.timer, opened: false))
        j.apply(.open(.activity))
        j.apply(.openTray)
        assertToolsOnly(j)
    }

    // Bug 11-10: something running but hidden (here the meeting, with Calendar in front) left the notch looking empty,
    // and a press there did nothing because the tray asked `live` instead of what shows.
    func testToolsReplaceAnAgentCardWithoutHidingTheRunningAgent() {
        var i = Island()
        i.apply(.agent(AgentHook(provider: .claude, event: "UserPromptSubmit", sessionID: "tray-agent", cwd: "/tmp/lenotch")))
        i.apply(.open(.agents(.claude)))
        XCTAssertEqual(i.groups(.card).agentsCard, .claude)

        i.apply(.openTray)

        assertToolsOnly(i)
        XCTAssertTrue(i.trayOver)
        XCTAssertEqual(i.bubbleParties(.card), [.agents(.claude)])
        XCTAssertEqual(i.agents.sessions.count, 1)

        i.apply(.showCard(.agents(.claude)))
        XCTAssertFalse(i.trayShows)
        XCTAssertFalse(i.trayOpen)
        XCTAssertEqual(i.groups(.card).agentsCard, .claude)
    }

    func testAHiddenActivityLeavesTheEmptyNotchPressable() {
        var i = Island()
        i.apply(.context(DesktopContext(frontmostApp: BundleID.calendar)))
        i.apply(.show(.meeting, opened: false))
        XCTAssertNil(i.arrangement.ears)
        XCTAssertTrue(i.canOpenEmptyTray)
        i.apply(.openTray)
        XCTAssertTrue(i.trayShows)
        XCTAssertEqual(i.mode, .card)
    }

    // Bug 11-10: the ears emptied under an open card (log: opened=true, mode=idle) and presses found nothing.
    func testAnIslandOpenOverNothingCloses() {
        var i = Island()
        i.apply(.show(.meeting, opened: false))
        i.apply(.open(.activity))
        XCTAssertTrue(i.opened)
        i.apply(.context(DesktopContext(frontmostApp: BundleID.calendar)))   // its own app comes forward: it hides
        XCTAssertFalse(i.opened)
        XCTAssertEqual(i.mode, .idle)
        XCTAssertTrue(i.canOpenEmptyTray)
    }

    func testAnActivityCanTakeTheToolsPlaceButMediaCannot() {
        var i = Island()
        i.apply(.openTray)
        i.apply(.show(.timer, opened: false))
        XCTAssertFalse(i.trayOpen)
        XCTAssertEqual(i.mode, .compact)

        var j = Island()
        j.apply(.openTray)
        j.apply(.startMedia)
        assertToolsOnly(j)
        XCTAssertTrue(j.mediaOn)
    }

    func testNothingOpensOverAMenuOrFullscreen() {
        for c in [DesktopContext(menuOpen: true), DesktopContext(fullscreen: true), DesktopContext(locked: true)] {
            var i = Island()
            i.apply(.context(c))
            XCTAssertFalse(i.canOpenEmptyTray)
            i.apply(.openTray)
            XCTAssertEqual(i.mode, .idle)
            i.apply(.startMedia)
            i.apply(.openTray)
            XCTAssertFalse(i.trayOpen)
            XCTAssertFalse(i.trayShows)
        }
        var i = Island()
        i.apply(.openTray)
        i.apply(.context(DesktopContext(menuOpen: true)))
        XCTAssertFalse(i.trayOpen)
    }

    // A click on the event card: the day, large (the lyrics player's size); Back to the grid shrinks it.
    func testOpenDayIsLargeAndCloseDayShrinks() {
        var i = Island()
        i.apply(.openDay)
        XCTAssertTrue(i.trayShows)
        XCTAssertTrue(i.dayLarge)
        XCTAssertEqual(i.cardSize(player: player), Island.dayCard)
        i.apply(.closeDay)
        XCTAssertFalse(i.dayLarge)
        assertToolsOnly(i)
        i.apply(.close)
        XCTAssertFalse(i.dayLarge)
    }

    func testOpenDayWithASongHidesThePlayer() {
        var i = Island()
        i.apply(.startMedia)
        i.apply(.openDay)
        XCTAssertTrue(i.dayLarge)
        XCTAssertFalse(i.groups(.card).player)
        XCTAssertEqual(i.cardSize(player: player), Island.dayCard)
        i.apply(.close)
        XCTAssertFalse(i.dayLarge)
    }
}
