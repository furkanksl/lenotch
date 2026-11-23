import AppKit
import IslandCore
import NowPlaying
import Observation
import OSLog
import QuartzCore

/// Lyrics timing (instrumentation, 11-07): every player report, every line change, every check of the clock.
let lyricsLog = Logger(subsystem: "com.lenotch.app", category: "lyrics")
/// Every press on the island and what it did (owner, 11-07: "sometimes your click does nothing or does the wrong thing").
let clickLog = Logger(subsystem: "com.lenotch.app", category: "click")

/// A pending piece of choreography that can be called off.
@MainActor
final class Scheduled {
    private let onCancel: () -> Void
    init(onCancel: @escaping () -> Void = {}) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}

/// Runs `body` after `seconds` of animator time (slow motion slows it too).
typealias Schedule = @MainActor (_ seconds: Double, _ body: @escaping @MainActor () -> Void) -> Scheduled

/// Everything the island does that isn't drawing: the island's state (`Island`, the pure reducer),
/// the sample activities and music, the timers that end transients and alerts, and the pointer
/// rules (hover, press, drag, swipe up, the linger). Ported from the simulator's controller.
@MainActor @Observable
final class IslandDirector {
    private(set) var island = Island()
    let prompter: PrompterModel
    /// The to-do lists. Without one given the director keeps them in memory only, so a test never touches the real file.
    let todos: TodoStore
    let notes: NotesStore
    let videoPlayback = VideoPlaybackState()
    @ObservationIgnored var analytics: Analytics
    @ObservationIgnored private var pendingTraySource: String?
    @ObservationIgnored private let prompterEditor = PrompterEditor()

    init(prompter: PrompterModel? = nil, askVoice: ChatGPTVoiceSession? = nil,
         voiceAccountConnected: @escaping () -> Bool = { ChatGPTAccount.shared.isConnected },
         chatDefaults: UserDefaults = .standard, systemUsage: SystemUsageModel? = nil,
         toolMenu: ToolMenuModel? = nil, todos: TodoStore? = nil, notes: NotesStore? = nil,
         analytics: Analytics = .shared) {
        self.prompter = prompter ?? PrompterModel()
        self.todos = todos ?? TodoStore(storageURL: nil)
        self.notes = notes ?? NotesStore(storageURL: nil)
        self.askVoice = askVoice ?? ChatGPTVoiceSession()
        self.voiceAccountConnected = voiceAccountConnected
        self.chatDefaults = chatDefaults
        self.systemUsage = systemUsage ?? SystemUsageModel()
        self.toolMenu = toolMenu ?? ToolMenuModel(defaults: chatDefaults)
        self.analytics = analytics
        self.askProvider = ChatPreferences.provider(in: chatDefaults)
        tray.onGo = { [weak self] page in
            guard let self else { return }
            if page == .launcher {
                tray.go(.main)
                showLauncher(source: "tray")
                return
            }
            if let feature = page.analyticsFeature {
                let source = pendingTraySource ?? "tray"
                pendingTraySource = nil
                self.analytics.trackFeature(feature, action: "open", data: ["source": .string(source)])
            }
            if page != .notifications && notificationInbox.composing {
                notificationInbox.cancelComposition()
                onYieldsKey?()
            }
            if page != .today && island.dayLarge { send(.closeDay) }
            else { changed() }
        }
        self.toolMenu.onChange = { [weak self] tool in self?.toolMenuChanged(tool) }
    }

    // Media: what's really playing (P2), or the samples while the debug panel plays them.
    private(set) var nowPlaying: NowPlaying?
    /// The cover and the colour taken from it, decoded once per cover.
    private(set) var artwork: Artwork?
    /// The sample music is on (it takes the island over from the real feed until stopped).
    private(set) var sampleOn = false
    private(set) var samplePlaying = true
    private(set) var trackIndex = 0
    /// The sample's elapsed time from (base, timestamp), not from tick counting.
    @ObservationIgnored private var elapsedBase = 0.0
    @ObservationIgnored private var elapsedAt = 0.0
    /// Where the real feed comes from (debug readout).
    var nowPlayingSource = "none"
    /// The real context drives the island (off while the debug panel fakes one).
    var liveContext = true
    /// The last context the system reported (debug readout, and what "Live" goes back to).
    private(set) var systemContext = DesktopContext()

    // System levels for the HUD
    private(set) var hudLevel = 0.5
    private(set) var volume = 0.5
    private(set) var brightness = 0.625

    // Sample activities
    private(set) var samples = SampleState()
    // Live data (P4): what the real activities show.
    private(set) var power: PowerInfo?
    private(set) var meeting: MeetingInfo?
    private(set) var pods: PodsInfo?
    private(set) var transfer: TransferInfo?
    /// Pause/resume and Show in Finder for a live transfer.
    @ObservationIgnored var transferControl: ((ActivityAction) -> Void)?
    /// Showings started by the debug panel draw the samples; the rest draw live data.
    @ObservationIgnored private var sampleSerials: Set<Int> = []
    /// The activity the content draws: lingers a moment after it ends so it can fade out.
    private(set) var shownActivity: ActivityInstance?
    /// The activity whose card shows: a ball's when its card is open, else the ears' (lingering while it leaves).
    var cardShown: ActivityInstance? { island.cardActivity ?? shownActivity }
    /// Bumped by the ticker (4 Hz while something live is visible) so clocks redraw.
    private(set) var now = 0.0

    /// Content has been asked to leave before the shape changes (closing).
    private(set) var contentHeld = false
    /// The debug panel forced a shape.
    private(set) var forcedMode: PresentationMode?

    /// The Messages reply field has focus: the card stays open while typing.
    var replyFocused = false

    /// What's in the tray (the island decides when it shows).
    let tray = TrayModel()
    let notificationInbox = NotificationInbox()
    let launcher = LauncherModel.shared
    let usage = UsageModel.shared
    let systemUsage: SystemUsageModel
    /// Which tools the tools menu shows (Setup's Tools page).
    let toolMenu: ToolMenuModel
    var sendNotificationReply: ((Notice, String) async throws -> String)?
    @ObservationIgnored private var notificationReplyTask: Task<Void, Never>?
    /// The pointer is over the empty notch: it swells a little to say a press opens the tray.
    private(set) var idleHover = false

    // Pointer
    private(set) var pressed = false
    /// The card's drag from where the press started (pt), while pressed on the card.
    private(set) var drag: SIMD2<Double>?
    @ObservationIgnored private var dragStart: SIMD2<Double>?
    @ObservationIgnored private var notchPress = false
    @ObservationIgnored private var suppressClick = false
    @ObservationIgnored private var noRehover = false
    @ObservationIgnored private var hoverOff: Scheduled?
    /// When a press opened a card (real time): a second press soon after on the notch opens the tray's tools.
    @ObservationIgnored private var pressOpenedAt: Double?

    // Wiring to the surface
    @ObservationIgnored var tuning: () -> Tuning = { Tuning() }
    @ObservationIgnored var reduceMotion: () -> Bool = { false }
    /// Animator time in seconds (slowed by the debug time scale).
    @ObservationIgnored var clock: () -> Double = { CACurrentMediaTime() }
    @ObservationIgnored var schedule: Schedule = IslandDirector.taskSchedule
    @ObservationIgnored var random: () -> Double = { Double.random(in: 0..<1) }
    /// The wanted shape or what shows on it may have changed.
    @ObservationIgnored var onChange: (() -> Void)?
    /// A jolt of the liquid (power arriving, a button, a nudge).
    @ObservationIgnored var onKick: ((Double) -> Void)?
    /// An activity took over the ears from the ears: a squeeze.
    @ObservationIgnored var onTakeover: (() -> Void)?
    /// A colour pulse on the bloom (opening a card).
    @ObservationIgnored var onPulse: ((String) -> Void)?
    /// Transport commands for the real player.
    @ObservationIgnored var sendCommand: ((MediaCommand) -> Void)?
    /// Seeks the real player (seconds).
    @ObservationIgnored var sendSeek: ((Double) -> Void)?
    /// Real seconds (never slowed), for telling a double click from two clicks.
    @ObservationIgnored var realTime: () -> Double = { CACurrentMediaTime() }
    /// Wall-clock time, for the real feed's (elapsed, timestamp, rate).
    @ObservationIgnored var date: () -> Date = { Date() }
    /// Typed just now (read when something would open by itself).
    @ObservationIgnored var typingNow: (() -> Bool)?
    /// Opens Setup when a feature needs access that has not been granted.
    @ObservationIgnored var onNeedsSetup: (() -> Void)?

    /// A transient's end, per showing (one can wait in a ball while an alert holds the ears).
    @ObservationIgnored private var transientEnds: [Int: Scheduled] = [:]
    @ObservationIgnored private var hudEnd: Scheduled?
    @ObservationIgnored private var pulseLoop: Scheduled?
    @ObservationIgnored private var shownClear: Scheduled?
    @ObservationIgnored private var closing: Scheduled?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var lastAdvance: Double?
    @ObservationIgnored private var leaving: Scheduled?

    var track: FakeTrack { FakeTrack.samples[trackIndex] }

    // MARK: The second player (owner, 11-11: "if I have a video and a music one of them go to the ball")

    /// Another player playing at the same time (a video beside a song). The song keeps the ears; this one waits in a
    /// ball, and while its ball's peek or its card is the one in focus the player views show it.
    private(set) var nowPlaying2: NowPlaying?
    private(set) var artwork2: Artwork?
    /// Sends a command to one player by its app (the second player's controls).
    @ObservationIgnored var sendCommandTo: ((MediaCommand, String) -> Void)?
    @ObservationIgnored var sendSeekTo: ((Double, String) -> Void)?

    func videoPlayerChanged(_ player: NowPlaying) { videoPlayback.update(player) }

    var secondInFocus: Bool {
        guard island.media2On else { return false }
        return (island.opened && island.cardOwner == .media2) || island.peekBall == .media2
    }

    /// The second player's info, for its ball and (in focus) the player views.
    var media2: MediaInfo {
        let np = nowPlaying2
        return MediaInfo(id: "2:" + (np?.title ?? ""), title: np?.title ?? "", artist: np?.artist ?? "", duration: np?.duration,
                         colorHex: artwork2?.colorHex ?? "#FFFFFF", artwork: artwork2, sample: nil)
    }

    func nowPlaying2Changed(_ np: NowPlaying?) {
        if let np { videoPlayback.update(np) }
        if np == nil, let pinned = videoPlayback.snapshot,
           pinned.bundleID == nowPlaying2?.bundleID,
           pipOpen || (island.mediaFocus && island.cardOwner == .media2) {
            // The main-player sorter hides paused alternatives. Keep the explicitly watched video, rather than
            // closing its card or redirecting Resume to the music player.
            nowPlaying2 = pinned
            return
        }
        if let data = np?.artwork { if data != artwork2?.data { artwork2 = Artwork(data: data) } } else if np == nil { artwork2 = nil }
        nowPlaying2 = np
        island.media2Title = np?.title ?? ""
        if let np, np.playing, let app = np.bundleID { send(.startMedia2(app)) } else { send(.stopMedia2) }
    }

    /// What the content shows for media.
    var media: MediaInfo {
        if secondInFocus { return media2 }
        if !sampleOn, let np = nowPlaying {
            return MediaInfo(id: np.title, title: np.title, artist: np.artist, duration: np.duration,
                             colorHex: artwork?.colorHex ?? "#FFFFFF", artwork: artwork, sample: nil)
        }
        let t = track
        return MediaInfo(id: "sample\(trackIndex)", title: t.title, artist: t.artist, duration: t.length,
                         colorHex: t.colorHex, artwork: nil, sample: t)
    }

    var playing: Bool {
        if secondInFocus { return nowPlaying2?.playing == true }
        return sampleOn || nowPlaying == nil ? samplePlaying : nowPlaying?.playing == true
    }

    /// What the liquid should be doing now.
    var mode: PresentationMode { forcedMode ?? island.mode }

    /// While closing, the shape waits for the content to leave first.
    var holdsShape: Bool { closing != nil }

    /// Which content shows.
    var groups: ContentGroups {
        if let forcedMode {
            var g = ContentGroups()
            g.hud = forcedMode == .hud
            g.dictation = forcedMode == .dictation
            return g
        }
        var g = island.groups(mode)
        if contentHeld { g.musicEars = false; g.peek = false; g.player = false }
        return g
    }

    var elapsed: Double {
        if secondInFocus, let np = nowPlaying2 { return np.elapsed(at: date()) }
        if !sampleOn, let np = nowPlaying {
            let reported = np.elapsed(at: date())
            // Just after a seek the player's reports lag: hold the new place for up to 1.5 s unless they agree.
            if let h = seekHold, date().timeIntervalSince(h.at) < 1.5 {
                let held = h.value + (np.playing ? date().timeIntervalSince(h.at) : 0)
                if abs(reported - held) > 1.5 { return np.duration.map { min(held, $0) } ?? held }
            }
            return reported
        }
        guard island.mediaOn, samplePlaying else { return elapsedBase }
        return (elapsedBase + (clock() - elapsedAt)).truncatingRemainder(dividingBy: track.length)
    }

    /// The colour the moment belongs to: the activity's, else the album's.
    var eventColor: String {
        if let a = island.activity { return color(of: a.id) }
        return media.colorHex
    }

    /// The aura colour while something sets one (album glow).
    var auraHex: String? {
        if let a = island.activity { return color(of: a.id) }
        return island.mediaOn ? media.colorHex : nil
    }

    func color(of id: ActivityID) -> String {
        ActivitySpec[id].colorHex
    }

    // MARK: - Island events

    private func send(_ event: IslandEvent) {
        forcedMode = nil
        let trayWas = groups.tray
        let effects = island.apply(event)
        if !island.opened {
            notificationInbox.cancelComposition()
            onYieldsKey?()
        }
        if groups.tray && !trayWas { tray.opened() }   // it starts at the grid (or the Shelf for a drag)
        for e in effects { perform(e) }
        if !island.mediaFocus && !pipOpen && videoMirror.state != .idle { videoMirror.stop() }   // the video's view closed
        // Pausing can remove a video from the secondary-player ball, but must not close its floating controls.
        if !island.opened && !heldNotices.isEmpty { showHeldNotices() }
        if let a = island.activity {
            if shownActivity != a { shownActivity = a }
            shownClear?.cancel(); shownClear = nil
        } else if shownActivity != nil && shownClear == nil {
            shownClear = schedule(0.4) { [weak self] in
                guard let self else { return }
                shownClear = nil
                if island.activity == nil { shownActivity = nil }
            }
        }
        if island.activity?.id != .incoming { pulseLoop?.cancel(); pulseLoop = nil }
        updateTicker()
        changed()
    }

    private func perform(_ effect: IslandEffect) {
        switch effect {
        case .armTransient(let serial, let seconds):
            transientEnds[serial]?.cancel()
            transientEnds[serial] = schedule(seconds) { [weak self] in
                guard let self else { return }
                transientEnds[serial] = nil
                send(.transientExpired(serial: serial))
            }
        case .nudge:
            _ = schedule(0.2) { [weak self] in self?.kick(55) }
        case .takeover:
            onTakeover?()
        case .redact:
            break                       // the content reads `island.context.presenting`
        }
    }

    private func updateSystemUsageMonitoring() {
        if mode == .card && groups.tray && island.opened && tray.page == .system
            && !island.context.locked && !island.context.presenting
            && !systemContext.locked && !systemContext.presenting {
            systemUsage.start()
        } else {
            systemUsage.stop()
        }
    }

    private func changed() {
        updateSystemUsageMonitoring()
        if askVoiceActive && (island.context.locked || island.context.presenting) {
            if let voice = island.running.first(where: { $0.id == .voice }) { end(serial: voice.serial) }
            return
        }
        syncMediaFacts()
        // Never run the script unseen: alerts, HUDs, a closed card and lock all pause it.
        if mode != .card || !island.opened || island.instance(island.cardOwner)?.id != .prompter || systemContext.lockScreen || island.context.locked {
            prompter.pause()
        }
        if vinylOut && !(island.opened && groups.player) { vinylOut = false }   // it goes back in with the player
        if island.mediaFocus || lockLyrics { loadLyrics() }   // a new song while the lyrics show
        if !island.agents.sessions.isEmpty || !idleLeaves.isEmpty { syncIdleSessions() }
        onChange?()
    }

    /// The island ranks a paused song below a playing one (no ball), and a song hidden from its menu comes back when
    /// the track changes.
    @ObservationIgnored private var lastTrackID: String?
    private func syncMediaFacts() {
        if island.mediaPlaying != playing { island.apply(.playback(playing)) }
        if media.id != lastTrackID {
            lastTrackID = media.id
            if island.mediaHidden { island.apply(.trackChanged) }
        }
    }

    private func kick(_ v: Double) {
        guard !reduceMotion() else { return }   // Reduce Motion: no jolts
        onKick?(v)
    }

    // MARK: - Media

    /// The real feed changed. Like iPhone, media stays while the player has a song, playing or paused,
    /// and leaves when the player quits or drops it (owner, 11-01; this replaced a 10-minute linger).
    ///
    /// A track change arrives in pieces (title, then artist, then the cover a moment later), sometimes with a
    /// brief "nothing playing" between two songs (seen live with a web player in Chrome, 11-01). So the old
    /// cover stays until the new one arrives (at most 1.5 s), and "nothing" has to last 1.5 s before media
    /// leaves; the text crossfades once, on the title.
    func nowPlayingChanged(_ incoming: NowPlaying?) {
        // A browser tab that isn't a player (a page's notification sound) counts as nothing.
        let real = incoming?.isMedia == false ? nil : incoming
        guard var np = real else {
            if nothingHold == nil && nowPlaying != nil {
                nothingHold = schedule(Self.settle) { [weak self] in
                    guard let self else { return }
                    nothingHold = nil
                    artHold?.cancel(); artHold = nil
                    artwork = nil
                    nowPlaying = nil
                    if !sampleOn { applyRealMedia() }
                }
            }
            return
        }
        nothingHold?.cancel(); nothingHold = nil
        if let data = np.artwork {
            artHold?.cancel(); artHold = nil
            if data != artwork?.data { artwork = Artwork(data: data) }
        } else if artwork != nil && artHold == nil {
            // Keep the last cover a moment: the new one usually follows.
            artHold = schedule(Self.settle) { [weak self] in
                guard let self else { return }
                artHold = nil
                if nowPlaying?.artwork == nil { artwork = nil }
            }
        }
        let at = date(), before = nowPlaying.map { $0.elapsed(at: at) }
        // The clock: a repeat that only re-stamps a fresh report keeps it (`NowPlaying.restamps`); anything else sets it.
        if let old = nowPlaying, clockFresh, np.restamps(old) {
            np.timestamp = old.timestamp
        } else {
            clockFresh = at.timeIntervalSince(np.timestamp) < 0.5
        }
        lyricsLog.notice("report \(np.title, privacy: .public) playing=\(np.playing) elapsed=\(np.elapsed, format: .fixed(precision: 3)) age=\(at.timeIntervalSince(np.timestamp), format: .fixed(precision: 3)) est=\(np.elapsed(at: at), format: .fixed(precision: 3)) jump=\((before.map { np.elapsed(at: at) - $0 } ?? 0), format: .fixed(precision: 3))")
        let playerChanged = nowPlaying?.bundleID != np.bundleID
        nowPlaying = np
        adoptShuffle(from: np, playerChanged: playerChanged)
        guard !sampleOn else { return }
        applyRealMedia()
    }

    // MARK: Shuffle

    /// Shuffle on or off, when the player says (nil: unknown; the button still toggles it).
    private(set) var shuffle: Bool?
    @ObservationIgnored var sendShuffle: ((Bool) -> Void)?
    /// Asks the player whether shuffle is on (AppleScript, Music and Spotify).
    @ObservationIgnored var probeShuffle: ((@escaping @MainActor (Bool) -> Void) -> Void)?
    /// A toggle answers at once; the player's own report can lag it, so for a moment the toggle wins.
    @ObservationIgnored private var shuffleHeldUntil: Date?

    private var shuffleHeld: Bool { shuffleHeldUntil.map { date() < $0 } ?? false }

    private func adoptShuffle(from np: NowPlaying, playerChanged: Bool) {
        if playerChanged { shuffle = nil }
        if !shuffleHeld, let s = np.shuffle { shuffle = s }
        if playerChanged, np.shuffle == nil { refreshShuffle() }
    }

    /// Reads shuffle from the player where its Now Playing doesn't carry it.
    func refreshShuffle() {
        guard !sampleOn, nowPlaying != nil, nowPlaying?.shuffle == nil else { return }
        probeShuffle? { [weak self] on in
            guard let self, !self.shuffleHeld else { return }
            self.shuffle = on
        }
    }

    func toggleShuffle() {
        let on = !(shuffle ?? false)
        shuffle = on
        shuffleHeldUntil = date().addingTimeInterval(2)
        if !sampleOn, nowPlaying != nil {
            analytics.trackFeature(.nowPlaying, action: "shuffle")
            sendShuffle?(on)
        }
    }

    /// Opens the playing song in its player (`NowPlayingMonitor.openTrack`: Spotify's track, Music's reveal); false when it
    /// couldn't.
    @ObservationIgnored var openTrack: ((@escaping @MainActor (Bool) -> Void) -> Void)?

    /// The app playing the song (nil for the samples).
    var playerApp: String? { sampleOn ? nil : nowPlaying?.bundleID }

    /// What plays is music (`NowPlaying.isMusic`): the desktop's colours and the lock screen's art follow only music.
    /// Never the samples.
    var mediaIsMusic: Bool { !sampleOn && nowPlaying?.isMusic == true }

    /// The focused player's small button (owner, 11-07: "a small button that'd take me to the song on Spotify"): Spotify
    /// opens on the track, Music reveals it, any other player comes to the front; the focused view closes behind it.
    func openInPlayer() {
        guard let bundle = playerApp else { return }
        analytics.trackFeature(.nowPlaying, action: "open_player")
        clickLog.notice("open in \(bundle, privacy: .public)")
        let activate = {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                app.activate()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        if let openTrack {
            openTrack { opened in if !opened { activate() } }
        } else {
            activate()
        }
        send(.close)
    }

    /// Asks the player for its own position (`NowPlayingMonitor.probePosition`).
    @ObservationIgnored var probePosition: ((@escaping @MainActor (Double, Date) -> Void) -> Void)?
    @ObservationIgnored private var lastProbeOff: Double?

    /// While lyrics show, they check the Now Playing clock against the player's own position every few seconds (owner,
    /// 11-07: "still very delayed"). When the last two checks agree it's off by more than 0.3 s, the clock takes the
    /// player's position. Every check is logged (category `lyrics`, `probe`).
    func checkClock() {
        lyricsDelay = outputLatency()
        guard !sampleOn, let probePosition, let key = nowPlaying?.identity, nowPlaying?.playing == true,
              seekHold.map({ date().timeIntervalSince($0.at) > 2 }) ?? true else { return }
        probePosition { [weak self] position, at in
            guard let self, var np = nowPlaying, np.identity == key, np.playing else { return }
            let off = position - np.elapsed(at: at), last = lastProbeOff
            lyricsLog.notice("probe player=\(position, format: .fixed(precision: 3)) est=\(np.elapsed(at: at), format: .fixed(precision: 3)) off=\(off, format: .fixed(precision: 3))")
            lastProbeOff = off
            guard abs(off) > 0.3, let last, abs(last - off) < 0.3 else { return }
            np.elapsed = position
            np.timestamp = at
            nowPlaying = np
            clockFresh = true
            lastProbeOff = nil
            lyricsLog.notice("probe: the clock takes the player's position")
        }
    }

    /// Whether the clock in `nowPlaying` was fresh when it came (stamped within half a second of arriving): only a fresh
    /// one outlives its re-stamped repeat (a resume can arrive stamped with the pause's time).
    @ObservationIgnored private var clockFresh = false

    /// How long a missing cover or a "nothing playing" may last before the island believes it.
    static let settle = 1.5
    @ObservationIgnored private var nothingHold: Scheduled?
    @ObservationIgnored private var artHold: Scheduled?

    private func applyRealMedia() {
        guard let np = nowPlaying else {
            hideMedia()
            return
        }
        island.mediaApp = np.bundleID ?? BundleID.music
        island.mediaTitle = np.title
        if island.mediaOn { mediaUpdated() } else { showMedia() }
    }

    private func mediaUpdated() {
        updateTicker()
        changed()
    }

    private func showMedia() {
        guard !island.mediaOn else { return }
        closing?.cancel(); closing = nil
        contentHeld = false
        send(.startMedia)
    }

    private func hideMedia() {
        guard island.mediaOn else { return }
        hoverOff?.cancel(); hoverOff = nil
        guard island.activity == nil else { send(.stopMedia); return }
        // Content leaves first, then the liquid closes.
        contentHeld = true
        changed()
        closing = schedule(0.11) { [weak self] in
            guard let self else { return }
            closing = nil
            contentHeld = false
            send(.stopMedia)
        }
    }

    /// Stills for the README: the sample music is this real song instead (through the real feed, cover and all).
    @ObservationIgnored var snapshotSong: NowPlaying?

    /// Debug: the sample music takes the island over from the real feed.
    func startMusic() {
        if let song = snapshotSong { nowPlayingChanged(song); return }
        guard !sampleOn else { return }
        sampleOn = true
        samplePlaying = true
        elapsedAt = clock()
        island.mediaApp = BundleID.music
        if island.mediaOn { mediaUpdated() } else { showMedia() }
    }

    /// Debug: the samples stop; the real feed (if anything plays) comes back.
    func stopMusic() {
        guard sampleOn else { return }
        sampleOn = false
        if nowPlaying != nil { applyRealMedia() } else { hideMedia() }
    }

    func togglePlaying() {
        if secondInFocus, let app = nowPlaying2?.bundleID {
            analytics.trackFeature(.nowPlaying, action: "play_pause")
            sendCommandTo?(.togglePlayPause, app)
            return
        }
        if !sampleOn, var np = nowPlaying {
            analytics.trackFeature(.nowPlaying, action: "play_pause")
            sendCommand?(.togglePlayPause)
            // Answer at once; the player confirms a moment later.
            let now = date()
            np.elapsed = np.elapsed(at: now)
            np.timestamp = now
            np.playing.toggle()
            nowPlaying = np
            clockFresh = true
            applyRealMedia()
            return
        }
        elapsedBase = elapsed
        elapsedAt = clock()
        samplePlaying.toggle()
        updateTicker()
        changed()
    }

    /// The art, title and artist crossfade in place; the card, its controls and the bloom stay put.
    /// (The sim emptied the whole player and flashed a pulse, which read badly live; owner, 11-01.)
    // MARK: Scrubbing the player's bar (11-06, docs/superpowers/specs/2026-11-06-scrubber-design.md)

    /// Holding the bar is using the card: it never closes meanwhile (`unhover`, `clickOutside`).
    private(set) var scrubbing = false
    @ObservationIgnored private var seekHold: (value: Double, at: Date)?

    func scrub(_ on: Bool) {
        guard scrubbing != on else { return }
        scrubbing = on
        if !on, !sampleOn, nowPlaying != nil { analytics.trackFeature(.nowPlaying, action: "scrub") }
        hoverOff?.cancel(); hoverOff = nil
        // Let go off the card: from now on it lingers like any other leave.
        if !on && !island.pointerOnLiquid { unhover() }
    }

    /// Seeks to `seconds`: the sample at once, the real player through the adapter (or AppleScript).
    func seek(to seconds: Double) {
        let length = media.duration ?? 0
        guard length > 0 else { return }
        let s = min(max(seconds, 0), length)
        if sampleOn || nowPlaying == nil {
            elapsedBase = s; elapsedAt = clock()
        } else {
            seekHold = (s, date())
            sendSeek?(s)
        }
        changed()
    }

    // MARK: The focused player and its lyrics (owner, 11-07)

    /// The notch's size in the panel (the surface sets them): a double-click's second press on the notch adds the tools.
    @ObservationIgnored var notchHalfWidth: () -> Double = { 104 }
    @ObservationIgnored var notchHeight: () -> Double = { 37.5 }
    /// The playing song's lyrics once found (`lyricsKey` says for which song), and whether they're being looked up.
    private(set) var lyrics: Lyrics?
    private(set) var lyricsLoading = false
    @ObservationIgnored var fetchLyrics: @Sendable (String, String, String, Double?) async -> Lyrics? = { t, a, al, d in
        await LyricsSource.fetch(title: t, artist: a, album: al, duration: d)
    }
    @ObservationIgnored private var lyricsCache: [String: Lyrics] = [:]

    /// The lock card shows the lyrics (owner, 11-07): they're looked up, and follow a skip, as in the focused view.
    var lockLyrics = false {
        didSet { if lockLyrics { loadLyrics(); lyricsDelay = outputLatency() } }
    }

    /// How late the output plays the song (`OutputLatency`; AirPods 0.17 s): the lyrics follow what you hear, not what
    /// the player has sent. Read when the lyrics open and at every check of the clock.
    @ObservationIgnored var outputLatency: () -> Double = { OutputLatency.seconds() }
    @ObservationIgnored private var lyricsDelay = 0.0

    /// Where the song is in your ears: the lyrics' clock.
    var lyricsElapsed: Double { max(elapsed - lyricsDelay, 0) }

    /// The song's art is the lock screen's wallpaper: the lock card shows no cover of its own and is shorter (owner,
    /// 11-07: "on iPhone, with the big album artwork on the wallpaper it doesn't show on the card and it gets smaller").
    var lockArt = false

    /// Lyrics already in hand (the stills' sample).
    func useLyrics(_ l: Lyrics) { lyricsCache[l.key] = l; lyrics = l }

    /// The player grows into the focused view: the cover large, the title, the synced lyrics, the controls.
    /// Mirrors a video into the island while its focused view shows (`VideoMirror`), or into picture in picture.
    let videoMirror = VideoMirror()
    @ObservationIgnored lazy var pip: VideoPiP = {
        let p = VideoPiP()
        p.onClose = { [weak self] in self?.closePiP() }
        p.onBackToIsland = { [weak self] in self?.pipBackToIsland() }
        return p
    }()
    private(set) var pipOpen = false
    /// Which player the picture in picture shows (to bring it back to its card).
    @ObservationIgnored private var pipParty: Party = .media

    /// The video's view pops out into its own floating window; the island closes behind it.
    func popOutVideo() {
        guard island.mediaFocus, island.focusVideo else { return }
        analytics.trackFeature(.notchVideo, action: "pip")
        pipParty = island.cardOwner
        pipOpen = true
        pip.show(layer: videoMirror.pipLayer, aspect: videoMirror.aspect, playback: videoPlayback)
        send(.close)
    }

    func closePiP() {
        pipOpen = false
        pip.hide()
        videoMirror.stop()
        videoPlayback.clear()
    }

    func pipBackToIsland() {
        pipOpen = false
        pip.hide()
        if let video = videoPlayback.snapshot, let app = video.bundleID {
            if nowPlaying?.bundleID == app {
                pipParty = .media
            } else {
                nowPlaying2 = video
                send(.startMedia2(app))
                pipParty = .media2
            }
            openCard(pipParty)
            island.focusVideo = true
            send(.focusMedia)
        } else {
            openCard(pipParty)
            openFocus()
        }
    }

    /// The player in focus is a video (YouTube in a browser, a movie): its focused view shows the video, not lyrics.
    var focusedIsVideo: Bool {
        if island.mediaFocus && island.focusVideo && videoPlayback.available { return true }
        let np = secondInFocus ? nowPlaying2 : (sampleOn ? nil : nowPlaying)
        return np.map { $0.kind == .video || !$0.isMusic } ?? false
    }

    func openFocus() {
        clickLog.notice("open lyrics (media on: \(self.island.mediaOn))")
        guard island.mediaOn else { return }
        hoverOff?.cancel(); hoverOff = nil
        let video = focusedIsVideo, np = secondInFocus ? nowPlaying2 : nowPlaying
        island.focusVideo = video
        send(.focusMedia)
        if video, let np, let app = np.bundleID {
            analytics.trackFeature(.notchVideo, action: "mirror")
            prepareVideoPlayback(np)
            videoMirror.start(app: app, title: np.title)
            if videoMirror.state == .needsPermission { onNeedsSetup?() }
            onPulse?(media.colorHex); kick(35)
            return
        }
        if !sampleOn, nowPlaying != nil { analytics.trackFeature(.nowPlaying, action: "lyrics") }
        onPulse?(media.colorHex)
        kick(35)
        lyricsDelay = outputLatency()
        loadLyrics()
    }

    private func prepareVideoPlayback(_ player: NowPlaying) {
        videoPlayback.date = { [weak self] in self?.date() ?? Date() }
        videoPlayback.onCommand = { [weak self] command, app in self?.sendCommandTo?(command, app) }
        videoPlayback.onSeek = { [weak self] seconds, app in self?.sendSeekTo?(seconds, app) }
        videoPlayback.onScrub = { [weak self] on in self?.scrub(on) }
        videoPlayback.bind(player)
    }

    func retryVideo() {
        let np = secondInFocus ? nowPlaying2 : nowPlaying
        guard let np, let app = np.bundleID, focusedIsVideo else { return }
        videoMirror.start(app: app, title: np.title)
        if videoMirror.state == .needsPermission { onNeedsSetup?() }
    }

    /// Looks the song's lyrics up once per song while the focused view shows.
    private func loadLyrics() {
        let m = media, key = LyricsSource.key(title: m.title, artist: m.artist)
        guard lyrics?.key != key else { return }
        if let cached = lyricsCache[key] { lyrics = cached; return }
        lyrics = nil
        guard !m.title.isEmpty, !lyricsLoading else { return }
        lyricsLoading = true
        let fetch = fetchLyrics, album = nowPlaying?.album ?? ""
        Task { [weak self] in
            let found = await fetch(m.title, m.artist, album, m.duration)
            guard let self else { return }
            lyricsLoading = false
            let result = found ?? Lyrics(key: key, lines: [], plain: [])
            lyricsCache[key] = result
            if LyricsSource.key(title: media.title, artist: media.artist) == key { lyrics = result } else if island.mediaFocus || lockLyrics { loadLyrics() }
        }
    }

    // MARK: The record (owner, 11-07: "something cool if you click the album artwork")

    /// The player's record is out of its sleeve, turning with the song.
    private(set) var vinylOut = false

    func toggleVinyl() {
        vinylOut.toggle()
        if !sampleOn, nowPlaying != nil { analytics.trackFeature(.nowPlaying, action: "vinyl") }
        onPulse?(media.colorHex)
        kick(vinylOut ? 30 : 18)
    }

    func nextTrack(_ step: Int = 1) {
        if secondInFocus, let app = nowPlaying2?.bundleID {
            analytics.trackFeature(.nowPlaying, action: step < 0 ? "previous" : "next")
            sendCommandTo?(step < 0 ? .previous : .next, app)
            return
        }
        if !sampleOn, nowPlaying != nil {
            analytics.trackFeature(.nowPlaying, action: step < 0 ? "previous" : "next")
            sendCommand?(step < 0 ? .previous : .next)
            return
        }
        guard island.mediaOn else { startMusic(); return }
        let n = FakeTrack.samples.count
        trackIndex = (trackIndex + step + n) % n
        elapsedBase = 0
        elapsedAt = clock()
        changed()
    }

    // MARK: - HUD (volume and brightness take over the ears)

    func volumeUp() {
        volume = volume >= 1 ? 0.25 : min(volume + 0.125, 1)
        levelAlert(.volume, volume)
    }

    func brightnessUp() {
        brightness = brightness >= 1 ? 0.25 : min(brightness + 0.125, 1)
        levelAlert(.brightness, brightness)
    }

    /// A real volume or brightness change (the key tap): the HUD takes over the ears.
    func levelChanged(brightness isBrightness: Bool, level: Double) {
        if isBrightness { brightness = level } else { volume = level }
        levelAlert(isBrightness ? .brightness : .volume, level)
    }

    private func levelAlert(_ kind: HUDKind, _ level: Double) {
        kick(18)                            // each press is felt in the liquid
        hudLevel = level
        // A key pressed mid-drag moves the drag's starting point, so the slider and the key never fight.
        if let d = hudDrag { hudDrag = (x: d.lastX, level: level, lastX: d.lastX) }
        hudEnd?.cancel()
        if !hudHeld { hudEnd = schedule(Self.hudLinger) { [weak self] in self?.send(.hudEnded) } }
        send(.hud(kind))
    }

    // The HUD is a slider (v1, 11-11): press anywhere on it and drag sideways; the level follows the bar one to one. While
    // the pointer is on it or it's held it stays; it leaves on the usual delay after both end.
    nonisolated static let hudLinger = 1.4
    /// The bar's width in the HUD (`HUDLayer`): a drag this long goes from 0 to 100%.
    nonisolated static let hudBarWidth = 62.0
    /// Sets the system level (volume through CoreAudio, brightness through DisplayServices); false when it can't.
    @ObservationIgnored var setLevel: ((HUDKind, Double) -> Bool)?
    /// The pointer is on the HUD or dragging it: the bar thickens and nothing times out.
    private(set) var hudHeld = false
    /// The level couldn't be set (brightness on a display DisplayServices won't drive): the bar only shows it.
    private(set) var hudReadOnly = false
    @ObservationIgnored private var hudDrag: (x: Double, level: Double, lastX: Double)?
    /// A press is being dragged (the card or the HUD): the panel keeps the pointer wherever it goes.
    var holdsPointer: Bool { pressed || hudDrag != nil }
    @ObservationIgnored private var hudHovered = false

    private func hudHover(_ on: Bool) {
        hudHovered = on
        updateHUDHeld()
    }

    private func updateHUDHeld() {
        let held = hudHovered || hudDrag != nil
        guard held != hudHeld else { return }
        hudHeld = held
        hudEnd?.cancel(); hudEnd = nil
        if !held, island.hud != nil { hudEnd = schedule(Self.hudLinger) { [weak self] in self?.send(.hudEnded) } }
    }

    /// The level a drag asks for: where it started plus how far it went, on the bar's scale.
    nonisolated static func hudDragLevel(startLevel: Double, startX: Double, x: Double) -> Double {
        min(max(startLevel + (x - startX) / hudBarWidth, 0), 1)
    }

    private func hudDragged(to x: Double) {
        guard let d = hudDrag, let kind = island.hud else { return }
        hudDrag = (x: d.x, level: d.level, lastX: x)
        let level = Self.hudDragLevel(startLevel: d.level, startX: d.x, x: x)
        guard level != hudLevel else { return }
        if setLevel?(kind, level) ?? false {
            hudReadOnly = false
            hudLevel = level
            if kind == .brightness { brightness = level } else { volume = level }
        } else {
            hudReadOnly = true
        }
    }

    // MARK: - Dictation

    /// What dictation shows in the notch (`DictationCoordinator.indicator`), nil while it isn't there. It holds the ears,
    /// as the HUD does for a moment (`Island.dictating`).
    private(set) var dictation: DictationCoordinator.Indicator?
    /// The words heard so far, while dictation listens and works (`DictationCoordinator.liveText`).
    private(set) var dictationTranscript = ""

    /// Dictation started, moved on (listening, working, done), heard more, or ended. Starting and ending change the
    /// island; new words change what the lip under the notch holds; the rest is the content's.
    func dictationChanged(_ indicator: DictationCoordinator.Indicator?, transcript: String = "") {
        let lipBefore = dictationLipText
        dictation = indicator
        dictationTranscript = indicator == nil ? "" : transcript
        if island.dictating != (indicator != nil) {
            send(.dictation(indicator != nil))
        } else if dictationLipText != lipBefore {
            changed()   // the lip may grow a line, or go
        }
    }

    /// The lip's text column: the dictation ears' resting width, less its margins.
    var dictationTextWidth: Double {
        let t = tuning()
        return 2 * (notchHalfWidth() + t.dictationExtent + t.peekExtra) - 2 * DictationText.inset
    }

    /// How many lines the lip holds (0 with no lip): the shape grows to fit them.
    var dictationLipLines: Int { dictationLipText.map { DictationText.lines($0, width: dictationTextWidth) } ?? 0 }

    /// Snapshots draw a voice instead of the mic's real meter (`SnapshotRunner`).
    @ObservationIgnored var sampleDictationMeter: DictationMeter?

    /// The words under the notch: what you're saying as it's heard, or a problem's message. Your words stay off the
    /// notch while you're presenting, like a notification's.
    var dictationLipText: String? {
        switch dictation {
        case .problem(let message)?: return message
        case .listening?, .working?:
            guard !dictationTranscript.isEmpty, !island.context.presenting else { return nil }
            return dictationTranscript
        default: return nil
        }
    }

    // MARK: - Activities

    /// Puts an activity on the island. `sample`: the debug panel's sample data rather than live data.
    func show(_ id: ActivityID, opened: Bool? = nil, sample: Bool = true) {
        if !island.running.contains(where: { $0.id == id }) {
            samples.reset(id)
            if sample, id == .chess { chessClock = ChessSample.now(chessStep).myClock }
        }
        let before = island.running.map(\.serial).max() ?? 0
        // Typing only matters at the moment something would open by itself: read it now.
        let typed = liveContext && typingNow?() == true && !island.context.typing
        if typed { var c = island.context; c.typing = true; island.apply(.context(c)) }
        send(.show(id, opened: opened))
        if typed { var c = island.context; c.typing = false; island.apply(.context(c)) }
        // The new showing may hold the ears or start in a ball (it ranks below what's there).
        guard let a = island.running.first(where: { $0.id == id && $0.serial > before }) else { return }
        if sample { sampleSerials.insert(a.serial) }
        lastAdvance = clock()
        if island.opened { onPulse?(color(of: id)) }
        if let period = ActivitySpec[id].pulse, !reduceMotion() { startPulseLoop(id, period) }
        arrived(id, serial: a.serial)
        if id == .charging {
            // Plugging in is an event: the liquid jolts as the power arrives (once per showing).
            _ = schedule(0.16) { [weak self] in
                if self?.island.activity?.serial == a.serial { self?.kick(70) }
            }
        }
    }

    func endActivity() {
        guard let a = island.activity else { return }
        end(serial: a.serial)
    }

    /// Ends a showing wherever it is: the ears, a ball, off the island.
    func end(serial: Int) {
        if island.running.first(where: { $0.serial == serial })?.id == .voice { askVoice.stop() }
        transientEnds[serial]?.cancel(); transientEnds[serial] = nil
        if island.activity?.serial == serial { leaving?.cancel(); leaving = nil }
        send(.end(serial: serial))
    }

    /// One right-click model (11-06): the island's part of the menu, for what's under the pointer. The app's own
    /// items follow it (`AppDelegate.makeMenu`).
    func menuEntries(at hit: HitRegion?) -> [IslandMenuEntry] {
        let a = island.arrangement
        var groups: [[IslandMenuEntry]] = []
        if island.live, let p = party(at: hit), island.hideable(p) { groups.append([.hide(p, "Hide \(title(of: p))")]) }
        let also = a.overflow + a.quiet
        if !also.isEmpty { groups.append([.header("Also running")] + also.map { .open($0, title(of: $0), status(of: $0)) }) }
        if !a.hidden.isEmpty { groups.append([.header("Hidden")] + a.hidden.map { .show($0, "Show \(title(of: $0))") }) }
        return groups.flatMap { $0 + [.separator] }
    }

    // MARK: - Agents (phase 2: the balls and approvals)

    /// Approvals waiting on Allow or Deny, by session: the hook's connection, answered once.
    @ObservationIgnored private var approvals: [String: (token: Int, reply: (String?) -> Void)] = [:]
    /// Each option's description as the question gave it, by session and label (shown when you hover the option).
    @ObservationIgnored private var optionDetails: [String: [String: String]] = [:]

    func optionDetail(_ id: String, _ label: String) -> String? { optionDetails[id]?[label] }

    /// A held question's tool input and its text, to answer it with your pick (`updatedInput.answers`).
    @ObservationIgnored private var heldQuestions: [String: (input: [String: Any], question: String, app: String)] = [:]
    @ObservationIgnored private var approvalToken = 0
    /// Sessions the card can still answer (the rest are answered in their app).
    private(set) var answerable: Set<String> = []
    /// The app in front (a session's question waits in its ball while its own app is in front).
    var frontmostApp: () -> String = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }

    /// A hook call arrived. An approval is held for Allow or Deny, and Claude's question for your pick, for up to 24 s
    /// (the hook gives up at 25 and the session asks in its own app); answered at once with nothing when that app is in
    /// front (you're there). Going to that app while a question waits lets the app ask it (`releaseQuestions`).
    func agentHook(_ line: AgentSocket.Line, reply: ((String?) -> Void)?) {
        guard let h = AgentHook(line) else { reply?(nil); return }
        // Codex's own hooks fire for the notch's quick asks too: those sessions are already ours.
        if (h.cwd as NSString).standardizingPath == (QuickAsk.workspace.path as NSString).standardizingPath { reply?(nil); return }
        // A session closed from its chip stays off the island until it needs you (a question or an approval).
        if closedSessions.contains(h.sessionID) {
            let asks = h.tool == "AskUserQuestion" || h.event == "PermissionRequest"
            if h.event == "SessionEnd" { closedSessions.remove(h.sessionID) }
            guard asks else { reply?(nil); return }
            closedSessions.remove(h.sessionID)
        }
        let needed = island.agents.needsYou(h.provider)
        send(.agent(h))
        limitMoment(h, line.json)
        if h.tool == "AskUserQuestion", let q = ((line.json["tool_input"] as? [String: Any])?["questions"] as? [[String: Any]])?.first {
            var details: [String: String] = [:]
            for o in q["options"] as? [[String: Any]] ?? [] {
                if let label = o["label"] as? String, let d = o["description"] as? String, !d.isEmpty { details[label] = d }
            }
            optionDetails[h.sessionID] = details
        }
        let session = island.agents.sessions.first { $0.id == h.sessionID }
        if session?.state != .needs { settleApproval(h.sessionID, nil) }   // answered in its app, or moved on
        if let reply {
            let holds: Bool = switch session?.need {
            case .permission?: true
            case .question?: h.event == "PreToolUse" && h.provider == .claude   // phase 4: answered with your pick
            default: false
            }
            // Held unless you're looking at that very session in its app (then it asks you there).
            if let session, holds, island.context.viewedSession != session.id,
               session.provider == .claude || frontmostApp() != Agents.app(of: session) {
                settleApproval(h.sessionID, nil)
                if case .question(let q, _)? = session.need {
                    heldQuestions[h.sessionID] = (line.json["tool_input"] as? [String: Any] ?? [:], q, Agents.app(of: session))
                }
                approvalToken += 1
                let token = approvalToken, id = h.sessionID
                approvals[id] = (token, reply)
                answerable.insert(id)
                // A permission's hook waits 25 s; a question's up to 10 minutes (reading takes a while).
                let hold: Double = if case .question? = session.need { 590 } else { 24 }
                _ = schedule(hold) { [weak self] in
                    if self?.approvals[id]?.token == token { self?.settleApproval(id, nil) }
                }
            } else {
                reply(nil)
            }
        }
        if island.agents.needsYou(h.provider) && !needed {
            kick(60)
            onPulse?("#FF9F0A")
        }
        // Its chat is showing (the card or the ball's peek): read what's new.
        if let s = island.agents.sessions.first(where: { $0.id == h.sessionID }), showsChat(s) { refreshAgent(s) }
    }

    /// Allow or Deny from the card.
    func answerAgent(_ id: String, allow: Bool) {
        guard approvals[id] != nil else { return }
        analytics.trackFeature(.agentSessions, action: "permission", data: ["decision": .string(allow ? "allow" : "deny")])
        settleApproval(id, AgentHook.decision(allow: allow))
        send(.agentAnswered(id))
        kick(25)
    }

    private func settleApproval(_ id: String, _ answer: String?) {
        approvals.removeValue(forKey: id)?.reply(answer)
        heldQuestions[id] = nil
        answerable.remove(id)
    }

    /// A question's option from the card: the hook lets the tool run with your pick as its answer.
    func answerQuestion(_ id: String, _ option: String) {
        guard approvals[id] != nil, let held = heldQuestions[id] else { return }
        analytics.trackFeature(.agentSessions, action: "question")
        settleApproval(id, AgentHook.answer(input: held.input, question: held.question, option: option))
        send(.agentAnswered(id))
        agentChats[id, default: []].append(.you(option))
        kick(25)
    }

    // MARK: Chats, titles, links and replies (11-06)

    /// Where sessions live on disk (tests point it at a temporary folder).
    @ObservationIgnored var agentDirectory = AgentDirectory.live
    @ObservationIgnored private var claudeRecords: [String: AgentDirectory.ClaudeRecord] = [:]
    @ObservationIgnored private var refreshing: Set<String> = []
    @ObservationIgnored private var refreshAgain: Set<String> = []
    /// Each session's recent chat, read from its transcript (`refreshAgent`; the stills set it directly).
    var agentChats: [String: [AgentChatItem]] = [:]
    /// A session's title: the Claude app's, Codex's thread name (the stills set it directly).
    var agentTitles: [String: String] = [:]
    /// The session each provider's card shows (its chips pick one); else its most urgent.
    private(set) var agentSelected: [AgentProvider: String] = [:]
    /// Where a reply went, under the field (`Queued for Codex`, `Copied: paste it in Claude`).
    private(set) var agentNotes: [String: String] = [:]
    /// Sends a reply to Codex (`codex queue`); tests replace it.
    @ObservationIgnored var codexQueue: @Sendable (String, String) async -> Bool = { thread, text in await AgentReply.codexQueue(thread: thread, text) }
    /// Opens a URL or an app, and copies a reply (tests record both).
    @ObservationIgnored var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored var copyText: (String) -> Void = {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString($0, forType: .string)
    }

    func agentShown(_ p: AgentProvider) -> AgentSession? {
        island.agents.sessions(p).first { $0.id == agentSelected[p] } ?? island.agents.urgent(p)
    }

    func agentTitle(_ s: AgentSession) -> String { agentTitles[s.id] ?? s.project }

    /// The × on a chat chip (owner, 11-07: "put an x here so I can close some sessions"): the notch stops following that
    /// session. Its events are ignored from then on unless it needs you (a question or an approval brings it back); what
    /// it was waiting on goes back to its app. A quick ask's conversation simply ends.
    @ObservationIgnored private var closedSessions: Set<String> = []

    func closeSession(_ s: AgentSession) {
        if s.provider != .ask { closedSessions.insert(s.id) }
        settleApproval(s.id, nil)
        if agentSelected[s.provider] == s.id { agentSelected[s.provider] = nil }
        send(.agent(AgentHook(provider: s.provider, event: "SessionEnd", sessionID: s.id)))
    }

    /// A chip in the card: show that session.
    func selectAgent(_ s: AgentSession) {
        agentSelected[s.provider] = s.id
        if s.state == .done { send(.agentRead(s.id)) }
        refreshAgent(s)
    }

    private func showsChat(_ s: AgentSession) -> Bool {
        if island.opened, island.cardOwner == .agents(s.provider) { return agentShown(s.provider)?.id == s.id }
        let peeking = island.peekBall == .agents(s.provider) || groups.agentsPeek == s.provider   // a ball's or the ears'
        return peeking && agentShown(s.provider)?.id == s.id
    }

    /// Reads the session's transcript and title off the main thread; asked again while reading, it reads once more after.
    func refreshAgent(_ s: AgentSession) {
        guard !askSessions.contains(s.id) else { return }   // the notch's own: its chat is already here
        guard !refreshing.contains(s.id) else { refreshAgain.insert(s.id); return }
        refreshing.insert(s.id)
        let dir = agentDirectory, known = claudeRecords[s.id]
        Task.detached(priority: .utility) { [weak self] in
            let url = s.transcript.isEmpty ? (s.provider == .codex ? dir.codexTranscript(id: s.id) : nil) : URL(fileURLWithPath: s.transcript)
            let chat = url.map { AgentTranscript.read($0, provider: s.provider, limit: 40) } ?? []
            let record = s.provider == .claude ? (dir.claudeRecord(cliID: s.id) ?? known) : nil
            let title = s.provider == .claude ? record?.title : dir.codexName(id: s.id)
            await self?.refreshed(s.id, chat: chat, record: record, title: title)
        }
    }

    private func refreshed(_ id: String, chat: [AgentChatItem], record: AgentDirectory.ClaudeRecord?, title: String?) {
        refreshing.remove(id)
        agentChats[id] = chat
        if let record { claudeRecords[id] = record }
        if let title, !title.isEmpty { agentTitles[id] = title }
        if refreshAgain.remove(id) != nil, let now = island.agents.sessions.first(where: { $0.id == id }) { refreshAgent(now) }
    }

    /// The session itself in its app when the app has a link for it (`claude://code/continue?session=local_…`,
    /// `codex://threads/<id>`), else the app it runs in.
    func openAgentApp(_ p: AgentProvider) {
        if p != .ask {
            analytics.trackFeature(.agentSessions, action: "open_app", data: ["provider": .string(p.rawValue)])
        }
        if let s = agentShown(p) { openSession(s) } else { openApp(Agents.app(p)) }
        send(.close)
    }

    private func openSession(_ s: AgentSession) {
        if s.provider == .claude, claudeRecords[s.id] == nil, Agents.app(of: s) == Agents.app(.claude) {
            // Not looked up yet: find its record first (off the main thread), then open.
            let dir = agentDirectory
            Task.detached(priority: .userInitiated) { [weak self] in
                let record = dir.claudeRecord(cliID: s.id)
                await self?.found(record, for: s)
            }
            return
        }
        if let url = AgentDirectory.link(s, claude: claudeRecords[s.id]) { openURL(url) } else { openApp(Agents.app(of: s)) }
    }

    private func found(_ record: AgentDirectory.ClaudeRecord?, for s: AgentSession) {
        if let record { claudeRecords[s.id] = record }
        if let url = AgentDirectory.link(s, claude: record) { openURL(url) } else { openApp(Agents.app(of: s)) }
    }

    private func openApp(_ bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { openURL(url) }
    }

    /// A ball's peek: who it is, and where it stands (for a session, its state and the last line it wrote; names and
    /// text stay private while presenting).
    func peekText(_ party: Party) -> (title: String, line: String) {
        guard case .agents(let p) = party, let s = agentShown(p) else { return (title(of: party), status(of: party)) }
        let (word, _) = AgentLook.word(s, working: island.agents.sessions(p).filter { $0.state == .working }.count)
        if island.context.presenting { return (p.name, word) }
        let detail: String? = switch s.need {
        case .permission(let tool, let d): d.isEmpty ? tool : d
        case .question(let q, _): q
        case nil: s.state == .error ? s.step : lastLine(s)
        }
        return (agentTitle(s), detail.map { "\(word) · \($0)" } ?? word)
    }

    /// The last line the session's agent wrote, plain.
    func lastLine(_ s: AgentSession) -> String? {
        for item in (agentChats[s.id] ?? []).reversed() {
            guard case .agent(let t) = item else { continue }
            let line = t.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return line.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*-` ")) }
        }
        return nil
    }

    /// How a reply reaches a session: Codex queues it on the thread (`codex queue`); the Claude app (or a terminal) has
    /// no way in yet, so the reply is copied and the session opened to paste it.
    enum ReplyRoute: Equatable { case codexQueue, paste(app: String), ask }

    func replyRoute(_ s: AgentSession) -> ReplyRoute {
        if s.provider == .ask || askSessions.contains(s.id) { return .ask }
        return s.provider == .codex ? .codexQueue : .paste(app: Agents.app(of: s))
    }

    /// The field's placeholder says where the reply goes.
    func replyPlaceholder(_ s: AgentSession) -> String {
        switch replyRoute(s) {
        case .codexQueue: "Reply · sent to Codex"
        case .paste(let app): "Reply · opens \(Self.appName(app)) to paste"
        case .ask: "Ask a follow-up"
        }
    }

    func replyAgent(_ s: AgentSession, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch replyRoute(s) {
        case .codexQueue:
            analytics.trackFeature(.agentSessions, action: "reply", data: ["provider": .string(s.provider.rawValue)])
            agentChats[s.id, default: []].append(.you(text))
            agentNotes[s.id] = "Sending to Codex…"
            let queue = codexQueue
            Task { [weak self] in
                let ok = await queue(s.id, text)
                guard let self else { return }
                if ok { agentNotes[s.id] = "Queued for Codex" } else { paste(text, into: s, note: "Codex didn't take it") }
            }
        case .paste:
            analytics.trackFeature(.agentSessions, action: "reply", data: ["provider": .string(s.provider.rawValue)])
            paste(text, into: s, note: nil)
        case .ask:
            askFollowUp(s, text)
        }
        kick(25)
    }

    private func paste(_ text: String, into s: AgentSession, note: String?) {
        copyText(text)
        agentNotes[s.id] = (note.map { $0 + ": " } ?? "") + "copied, paste it in \(Self.appName(Agents.app(of: s))) and press Return"
        openSession(s)
        send(.close)
    }

    static func appName(_ bundleID: String) -> String {
        switch bundleID {
        case Agents.app(.claude): "Claude"
        case Agents.app(.codex): "ChatGPT"
        default:
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
                FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            } ?? "its app"
        }
    }

    /// A session's line under its name.
    func agentLine(_ s: AgentSession) -> String {
        switch s.state {
        case .needs: if case .question = s.need { "\(s.provider.name) asks you" } else { "\(s.provider.name) wants to run this" }
        case .working: s.step.isEmpty ? "Working" : "Working · \(s.step)"
        case .done: "Done"
        case .ready: "Waiting for you"
        case .error: s.step.isEmpty ? "Stopped" : s.step
        }
    }

    /// A party's name and one line for where it stands, for the island's menu and the +N list.
    func title(of p: Party) -> String {
        switch p {
        case .media: media.title
        case .media2: media2.title
        case .more: "More"
        case .agents(let provider): provider.name
        case .activity, .background: island.instance(p)?.spec.title ?? ""
        }
    }

    func status(of p: Party) -> String {
        switch p {
        case .media: return media.artist + (playing ? "" : " · paused")
        case .media2: return media2.artist
        case .more: return ""
        case .agents(let provider):
            guard let s = island.agents.urgent(provider) else { return "" }
            return "\(s.project) · \(agentLine(s))"
        case .activity, .background:
            guard let a = island.instance(p) else { return "" }
            switch a.id {
            case .voice: return askVoiceStatus
            case .timer: return clockText(samples.timerLeft) + " left"
            case .download: return "\(Int(transferFor(a).fraction * 100))%"
            case .meeting: return "in \(Int((meetingLeft(a) / 60).rounded(.up))) min"
            case .call: return clockText(samples.callSeconds)
            default: return ""
            }
        }
    }

    /// From the island's menu and the +N list: hide a party, show it again, or open its card in place.
    func hide(_ p: Party) { send(.hide(p)); kick(30) }
    func unhide(_ p: Party) { send(.unhide(p)); kick(30) }
    func openCard(_ p: Party) {
        hoverOff?.cancel(); hoverOff = nil
        send(.showCard(p))
        onPulse?(eventColor)
    }

    /// A button on an activity's card: it acts on that card's own activity (the ears' one, or a ball's).
    func perform(_ action: ActivityAction) {
        let target = island.cardActivity ?? island.activity
        let endTarget = { [self] in if let t = target { end(serial: t.serial) } }
        switch action {
        case .accept: show(.call, opened: false)
        case .join:
            if let a = target, !isSample(a), let url = meeting?.joinURL {
                analytics.trackFeature(.today, action: "join_meeting")
                NSWorkspace.shared.open(url)
            }
            endTarget()
        case .decline, .endCall, .cancelTimer, .markRead: endTarget()
        case .mute: samples.muted.toggle(); kick(25)
        case .speaker: samples.speaker.toggle(); kick(25)
        case .pauseTimer: samples.timerPaused.toggle(); kick(25)
        case .pauseDownload:
            if let a = target, !isSample(a) { transferControl?(.pauseDownload) } else { samples.downloadPaused.toggle() }
            kick(25)
        case .send(let text):
            // P4 sends through Messages with AppleScript; the sample only ends the notification.
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            replyFocused = false
            endTarget()
        case .showInFinder:
            if let a = target, !isSample(a) { transferControl?(.showInFinder) }
        case .video, .share, .info:
            break                       // samples only
        }
    }

    private func startPulseLoop(_ id: ActivityID, _ period: Double) {
        pulseLoop?.cancel()
        pulseLoop = schedule(period) { [weak self] in
            guard let self, island.activity?.id == id else { return }
            kick(55)
            startPulseLoop(id, period)
        }
    }

    // MARK: - Live activities (P4)

    func isSample(_ a: ActivityInstance) -> Bool { sampleSerials.contains(a.serial) }

    /// The battery for the charging card: live, or the sample's.
    func powerFor(_ a: ActivityInstance) -> PowerInfo {
        if !isSample(a), let power { return power }
        return PowerInfo(level: 75, charging: true, onAdapter: true, watts: 70, minutesToFull: 42)
    }

    /// The meeting for its ears and card: live, or the sample's ("Design review" in 5 min).
    func meetingFor(_ a: ActivityInstance) -> MeetingInfo {
        if !isSample(a), let meeting { return meeting }
        let start = date().addingTimeInterval(samples.meetingLeft)
        return MeetingInfo(title: "Design review", start: start, end: start.addingTimeInterval(1800), joinURL: nil,
                           initials: ["MC", "JP", "AL"], more: 2)
    }

    /// Seconds until the meeting starts (0 once it has).
    func meetingLeft(_ a: ActivityInstance) -> Double {
        let _ = now
        return max(meetingFor(a).start.timeIntervalSince(date()), 0)
    }

    /// The AirPods for their ears and card: live, or the sample's.
    func podsFor(_ a: ActivityInstance) -> PodsInfo {
        if !isSample(a), let pods { return pods }
        return PodsInfo(name: "AirPods Pro", left: 75, right: 75, caseLevel: 90, single: nil)
    }

    func powerChanged(_ p: PowerInfo) { power = p }

    /// An adapter was plugged in: Charging, with the real battery.
    func pluggedIn(_ p: PowerInfo) {
        power = p
        show(.charging, sample: false)
    }

    /// Today's events (all-day first, then by start), for the day view.
    private(set) var agenda: [AgendaItem] = []

    func agendaChanged(_ a: [AgendaItem]) { agenda = a }

    /// Your day, large (a click on the event card or its ball's peek): the tools at the lyrics player's size, on the day.
    func openDay() {
        guard forcedMode == nil else { return }
        hoverOff?.cancel(); hoverOff = nil
        setIdleHover(false)
        if groups.tray {
            pendingTraySource = "meeting"
            tray.go(.today)
            pendingTraySource = nil
            send(.openDay)
            return
        }
        tray.nextPage = .today
        send(.openDay)
        if groups.tray {
            analytics.trackFeature(.today, action: "open", data: ["source": "meeting"])
        } else {
            tray.nextPage = .main
        }
    }

    /// The next event came within 10 minutes (or ended).
    func meetingChanged(_ m: MeetingInfo?) {
        meeting = m
        let showingReal = island.activity.map { $0.id == .meeting && !isSample($0) } ?? false
        if m != nil && !showingReal {
            show(.meeting, opened: false, sample: false)
        } else if m == nil && showingReal {
            endActivity()
        }
    }

    func podsConnected(_ p: PodsInfo) {
        pods = p
        show(.airpods, sample: false)
    }

    func podsUpdated(_ p: PodsInfo) { pods = p }

    /// The transfer for the download's ears and card: live, or the sample's.
    func transferFor(_ a: ActivityInstance) -> TransferInfo {
        if !isSample(a), let transfer { return transfer }
        let s = samples, total = Int64(SampleState.downloadGB * 1_000_000_000)
        let left = (1 - s.download) * SampleState.downloadGB * 1024 / 42 / 6
        return TransferInfo(name: "Wallpapers-4K.zip", totalBytes: total, doneBytes: Int64(Double(total) * s.download),
                            bytesPerSecond: s.downloadPaused ? nil : s.downloadSpeed * 1_000_000, secondsLeft: left,
                            paused: s.downloadPaused, finished: s.download >= 1)
    }

    /// A download into Downloads began.
    func transferStarted(_ t: TransferInfo) {
        transfer = t
        show(.download, opened: false, sample: false)
    }

    func transferUpdated(_ t: TransferInfo) { transfer = t }

    /// It finished (it stays a moment, then leaves, never while its card is open) or was cancelled.
    func transferEnded(_ t: TransferInfo, finished: Bool) {
        transfer = t
        guard let a = island.activity, a.id == .download, !isSample(a) else { return }
        if finished {
            kick(70)
            scheduleDownloadLeave(a.serial, after: 3)
        } else {
            endActivity()
        }
    }

    // MARK: - Context (debug panel in P1; ContextMonitor in P3)

    func setContext(_ c: DesktopContext) {
        if c.locked || c.presenting {
            onDismissLauncher?()
            notificationReplyTask?.cancel()
            notificationInbox.cancelComposition()
            onYieldsKey?()
        }
        if c.menuOpen || c.fullscreen { hoverOff?.cancel(); hoverOff = nil }
        // Opening a session whose question waits here lets its app ask it at once.
        if let viewed = c.viewedSession, viewed != island.context.viewedSession, heldQuestions[viewed] != nil { settleApproval(viewed, nil) }
        send(.context(c))
    }

    /// The system reported where you are (ContextMonitor).
    func systemContextChanged(_ c: DesktopContext) {
        if c.locked || c.presenting { onDismissLauncher?() }
        let was = systemContext
        systemContext = c
        updateSystemUsageMonitoring()
        if liveContext { setContext(c) }
        if c.lockScreen != was.lockScreen { lockScreenChanged(c.lockScreen) }
        if c.cameraInUse && !was.cameraInUse {
            cameraSince = date()
            show(.camera, opened: false, sample: false)
        } else if !c.cameraInUse && was.cameraInUse {
            cameraSince = nil
            if let a = island.activity, a.id == .camera, !isSample(a) { endActivity() }
        }
    }

    /// When the camera turned on (live camera activity).
    private(set) var cameraSince: Date?

    /// Seconds the camera has been on, and since when.
    func cameraFor(_ a: ActivityInstance) -> (seconds: Double, since: Date) {
        let _ = now
        if !isSample(a), let since = cameraSince { return (max(date().timeIntervalSince(since), 0), since) }
        return (samples.cameraSeconds, date().addingTimeInterval(-samples.cameraSeconds))
    }

    /// The battery for the low-battery card: live, or the sample's.
    func lowPowerFor(_ a: ActivityInstance) -> PowerInfo {
        if !isSample(a), let power { return power }
        let level = samples.lowLevel
        return PowerInfo(level: level, charging: false, onAdapter: false, watts: nil, minutesToFull: nil,
                         minutesToEmpty: level <= 10 ? 35 : 70)
    }

    /// The battery dropped past 20% or 10% on battery power.
    func lowBattery(_ p: PowerInfo) {
        power = p
        show(.battery, sample: false)
    }

    /// Debug: low battery at a level (sample).
    func showLowBatterySample(level: Int) {
        samples.lowLevel = level
        show(.battery)
    }

    /// A timer from the menu bar's Timer menu.
    func startTimer(minutes: Int, source: String = "tray") {
        analytics.trackFeature(.timer, action: "start", data: ["minutes": .int(minutes), "source": .string(source)])
        samples.timerTotal = Double(minutes) * 60
        if island.activity?.id == .timer { endActivity() }
        show(.timer, sample: false)
    }

    // MARK: - Tray

    /// The running timer's time left (nil: no timer).
    var trayTimerLeft: Double? {
        let _ = now
        return island.activity?.id == .timer || island.background.contains { $0.id == .timer } ? samples.timerLeft : nil
    }

    /// Opens the standalone tools menu without interrupting the current activity or playback.
    func openTray(at page: TrayModel.Page = .main, source: String = "notch") {
        guard forcedMode == nil else { return }
        if page == .launcher { showLauncher(source: source); return }
        onDismissLauncher?()
        if groups.tray {
            if page != .main, tray.page != page {
                pendingTraySource = source
                tray.go(page)
                pendingTraySource = nil
            }
            return
        }
        tray.nextPage = page
        hoverOff?.cancel(); hoverOff = nil
        setIdleHover(false)
        send(.openTray)
        if groups.tray {
            onPulse?(island.mediaOn ? eventColor : "#FFFFFF")
            if let feature = page.analyticsFeature {
                analytics.trackFeature(feature, action: "open", data: ["source": .string(source)])
            } else {
                analytics.trackEvent("tray_opened", url: "/app/tray", data: ["source": .string(source)])
            }
        } else {
            tray.nextPage = .main
        }
    }

    func dismissTrayForDictation() {
        if groups.tray { send(.close) }
    }

    /// Files dragged onto the notch: the tray opens at the Shelf. True when it can take them.
    func fileDragEntered() -> Bool {
        openTray(at: .shelf, source: "drag")
        return groups.tray
    }

    func filesDropped(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        analytics.trackFeature(.shelf, action: "drop", data: ["count": .int(urls.count)])
        tray.addFiles(urls)
        kick(35)
    }

    // MARK: - Prompter

    /// Opening the reader never resumes a script behind the user's back.
    func openPrompter() {
        guard prompter.canPlay else { editPrompter(); return }
        prompter.pause()
        show(.prompter, opened: true, sample: false)
    }

    func startPrompter() {
        guard prompter.canPlay else { editPrompter(); return }
        analytics.trackFeature(.prompter, action: "start")
        show(.prompter, opened: true, sample: false)
        // An incoming call can outrank a user-started session. Wait rather than scrolling offscreen.
        if mode == .card && island.instance(island.cardOwner)?.id == .prompter { prompter.start() }
    }

    func editPrompter(source: String = "tray") {
        analytics.trackFeature(.prompter, action: "edit", data: ["source": .string(source)])
        prompter.pause()
        prompterEditor.show(model: prompter) { [weak self] in self?.startPrompter() }
    }

    func stopPrompter() {
        prompter.stop()
        if let session = island.running.first(where: { $0.id == .prompter }) { end(serial: session.serial) }
    }

    // MARK: - Notifications

    /// Which notification each showing is.
    private(set) var noticeBySerial: [Int: Notice] = [:]
    @ObservationIgnored private var sampleNoticeIndex = 0
    /// How long a notification's card stays open by itself before it closes into the ears (owner, 11-11: "a bit clearer
    /// on the preview"; the card is iPhone's banner, then the ears give it two more seconds and it leaves).
    nonisolated static let noticeBannerSeconds = 4.0

    func notice(for instance: ActivityInstance) -> Notice {
        if instance.id == .notice, let selected = notificationInbox.selected { return selected }
        return noticeBySerial[instance.serial] ?? pendingNotice ?? NoticeSamples.arrivals(now: date())[0]
    }

    /// macOS delivered these just now (the store's first read after launch delivers none).
    func noticesChanged(all: [Notice], arrived: [Notice]) {
        notificationInbox.synchronize(all.filter { $0.app != "com.lenotch.app" }, arrived: arrived)
        for n in arrived { notify(n) }
    }

    /// One arrives: its card opens by itself for a few seconds (not over a card you have open, not while you type), then
    /// it waits in the ears and leaves. Skipped where it would intrude (`NoticeArrival.of`).
    func notify(_ n: Notice) {
        noticeBySerial = noticeBySerial.filter { s, _ in island.running.contains { $0.serial == s } || shownActivity?.serial == s }
        guard NoticeArrival.of(n, context: island.context, trayOpen: island.trayShows) == .ears else { return }
        notificationInbox.receive(n)
        if launcherVisible { return }
        // A card is open (you're using it): it waits, and comes when the card closes.
        if island.opened { heldNotices = Array((heldNotices + [n]).suffix(3)); return }
        notificationInbox.select(n)
        notificationInbox.expanded = false
        let before = island.running.map(\.serial).max() ?? 0
        pendingNotice = n
        show(.notice, opened: island.opened ? false : nil, sample: false)
        pendingNotice = nil
        guard let a = island.running.first(where: { $0.id == .notice && $0.serial > before }) else { return }
        noticeBySerial[a.serial] = n
        if n.level == .critical { _ = schedule(0.16) { [weak self] in self?.kick(70) } }
        if island.opened && island.cardOwner == .activity && island.activity?.serial == a.serial {
            _ = schedule(Self.noticeBannerSeconds) { [weak self] in self?.closeNoticeBanner(serial: a.serial) }
        }
        changed()
    }
    /// The one being shown, before its showing has a serial (the first render already draws it).
    @ObservationIgnored private var pendingNotice: Notice?
    /// Arrived while a card was open: shown when it closes, if they're still fresh (the newest three).
    @ObservationIgnored private var heldNotices: [Notice] = []
    nonisolated static let noticeHoldLimit = 60.0

    private func showHeldNotices() {
        let held = heldNotices.filter { date().timeIntervalSince($0.date) < Self.noticeHoldLimit }
        heldNotices = []
        if let newest = held.last { notify(newest) }   // one card; the others macOS keeps in its own list
    }

    /// The banner's time is up: its card closes into the ears, unless the pointer is on it (then it closes like any card
    /// when the pointer leaves).
    private func closeNoticeBanner(serial: Int) {
        guard island.opened, island.cardOwner == .activity, island.activity?.serial == serial,
              !notificationInbox.expanded, !notificationInbox.composing, !notificationInbox.submitting,
              !island.pointerOnLiquid, !pressed else { return }
        send(.close)
    }

    func showTool(_ page: TrayModel.Page, source: String = "tray") {
        openTray(at: page, source: source)
    }

    /// Shortcut access is independent of menu visibility. Repeating the same shortcut closes its
    /// page; a different tool switches in place. Locked/presenting Macs never reveal local content.
    func toggleToolShortcut(_ target: ToolShortcutTarget) {
        guard !island.context.locked, !island.context.presenting,
              !systemContext.locked, !systemContext.presenting else { return }
        switch target {
        case .chat: toggleAsk(source: "shortcut"); return
        case .dictation: onToggleDictation?(); return
        case .launcher: toggleLauncher(source: "shortcut"); return
        default: break
        }
        guard let page = target.page else { return }
        if island.opened, island.trayShows, tray.page == page {
            clickOutside()
        } else { showTool(page, source: "shortcut") }
    }

    func toggleLauncher(source: String = "shortcut") {
        showLauncher(toggle: true, source: source)
    }

    @ObservationIgnored var onShowLauncher: (() -> Void)?
    @ObservationIgnored var onToggleLauncher: (() -> Void)?
    @ObservationIgnored var onDismissLauncher: (() -> Void)?
    private(set) var launcherVisible = false

    private func showLauncher(toggle: Bool = false, source: String = "tray") {
        guard forcedMode == nil, !island.context.locked, !island.context.presenting,
              !systemContext.locked, !systemContext.presenting,
              !notificationInbox.submitting else { return }
        let opening = !(toggle && launcherVisible)
        hoverOff?.cancel(); hoverOff = nil
        setIdleHover(false)
        send(.close)
        if opening {
            analytics.trackFeature(.launcher, action: "open", data: ["source": .string(source)])
        }
        if toggle { onToggleLauncher?() } else { onShowLauncher?() }
    }

    func launcherVisibilityChanged(_ visible: Bool) {
        launcherVisible = visible
        changed()
    }

    func presentationCard(player: CardSize) -> CardSize {
        if island.trayShows {
            switch tray.page {
            case .notifications: return CardSize(width: 420, height: 348, radius: 36)
            case .usage: return CardSize(width: 480, height: 266, radius: 36)
            case .system: return CardSize(width: 400, height: 208, radius: 36)
            case .todo: return CardSize(width: 440, height: 324, radius: 36)
            case .notes: return CardSize(width: 460, height: 348, radius: 36)
            default: break
            }
        }
        if !island.trayShows, island.cardOwner == .activity, island.instance(.activity)?.id == .notice {
            return CardSize(width: 420, height: notificationInbox.expanded ? 348 : 206, radius: 36)
        }
        let card = island.cardSize(player: player)
        // The tools menu is as tall as its rows: a row more or fewer follows the tools turned on in Setup.
        if island.trayShows, tray.page == .main, card == Island.trayOnly {
            return CardSize(width: card.width, height: toolMenu.cardHeight, radius: card.radius)
        }
        return card
    }

    /// A tool turned on or off in Setup. The menu redraws at its new height; a page of a tool just turned off
    /// closes back to the menu, which is the one place a hidden tool's page can't be left open.
    private func toolMenuChanged(_ tool: TrayTool) {
        if !toolMenu.isEnabled(tool), let page = tool.page, tray.page == page, island.trayShows {
            tray.go(.main)
        } else {
            changed()
        }
    }

    func expandNotices(_ expanded: Bool) {
        guard !notificationInbox.submitting else { return }
        notificationInbox.expanded = expanded
        if expanded { notificationInbox.cancelComposition(); onYieldsKey?() }
        changed()
    }

    func selectInboxNotice(_ notice: Notice) {
        guard !notificationInbox.submitting else { return }
        notificationInbox.select(notice)
        notificationInbox.expanded = false
        changed()
    }

    func beginNoticeReply(_ notice: Notice) {
        guard !island.context.locked, !island.context.presenting,
              !notificationInbox.submitting, NotificationReplyService.supports(notice),
              notificationInbox.items.contains(notice) else { return }
        notificationInbox.beginReply(to: notice)
        onWantsKey?()
        changed()
    }

    func cancelNoticeReply() {
        guard !notificationInbox.submitting else { return }
        notificationInbox.cancelComposition()
        onYieldsKey?()
        changed()
    }

    func submitNoticeReply() {
        let inbox = notificationInbox
        guard !island.context.locked, !island.context.presenting,
              inbox.composing, !inbox.submitting,
              let dispatch = sendNotificationReply else { return }
        let text = inbox.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { return }
        guard let target = inbox.beginSubmission() else { return }
        onYieldsKey?()
        notificationReplyTask = Task { [weak self] in
            defer { self?.notificationReplyTask = nil }
            do {
                try Task.checkCancellation()
                let status = try await dispatch(target, text)
                self?.analytics.trackFeature(.inbox, action: "reply")
                inbox.submitting = false
                guard inbox.selected?.id == target.id else { return }
                inbox.draft = ""
                inbox.composing = false
                inbox.feedback = status
            } catch {
                inbox.submitting = false
                guard inbox.selected?.id == target.id else { return }
                inbox.feedback = error.localizedDescription
                if self?.island.context.locked == false && self?.island.context.presenting == false {
                    self?.onWantsKey?()
                }
            }
            self?.changed()
        }
    }

    func clearNotificationInbox() {
        guard !notificationInbox.submitting else { return }
        notificationInbox.clear()
        heldNotices = []
        for activity in island.running where activity.id == .notice { end(serial: activity.serial) }
        onYieldsKey?()
        changed()
    }

    /// The debug panel's Notification button: the next sample, as if macOS had delivered it.
    func notifySample() {
        let all = NoticeSamples.arrivals(now: date())
        let n = all[sampleNoticeIndex % all.count]
        sampleNoticeIndex += 1
        notify(Notice(id: n.id + "-\(sampleNoticeIndex)", app: n.app, appName: n.appName, title: n.title, subtitle: n.subtitle,
                      body: n.body, thread: n.thread, date: date(), level: n.level))
    }

    /// Opens it where it points (its app comes forward) and it leaves the notch.
    func openNotice(_ n: Notice) {
        analytics.trackFeature(.inbox, action: "open_notice")
        dismissNotice(n)
        NoticeOpener.open(n)
    }

    /// × on the card: it leaves the notch.
    func dismissNotice(_ n: Notice) {
        guard !notificationInbox.submitting else { return }
        notificationInbox.dismiss(n.id)
        for (serial, m) in noticeBySerial where m.id == n.id && island.running.contains(where: { $0.serial == serial }) {
            end(serial: serial)
        }
        changed()
    }

    private func setIdleHover(_ on: Bool) {
        guard on != idleHover else { return }
        idleHover = on
        changed()
    }

    /// Debug: the real context drives the island again, or the panel's controls take over.
    func setLiveContext(_ on: Bool) {
        liveContext = on
        if on { setContext(systemContext) }
    }

    // MARK: - Quick ask (agents phase 3, docs/superpowers/specs/2026-11-06-quick-ask-native-design.md)

    @ObservationIgnored let quickAsk = QuickAsk()
    /// Who answers a new conversation (the ask card's switch). The conversation itself is `AgentProvider.ask`: its own
    /// ball, apart from the sessions the notch watches (owner, 11-07).
    private(set) var askProvider: AgentProvider = .codex
    @ObservationIgnored private let chatDefaults: UserDefaults
    let askVoice: ChatGPTVoiceSession
    @ObservationIgnored private let voiceAccountConnected: () -> Bool
    var askVoiceActive: Bool { island.running.contains { $0.id == .voice } }
    var askVoiceOpen: Bool { island.opened && island.cardActivity?.id == .voice }
    static let askVoiceCard = CardSize(width: 420, height: 360, radius: 34)

    var askVoiceStatus: String {
        if case .failed = askVoice.phase { return "Tap to retry" }
        if case .working(let status) = askVoice.phase { return status }
        if askVoice.muted { return "Microphone muted" }
        switch askVoice.phase {
        case .connecting: return "Connecting"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .working(let status): return status
        case .speaking: return "Speaking"
        case .failed: return "Tap to retry"
        }
    }

    func openAskVoice() {
        guard askProvider == .codex, voiceAccountConnected(),
              !island.context.locked, !island.context.presenting else { return }
        replyFocused = false
        hoverOff?.cancel(); hoverOff = nil
        if let voice = island.running.first(where: { $0.id == .voice }) {
            analytics.trackFeature(.voiceMode, action: "reopen")
            openCard(island.activity?.serial == voice.serial ? .activity : .background(voice.serial))
        } else {
            analytics.trackFeature(.voiceMode, action: "start")
            show(.voice, opened: true, sample: false)
            // Starting from the empty Chat composer must hand its card to voice, not leave
            // askOpen in control while the ongoing call appears only as a minimized bubble.
            if let voice = island.running.first(where: { $0.id == .voice }) {
                openCard(island.activity?.serial == voice.serial ? .activity : .background(voice.serial))
            }
            askVoice.start()
        }
        onWantsKey?()
        changed()
    }

    func minimizeAskVoice() {
        guard askVoiceOpen else { return }
        send(.close)
    }

    func endAskVoice() {
        if let voice = island.running.first(where: { $0.id == .voice }) { end(serial: voice.serial) }
        openAsk(.codex, track: false)
        askFocusTick += 1
    }
    /// The field asked for the keyboard (the panel becomes key without activating the app).
    @ObservationIgnored var onWantsKey: (() -> Void)?
    @ObservationIgnored var onToggleDictation: (() -> Void)?
    @ObservationIgnored var onYieldsKey: (() -> Void)?
    /// Bumps when the Ask chat's field should take the keyboard (opening it from its ball, the shortcut).
    private(set) var askFocusTick = 0
    /// Sends a question to its session's process (tests record it instead of starting claude or codex).
    @ObservationIgnored var askSend: ((String, AgentProvider, String) -> Void)?
    /// The notch's own sessions, and who answers each (they leave like any other idle session: `syncIdleSessions`).
    @ObservationIgnored private(set) var askSessions: Set<String> = []
    @ObservationIgnored private(set) var askBackend: [String: AgentProvider] = [:]
    /// When each conversation last had a message, yours or its answer (`recentAsk`).
    @ObservationIgnored private var askLastUsed: [String: Date] = [:]
    /// Each session's leave timer, with the state and serial it was armed for (`syncIdleSessions`).
    @ObservationIgnored private var idleLeaves: [String: (state: AgentState, serial: Int, timer: Scheduled)] = [:]
    /// Bumps when a ball should do a barrel roll (easter egg).
    private(set) var barrelRolls = 0

    /// ⌥Space: opens Ask, or closes it when it's the card showing (owner, 11-07: "the shortcut again should close it").
    func toggleAsk(source: String = "shortcut") {
        let showing = island.opened && (island.askOpen != nil || island.cardOwner == .agents(.ask))
        if showing { closeAsk() } else { openAsk(source: source) }
    }

    /// How long a conversation stays the one Ask opens into (owner, 11-07: "if you open it it goes to the same session
    /// with a time limit"): its last message within this many seconds, else a fresh question.
    static let askContinueWindow = 600.0

    /// The conversation Ask opens into: the latest one, if it was used recently.
    var recentAsk: AgentSession? {
        let now = date()
        return island.agents.sessions(.ask)
            .filter { now.timeIntervalSince(askLastUsed[$0.id] ?? .distantPast) < Self.askContinueWindow }
            .max { (askLastUsed[$0.id] ?? .distantPast) < (askLastUsed[$1.id] ?? .distantPast) }
    }

    /// Ask from the tray, the shortcut or a chat's `+`: a recent conversation opens with its field ready; with none (or
    /// `new`), the ask card starts one.
    func openAsk(_ backend: AgentProvider? = nil, new: Bool = false, source: String = "tray", track: Bool = true) {
        if let backend, backend != .ask {
            askProvider = backend
            chatDefaults.set(backend.rawValue, forKey: ChatPreferences.providerKey)
        }
        hoverOff?.cancel(); hoverOff = nil
        let providerName = askProvider == .claude ? "claude" : "chatgpt"
        if !new, let recent = recentAsk, !island.context.menuOpen, !island.context.fullscreen {
            agentSelected[.ask] = recent.id
            if island.opened && island.cardOwner == .agents(.ask) && island.askOpen == nil { focusAsk(); return }
            if island.opened { send(.close) }
            send(.showCard(.agents(.ask)))
            if track {
                analytics.trackFeature(.chat, action: "open", data: ["provider": .string(providerName), "source": .string(source)])
            }
            focusAsk()
            return
        }
        send(.openAsk(askProvider))
        guard island.askOpen != nil else { return }
        if track {
            analytics.trackFeature(.chat, action: "open", data: ["provider": .string(providerName), "source": .string(new ? "new" : source)])
        }
        onWantsKey?()
    }

    private func focusAsk() {
        onWantsKey?()
        askFocusTick += 1
    }

    func setAskProvider(_ p: AgentProvider) {
        guard askProvider != p, p != .ask else { return }
        askProvider = p
        chatDefaults.set(p.rawValue, forKey: ChatPreferences.providerKey)
        if island.askOpen != nil { send(.openAsk(p)) }
    }

    /// The video's × (it stays open until you close it).
    func closeVideo() { send(.close) }

    func closeAsk() {
        replyFocused = false
        send(.close)
    }

    /// Return in the ask card: a new conversation for the question, its chat card, the answer streaming in.
    func submitAsk(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let backend = askProvider, id = "ask-" + UUID().uuidString.prefix(8).lowercased()
        analytics.trackFeature(.chat, action: "submit", data: [
            "provider": .string(backend == .claude ? "claude" : "chatgpt"),
            "follow_up": false,
        ])
        askSessions.insert(id)
        askBackend[id] = backend
        askLastUsed[id] = date()
        agentChats[id] = [.you(q)]
        agentTitles[id] = Self.askTitle(q)
        askHook("UserPromptSubmit", id)
        agentSelected[.ask] = id
        replyFocused = false
        send(.showCard(.agents(.ask)))
        focusAsk()
        sendAsk(id, backend, q)
        if q.range(of: "barrel roll", options: .caseInsensitive) != nil { _ = schedule(0.9) { [weak self] in self?.barrelRoll() } }
        kick(30)
    }

    /// A follow-up from the chat's reply field goes to the same conversation.
    private func askFollowUp(_ s: AgentSession, _ text: String) {
        let backend = askBackend[s.id] ?? .claude
        analytics.trackFeature(.chat, action: "submit", data: [
            "provider": .string(backend == .claude ? "claude" : "chatgpt"),
            "follow_up": true,
        ])
        agentChats[s.id, default: []].append(.you(text))
        askLastUsed[s.id] = date()
        askHook("UserPromptSubmit", s.id)
        sendAsk(s.id, backend, text)
    }

    /// Ask only sends the text the user typed, never a screen capture.
    private func sendAsk(_ id: String, _ backend: AgentProvider, _ text: String) {
        if let askSend { askSend(id, backend, text) } else { quickAsk.ask(id, provider: backend, text: text) }
    }

    /// The session's title: the question's first words.
    static func askTitle(_ q: String) -> String {
        let one = q.replacingOccurrences(of: "\n", with: " ")
        return one.count > 32 ? String(one.prefix(30)).trimmingCharacters(in: .whitespaces) + "…" : one
    }

    private func askHook(_ event: String, _ id: String, tool: String = "", kind: String = "") {
        send(.agent(AgentHook(provider: .ask, event: event, sessionID: id, cwd: QuickAsk.workspace.path, tool: tool, kind: kind)))
    }

    /// What the process says: text streams into the chat, tools show as the step, the end settles the session.
    func askEvent(_ id: String, _ e: QuickAsk.Event) {
        guard askSessions.contains(id), let s = island.agents.sessions.first(where: { $0.id == id }) else { return }
        askLastUsed[id] = date()
        switch e {
        case .delta(let t):
            var chat = agentChats[id] ?? []
            if case .agent(let prev)? = chat.last { chat[chat.count - 1] = .agent(prev + t) } else { chat.append(.agent(t)) }
            agentChats[id] = chat
        case .tool(let name):
            let label = name == "WebSearch" ? "Searching the web…" : name == "WebFetch" ? "Opening a page…" : name == "WebFind" ? "Finding on a page…" : name
            askHook("PreToolUse", id, tool: label)
            let line = name == "WebSearch" ? "Searched the web" : name == "WebFetch" ? "Read a page" : name == "WebFind" ? "Searched a page" : "Used \(name)"
            agentChats[id, default: []].append(.tools(line, []))
        case .sources(let links):
            if !links.isEmpty { agentChats[id, default: []].append(.sources(links)) }
        case .done(let error):
            if let error {
                agentChats[id, default: []].append(.agent(error))
                askHook("StopFailure", id, kind: "error")
            } else {
                askHook("Stop", id)
                // Read already when its chat is the one showing.
                if island.opened, island.cardOwner == .agents(s.provider), agentShown(s.provider)?.id == id { send(.agentRead(id)) }
            }
        }
    }

    /// Sessions you've stopped using leave the island by themselves (owner, 11-07: "it's always cluttered with chats …
    /// when I stop using one it should disappear after a while"). The Claude app keeps its sessions open for days, so
    /// waiting for `SessionEnd` isn't enough. Counted from the session's last event: read 10 minutes (a quick ask's
    /// ruling), finished-but-unread or stopped by an error 30, working without a word for an hour; one that needs you
    /// never leaves. Any new event re-arms it, and a session that's gone comes back with its next event.
    static func idleLimit(_ state: AgentState) -> Double? {
        switch state {
        case .ready: 600
        case .done, .error: 1800
        case .working: 3600
        case .needs: nil
        }
    }

    private func syncIdleSessions() {
        let live = Set(island.agents.sessions.map(\.id))
        for id in idleLeaves.keys where !live.contains(id) {
            idleLeaves.removeValue(forKey: id)?.timer.cancel()
            if askSessions.remove(id) != nil { quickAsk.end(id); askBackend[id] = nil; askLastUsed[id] = nil }
        }
        for s in island.agents.sessions {
            let key = (s.state, s.serial)
            if let armed = idleLeaves[s.id], armed.state == key.0, armed.serial == key.1 { continue }
            idleLeaves.removeValue(forKey: s.id)?.timer.cancel()
            guard let limit = Self.idleLimit(s.state) else { continue }
            let id = s.id, p = s.provider
            let t = schedule(limit) { [weak self] in
                guard let self, let now = island.agents.sessions.first(where: { $0.id == id }),
                      now.state == key.0, now.serial == key.1 else { return }
                idleLeaves[id] = nil
                send(.agent(AgentHook(provider: p, event: "SessionEnd", sessionID: id)))
            }
            idleLeaves[s.id] = (key.0, key.1, t)
        }
    }

    /// Ask for a barrel roll and the ball does one (and the liquid with it).
    func barrelRoll() {
        barrelRolls += 1
        kick(80)
    }

    // MARK: - The lock screen (11-07, docs/superpowers/specs/2026-11-07-lock-screen-design.md)

    /// You're using the Mac on the lock screen (a key, the trackpad, the mouse within the last moments): the fingerprint
    /// shows, as Face ID's glyph does while it looks (`NotchSurfaceController` reads the input idle time while locked).
    private(set) var lockTouched = false

    func setLockTouched(_ on: Bool) { if lockTouched != on { lockTouched = on } }

    /// Locked: the lock and the fingerprint hold the ears (the song has its own card below the clock). Unlocked: the lock
    /// opens and the fingerprint turns into a check, then the island hands back what was there.
    func lockScreenChanged(_ locked: Bool) {
        if locked {
            for a in island.running where a.id == .unlocked { end(serial: a.serial) }
            if !island.running.contains(where: { $0.id == .lockScreen }) { show(.lockScreen, opened: false, sample: false) }
        } else {
            for a in island.running where a.id == .lockScreen { end(serial: a.serial) }
            show(.unlocked, opened: false, sample: false)
        }
    }

    // MARK: - Chess, the usage limit (11-06, ported from the sim)

    /// Chess: the sample game's step and your running clock.
    private(set) var chessStep = 0
    private(set) var chessClock = ChessSample.now(0).myClock
    /// The usage limit's provider and when it resets (from the hook's text, when it says).
    private(set) var limit = LimitInfo(provider: .claude, resets: "18:00")

    func chessFor(_ a: ActivityInstance) -> (now: ChessSample.Now, step: Int, mine: Double) {
        (ChessSample.now(chessStep), chessStep, chessClock)
    }

    func limitFor(_ a: ActivityInstance) -> LimitInfo { limit }

    /// The moments when something arrives (sim `mount`): the chess move's jolt, the limit's return.
    private func arrived(_ id: ActivityID, serial: Int) {
        switch id {
        case .chess:
            onPulse?(ActivitySpec[.chess].colorHex)
            _ = schedule(0.16) { [weak self] in if self?.island.running.contains(where: { $0.serial == serial }) == true { self?.kick(70) } }
        case .agentBack:
            _ = schedule(0.16) { [weak self] in if self?.island.activity?.serial == serial { self?.kick(60) } }
        case .unlocked:
            // The unlock moment: a green pulse, and the liquid jolts as the lock opens.
            onPulse?(ActivitySpec[.unlocked].colorHex)
            _ = schedule(0.12) { [weak self] in self?.kick(60) }
        default: break
        }
    }

    /// Open game: the chess tab comes to the front. The live route needs the browser extension; the sample plays your
    /// reply and the opponent answers 4 s later (sim `chessOpen`).
    func chessOpen(_ a: ActivityInstance) {
        end(serial: a.serial)
        chessStep = (chessStep + 1) % ChessSample.line.count
        _ = schedule(4) { [weak self] in
            guard let self, !island.running.contains(where: { $0.id == .chess }) else { return }
            show(.chess, opened: false, sample: true)
        }
    }

    /// A usage limit hits (StopFailure `rate_limit`), and the session carries on when it resets.
    private func limitMoment(_ h: AgentHook, _ json: [String: Any]) {
        if h.event == "StopFailure", h.kind == "rate_limit" || h.kind == "billing_error" {
            limit = LimitInfo(provider: h.provider, resets: Self.resetTime(in: json))
            show(.agentLimit, opened: false, sample: false)
        } else if h.event == "Notification", h.kind == "quota_auto_resume_fired" {
            limit.provider = h.provider
            show(.agentBack, opened: false, sample: false)
        }
    }

    /// "6pm", "18:00" from text like "Your limit will reset at 6pm (America/Sao_Paulo)", anywhere in the hook's input.
    static func resetTime(in json: [String: Any]) -> String? {
        var texts: [String] = []
        func collect(_ v: Any) {
            if let s = v as? String { texts.append(s) } else if let d = v as? [String: Any] { d.values.forEach(collect) }
            else if let a = v as? [Any] { a.forEach(collect) }
        }
        collect(json)
        let pattern = #"(?i)resets?\s+(?:at\s+)?(\d{1,2}(?::\d{2})?\s?(?:am|pm)?)"#
        for t in texts {
            guard let r = t.range(of: pattern, options: .regularExpression) else { continue }
            let match = String(t[r])
            if let n = match.range(of: #"\d{1,2}(?::\d{2})?\s?(?:am|pm)?"#, options: [.regularExpression, .caseInsensitive]) {
                return String(match[n]).replacingOccurrences(of: " ", with: "").lowercased()
            }
        }
        return nil
    }

    // MARK: - Debug

    /// The debug panel forced a shape: everything stops.
    func force(_ m: PresentationMode) {
        stopAll()
        forcedMode = m
    }

    func stopAll() {
        systemUsage.stop()
        askVoice.stop()
        for t in [hudEnd, pulseLoop, closing, hoverOff, leaving, shownClear] { t?.cancel() }
        for t in transientEnds.values { t.cancel() }
        transientEnds = [:]; hudEnd = nil; pulseLoop = nil; closing = nil; hoverOff = nil; leaving = nil; shownClear = nil
        sampleOn = false
        idleHover = false
        let context = island.context
        island = Island()
        island.context = context
        shownActivity = nil
        contentHeld = false
        quickAsk.stopAll(); askSessions = []; for t in idleLeaves.values { t.timer.cancel() }; idleLeaves = [:]
        pressed = false; drag = nil
        forcedMode = nil
        updateTicker()
    }

    // MARK: - Ticker

    /// One ticker, only while something live is visible: a clock on the island or the playing player.
    private func updateTicker() {
        let needed = island.running.contains { SampleState.ticks($0.id) }
            || (island.mediaOn && playing && island.mode == .card)
        if needed && ticker == nil {
            lastAdvance = clock()
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        } else if !needed {
            ticker?.invalidate()
            ticker = nil
        }
    }

    /// Advances the sample clocks from elapsed time and handles their endings.
    func tick() {
        let t = clock()
        let dt = max(t - (lastAdvance ?? t), 0)
        lastAdvance = t
        now = t
        // Every running activity keeps time, in the ears, a ball or off the island.
        if island.running.contains(where: { $0.id == .chess }) { chessClock = max(0, chessClock - dt) }
        for a in island.running {
            samples.advance(a.id, dt, random: random)
            if a.id == .timer && samples.timerLeft <= 0 && !samples.timerDone {
                samples.timerDone = true
                kick(90)
                _ = schedule(0.9) { [weak self] in
                    if self?.island.running.contains(where: { $0.serial == a.serial }) == true { self?.end(serial: a.serial) }
                }
            }
            if a.id == .download && samples.download >= 1 && !samples.downloadDone {
                samples.downloadDone = true
                kick(70)
                scheduleDownloadLeave(a.serial, after: 3)
            }
            // A meeting gets a ball only in its last 5 minutes (11-06).
            if a.id == .meeting, a.quiet != (meetingLeft(a) > 300) { island.apply(.quiet(serial: a.serial, meetingLeft(a) > 300)); changed() }
        }
    }

    /// A finished download leaves after a while, but never while its card is open.
    private func scheduleDownloadLeave(_ serial: Int, after seconds: Double) {
        _ = schedule(seconds) { [weak self] in
            guard let self, island.running.contains(where: { $0.serial == serial }) else { return }
            if island.opened && island.cardActivity?.serial == serial { scheduleDownloadLeave(serial, after: 0.5); return }
            end(serial: serial)
        }
    }

    // MARK: - Pointer

    /// The pointer moved. `hit` is what it's over (with the margins), `corridor` the gap above the open card.
    /// `settled`: the pointer has slowed or stopped on the island (hover intent, owner 11-07: "way too often … just moving
    /// my mouse up to close a tab or move a window and it opening … but I also don't want it to be very delayed"). Passing
    /// over it fast opens nothing; leaving is handled either way.
    func pointerMoved(hit: HitRegion?, corridor: Bool, buttonDown: Bool, settled: Bool = true) {
        guard forcedMode == nil else { return }
        if mode == .hud { hudHover(hit != nil); return }
        if mode == .dictation { return }   // nothing previews or opens under dictation
        if hudHovered { hudHover(false) }
        // The empty notch only swells under the pointer; a press opens the tray.
        guard island.live else { setIdleHover(island.canOpenEmptyTray && hit != nil && !buttonDown); return }
        if idleHover { setIdleHover(false) }
        let onShape = hit != nil
        if island.pointerOnLiquid != onShape { island.apply(.pointer(onLiquid: onShape)) }
        guard onShape || corridor else {
            noRehover = false
            unhover()
            return
        }
        hoverOff?.cancel(); hoverOff = nil
        guard settled || island.opened || island.hovered || island.peekBall != nil else { return }   // just passing through
        // A ball has its own hover (owner, 11-06): it swells and peeks; the ears stay as they are.
        if !island.opened && !buttonDown {
            if case .bubble(let i) = hit, let b = island.balls(mode)[i] {
                if asks(b) { if !noRehover { openQuestion(b) } } else if island.peekBall != b { peek(b) }
                return
            }
            if hit == .card, island.peekBall != nil { return }   // on the peek itself
            if island.peekBall != nil { send(.peekBall(nil)) }
            // A session in the ears that needs you shows its question at once, even over its preview.
            if hit == .ears, let e = island.arrangement.ears, asks(e), !noRehover { openQuestion(e); return }
        }
        if island.hovered || noRehover || buttonDown { return }   // dragging a window across the top: not a hover
        send(.hover)
        // Claude or Codex in the ears previews its session: read what it last wrote (sim `agPeek`).
        if let p = groups.agentsPeek, let s = agentShown(p) { refreshAgent(s) }
    }

    private func peek(_ b: Party) {
        send(.peekBall(b))
        if case .agents(let p) = b, let s = agentShown(p) { refreshAgent(s) }
    }

    /// A provider with a session that needs you: hovering it shows the question (owner, 11-06: "if i hover, only the
    /// question"), clicking the chat.
    private func asks(_ party: Party) -> Bool {
        guard case .agents(let p) = party else { return false }
        return island.agents.needsYou(p)
    }

    /// Opens the card on the question alone, on the session asking (the chat it grows into starts there too).
    private func openQuestion(_ party: Party) {
        guard case .agents(let p) = party else { return }
        agentSelected[p] = island.agents.urgent(p)?.id
        send(.openQuestion(party))
        if let s = agentShown(p) { refreshAgent(s) }
    }

    /// The pointer left the liquid and the corridor: it lingers, then closes.
    private func unhover() {
        // Holding the card is using it: the linger starts on release.
        guard island.hovered || island.peekBall != nil, hoverOff == nil, !pressed, !scrubbing else { return }
        if island.holdsOpen { return }      // closes by its buttons, the notch or a click outside
        if askVoiceOpen { return }
        // Notes and To-do stay open when the pointer moves away; clicking outside, the notch, or their shortcut closes them.
        if island.opened && groups.tray && (tray.page == .notes || tray.page == .todo) { return }
        if island.opened && (replyFocused || notificationInbox.composing || notificationInbox.submitting) { return }
        let t = tuning()
        hoverOff = schedule(island.opened ? t.closeDelay : t.leaveDelay) { [weak self] in
            guard let self else { return }
            hoverOff = nil
            send(.unhover)
        }
    }

    /// Which card a press opens: a ball's owner when a ball is pressed (the +N ball opens its list), else the ears'.
    private func pickCard(_ hit: HitRegion?) -> Party {
        party(at: hit) ?? .media
    }

    /// The party under the pointer: a ball's, the open card's, or the ears'.
    func party(at hit: HitRegion?) -> Party? {
        if case .bubble(let i) = hit, let b = island.balls(mode)[i] { return b }
        if hit == .card, island.opened { return island.cardOwner }
        if hit == .card, let b = island.peekBall { return b }   // a press on a ball's peek opens its card
        return island.arrangement.ears
    }

    func pointerDown(at p: SIMD2<Double>, hit: HitRegion?) {
        clickLog.notice("down x=\(Int(p.x - FrameModel.cx)) y=\(Int(p.y)) hit=\(hit.map { "\($0)" } ?? "none", privacy: .public) mode=\("\(self.mode)", privacy: .public) opened=\(self.island.opened) owner=\("\(self.island.cardOwner)", privacy: .public) focus=\(self.island.mediaFocus)")
        suppressClick = false
        notchPress = false
        if forcedMode == nil, mode == .hud, hit != nil {
            hudDrag = (x: p.x, level: hudLevel, lastX: p.x)
            updateHUDHeld()
            suppressClick = true
            return
        }
        // Dictation's ears take a press (it belongs to the island, not the menu bar under it) and do nothing with it:
        // ⌥D finishes, Esc cancels.
        if forcedMode == nil, mode == .dictation, hit != nil {
            suppressClick = true
            return
        }
        // Double-click (owner, 11-07 and 11-11): the second press on the notch itself opens the tools, whatever the first
        // press opened (the empty notch's tray, the player, Claude's chat, an activity's card); on the music anywhere
        // else it grows the player into the focused view with the lyrics. The second press never closes what the first
        // opened. The panel keeps the pointer for the double-click time after a press opens a card, so this second
        // press never reaches the menu bar underneath.
        if forcedMode == nil, let at = pressOpenedAt, realTime() - at < NSEvent.doubleClickInterval, island.opened {
            pressOpenedAt = nil
            suppressClick = true
            if abs(p.x - FrameModel.cx) <= notchHalfWidth() + 6 && p.y <= notchHeight() + 4 {
                openTray()
                return
            }
            if island.cardOwner == .media, island.mediaOn, !groups.tray, !island.mediaFocus { openFocus(); return }
            suppressClick = false
        }
        if forcedMode == nil, island.canOpenEmptyTray, hit != nil {
            openTray()                      // on the press, like every card; the click that ends it belongs to it
            pressOpenedAt = island.opened ? realTime() : nil
            suppressClick = true
            return
        }
        guard forcedMode == nil, mode != .idle, mode != .hud, mode != .dictation, let hit else { return }
        if island.live && !island.opened {
            // Opens on the press itself, so the liquid answers the instant the button goes down.
            // The click that ends this press belongs to it (the ears retract under the pointer).
            let party = pickCard(hit)
            open(party)
            pressOpenedAt = island.opened ? realTime() : nil
            suppressClick = true
            return
        }
        if island.questionOnly {
            // A press on the question grows it into the chat (owner, 11-06: "if i click it shows part of the chat"); a
            // press on another ball opens that one's card.
            let party: Party = if case .bubble = hit { pickCard(hit) } else { island.cardOwner }
            send(.showCard(party))
            if case .agents(let p) = party, let s = agentShown(p) { refreshAgent(s) }
            suppressClick = true
            return
        }
        pressOpenedAt = nil
        if mode == .card {
            // A press on the notch (not the card) while the card is out closes it on release.
            guard hit == .card else { notchPress = true; return }
            dragStart = p
            drag = .zero
        }
        hoverOff?.cancel(); hoverOff = nil
        pressed = true
        changed()
    }

    func pointerDragged(to p: SIMD2<Double>) {
        if hudDrag != nil { hudDragged(to: p.x); return }
        guard pressed, let start = dragStart else { return }
        drag = p - start
        changed()
    }

    func pointerUp(at p: SIMD2<Double>, hit: HitRegion?, corridor: Bool) {
        if hudDrag != nil {
            hudDrag = nil
            hudHovered = hit != nil
            updateHUDHeld()
            suppressClick = false
            return
        }
        if pressed {
            let swipeUp = (drag?.y ?? 0) < -36
            if let d = drag, abs(d.x) + abs(d.y) > 4 { suppressClick = true }
            pressed = false
            drag = nil
            dragStart = nil
            if swipeUp && island.opened {
                // A swipe up closes the card, as on the island.
                suppressClick = true
                send(.close)
                return
            }
            changed()
            // Let go away from the card: from now on it lingers and closes like any other leave.
            if hit == nil && !corridor { unhover() }
        }
        // The click that ends the press.
        if suppressClick { suppressClick = false; return }
        if notchPress {
            // Clicking the notch again closes the card; the preview waits until the pointer has left.
            notchPress = false
            noRehover = true
            send(.close)
            return
        }
        // Reading stays beside the camera while the user works or presents in another app.
        if hit == nil && island.opened && island.instance(island.cardOwner)?.id == .prompter { return }
        // A click on the open player's card (not its buttons) opens the lyrics (owner, 11-07: "if I click something then
        // try to open the lyrics, it doesn't … sometimes I click on the music card and it doesn't open"; only the cover
        // and a double-click whose first press opened the player did).
        if hit == .card, island.opened, island.cardOwner == .media || island.cardOwner == .media2, island.mediaOn,
           !island.mediaFocus, !groups.tray {
            openFocus()
            return
        }
        guard island.live, mode != .hud, mode != .dictation else { return }
        if hit != nil && !island.opened {
            open(pickCard(hit))
        } else if hit == nil && island.opened {
            hoverOff?.cancel(); hoverOff = nil
            send(.close)
        }
    }

    /// A click anywhere else (another app) closes the open card.
    func clickOutside() {
        // The Ask conversation stays open while you use the screen (owner, 11-07).
        let askOpenHere = island.cardOwner == .agents(.ask) && island.askOpen == nil
        // A video watched in the island stays until its × (owner, 11-11: "it should stay even when you click away").
        let watching = island.mediaFocus && island.focusVideo
        let prompting = island.instance(island.cardOwner)?.id == .prompter
        guard island.opened, !pressed, !scrubbing, !askOpenHere, !watching, !prompting else { return }
        hoverOff?.cancel(); hoverOff = nil
        send(.close)
    }

    private func open(_ party: Party) {
        // The lock and the unlock moment live in the ears: a press opens nothing.
        let earsOnly: Bool = switch party {
        case .activity: island.activity?.id.earsOnly == true
        case .background(let serial): island.background.first { $0.serial == serial }?.id.earsOnly == true
        default: false
        }
        if earsOnly { return }
        hoverOff?.cancel(); hoverOff = nil
        send(.open(party))
        if party == .agents(.ask) { focusAsk() }   // its ball opens straight into the field
        // A provider's card opens on its most urgent session and keeps it while open (reading a finished one makes it
        // less urgent; the card mustn't jump to another); the chips pick another.
        if case .agents(let p) = party {
            agentSelected[p] = nil
            if let s = agentShown(p) {
                agentSelected[p] = s.id
                if s.state == .done { send(.agentRead(s.id)) }
                refreshAgent(s)
            }
        }
        onPulse?(eventColor)
    }

    // MARK: - Scheduling

    static let taskSchedule: Schedule = { seconds, body in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            body()
        }
        return Scheduled { task.cancel() }
    }
}

/// Buttons on the activities' cards.
enum ActivityAction: Equatable, Sendable {
    case accept, decline
    case endCall, mute, speaker, video, share, info
    case pauseTimer, cancelTimer
    case join
    case pauseDownload, showInFinder
    case send(String), markRead
}

/// A usage limit: whose, and when it resets (when the hook says).
struct LimitInfo: Equatable {
    var provider: AgentProvider
    var resets: String?
}

/// What the content shows for media, from the real feed or a sample.
struct MediaInfo: Equatable {
    /// Changes with the song (its title): the text crossfades on it.
    var id: String
    /// Changes with the cover: the art crossfades on it, on its own (it can arrive after the title).
    var artKey: String {
        if let a = artwork { return "art\(a.key)" }
        return sample.map { "sample-" + $0.title } ?? "none"
    }
    var title: String
    var artist: String
    var duration: Double?
    /// The bars' colour: the album's, or the sample's.
    var colorHex: String
    var artwork: Artwork?
    var sample: FakeTrack?
}

/// A decoded cover and the colour taken from it.
final class Artwork: Equatable, @unchecked Sendable {
    let data: Data
    let image: NSImage
    let colorHex: String?
    /// The cover's identity, hashed once: views read it every frame (hashing the image there cost ~15% CPU, 11-07).
    let key: Int

    init?(data: Data) {
        guard let image = NSImage(data: data) else { return nil }
        self.data = data
        self.image = image
        colorHex = AlbumColor.hex(from: data)
        key = data.hashValue
    }

    static func == (a: Artwork, b: Artwork) -> Bool { a === b || (a.key == b.key && a.data == b.data) }
}

/// The island's part of the right-click menu.
enum IslandMenuEntry: Equatable {
    case hide(Party, String)
    case header(String)
    case open(Party, String, String)   // title, status
    case show(Party, String)
    case separator
}
