import Foundation
import NowPlaying
import Observation

/// Playback stays pinned to the video app even when PiP closes the notch card or music becomes the foreground player.
@MainActor @Observable
final class VideoPlaybackState {
    private(set) var bundleID: String?
    private(set) var title = ""
    let subtitles = VideoSubtitles()
    private var player: NowPlaying?
    @ObservationIgnored var date: () -> Date = Date.init
    @ObservationIgnored var onCommand: ((MediaCommand, String) -> Void)?
    @ObservationIgnored var onSeek: ((Double, String) -> Void)?
    @ObservationIgnored var onScrub: ((Bool) -> Void)?
    @ObservationIgnored private var positionHeldUntil: Date?
    @ObservationIgnored private var playingHeldUntil: Date?

    var available: Bool { player != nil && bundleID != nil }
    var snapshot: NowPlaying? { player }
    var playing: Bool { player?.playing == true }
    var duration: Double? {
        guard let length = player?.duration, length.isFinite, length > 0 else { return nil }
        return length
    }
    var canSeek: Bool { available && duration != nil && onSeek != nil }
    var elapsed: Double {
        guard let player else { return 0 }
        let position = player.elapsed(at: date())
        guard position.isFinite else { return 0 }
        return min(max(position, 0), duration ?? .greatestFiniteMagnitude)
    }

    func bind(_ np: NowPlaying) {
        if player?.identity != np.identity || bundleID != np.bundleID {
            subtitles.clear()
            positionHeldUntil = nil
            playingHeldUntil = nil
        }
        player = np
        bundleID = np.bundleID
        title = np.title
    }

    /// Metadata from every source is supplied before main/secondary-player sorting, so pausing a video cannot lose it.
    func update(_ incoming: NowPlaying) {
        guard let bundleID, incoming.bundleID == bundleID else { return }
        guard let old = player, old.identity == incoming.identity else { bind(incoming); return }
        var np = incoming
        let now = date()
        if let until = positionHeldUntil, now < until, abs(np.elapsed(at: now) - elapsed) > 1.5 {
            np.elapsed = elapsed
            np.timestamp = now
        } else { positionHeldUntil = nil }
        if let until = playingHeldUntil, now < until, np.playing != old.playing {
            np.elapsed = elapsed
            np.timestamp = now
            np.playing = old.playing
        } else { playingHeldUntil = nil }
        player = np
        title = np.title
    }

    func togglePlaying() {
        guard let bundleID, var player, let onCommand else { return }
        let now = date()
        player.elapsed = elapsed
        player.timestamp = now
        player.playing.toggle()
        self.player = player
        playingHeldUntil = now.addingTimeInterval(1.2)
        onCommand(.togglePlayPause, bundleID)
    }

    func skip(_ seconds: Double) {
        guard seconds.isFinite else { return }
        seek(to: elapsed + seconds)
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, let bundleID, let duration, var player, let onSeek else { return }
        let target = min(max(seconds, 0), duration)
        let now = date()
        player.elapsed = target
        player.timestamp = now
        self.player = player
        positionHeldUntil = now.addingTimeInterval(1.5)
        onSeek(target, bundleID)
    }

    func scrub(_ on: Bool) { onScrub?(on) }

    func clear() {
        player = nil
        bundleID = nil
        title = ""
        positionHeldUntil = nil
        playingHeldUntil = nil
        subtitles.clear()
        onScrub?(false)
    }
}
