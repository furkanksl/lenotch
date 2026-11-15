import AppKit
import ApplicationServices
import AVFoundation
import CoreBluetooth
import CoreGraphics
import EventKit
import NowPlaying
import OSLog
import SwiftUI

enum SetupPermissionFilter: String, CaseIterable, Identifiable {
    case all, notEnabled, allowed

    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All"
        case .notEnabled: "Not enabled"
        case .allowed: "Allowed"
        }
    }

    func includes(_ state: SetupAccessState) -> Bool {
        switch self {
        case .all: true
        case .notEnabled: state != .allowed
        case .allowed: state == .allowed
        }
    }
}

/// Checks access without asking. A system prompt is only started by one of this page's buttons.
struct SetupPermissionsPage: View {
    @StateObject private var access = SetupPermissionAccess()
    @State private var refreshID = UUID()
    @State private var requestID = UUID()
    @State private var request: SetupPermissionRequest?
    @State private var filter: SetupPermissionFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Label("Managed by macOS", systemImage: "lock.shield")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Picker("Show permissions", selection: $filter) {
                    ForEach(SetupPermissionFilter.allCases) { item in Text(item.title).tag(item) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 256)
                .accessibilityIdentifier("setup-permission-filter")
            }
            if hasAny([access.microphone, access.accessibility]) {
                SetupSection(title: "Dictation", subtitle: "Requested only when you click Allow") {
                    if filter.includes(access.microphone) {
                        SetupPermissionRow(
                            symbol: "mic", title: "Microphone",
                            detail: "Record your voice for on-device dictation.", state: access.microphone
                        ) { allow(.microphone, current: access.microphone, settings: "Privacy_Microphone") }
                        if filter.includes(access.accessibility) { rowDivider }
                    }
                    if filter.includes(access.accessibility) {
                        SetupPermissionRow(
                            symbol: "accessibility", title: "Accessibility",
                            detail: "Insert dictated text in other apps; also enables call controls and hardware-key HUDs.",
                            state: access.accessibility
                        ) { allow(.accessibility, current: access.accessibility, settings: "Privacy_Accessibility") }
                    }
                }
            }
            if hasAny([access.calendar, access.bluetooth]) {
                SetupSection(title: "Everyday essentials") {
                    if filter.includes(access.calendar) {
                        SetupPermissionRow(
                            symbol: "calendar", title: "Calendar",
                            detail: "Upcoming meetings and your daily agenda.", state: access.calendar
                        ) { allow(.calendar, current: access.calendar, settings: "Privacy_Calendars") }
                        if filter.includes(access.bluetooth) { rowDivider }
                    }
                    if filter.includes(access.bluetooth) {
                        SetupPermissionRow(
                            symbol: "headphones", title: "Bluetooth",
                            detail: "AirPods connections and battery levels.", state: access.bluetooth
                        ) { allow(.bluetooth, current: access.bluetooth, settings: "Privacy_Bluetooth") }
                    }
                }
            }
            if hasAny(mediaStates) {
                SetupSection(title: "Music & media") {
                    if access.musicInstalled && filter.includes(access.music) {
                        SetupPermissionRow(
                            symbol: "music.note", title: "Music automation",
                            detail: "Playback controls when Now Playing is unavailable.", state: access.music
                        ) { allow(.music, current: access.music, settings: "Privacy_Automation") }
                        rowDivider
                    }
                    if access.spotifyInstalled && filter.includes(access.spotify) {
                        SetupPermissionRow(
                            symbol: "play.circle", title: "Spotify automation",
                            detail: "Playback controls when Now Playing is unavailable.", state: access.spotify
                        ) { allow(.spotify, current: access.spotify, settings: "Privacy_Automation") }
                        rowDivider
                    }
                    if filter.includes(access.audio) {
                        SetupPermissionRow(
                            symbol: "waveform", title: "Music bars",
                            detail: "Follow your Mac’s audio. Play music to test.", state: access.audio
                        ) { allow(.audio, current: access.audio, settings: "Privacy_AudioCapture") }
                        rowDivider
                    }
                    if filter.includes(access.screen) {
                        SetupPermissionRow(
                            symbol: "play.rectangle", title: SetupScreenCaptureAccess.title,
                            detail: SetupScreenCaptureAccess.detail, state: access.screen
                        ) { allow(.screen, current: access.screen, settings: "Privacy_ScreenCapture") }
                    }
                }
            }
            if filter.includes(access.disk) {
                VStack(alignment: .leading, spacing: 10) {
                    SetupSection(title: "Messages & notifications") {
                        SetupPermissionRow(
                            symbol: "externaldrive", title: "Full Disk Access",
                            detail: access.diskDetail, state: access.disk, actionLabel: "Open Settings"
                        ) { setupOpenPrivacy("Privacy_AllFiles") }
                        .id("full-disk-access")
                    }
                    Text("Enable LeNotch in Full Disk Access. Reopen the app if macOS asks.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !hasAny([access.microphone, access.accessibility, access.calendar, access.bluetooth, access.disk] + mediaStates) {
                VStack(spacing: 10) {
                    Image(systemName: filter == .allowed ? "lock.open" : "checkmark.circle")
                        .font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
                    Text(filter == .allowed ? "No permissions allowed yet" : "Nothing needs your attention")
                        .font(.system(size: 14, weight: .medium))
                    Text("You can use LeNotch without enabling every feature.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
            }
        }
        .task(id: refreshID) { await access.refresh() }
        .task(id: requestID) {
            guard let request else { return }
            await access.ask(request)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: AudioBars.permissionCheckCompleted)) { _ in
            access.audioCheckCompleted()
            refreshID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: MeetingWatcher.accessChanged)) { _ in
            refreshID = UUID()
        }
        .onDisappear {
            request = nil
            requestID = UUID()
            access.stop()
        }
    }

    private var mediaStates: [SetupAccessState] {
        [access.audio, access.screen] + (access.musicInstalled ? [access.music] : [])
            + (access.spotifyInstalled ? [access.spotify] : [])
    }

    private func hasAny(_ states: [SetupAccessState]) -> Bool { states.contains(where: filter.includes) }

    private var rowDivider: some View { SetupTheme.line.frame(height: 0.5).padding(.leading, 62).padding(.trailing, 16) }

    private func allow(_ permission: SetupPermissionRequest, current: SetupAccessState, settings: String) {
        guard !access.isRequesting else { return }
        if current == .denied {
            setupOpenPrivacy(settings)
        } else {
            request = permission
            requestID = UUID()
        }
    }
}

/// Shared with the setup panes; opening Settings never triggers an authorization request itself.
@MainActor
func setupOpenPrivacy(_ anchor: String) {
    let destination = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
    if let url = URL(string: destination) { NSWorkspace.shared.open(url) }
}

private enum SetupPermissionRequest: Equatable {
    case microphone, accessibility, calendar, bluetooth, music, spotify, audio, screen
}

/// macOS names the permission Screen Recording even when the app only displays captured frames, as VideoMirror does.
/// The injectable system calls let tests verify that checking access never triggers the system prompt.
@MainActor
struct SetupScreenCaptureAccess {
    static let title = "Screen Recording"
    static let detail = "Show a video’s window in the notch. No recordings are saved."
    private let preflight: () -> Bool
    private let request: () -> Bool
    private var requested = false

    init(preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() }) {
        self.preflight = preflight
        self.request = request
    }

    var state: SetupAccessState { preflight() ? .allowed : requested ? .denied : .notAsked }

    mutating func ask() {
        requested = true
        _ = request()
    }
}

@MainActor
private final class SetupPermissionAccess: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var microphone: SetupAccessState = .notAsked
    @Published private(set) var accessibility: SetupAccessState = .notAsked
    @Published private(set) var calendar: SetupAccessState = .notAsked
    @Published private(set) var bluetooth: SetupAccessState = .notAsked
    @Published private(set) var music: SetupAccessState = .notAsked
    @Published private(set) var spotify: SetupAccessState = .notAsked
    @Published private(set) var audio: SetupAccessState = .notAsked
    @Published private(set) var screen: SetupAccessState = .notAsked
    @Published private(set) var disk: SetupAccessState = .notAsked
    @Published private(set) var musicInstalled = false
    @Published private(set) var spotifyInstalled = false
    @Published private(set) var isRequesting = false
    @Published private(set) var diskDetail = "Local Messages and stored macOS notifications."

    // EventKit stores must outlive the request. Prefer the watcher's own store so its event queries refresh too.
    private static let calendarStore = EKEventStore()
    private static let log = Logger(subsystem: "com.lenotch.app", category: "setup")
    private var central: CBCentralManager?
    private var asking: SetupPermissionRequest?
    private var audioCheckFinished = false
    private var screenAccess = SetupScreenCaptureAccess()
    private var accessibilityRequested = false
    private var refreshGeneration: UInt64 = 0

    func stop() {
        refreshGeneration &+= 1
        central?.delegate = nil
        central = nil
    }

    func audioCheckCompleted() {
        audioCheckFinished = true
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if asking != .microphone { microphone = Self.microphoneState() }
        if asking != .accessibility {
            accessibility = AXIsProcessTrusted() ? .allowed : accessibilityRequested ? .denied : .notAsked
        }
        if asking != .calendar { calendar = Self.calendarState() }
        if asking != .bluetooth { bluetooth = Self.bluetoothState() }
        if asking != .audio {
            audio = UserDefaults.standard.bool(forKey: AudioBars.heardKey) ? .allowed : .notAsked
        }
        if asking != .screen { screen = screenAccess.state }
        musicInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") != nil
        spotifyInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
        let checkMusic = musicInstalled && asking != .music
        let checkSpotify = spotifyInstalled && asking != .spotify

        // Apple Events can wait on another process; SQLite and protected files can also block.
        let snapshot = await Task.detached(priority: .utility) {
            let messages = MessageStore.readable
            let notifications = NotificationStore.readable
            return (
                messages, notifications,
                checkMusic ? NowPlayingMonitor.automation("com.apple.Music", ask: false) : nil,
                checkSpotify ? NowPlayingMonitor.automation("com.spotify.client", ask: false) : nil
            )
        }.value
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        disk = snapshot.0 && snapshot.1 ? .allowed : .denied
        if snapshot.0 != snapshot.1 {
            diskDetail = snapshot.0
                ? "Messages readable; local notifications still need access."
                : "Notifications readable; Messages still needs access."
        } else {
            diskDetail = "Local Messages and stored macOS notifications."
        }
        if let value = snapshot.2, asking != .music { music = Self.automationState(value) }
        if let value = snapshot.3, asking != .spotify { spotify = Self.automationState(value) }
    }

    func ask(_ permission: SetupPermissionRequest) async {
        guard !Task.isCancelled, !isRequesting else { return }
        isRequesting = true
        asking = permission
        refreshGeneration &+= 1
        setAsking(permission)
        defer {
            asking = nil
            isRequesting = false
        }

        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .accessibility:
            accessibilityRequested = true
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .calendar:
            if let watcher = MeetingWatcher.shared {
                await withCheckedContinuation { continuation in
                    watcher.requestAccess { _ in continuation.resume() }
                }
            } else {
                _ = try? await Self.calendarStore.requestFullAccessToEvents()
                Self.calendarStore.reset()
                NotificationCenter.default.post(name: MeetingWatcher.accessChanged, object: nil)
            }
        case .bluetooth:
            central = CBCentralManager(delegate: self, queue: .main)
            while CBManager.authorization == .notDetermined {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        case .music, .spotify:
            let bundleID = permission == .music ? "com.apple.Music" : "com.spotify.client"
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                guard await launchHidden(bundleID), !Task.isCancelled else { return }
            }
            let result = await Task.detached(priority: .userInitiated) {
                NowPlayingMonitor.automation(bundleID, ask: true)
            }.value
            guard !Task.isCancelled else { return }
            if permission == .music { music = Self.automationState(result) }
            else { spotify = Self.automationState(result) }
            // A previous denial cannot be requested again through Apple Events.
            if result == .denied { setupOpenPrivacy("Privacy_Automation") }
        case .audio:
            audioCheckFinished = false
            UserDefaults.standard.set(false, forKey: AudioBars.retrySuppressedKey)
            AudioBars.askPermission()
            // Wait for the tap's real completion, not a timer that can outrun the permission sheet.
            while !audioCheckFinished {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        case .screen:
            screenAccess.ask()
        }

        guard !Task.isCancelled else { return }
        asking = nil
        await refresh()
    }

    private func setAsking(_ permission: SetupPermissionRequest) {
        switch permission {
        case .microphone: microphone = .asking
        case .accessibility: accessibility = .asking
        case .calendar: calendar = .asking
        case .bluetooth: bluetooth = .asking
        case .music: music = .asking
        case .spotify: spotify = .asking
        case .audio: audio = .asking
        case .screen: screen = .asking
        }
    }

    private static func microphoneState() -> SetupAccessState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        @unknown default: .unavailable
        }
    }

    private static func calendarState() -> SetupAccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .allowed
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        case .writeOnly: .notAsked
        @unknown default: .unavailable
        }
    }

    private static func bluetoothState() -> SetupAccessState {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        @unknown default: .unavailable
        }
    }

    private static func automationState(_ state: NowPlayingMonitor.Automation) -> SetupAccessState {
        switch state {
        case .allowed: .allowed
        case .denied: .denied
        case .notAsked: .notAsked
        case .notRunning: .unavailable
        }
    }

    /// Start the target without stealing focus, then allow it to finish registering with Apple Events.
    private func launchHidden(_ bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<40 {
            guard !Task.isCancelled else { return false }
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return false }
                return true
            }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
        }
        return false
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Only CBManager.authorization is an authorization result. A powered-off radio is not a denial.
        Task { @MainActor [weak self] in
            guard let self, self.central != nil, self.asking != .bluetooth else { return }
            self.bluetooth = Self.bluetoothState()
        }
    }
}
