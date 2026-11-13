import AppKit
import ApplicationServices
import CoreBluetooth
import CoreGraphics
import EventKit
import Intents
import NowPlaying
import OSLog
import SwiftUI

/// Checks access without asking. A system prompt is only started by one of this page's buttons.
struct SetupPermissionsPage: View {
    @StateObject private var access = SetupPermissionAccess()
    @State private var refreshID = UUID()
    @State private var requestID = UUID()
    @State private var request: SetupPermissionRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupSection(title: "Everyday essentials") {
                SetupPermissionRow(
                    symbol: "accessibility", title: "Accessibility",
                    detail: "Call controls, volume and brightness HUDs, and Focus.",
                    state: access.accessibility, actionLabel: "Open Settings"
                ) { setupOpenPrivacy("Privacy_Accessibility") }
                SetupPermissionRow(
                    symbol: "calendar", title: "Calendar",
                    detail: "Upcoming meetings and your daily agenda.",
                    state: access.calendar
                ) { allow(.calendar, current: access.calendar, settings: "Privacy_Calendars") }
                SetupPermissionRow(
                    symbol: "headphones", title: "Bluetooth",
                    detail: "AirPods connections and battery levels.", state: access.bluetooth
                ) { allow(.bluetooth, current: access.bluetooth, settings: "Privacy_Bluetooth") }
                SetupPermissionRow(
                    symbol: "moon", title: "Focus status",
                    detail: "Share Focus on/off status with LeNotch.",
                    state: access.focus
                ) { allow(.focus, current: access.focus, settings: "Focus") }
            }

            VStack(alignment: .leading, spacing: 8) {
                SetupSection(title: "Music & media") {
                    if access.musicInstalled {
                        SetupPermissionRow(
                            symbol: "music.note", title: "Music automation",
                            detail: "Fallback playback controls for Apple Music.", state: access.music
                        ) { allow(.music, current: access.music, settings: "Privacy_Automation") }
                    }
                    if access.spotifyInstalled {
                        SetupPermissionRow(
                            symbol: "play.circle", title: "Spotify automation",
                            detail: "Fallback playback controls for Spotify.", state: access.spotify
                        ) { allow(.spotify, current: access.spotify, settings: "Privacy_Automation") }
                    }
                    SetupPermissionRow(
                        symbol: "waveform", title: "Music bars",
                        detail: "Live waveform from system audio. Play music to test.",
                        state: access.audio
                    ) { allow(.audio, current: access.audio, settings: "Privacy_AudioCapture") }
                    SetupPermissionRow(
                        symbol: "record.circle", title: "Screen recording",
                        detail: "Record a display, window, or selected area.",
                        state: access.screen
                    ) { allow(.screen, current: access.screen, settings: "Privacy_ScreenCapture") }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SetupSection(title: "Messages & notifications") {
                    SetupPermissionRow(
                        symbol: "externaldrive", title: "Full Disk Access",
                        detail: access.diskDetail, state: access.disk,
                        actionLabel: "Open Settings"
                    ) { setupOpenPrivacy("Privacy_AllFiles") }
                    .id("full-disk-access")
                }
                Text("Enable LeNotch in Full Disk Access. Reopen the app if macOS asks.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    let destination = anchor == "Focus"
        ? "x-apple.systempreferences:com.apple.Focus"
        : "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
    if let url = URL(string: destination) { NSWorkspace.shared.open(url) }
}

private enum SetupPermissionRequest: Equatable {
    case calendar, bluetooth, focus, music, spotify, audio, screen
}

@MainActor
private final class SetupPermissionAccess: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var accessibility: SetupAccessState = .notAsked
    @Published private(set) var calendar: SetupAccessState = .notAsked
    @Published private(set) var bluetooth: SetupAccessState = .notAsked
    @Published private(set) var focus: SetupAccessState = .notAsked
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
    private var screenRequested = false
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
        accessibility = AXIsProcessTrusted() ? .allowed : .denied
        if asking != .calendar { calendar = Self.calendarState() }
        if asking != .bluetooth { bluetooth = Self.bluetoothState() }
        if asking != .focus { focus = Self.focusState() }
        if asking != .audio {
            audio = UserDefaults.standard.bool(forKey: AudioBars.heardKey) ? .allowed : .notAsked
        }
        if asking != .screen {
            screen = CGPreflightScreenCaptureAccess() ? .allowed : (screenRequested ? .denied : .notAsked)
        }
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
        case .focus:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                INFocusStatusCenter.default.requestAuthorization { _ in continuation.resume() }
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
            screenRequested = true
            // CoreGraphics owns this system sheet. Keep its invocation on the main actor, as before.
            let granted = CGRequestScreenCaptureAccess()
            Self.log.notice("screen recording request granted=\(granted)")
        }

        guard !Task.isCancelled else { return }
        asking = nil
        await refresh()
    }

    private func setAsking(_ permission: SetupPermissionRequest) {
        switch permission {
        case .calendar: calendar = .asking
        case .bluetooth: bluetooth = .asking
        case .focus: focus = .asking
        case .music: music = .asking
        case .spotify: spotify = .asking
        case .audio: audio = .asking
        case .screen: screen = .asking
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

    private static func focusState() -> SetupAccessState {
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: .allowed
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
