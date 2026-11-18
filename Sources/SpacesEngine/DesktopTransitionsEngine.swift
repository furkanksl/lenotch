import AppKit
import ApplicationServices
import CDockSwipe

public enum DesktopTransitionStatus: Equatable, Sendable, Codable {
    case off, systemDefault, needsAccessibility, unsupported, paused
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

    static func shouldPoll(enabled: Bool, customTransition: Bool, paused: Bool, fullySetUp: Bool,
                           settingsInFront: Bool, pendingInspection: Bool) -> Bool {
        guard enabled, customTransition, !paused else { return false }
        return !fullySetUp || settingsInFront || pendingInspection
    }
}

/// Owns the input hooks used by Instant. System leaves the same controls entirely with macOS.
@MainActor
public final class DesktopTransitionsEngine {
    public var onStatus: ((DesktopTransitionStatus) -> Void)?
    /// A native switch started or ended. Always ends with false when input hooks are released.
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
    public init() {}

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
        self.options = options
        stopResources()
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
            stopResources(); publish(.paused); return
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
        guard Spaces.isAvailable, let screen = NSScreen.underCursor, let initialLayout = Spaces.layout(for: screen.displayID) else {
            stopResources(); publish(.unsupported); return
        }
        let controller = TransitionController(initialLayout: initialLayout, sensitivity: options.sensitivity)
        self.controller = controller
        controller.onActivityChanged = { [weak self] active in self?.setTransitioning(active) }
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
        ds_tap_set_suppress(hasTrackpad)
        SpaceShortcuts.update(enabled: keysInstalled)
        publish(.active(keyboard: keysInstalled, trackpad: hasTrackpad))
    }

    private func stopResources() {
        active = false
        pendingInspection = false
        ds_tap_set_suppress(false)
        controller?.onActivityChanged = nil
        controller?.shutdown()
        controller = nil
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
        if !value, active, pendingInspection { reconcile() }
    }

    private func publish(_ status: DesktopTransitionStatus) {
        guard self.status != status else { return }
        self.status = status
        onStatus?(status)
    }
}
