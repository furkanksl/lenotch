import AppKit
import ApplicationServices
import CDockSwipe

public enum DesktopTransitionStatus: Equatable, Sendable, Codable {
    case off, systemDefault, needsAccessibility, needsScreenRecording, unsupported, paused
    case active(keyboard: Bool, trackpad: Bool)
}

/// Pure scheduling decisions: evaluating them never touches TCC, Dock, WindowServer, or an event tap.
enum DesktopTransitionPollingPolicy {
    static let systemSettingsBundleID = "com.apple.systempreferences"

    enum Action: Equatable {
        case pause, deferInspection, keepActive, inspect
    }

    static func action(paused: Bool, active: Bool, fullySetUp: Bool, transitioning: Bool,
                       settingsInFront: Bool, explicit: Bool) -> Action {
        // Privacy changes interrupt immediately, even when a gesture is in progress.
        if paused { return .pause }
        if active && transitioning { return .deferInspection }
        if active && fullySetUp && !settingsInFront && !explicit { return .keepActive }
        return .inspect
    }

    /// Desktop pictures are plain images of the screen. A settings change keeps them unless it changes what a picture
    /// contains (with or without the Dock) or the new style draws no pictures at all.
    static func keepsPictures(from old: DesktopTransitionOptions, to new: DesktopTransitionOptions) -> Bool {
        old.moveDock == new.moveDock && new.style.isDrawn
    }

    static func shouldPoll(enabled: Bool, customTransition: Bool, paused: Bool, fullySetUp: Bool,
                           settingsInFront: Bool, pendingInspection: Bool) -> Bool {
        guard enabled, customTransition, !paused else { return false }
        return !fullySetUp || settingsInFront || pendingInspection
    }
}

/// LeNotch's explicit lifecycle around Interspace's transition engine. No event taps, keyboard preferences,
/// trackpad callbacks, captures, or observers exist until start(). stop() restores the native desktop controls.
@MainActor
public final class DesktopTransitionsEngine {
    public var onStatus: ((DesktopTransitionStatus) -> Void)?
    /// A drawn transition started or ended. Always ends with false when resources are released mid-transition.
    public var onTransition: ((Bool) -> Void)?
    private var transitioning = false
    private var options = DesktopTransitionOptions()
    private var enabled = false
    private var suspended = false
    private var sleeping = false
    private var reduceMotion = false
    private var settingsInFront = false
    private var pendingInspection = false
    private var active = false
    private var controller: TransitionController?
    private var multitouch: MultitouchMonitor?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var tapInstalled = false
    private var keysInstalled = false
    private var hasTrackpad = false
    private var status = DesktopTransitionStatus.off
    private let excludedProcessIDs: Set<pid_t>

    public init(excludingProcessIDs: Set<pid_t> = []) {
        excludedProcessIDs = excludingProcessIDs
    }

    public func start(_ options: DesktopTransitionOptions) {
        guard !enabled else { update(options); return }
        self.options = options
        enabled = true
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        settingsInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == DesktopTransitionPollingPolicy.systemSettingsBundleID
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.reconcile()
            }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleeping = false; self?.reconcile() }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleeping = true; self?.reconcile() }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.spacesChanged() }
        })
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.frontApplicationChanged(notification) }
            })
        }
        appObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.displaysChanged(); self?.reconcile() }
        })
        appObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        reconcile()
    }

    public func update(_ options: DesktopTransitionOptions) {
        guard options != self.options else { return }
        let old = self.options
        self.options = options
        // The hooks restart with the new options; the desktops' pictures stay unless they no longer fit.
        stopResources(keepPictures: DesktopTransitionPollingPolicy.keepsPictures(from: old, to: options))
        if enabled { reconcile() }
    }

    public func setSuspended(_ suspended: Bool) {
        guard suspended != self.suspended else { return }
        self.suspended = suspended
        if enabled { reconcile() }
    }

    public func stop() {
        enabled = false
        timer?.invalidate()
        timer = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        for observer in appObservers { NotificationCenter.default.removeObserver(observer) }
        appObservers.removeAll()
        stopResources()
        publish(.off)
    }

    #if DEBUG
    /// Development only: drives the same path as the desktop keyboard shortcut, for frame measurements.
    public func debugStep(_ direction: Int) {
        guard active else { return }
        controller?.keyboardStep(direction)
    }

    /// Development only: the same path as a style/speed change in Setup (speed nudged, then restored).
    public func debugRestyle() {
        var nudged = options
        nudged.speed = options.speed == 1 ? 1.01 : 1
        let original = options
        update(nudged)
        update(original)
    }
    #endif

    private var isPaused: Bool { suspended || sleeping || reduceMotion }

    private var isFullySetUp: Bool { active && tapInstalled && keysInstalled && hasTrackpad }

    private func frontApplicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let wasSettingsInFront = settingsInFront
        if notification.name == NSWorkspace.didActivateApplicationNotification {
            settingsInFront = app.bundleIdentifier == DesktopTransitionPollingPolicy.systemSettingsBundleID
        } else if app.bundleIdentifier == DesktopTransitionPollingPolicy.systemSettingsBundleID {
            settingsInFront = false
        } else {
            return
        }
        // Start polling while Settings is in front; make one final read when it leaves.
        if settingsInFront || wasSettingsInFront { reconcile() }
    }

    private func updatePolling() {
        let needed = DesktopTransitionPollingPolicy.shouldPoll(
            enabled: enabled, customTransition: options.style != .system, paused: isPaused,
            fullySetUp: isFullySetUp, settingsInFront: settingsInFront, pendingInspection: pendingInspection
        )
        if needed, timer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile(explicit: false) }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed {
            timer?.invalidate()
            timer = nil
        }
    }

    private func reconcile(explicit: Bool = true) {
        guard enabled else { return }
        defer { updatePolling() }
        guard options.style != .system else { stopResources(); publish(.systemDefault); return }
        switch DesktopTransitionPollingPolicy.action(
            paused: isPaused, active: active, fullySetUp: isFullySetUp,
            transitioning: controller?.isTransitioning == true, settingsInFront: settingsInFront,
            explicit: explicit || pendingInspection
        ) {
        case .pause:
            // Locked, asleep, presenting: no input hooks and nothing drawn. The pictures stay in memory for the return.
            stopResources(keepPictures: true); publish(.paused); return
        case .deferInspection:
            // Keep explicit wake/permission/app notifications until the gesture has handed back.
            pendingInspection = pendingInspection || explicit
            return
        case .keepActive:
            return
        case .inspect:
            pendingInspection = false
        }
        guard AXIsProcessTrusted() else { stopResources(); publish(.needsAccessibility); return }
        // Instant does not capture or draw screenshots.
        guard options.style == .instant || CGPreflightScreenCaptureAccess() else {
            stopResources(); publish(.needsScreenRecording); return
        }
        guard !active else {
            // A partial setup keeps polling for a reconnected trackpad or an installable tap.
            if !tapInstalled { tapInstalled = ds_tap_install() }
            if !keysInstalled { keysInstalled = SpaceShortcuts.install() }
            if !hasTrackpad, tapInstalled { hasTrackpad = multitouch?.start() == true }
            ds_tap_set_suppress(hasTrackpad)
            // Reread the user's desktop key bindings, not hard-coded Control-arrow shortcuts.
            SpaceShortcuts.update(enabled: keysInstalled)
            publish(.active(keyboard: keysInstalled, trackpad: hasTrackpad))
            return
        }
        // A live Spaces query can block while Dock is switching. It is an initial capability check,
        // never a periodic query against an already-running controller.
        guard Spaces.isAvailable, let screen = NSScreen.underCursor, let initialLayout = Spaces.layout(for: screen) else {
            stopResources(); publish(.unsupported); return
        }
        AppSettings.shared.apply(options)
        let controller: TransitionController
        if let kept = self.controller {
            controller = kept
            controller.resume(with: initialLayout)
        } else {
            controller = TransitionController(initialLayout: initialLayout, excludingProcessIDs: excludedProcessIDs)
            self.controller = controller
            controller.onActivityChanged = { [weak self] active in self?.setTransitioning(active) }
        }
        let multitouch = MultitouchMonitor()
        self.multitouch = multitouch
        multitouch.onFrame = { [weak self] fingers in
            guard let self, self.active else { return }
            self.controller?.receive(fingers: fingers)
        }
        tapInstalled = ds_tap_install()
        keysInstalled = SpaceShortcuts.install()
        hasTrackpad = tapInstalled && multitouch.start()
        SpaceShortcuts.onStep = { [weak self] direction in
            guard let self, self.active else { return }
            self.controller?.keyboardStep(direction)
        }
        guard keysInstalled || hasTrackpad else { stopResources(); publish(.unsupported); return }
        active = true
        controller.isEnabled = true
        if options.style.isDrawn { controller.prewarm() }
        ds_tap_set_suppress(hasTrackpad)
        SpaceShortcuts.update(enabled: keysInstalled)
        publish(.active(keyboard: keysInstalled, trackpad: hasTrackpad))
    }

    /// Removes every input hook. `keepPictures` suspends the controller with its desktop pictures instead of
    /// releasing it; anything else (feature off, a permission withdrawn, unsupported) releases all captured pixels.
    private func stopResources(keepPictures: Bool = false) {
        active = false
        pendingInspection = false
        ds_tap_set_suppress(false)
        if keepPictures, let controller {
            controller.suspend()
        } else {
            controller?.onActivityChanged = nil
            controller?.shutdown()
            controller = nil
        }
        setTransitioning(false)
        multitouch?.stop()
        multitouch = nil
        hasTrackpad = false
        SpaceShortcuts.uninstall()
        keysInstalled = false
        ds_tap_uninstall()
        tapInstalled = false
    }

    private func setTransitioning(_ value: Bool) {
        guard value != transitioning else { return }
        transitioning = value
        onTransition?(value)
    }

    private func publish(_ status: DesktopTransitionStatus) {
        guard self.status != status else { return }
        self.status = status
        onStatus?(status)
    }
}
