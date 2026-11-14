import Foundation
import NowPlaying
import XCTest
@testable import Lenotch

@MainActor
final class VideoPlaybackTests: XCTestCase {
    func testPausedSecondaryVideoKeepsPiPAndCanReturnToTheNotch() {
        let director = IslandDirector(prompter: PrompterModel(storageURL: nil))
        defer { director.closePiP() }
        let music = NowPlaying(title: "A song", artist: "Artist", bundleID: "com.apple.Music", playing: true,
                               duration: 180, elapsed: 15, kind: .audio)
        var video = NowPlaying(title: "A video", bundleID: "com.example.browser", playing: true,
                               duration: 120, elapsed: 30, kind: .video)
        director.nowPlayingChanged(music)
        director.nowPlaying2Changed(video)
        director.videoPlayback.bind(video)
        // Restore an already-captured/pinned session without starting real screen capture in a test.
        director.pipBackToIsland()
        director.popOutVideo()
        XCTAssertTrue(director.pipOpen)

        video.playing = false
        director.videoPlayerChanged(video)
        director.nowPlaying2Changed(nil) // paused sources may leave the main player's alternate list
        XCTAssertTrue(director.pipOpen)
        XCTAssertFalse(director.videoPlayback.playing)
        XCTAssertEqual(director.videoPlayback.bundleID, "com.example.browser")
        director.pipBackToIsland()
        XCTAssertFalse(director.pipOpen)
        XCTAssertTrue(director.island.mediaFocus)
        XCTAssertEqual(director.island.cardOwner, .media2)
        XCTAssertTrue(director.focusedIsVideo)
        XCTAssertFalse(director.videoPlayback.playing)
    }

    func testVideoTimeLabelsHandleHoursAndUnknownMetadata() {
        XCTAssertEqual(VideoTime.string(0), "0:00")
        XCTAssertEqual(VideoTime.string(69), "1:09")
        XCTAssertEqual(VideoTime.string(3_669), "1:01:09")
        XCTAssertEqual(VideoTime.string(-10), "0:00")
        XCTAssertEqual(VideoTime.string(.nan), "--:--")
        XCTAssertEqual(VideoTime.string(.infinity), "--:--")
    }

    private let epoch = Date(timeIntervalSince1970: 1_000)
    private let browser = "com.apple.Safari"

    private func video(title: String = "A video", artist: String = "A channel", bundleID: String? = "com.apple.Safari",
                       playing: Bool = false, duration: Double? = 120, elapsed: Double = 20,
                       timestamp: Date? = nil, rate: Double = 1) -> NowPlaying {
        NowPlaying(title: title, artist: artist, bundleID: bundleID, playing: playing,
                   duration: duration, elapsed: elapsed, timestamp: timestamp ?? epoch, rate: rate, kind: .video)
    }

    func testCommandsRemainPinnedWhenAnotherAppBecomesTheCurrentPlayer() {
        let state = VideoPlaybackState()
        state.date = { self.epoch }
        var commands: [MediaCommand] = []
        var commandApps: [String] = []
        var seeks: [Double] = []
        var seekApps: [String] = []
        state.onCommand = { command, app in commands.append(command); commandApps.append(app) }
        state.onSeek = { time, app in seeks.append(time); seekApps.append(app) }
        state.bind(video(playing: true, elapsed: 30))

        state.update(NowPlaying(title: "A song", artist: "A musician", bundleID: "com.apple.Music", playing: true,
                                duration: 240, elapsed: 50, timestamp: epoch, kind: .audio))
        state.togglePlaying()
        state.skip(10)

        XCTAssertEqual(state.bundleID, browser)
        XCTAssertEqual(state.title, "A video")
        XCTAssertFalse(state.playing)
        XCTAssertEqual(commands, [.togglePlayPause])
        XCTAssertEqual(commandApps, [browser], "PiP must not control music when another app takes media focus")
        XCTAssertEqual(seeks, [40])
        XCTAssertEqual(seekApps, [browser])
    }

    func testTenSecondSkipsAndDirectSeeksClampToTheTimelineAndSendOnce() {
        let state = VideoPlaybackState()
        state.date = { self.epoch }
        var seeks: [Double] = []
        var apps: [String] = []
        state.onSeek = { time, app in seeks.append(time); apps.append(app) }
        state.bind(video(duration: 95, elapsed: 5))

        state.skip(-10)
        XCTAssertEqual(state.elapsed, 0, accuracy: 0.001)
        state.skip(10)
        XCTAssertEqual(state.elapsed, 10, accuracy: 0.001)
        state.seek(to: 1_000)
        XCTAssertEqual(state.elapsed, 95, accuracy: 0.001)
        state.seek(to: -9)
        XCTAssertEqual(state.elapsed, 0, accuracy: 0.001)

        XCTAssertEqual(seeks, [0, 10, 95, 0])
        XCTAssertEqual(apps, Array(repeating: browser, count: 4))
        XCTAssertEqual(state.duration, 95, "seeking must not change the source's duration")
    }

    func testUnsupportedAndNonfiniteSeeksDoNotDispatchOrMoveTheTimeline() {
        let state = VideoPlaybackState()
        state.date = { self.epoch }
        var seeks: [Double] = []
        state.onSeek = { time, _ in seeks.append(time) }
        state.bind(video())

        for value in [Double.nan, .infinity, -.infinity] {
            state.seek(to: value)
            state.skip(value)
        }
        XCTAssertEqual(state.elapsed, 20, accuracy: 0.001)
        XCTAssertTrue(seeks.isEmpty)

        state.bind(video(duration: nil))
        XCTAssertFalse(state.canSeek, "a live stream with no duration has no seekable timeline")
        state.seek(to: 40)
        state.skip(10)
        XCTAssertEqual(state.elapsed, 20, accuracy: 0.001)
        XCTAssertTrue(seeks.isEmpty)

        state.bind(video())
        state.onSeek = nil
        state.seek(to: 80)
        XCTAssertEqual(state.elapsed, 20, accuracy: 0.001, "don't claim to seek without a command handler")
        XCTAssertTrue(seeks.isEmpty)
    }

    func testPauseFreezesTheCurrentTimeAndResumeContinuesFromThatAnchor() {
        let state = VideoPlaybackState()
        var now = epoch
        state.date = { now }
        var commands: [MediaCommand] = []
        state.onCommand = { command, _ in commands.append(command) }
        state.bind(video(playing: true))

        now = now.addingTimeInterval(5)
        XCTAssertEqual(state.elapsed, 25, accuracy: 0.001)
        state.togglePlaying()
        XCTAssertFalse(state.playing)
        now = now.addingTimeInterval(10)
        XCTAssertEqual(state.elapsed, 25, accuracy: 0.001)

        state.togglePlaying()
        XCTAssertTrue(state.playing)
        now = now.addingTimeInterval(2)
        XCTAssertEqual(state.elapsed, 27, accuracy: 0.001)
        XCTAssertEqual(commands, [.togglePlayPause, .togglePlayPause])
    }

    func testElapsedUsesTheMetadataClockAndInvalidDurationsNeverEnableSeeking() {
        let state = VideoPlaybackState()
        var now = epoch.addingTimeInterval(5)
        state.date = { now }
        state.onSeek = { _, _ in }
        state.bind(video(playing: true, duration: 15, elapsed: 9, rate: 2))
        XCTAssertEqual(state.elapsed, 15, accuracy: 0.001, "honor playback rate and stop at the duration")
        XCTAssertTrue(state.canSeek)

        state.bind(video(playing: false, elapsed: -5))
        XCTAssertEqual(state.elapsed, 0, accuracy: 0.001)
        now = now.addingTimeInterval(10)
        XCTAssertEqual(state.elapsed, 0, accuracy: 0.001, "paused metadata never advances")

        for duration in [Double.nan, .infinity, -.infinity, 0, -5] {
            state.bind(video(duration: duration, elapsed: .infinity))
            XCTAssertFalse(state.canSeek, "invalid duration \(duration) must not produce a seekable slider")
            XCTAssertTrue(state.elapsed.isFinite, "nonfinite player metadata must not enter the UI")
            XCTAssertGreaterThanOrEqual(state.elapsed, 0)
        }
    }

    func testOptimisticSeekAndPauseSurviveStaleReportsButAcceptLaterMetadata() {
        let state = VideoPlaybackState()
        var now = epoch
        state.date = { now }
        var seeks: [Double] = []
        var commands: [MediaCommand] = []
        state.onSeek = { time, _ in seeks.append(time) }
        state.onCommand = { command, _ in commands.append(command) }
        let old = video(elapsed: 40)
        state.bind(old)

        state.seek(to: 70)
        state.update(old)
        XCTAssertEqual(state.elapsed, 70, accuracy: 0.001, "a repeated report must not snap the slider backward")

        now = now.addingTimeInterval(2)
        let current = video(elapsed: 72, timestamp: now)
        state.update(current)
        XCTAssertEqual(state.elapsed, 72, accuracy: 0.001)
        state.togglePlaying()
        state.update(current)
        XCTAssertTrue(state.playing, "a repeated paused report must not undo the user's resume")

        now = now.addingTimeInterval(2)
        state.update(video(elapsed: 75, timestamp: now))
        XCTAssertFalse(state.playing, "current source metadata wins after the short optimistic interval")
        XCTAssertEqual(state.elapsed, 75, accuracy: 0.001)
        XCTAssertEqual(seeks, [70])
        XCTAssertEqual(commands, [.togglePlayPause], "metadata updates must never send media commands")
    }

    func testClearRemovesThePinnedPlayerAndDisablesAllTransportActions() {
        let state = VideoPlaybackState()
        state.date = { self.epoch }
        var commandCount = 0
        var seekCount = 0
        state.onCommand = { _, _ in commandCount += 1 }
        state.onSeek = { _, _ in seekCount += 1 }
        state.bind(video(playing: true))

        state.clear()
        state.togglePlaying()
        state.skip(10)
        state.seek(to: 50)

        XCTAssertNil(state.bundleID)
        XCTAssertTrue(state.title.isEmpty)
        XCTAssertNil(state.duration)
        XCTAssertEqual(state.elapsed, 0, accuracy: 0.001)
        XCTAssertFalse(state.playing)
        XCTAssertFalse(state.available)
        XCTAssertFalse(state.canSeek)
        XCTAssertEqual(commandCount, 0)
        XCTAssertEqual(seekCount, 0)

        state.bind(video(bundleID: nil))
        state.togglePlaying()
        state.seek(to: 50)
        XCTAssertFalse(state.available, "a source without an app cannot receive targeted transport commands")
        XCTAssertFalse(state.canSeek)
        XCTAssertEqual(commandCount, 0)
        XCTAssertEqual(seekCount, 0)
    }

    func testSubtitlesPersistForTheSameTrackAndClearOnlyWhenTheTrackOrSourceChanges() throws {
        let state = VideoPlaybackState()
        state.date = { self.epoch }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeNotch-video-playback-\(UUID().uuidString).srt")
        try "1\n00:00:00,000 --> 00:02:00,000\nA local caption.\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        state.bind(video())
        state.subtitles.load(from: file)
        XCTAssertEqual(state.subtitles.text(at: 20), "A local caption.")

        let progress = video(playing: true, elapsed: 35)
        state.update(progress)
        state.bind(progress)
        XCTAssertEqual(state.subtitles.name, file.lastPathComponent)
        XCTAssertEqual(state.subtitles.text(at: 35), "A local caption.", "reopening the same player retains captions")

        state.update(video(bundleID: "com.google.Chrome"))
        XCTAssertEqual(state.bundleID, browser)
        XCTAssertEqual(state.subtitles.name, file.lastPathComponent, "an unrelated player's report is not a track change")

        state.update(video(title: "Next video"))
        XCTAssertEqual(state.title, "Next video")
        XCTAssertNil(state.subtitles.name)
        XCTAssertTrue(state.subtitles.cues.isEmpty)

        state.subtitles.load(from: file)
        state.update(video(title: "Next video", artist: "Another channel"))
        XCTAssertNil(state.subtitles.name, "artist changes distinguish otherwise identically titled videos")

        state.subtitles.load(from: file)
        state.bind(video(title: "Next video", artist: "Another channel", bundleID: "com.google.Chrome"))
        XCTAssertEqual(state.bundleID, "com.google.Chrome")
        XCTAssertNil(state.subtitles.name, "captions never leak to a newly selected app")

        state.subtitles.load(from: file)
        state.clear()
        XCTAssertNil(state.subtitles.name)
        XCTAssertTrue(state.subtitles.cues.isEmpty)
    }

    func testScrubbingReportsItsLifecycleWithoutChangingPlaybackOrSendingCommands() {
        let state = VideoPlaybackState()
        state.date = { self.epoch }
        var scrubbing: [Bool] = []
        var commandCount = 0
        var seekCount = 0
        state.onScrub = { scrubbing.append($0) }
        state.onCommand = { _, _ in commandCount += 1 }
        state.onSeek = { _, _ in seekCount += 1 }
        state.bind(video(playing: true))

        state.scrub(true)
        state.scrub(false)

        XCTAssertEqual(scrubbing, [true, false])
        XCTAssertTrue(state.playing, "dragging the slider must not toggle the source player's play state")
        XCTAssertEqual(state.elapsed, 20, accuracy: 0.001)
        XCTAssertEqual(commandCount, 0)
        XCTAssertEqual(seekCount, 0, "the slider sends one explicit seek on release, not on edit begin or end")
    }
}
