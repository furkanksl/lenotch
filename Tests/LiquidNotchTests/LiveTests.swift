import IslandCore
import NowPlaying
import XCTest
@testable import Lenotch

/// P4: the live activities' data and how it reaches the island.
@MainActor
final class LiveTests: XCTestCase {
    func testJoinLinks() {
        XCTAssertEqual(MeetingInfo.joinLink(in: [nil, "Room 4", "Join: https://us02web.zoom.us/j/123?pwd=x thanks"])?.host,
                       "us02web.zoom.us")
        XCTAssertEqual(MeetingInfo.joinLink(in: ["https://meet.google.com/abc-defg-hij"])?.absoluteString,
                       "https://meet.google.com/abc-defg-hij")
        XCTAssertNil(MeetingInfo.joinLink(in: ["https://example.com/agenda", nil]))
    }

    func testInitials() {
        XCTAssertEqual(MeetingInfo.initials("Marina Costa"), "MC")
        XCTAssertEqual(MeetingInfo.initials("joe@example.com"), "J")
        XCTAssertEqual(MeetingInfo.initials("ana.vell@example.com"), "AV")
    }

    func testChargingText() {
        XCTAssertEqual(PowerInfo(level: 40, charging: true, onAdapter: true, watts: 60, minutesToFull: 42).status, "Charging · full in 42 min")
        XCTAssertEqual(PowerInfo(level: 40, charging: true, onAdapter: true, watts: nil, minutesToFull: 95).status, "Charging · full in 1 h 35 min")
        XCTAssertEqual(PowerInfo(level: 80, charging: false, onAdapter: true, watts: 60, minutesToFull: nil).status,
                       "On power adapter · not charging")
        XCTAssertEqual(PowerInfo(level: 100, charging: false, onAdapter: true, watts: 60, minutesToFull: nil).status, "Fully charged")
        XCTAssertEqual(PowerInfo(level: 50, charging: false, onAdapter: false, watts: nil, minutesToFull: nil).adapter, nil)
    }

    func testPodsLevel() {
        XCTAssertEqual(PodsInfo(name: "A", left: 70, right: 60, caseLevel: 90, single: nil).buds, 60)
        XCTAssertEqual(PodsInfo(name: "A", left: nil, right: nil, caseLevel: nil, single: 80).buds, 80)
        XCTAssertNil(PodsInfo(name: "A", left: nil, right: nil, caseLevel: nil, single: nil).buds)
    }

    // NX_SYSDEFINED data1: key << 16 | (0x0A down / 0x0B up) << 8.
    func testKeyDecoding() {
        XCTAssertEqual(MediaKeyTap.decode(subtype: 8, data1: (0 << 16) | (0x0A << 8))?.key, .soundUp)
        XCTAssertEqual(MediaKeyTap.decode(subtype: 8, data1: (3 << 16) | (0x0A << 8))?.down, true)
        XCTAssertEqual(MediaKeyTap.decode(subtype: 8, data1: (7 << 16) | (0x0B << 8))?.down, false)
        XCTAssertNil(MediaKeyTap.decode(subtype: 8, data1: 16 << 16))      // play/pause stays the system's
        XCTAssertNil(MediaKeyTap.decode(subtype: 7, data1: 0))
    }

    // Sixteen steps (sixty-four with ⌥⇧), snapping to the grid, clamped.
    func testSteps() {
        XCTAssertEqual(MediaKeyTap.step(0.5, up: true, fine: false), 0.5625, accuracy: 1e-9)
        XCTAssertEqual(MediaKeyTap.step(0.5, up: false, fine: false), 0.4375, accuracy: 1e-9)
        XCTAssertEqual(MediaKeyTap.step(0.5, up: true, fine: true), 0.515625, accuracy: 1e-9)
        XCTAssertEqual(MediaKeyTap.step(0.97, up: true, fine: false), 1)
        XCTAssertEqual(MediaKeyTap.step(0.03, up: false, fine: false), 0)
        XCTAssertEqual(MediaKeyTap.step(0.53, up: true, fine: false), 0.5625, accuracy: 1e-9)   // off-grid snaps up one
    }

    func testTransferText() {
        var t = TransferInfo(name: "Wallpapers-4K.zip", totalBytes: 3_400_000_000, doneBytes: 1_100_000_000,
                             bytesPerSecond: 42_000_000, secondsLeft: 54)
        XCTAssertEqual(t.kind, "ZIP")
        XCTAssertEqual(t.fraction, 1.1 / 3.4, accuracy: 1e-9)
        XCTAssertTrue(t.progressLine.hasSuffix("/s"))
        XCTAssertEqual(t.timeLeft, "About 1 min left")
        t.secondsLeft = 12
        XCTAssertEqual(t.timeLeft, "15 s left")
        t.paused = true
        XCTAssertEqual(t.timeLeft, "Paused")
        XCTAssertTrue(t.progressLine.hasSuffix("paused"))
        t.finished = true
        XCTAssertEqual(t.timeLeft, "Finished")
        XCTAssertTrue(t.progressLine.hasSuffix("in Downloads"))
    }

    // A download shows; finished, it stays 3 s then leaves; cancelled, it leaves at once.
    func testDownloadFlow() {
        let (d, s) = director()
        let t = TransferInfo(name: "a.zip", totalBytes: 100, doneBytes: 10, bytesPerSecond: 50, secondsLeft: 2)
        d.transferStarted(t)
        XCTAssertEqual(d.island.activity?.id, .download)
        XCTAssertEqual(d.transferFor(d.island.activity!).name, "a.zip")
        var done = t
        done.doneBytes = 100
        done.finished = true
        d.transferEnded(done, finished: true)
        s.advance(2.9)
        XCTAssertEqual(d.island.activity?.id, .download)
        s.advance(0.2)
        XCTAssertNil(d.island.activity)
        d.transferStarted(t)
        d.transferEnded(t, finished: false)
        XCTAssertNil(d.island.activity)
    }

    func testLowBatteryThresholds() {
        XCTAssertTrue(PowerMonitor.crossedLow(from: 21, to: 20))
        XCTAssertTrue(PowerMonitor.crossedLow(from: 11, to: 10))
        XCTAssertTrue(PowerMonitor.crossedLow(from: 25, to: 9))
        XCTAssertFalse(PowerMonitor.crossedLow(from: 20, to: 19))
        XCTAssertFalse(PowerMonitor.crossedLow(from: 15, to: 14))
        XCTAssertFalse(PowerMonitor.crossedLow(from: 10, to: 11))
        XCTAssertEqual(PowerInfo(level: 18, charging: false, onAdapter: false, watts: nil, minutesToFull: nil,
                                 minutesToEmpty: 70).lowStatus, "Low Battery · about 1 h 10 min left")
    }

    private func director() -> (IslandDirector, ManualScheduler) {
        let d = IslandDirector()
        let s = ManualScheduler()
        d.schedule = s.schedule
        return (d, s)
    }

    // Plugging in shows Charging with the real battery; the debug panel's sample shows the sample.
    func testChargingUsesLiveData() {
        let (d, s) = director()
        d.pluggedIn(PowerInfo(level: 63, charging: true, onAdapter: true, watts: 96, minutesToFull: 30))
        XCTAssertEqual(d.island.activity?.id, .charging)
        XCTAssertEqual(d.powerFor(d.island.activity!).level, 63)
        s.advance(5)
        d.show(.charging)
        XCTAssertEqual(d.powerFor(d.island.activity!).level, 75)
    }

    // A meeting coming within 10 minutes shows; it leaves when it ends; Join opens nothing for a sample.
    func testMeetingComesAndGoes() {
        let (d, _) = director()
        let start = Date().addingTimeInterval(300)
        d.meetingChanged(MeetingInfo(title: "Standup", start: start, end: start.addingTimeInterval(900), joinURL: nil,
                                     initials: ["MC"], more: 0))
        XCTAssertEqual(d.island.activity?.id, .meeting)
        XCTAssertEqual(d.meetingFor(d.island.activity!).title, "Standup")
        XCTAssertEqual(d.meetingLeft(d.island.activity!), 300, accuracy: 2)
        d.meetingChanged(nil)
        XCTAssertNil(d.island.activity)
    }

    func testAirPodsConnecting() {
        let (d, _) = director()
        d.podsConnected(PodsInfo(name: "AirPods Pro", left: 50, right: 52, caseLevel: nil, single: nil))
        XCTAssertEqual(d.island.activity?.id, .airpods)
        XCTAssertEqual(d.podsFor(d.island.activity!).buds, 50)
        d.podsUpdated(PodsInfo(name: "AirPods Pro", left: 50, right: 52, caseLevel: 88, single: nil))
        XCTAssertEqual(d.podsFor(d.island.activity!).caseLevel, 88)
    }

    // A key press shows the HUD at the real level, then hands back.
    func testLevelChangeShowsTheHUD() {
        let (d, s) = director()
        d.startMusic()
        d.levelChanged(brightness: true, level: 0.3)
        XCTAssertEqual(d.mode, .hud)
        XCTAssertEqual(d.island.hud, .brightness)
        XCTAssertEqual(d.hudLevel, 0.3)
        s.advance(1.5)
        XCTAssertEqual(d.mode, .compact)
    }

    // The four designs of 11-01.
    func testLowBatteryShows() {
        let (d, s) = director()
        d.lowBattery(PowerInfo(level: 10, charging: false, onAdapter: false, watts: nil, minutesToFull: nil, minutesToEmpty: 35))
        XCTAssertEqual(d.island.activity?.id, .battery)
        XCTAssertEqual(d.lowPowerFor(d.island.activity!).level, 10)
        s.advance(5.2)
        XCTAssertNil(d.island.activity, "a transient: it leaves by itself")
    }

    func testFocusChangesShowNotTheFirstReading() {
        let (d, _) = director()
        d.systemContextChanged(DesktopContext(focusOn: false))
        XCTAssertNil(d.island.activity, "the first reading isn't a change")
        d.systemContextChanged(DesktopContext(focusOn: true))
        XCTAssertEqual(d.island.activity?.id, .focus)
        XCTAssertTrue(d.focusOnFor(d.island.activity!))
    }

    func testCameraOnAndOff() {
        let (d, _) = director()
        var now = Date(timeIntervalSince1970: 1000)
        d.date = { now }
        d.systemContextChanged(DesktopContext(cameraInUse: true))
        XCTAssertEqual(d.island.activity?.id, .camera)
        now = now.addingTimeInterval(42)
        XCTAssertEqual(d.cameraFor(d.island.activity!).seconds, 42, accuracy: 1e-9)
        d.systemContextChanged(DesktopContext(cameraInUse: false))
        XCTAssertNil(d.island.activity)
    }

    func testTimerFromTheMenu() {
        let (d, _) = director()
        d.startTimer(minutes: 5)
        XCTAssertEqual(d.island.activity?.id, .timer)
        XCTAssertEqual(d.samples.timerLeft, 300)
        XCTAssertEqual(d.samples.timerTotal, 300)
    }

    // HUD1 (v1, 11-11): the volume HUD is a slider. On it or held it never times out; a drag follows the bar one to one and
    // sets the system level; a key pressed mid-drag moves the drag's start (no fighting); it leaves on the usual delay after
    // release and leave; brightness that can't be set shows read-only.
    func testHUD1DraggableHUD() {
        let d = IslandDirector(), s = ManualScheduler()
        d.schedule = s.schedule
        d.clock = { 0 }
        d.frontmostApp = { "" }
        var set: [Double] = []
        var settable = true
        d.setLevel = { _, level in if settable { set.append(level) }; return settable }
        d.levelChanged(brightness: false, level: 0.5)
        XCTAssertEqual(d.island.mode, .hud)
        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false)
        XCTAssertTrue(d.hudHeld)
        s.advance(5)
        XCTAssertEqual(d.island.mode, .hud, "held while the pointer is on it")
        d.pointerDown(at: SIMD2(400, 18), hit: .ears)
        d.pointerDragged(to: SIMD2(400 + IslandDirector.hudBarWidth / 4, 18))
        XCTAssertEqual(d.hudLevel, 0.75, accuracy: 0.001)
        XCTAssertEqual(set.last ?? -1, 0.75, accuracy: 0.001)
        d.levelChanged(brightness: false, level: 0.5)          // a key mid-drag
        d.pointerDragged(to: SIMD2(400 + IslandDirector.hudBarWidth / 4 + 6.2, 18))
        XCTAssertEqual(d.hudLevel, 0.6, accuracy: 0.001, "the drag carries on from the key's level")
        d.pointerDragged(to: SIMD2(2000, 18))
        XCTAssertEqual(d.hudLevel, 1, "clamped")
        d.pointerUp(at: SIMD2(2000, 18), hit: nil, corridor: false)
        XCTAssertFalse(d.hudHeld)
        s.advance(IslandDirector.hudLinger + 0.1)
        XCTAssertNotEqual(d.island.mode, .hud, "leaves on the usual delay")

        settable = false
        d.levelChanged(brightness: true, level: 0.4)
        d.pointerDown(at: SIMD2(400, 18), hit: .ears)
        d.pointerDragged(to: SIMD2(430, 18))
        XCTAssertTrue(d.hudReadOnly)
        XCTAssertEqual(d.hudLevel, 0.4, "read-only: the bar stays at the real level")
    }

    // VIDEO1 (owner, 11-11: "if it's a video, click on its card and you can watch the video from the island"): a song in
    // the ears and a video in a ball; the video's card opens, a click on it opens the video's view (16:9, not lyrics),
    // it stays open until closed, and closing it stops the mirror.
    func testVIDEO1WatchTheVideoInTheIsland() {
        let d = IslandDirector(), s = ManualScheduler()
        d.schedule = s.schedule
        d.clock = { 0 }
        d.frontmostApp = { "" }
        d.nowPlayingChanged(NowPlaying(title: "Song", artist: "Artist", bundleID: "com.spotify.client", playing: true, kind: .audio))
        d.nowPlaying2Changed(NowPlaying(title: "A Video", bundleID: "com.google.Chrome", playing: true, kind: .video))
        XCTAssertEqual(d.island.arrangement.balls, [.media2])
        d.openCard(.media2)
        XCTAssertEqual(d.media.title, "A Video", "the player views show the video while its card is open")
        XCTAssertTrue(d.focusedIsVideo)
        d.openFocus()
        XCTAssertTrue(d.groups.videoFocus)
        XCTAssertFalse(d.groups.playerFocus)
        XCTAssertEqual(d.island.cardSize(player: CardSize(width: 372, height: 168, radius: 34)), Island.videoCard)
        XCTAssertTrue(d.island.holdsOpen, "it stays until you close it")
        d.clickOutside()
        XCTAssertTrue(d.island.opened, "a click away doesn't close it (owner, 11-11)")
        let t = Tuning()
        XCTAssertLessThanOrEqual(37.5 + t.cardGap + Island.videoCard.height, 420, "it fits in the island's window")
        d.closeVideo()
        XCTAssertFalse(d.island.opened)
        XCTAssertEqual(d.videoMirror.state, .idle)
    }

    func testRepeatedAirPodsConnectionsShowBuiltInPopupAndReturnToIdle() {
        let (d, scheduler) = director()
        let pods = PodsInfo(name: "AirPods", left: 80, right: 80, caseLevel: 90, single: nil)
        for _ in 0..<5 {
            d.podsConnected(pods)
            XCTAssertEqual(d.island.activity?.id, .airpods)
            XCTAssertEqual(d.island.running.count, 1)
            XCTAssertEqual(d.podsFor(d.island.activity!).buds, 80)
            scheduler.advance(10)
            XCTAssertTrue(d.island.running.isEmpty, "the connection popup must not schedule a follow-up promotion")
        }
    }
}
