// Adapted from Interspace, Copyright (c) 2026 cnrad. MIT licensed.
// All state, AppKit access and public entry points belong to the main thread.
import AppKit
import QuartzCore
import CDockSwipe
import os

private let transitionLog = Logger(subsystem: "com.lenotch.app", category: "Spaces.Transition")

/// Renders cached desktops above instant Dock switches. It does not install hooks or start a tour.
final class TransitionController: NSObject {
    private let overlay = Overlay()
    private let snapshotter: Snapshotter
    private let layoutQueries = TransitionQueryCache<CGDirectDisplayID, SpaceLayout>(
        worker: { Spaces.queryQueue.async(execute: $0) }
    )
    private var layoutPoll: Timer?
    private var instantWaitStarted: CFTimeInterval?
    private enum DeferredInput { case key(Int), touch(TouchFrame) }
    private var deferredInput: [DeferredInput] = []
    private var deferredScreen: NSScreen?
    private var inputScreen: NSScreen?
    let recognizer = SwipeRecognizer()
    private enum Phase { case idle, dragging, settling, holding, revealing, touring }
    private var animationActivity: NSObjectProtocol?
    /// True while a drawn transition runs, false when it ends. LeNotch uses it to hold back WindowServer queries.
    var onActivityChanged: ((Bool) -> Void)?
    private var phase: Phase = .idle {
        didSet {
            if (phase == .idle) != (oldValue == .idle) { onActivityChanged?(phase != .idle) }
            if phase != .idle, oldValue == .idle {
                animationActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                    reason: "Responding to a desktop-switch gesture"
                )
            } else if phase == .idle, let activity = animationActivity {
                ProcessInfo.processInfo.endActivity(activity)
                animationActivity = nil
            }
            if phase != oldValue { trace("phase \(oldValue) → \(phase)") }
        }
    }
    private var layout: SpaceLayout?
    private var cache: [UInt64: Snapshot] = [:]
    private var packed: [UInt64: PackedSnapshot] = [:]
    private var cacheOrder: [UInt64] = []
    private var packing: Set<UInt64> = []
    private static let packQueue = DispatchQueue(label: "com.lenotch.app.spaces.pack", qos: .utility)
    private static let unpackQueue = DispatchQueue(label: "com.lenotch.app.spaces.unpack", qos: .userInitiated)
    private let imageUnpacker = TransitionImageUnpacker<UInt64, PackedSnapshot, Snapshot?>(
        worker: { work in TransitionController.unpackQueue.async(execute: work) },
        deliver: { work in DispatchQueue.main.async(execute: work) },
        sameSource: { $0.isSame(as: $1) }
    )
    private var knownSpaces: [String: [UInt64]] = [:]
    /// The small grey copy of each desktop's picture, to know when the live desktop below shows the same thing.
    private var pictureSamples: [UInt64: [UInt8]] = [:]
    /// The picture sample of the desktop the current transition lands on, if there is a picture of it.
    private var expectedSample: [UInt8]?
    /// When the live desktop below last changed, during the check before the overlay goes.
    private var liveStableSince: CFTimeInterval?
    /// The displays the pictures were taken on. Screen-parameter notifications also come for Dock and menu-bar
    /// changes; pictures are thrown away only when this changes.
    private var displaySignature = TransitionController.currentDisplaySignature()
    private var wallpapers: [CGDirectDisplayID: Snapshot] = [:]
    private var wallpaperGeneration = 0
    /// Changes on shutdown as well as any cache reset. Worker completions must match it.
    private var lifecycleGeneration = 0
    private var baseIndex = 0
    private var dockIndex = 0
    private var dockPostTime: CFTimeInterval = 0
    private var lastSwitch: (displayUUID: String, spaceIDs: [UInt64], index: Int, time: CFTimeInterval)?
    private var progress: CGFloat = 0
    private var velocity: CGFloat = 0
    /// The settle playing in the render server: the spring sampled every `settleInterval` from `start` (media clock).
    /// While it runs, `progress`/`velocity` are read from it and nothing is committed per frame.
    private var settle: (start: CFTimeInterval, samples: [CGFloat], velocities: [CGFloat])?
    private static let settleInterval: CFTimeInterval = 1.0 / 240
    private var dragOrigin: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    #if DEBUG
    private var frameIntervals: [CFTimeInterval] = []
    private var frameCosts: [CFTimeInterval] = []
    /// Per frame: vsync timestamp, interval since the previous one, how late the callback ran, phase.
    private var frameLog: [(time: CFTimeInterval, interval: CFTimeInterval, late: CFTimeInterval, phase: Phase)] = []
    private var frameMarks: [(time: CFTimeInterval, label: String)] = []
    private var frameNominal: CFTimeInterval = 0
    private var busyObserver: CFRunLoopObserver?
    #endif
    private func mark(_ label: @autoclosure () -> String) {
        #if DEBUG
        if frameMarks.count < 256 { frameMarks.append((CACurrentMediaTime(), label())) }
        #endif
    }
    private var phaseStart: CFTimeInterval = 0
    private var tracedActualIndex: Int?
    private var didSwitch = false
    private var overlayIsBelowDock = true
    private var revealIsCut = false
    private var captureToken = 0
    private var captureFinished = false
    private var captureFailed = false
    private var captureStarted: CFTimeInterval = 0
    private var pendingRelease: (target: Int, velocity: CGFloat)?
    private var keyPending = false
    private var stabilityToken = 0
    private var stabilityStarted = false
    private var liveReady = false
    private var lastSample: [UInt8]?
    private var refreshToken = 0
    private var tourToken = 0
    private var tourRoute: [Int] = []
    private var tourIncludesDock = true
    private var tourOriginSample: [UInt8]?
    private var lastTouchTime: CFTimeInterval = 0
    private var watchdog: Timer?
    private let completionDeadline = TransitionCompletionDeadline()
    private var instantOrigin = 0
    private var instantDirection = 0
    private var instantSteps = 0
    private var instantSwipeActive = false
    private var instantSwipeFired = false
    private var instantPump: Timer?
    private var isInstant: Bool { AppSettings.shared.transition == .instant }

    var hideMenuBarIcon: (() -> Overlay.Loader?)?
    var showMenuBarIcon: (() -> Void)?
    /// The LeNotch owner must explicitly opt in before any gesture or capture can run.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                trace("enabled style=\(AppSettings.shared.transition.rawValue)")
                let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                    guard let self, self.isEnabled, let screen = NSScreen.underCursor else { return }
                    _ = self.readLayout(for: screen)
                    if let deferred = self.deferredScreen { _ = self.readLayout(for: deferred) }
                }
                layoutPoll = timer
                RunLoop.main.add(timer, forMode: .common)
            } else {
                layoutPoll?.invalidate()
                layoutPoll = nil
                layoutQueries.invalidate()
                deferredInput.removeAll()
                deferredScreen = nil
            }
        }
    }

    init(initialLayout: SpaceLayout, excludingProcessIDs: Set<pid_t> = []) {
        snapshotter = Snapshotter(excludingProcessIDs: excludingProcessIDs)
        super.init()
        layoutQueries.seed(initialLayout, for: initialLayout.screen.displayID)
        layoutQueries.onUpdate = { [weak self] in self?.drainInput() }
        #if DEBUG
        // Records main-thread run-loop iterations over 4 ms during a transition (includes the CA commit).
        var iterationStart: CFTimeInterval = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, CFIndex.max) { [weak self] _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting { iterationStart = now; return }
            guard let self, iterationStart > 0, self.phase != .idle else { return }
            let busy = now - iterationStart
            if busy > 0.004, self.frameMarks.count < 256 {
                self.frameMarks.append((iterationStart, String(format: "main busy %.1fms", busy * 1000)))
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        busyObserver = observer
        #endif
        recognizer.onArm = { [weak self] in self?.arm() }
        recognizer.onDisarm = { [weak self] in
            guard let self, self.isEnabled, self.phase == .idle else { return }
            self.captureToken += 1
            self.layout = nil
        }
        recognizer.onBegin = { [weak self] in self?.beginDrag() }
        recognizer.onChange = { [weak self] in self?.change($0) }
        recognizer.onEnd = { [weak self] velocity, cancelled in self?.end(velocity: velocity, cancelled: cancelled) }
    }

    func handle(_ frame: TouchFrame) {
        guard isEnabled, phase != .touring else { return }
        lastTouchTime = CACurrentMediaTime()
        recognizer.handle(frame)
    }

    func receive(fingers: TouchFrame) {
        guard isEnabled else { return }
        if !deferredInput.isEmpty || (phase == .idle && fingers.points.count >= 3 && !inputLayoutReady) {
            deferInput(.touch(fingers))
        } else { handle(fingers) }
    }
    func keyboardStep(_ direction: Int) {
        guard isEnabled else { return }
        trace("keyboard \(direction)")
        if !deferredInput.isEmpty || (phase == .idle && !inputLayoutReady) {
            deferInput(.key(direction))
        } else { keyStep(direction) }
    }
    private var inputLayoutReady: Bool {
        guard let screen = NSScreen.underCursor else { return false }
        return readLayout(for: screen) != nil
    }
    private func deferInput(_ input: DeferredInput) {
        if deferredInput.isEmpty { deferredScreen = NSScreen.underCursor }
        // Preserve the gesture's release while waiting for an uncached display.
        if deferredInput.count >= 512 { deferredInput.removeFirst() }
        deferredInput.append(input)
        if let screen = deferredScreen { _ = readLayout(for: screen) }
    }
    private func drainInput() {
        guard isEnabled, !deferredInput.isEmpty, let screen = deferredScreen,
              readLayout(for: screen) != nil else { return }
        let inputs = deferredInput
        deferredInput.removeAll()
        deferredScreen = nil
        inputScreen = screen
        defer { inputScreen = nil }
        for input in inputs {
            switch input {
            case .key(let direction): keyStep(direction)
            case .touch(let frame): handle(frame)
            }
        }
    }
    var isTransitioning: Bool { phase != .idle || instantPump != nil || instantSwipeActive }

    /// Timing/state only in the system log: Launch Services discards stdout/stderr. No pixels, app names or titles.
    private func trace(_ event: String) {
        #if DEBUG
        let time = String(format: "%.3f", CACurrentMediaTime())
        let position = String(format: "%.3f", progress)
        let message = "SpacesTrace \(time) \(event) overlay=\(overlay.isVisible) base=\(baseIndex) dock=\(dockIndex) progress=\(position) captured=\(captureFinished) live=\(liveReady)"
        transitionLog.notice("\(message, privacy: .public)")
        #endif
    }

    func spacesChanged() {
        mark("active space changed (notification)")
        guard isEnabled, phase == .idle, instantPump == nil, !instantSwipeActive else { return }
        layoutQueries.invalidate()
        for screen in NSScreen.screens { _ = readLayout(for: screen) }
        layout = nil
        lastSwitch = nil
        // Arrived some other way (Mission Control, the Dock, an app's window): take this desktop's picture now, so a
        // transition back to it shows its windows, not the wallpaper. A transition's own arrival is handled in reset().
        guard AppSettings.shared.transition.isDrawn else { return }
        refreshToken += 1
        refreshCurrentSpace(refreshToken, delay: 0.4)
    }

    /// Stops all input handling and drawing, keeping the desktops' pictures. For a pause (locked, asleep, presenting)
    /// or a settings change: the pictures are plain images of the screen and are still right afterwards.
    func suspend() {
        guard isEnabled else { return }
        abort()
        isEnabled = false
        packing.removeAll()
        imageUnpacker.invalidateCallbacks()
    }

    /// Continues after `suspend()` with the pictures it kept.
    func resume(with initialLayout: SpaceLayout) {
        guard !isEnabled else { return }
        layoutQueries.seed(initialLayout, for: initialLayout.screen.displayID)
        isEnabled = true
    }

    private static func currentDisplaySignature() -> [String] {
        NSScreen.screens.map { "\($0.displayID) \($0.frame) \($0.backingScaleFactor)" }
    }

    func prewarm() {
        guard isEnabled, !isInstant else { return }
        let generation = lifecycleGeneration
        snapshotter.refreshDisplays { [weak self] in
            guard let self, self.isEnabled, generation == self.lifecycleGeneration, self.phase == .idle else { return }
            // The desktop you are on gets its picture at once, not only when you first leave it.
            self.refreshToken += 1
            self.refreshCurrentSpace(self.refreshToken, delay: 0) { [weak self] snapshot, screen in
                // WindowServer sets up a window, and maps its first surface, the first time it is shown: ~60 ms that
                // the first transition would otherwise wait for. Show it once now, fully transparent.
                guard let self, self.isEnabled, generation == self.lifecycleGeneration, self.phase == .idle,
                      !self.overlay.isVisible else { return }
                self.overlay.warmUp(on: screen, with: snapshot)
            }
        }
        prepareWallpapers()
    }

    func receiveScrollEnd() {
        guard isEnabled, phase == .dragging else { return }
        recognizer.reset()
        end(velocity: 0, cancelled: false)
    }

    func cancelGesture() {
        guard isEnabled, phase == .dragging else { return }
        recognizer.reset()
        pendingRelease = nil
        if overlay.isVisible {
            commit(target: 0, velocity: 0)
        } else {
            captureToken += 1
            reset()
        }
    }

    func abort() {
        instantSwipeActive = false
        instantPump?.invalidate()
        instantPump = nil
        recognizer.reset()
        captureToken += 1
        pendingRelease = nil
        reset()
    }

    /// Disable never switches a Space to restore a cache tour: the user keeps the live desktop.
    /// All outstanding callbacks are invalidated before textures and windows are released.
    func shutdown() {
        #if DEBUG
        if let busyObserver { CFRunLoopObserverInvalidate(busyObserver); self.busyObserver = nil }
        #endif
        isEnabled = false
        lifecycleGeneration += 1
        wallpaperGeneration += 1
        captureToken += 1
        stabilityToken += 1
        refreshToken += 1
        tourToken += 1
        instantSwipeActive = false
        instantPump?.invalidate()
        instantPump = nil
        recognizer.reset()
        snapshotter.cancel()
        reset()
        overlay.shutdown()
        forgetAllImages()
        wallpapers.removeAll()
        knownSpaces.removeAll()
        packing.removeAll()
        lastSwitch = nil
        lastSample = nil
        tourOriginSample = nil
    }

    func displaysChanged() {
        let signature = Self.currentDisplaySignature()
        guard signature != displaySignature else { return }
        displaySignature = signature
        guard isEnabled else {
            // Suspended: pictures of the old displays must not come back on resume.
            forgetAllImages()
            packing.removeAll()
            wallpapers.removeAll()
            return
        }
        layoutQueries.invalidate()
        deferredInput.removeAll()
        deferredScreen = nil
        lifecycleGeneration += 1
        abort()
        snapshotter.refreshDisplays()
        forgetAllImages()
        packing.removeAll()
        prepareWallpapers()
    }

    func desktopPictureChanged() {
        guard isEnabled else { return }
        forgetAllImages()
        prepareWallpapers()
    }

    func prepareWallpapers() {
        guard isEnabled else { return }
        wallpaperGeneration += 1
        let generation = wallpaperGeneration
        wallpapers.removeAll()
        for screen in NSScreen.screens {
            let id = screen.displayID
            snapshotter.wallpaper(for: screen) { [weak self] snapshot in
                guard let self, self.isEnabled, generation == self.wallpaperGeneration else { return }
                self.wallpapers[id] = snapshot
            }
        }
    }

    private func keyStep(_ direction: Int) {
        guard isEnabled, direction != 0, phase != .touring else { return }
        if isInstant {
            guard phase == .idle, !instantSwipeActive, instantPump == nil, let live = currentLayout() else { return }
            layout = live
            setBase(live.currentIndex)
            switchWithoutOverlay(direction.signum())
            return
        }
        // A hotkey during a held physical swipe is not a release and must not arm its timeout.
        guard phase != .dragging || keyPending else { return }
        armCompletionDeadline()
        mark("key \(direction)")
        if phase == .idle {
            phase = .dragging
            progress = 0
            velocity = 0
            didSwitch = false
            pendingRelease = nil
            keyPending = true
            prepare()
            guard layout != nil else { reset(); return }
            let target = direction > 0 ? (hasNext ? 1 : 0) : (hasPrevious ? -1 : 0)
            if captureFinished, !captureFailed { present() }
            pendingRelease = (target, 0)
            if overlay.isVisible || captureFinished { captureDidFinish() }
            else { switchWithoutOverlayIfLate() }
        } else {
            guard phase != .dragging else {
                guard keyPending, let layout else { return }
                let current = pendingRelease?.target ?? 0
                let total = min(max(baseIndex + current + direction, 0), layout.spaceIDs.count - 1) - baseIndex
                pendingRelease = (total, 0)
                return
            }
            syncSettle()
            stopLink()
            stopWatchdog()
            stabilityToken += 1
            stabilityStarted = false
            liveReady = false
            overlay.alpha = 1
            let target = direction > 0 ? (hasNext ? 1 : 0) : (hasPrevious ? -1 : 0)
            commit(target: target, velocity: velocity)
        }
    }

    private func arm() {
        guard isEnabled, Config.captureOnTouchDown, !isInstant, phase == .idle, !overlay.isVisible else { return }
        prepare()
    }

    private func change(_ dx: CGFloat) {
        guard isEnabled else { return }
        lastTouchTime = CACurrentMediaTime()
        if instantSwipeActive { instantChange(Self.progress(forFingerTravel: dx)); return }
        guard phase == .dragging, pendingRelease == nil else { return }
        var raw = dragOrigin + Self.progress(forFingerTravel: dx)
        let crossed = Int(raw.rounded(.towardZero))
        if crossed != 0, overlay.isVisible {
            let before = baseIndex
            progress = raw
            retarget(by: crossed)
            let moved = CGFloat(baseIndex - before)
            dragOrigin -= moved
            raw -= moved
        }
        if overlay.isVisible { pumpDock() }
        progress = constrain(raw)
        velocity = 0
        // The display link presents the newest position once per refresh.
    }

    private func end(velocity releaseVelocity: CGFloat, cancelled: Bool) {
        guard isEnabled else { return }
        if instantSwipeActive {
            instantSwipeActive = false
            instantSwipeFired = false
            if instantPump == nil { layout = nil; dockPostTime = 0 }
            return
        }
        guard phase == .dragging else { return }
        armCompletionDeadline()
        let releaseVelocity = Self.progress(forFingerTravel: releaseVelocity)
        let target = cancelled ? 0 : releaseTarget(velocity: releaseVelocity)
        guard overlay.isVisible else {
            if target == 0 { captureToken += 1; reset() }
            else { pendingRelease = (target, releaseVelocity); switchWithoutOverlayIfLate() }
            return
        }
        commit(target: target, velocity: releaseVelocity)
    }

    private func switchWithoutOverlayIfLate() {
        let token = captureToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.isEnabled, token == self.captureToken, let release = self.pendingRelease else { return }
            self.pendingRelease = nil
            self.captureToken += 1
            self.switchWithoutOverlay(release.target)
        }
    }

    private func beginDrag() {
        guard isEnabled, phase != .touring else { return }
        trace("trackpad begin")
        completionDeadline.cancel()   // a physical hold owns completion until its release
        if isInstant, phase == .idle, !overlay.isVisible {
            if instantPump == nil { layout = currentLayout(); setBase(layout?.currentIndex ?? 0) }
            instantOrigin = baseIndex
            instantDirection = 0
            instantSteps = 0
            instantSwipeActive = layout != nil
            instantSwipeFired = false
            return
        }
        lastTouchTime = CACurrentMediaTime()
        stopWatchdog()
        keyPending = false
        if phase != .idle {
            syncSettle()
            stabilityToken += 1
            stabilityStarted = false
            liveReady = false
            overlay.alpha = 1
            pendingRelease = nil
            dragOrigin = progress
            velocity = 0
            phase = .dragging
            if overlay.isVisible { startLink() }
            startWatchdog()
            return
        }
        phase = .dragging
        dragOrigin = 0
        progress = 0
        velocity = 0
        didSwitch = false
        pendingRelease = nil
        if layout == nil || CACurrentMediaTime() - captureStarted > Config.snapshotMaxAge { prepare() }
        guard layout != nil else { reset(); return }
        if captureFinished { captureDidFinish() }
        startWatchdog()
    }

    private func startWatchdog() {
        stopWatchdog()
        var staleChecks = 0
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isEnabled, self.phase == .dragging, self.pendingRelease == nil else { return }
            guard CACurrentMediaTime() - self.lastTouchTime > 1 else { staleChecks = 0; return }
            staleChecks += 1
            if staleChecks >= 2 { self.recognizer.reset(); self.end(velocity: 0, cancelled: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() { watchdog?.invalidate(); watchdog = nil }

    private func instantChange(_ travel: CGFloat) {
        guard let layout else { return }
        if !instantSwipeFired {
            guard travel != 0 else { return }
            instantSwipeFired = true
            instantDirection = travel > 0 ? 1 : -1
        }
        // A first step needs no extra travel; additional full-width steps preserve direction
        // reversal with hysteresis instead of jittering at the boundary.
        let forward = travel * CGFloat(instantDirection) + 1
        var steps = instantSteps * instantDirection
        while forward >= CGFloat(steps + 1) { steps += 1 }
        while forward < CGFloat(steps) - 0.15 { steps -= 1 }
        let wanted = min(max(instantOrigin + steps * instantDirection, 0), layout.spaceIDs.count - 1)
        instantSteps = wanted - instantOrigin
        guard wanted != baseIndex else { return }
        baseIndex = wanted
        pumpInstantDock()
    }

    private func pumpInstantDock() {
        guard isEnabled, layout != nil, dockIndex != baseIndex else { stopInstantPump(); return }
        if dockPostTime > 0, !dockIsOn(dockIndex) {
            guard CACurrentMediaTime() - dockPostTime > 1 else { startInstantPump(); return }
            baseIndex = dockIndex
            stopInstantPump()
            return
        }
        switch postSwitch(baseIndex > dockIndex ? 1 : -1) {
        case .waiting:
            let now = CACurrentMediaTime()
            if let began = instantWaitStarted, now - began > 2 { stopInstantPump(); return }
            if instantWaitStarted == nil { instantWaitStarted = now }
            startInstantPump()
            return
        case .failed: baseIndex = dockIndex; stopInstantPump(); return
        case .posted: instantWaitStarted = nil
        }
        if dockIndex == baseIndex { stopInstantPump() } else { startInstantPump() }
    }

    private func startInstantPump() {
        guard isEnabled, instantPump == nil else { return }
        let timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in self?.pumpInstantDock() }
        RunLoop.main.add(timer, forMode: .common)
        instantPump = timer
    }

    private func stopInstantPump() {
        instantPump?.invalidate(); instantPump = nil
        instantWaitStarted = nil
        if !instantSwipeActive { layout = nil; dockPostTime = 0 }
    }

    private func releaseTarget(velocity: CGFloat) -> Int {
        var target = 0
        if progress > Config.commitThreshold, hasNext { target = 1 }
        else if progress < -Config.commitThreshold, hasPrevious { target = -1 }
        if velocity > Config.flickVelocity {
            if target == -1 { target = 0 }
            else if progress > Config.flickMinProgress, hasNext { target = 1 }
        } else if velocity < -Config.flickVelocity {
            if target == 1 { target = 0 }
            else if progress < -Config.flickMinProgress, hasPrevious { target = -1 }
        }
        return target
    }

    private func commit(target: Int, velocity releaseVelocity: CGFloat) {
        guard isEnabled else { return }
        armCompletionDeadline()
        stopWatchdog()
        syncSettle()
        if target != 0 { retarget(by: target) }
        velocity = min(max(releaseVelocity, -TransitionMath.maxReleaseVelocity), TransitionMath.maxReleaseVelocity)
        stabilityToken += 1
        stabilityStarted = false
        liveReady = false
        phase = .settling
        mark("settling")
        startSettleAnimation()
        startLink()
    }

    /// Precomputes the whole spring (the same integration as a per-frame step) and gives it to the render server.
    private func startSettleAnimation() {
        guard isEnabled, overlay.isVisible else { settle = nil; return }
        var p = progress, v = velocity
        var samples = [p], velocities = [v]
        let speed = CGFloat(AppSettings.shared.speed)
        while samples.count < 2400 {
            TransitionMath.stepSpring(progress: &p, velocity: &v, delta: CGFloat(Self.settleInterval), speed: speed, limit: limit)
            samples.append(p)
            velocities.append(v)
            if TransitionMath.isSettled(progress: p, velocity: v) { break }
        }
        samples[samples.count - 1] = 0
        velocities[velocities.count - 1] = 0
        let start = CACurrentMediaTime()
        settle = (start, samples, velocities)
        overlay.animate(progress: samples, interval: Self.settleInterval, beginTime: start)
    }

    /// Where the played motion is at `time`, interpolated between samples.
    private func settleState(at time: CFTimeInterval) -> (progress: CGFloat, velocity: CGFloat, done: Bool)? {
        guard let settle else { return nil }
        let position = max(0, (time - settle.start) / Self.settleInterval)
        let last = settle.samples.count - 1
        guard position < Double(last) else { return (settle.samples[last], 0, true) }
        let index = Int(position)
        let fraction = CGFloat(position - Double(index))
        let p = settle.samples[index] + (settle.samples[index + 1] - settle.samples[index]) * fraction
        let v = settle.velocities[index] + (settle.velocities[index + 1] - settle.velocities[index]) * fraction
        return (p, v, false)
    }

    /// Stops the played motion where it is now, so the caller can change course from that exact position and speed.
    private func syncSettle() {
        guard let state = settleState(at: CACurrentMediaTime()) else { return }
        settle = nil
        progress = state.progress
        velocity = state.velocity
        overlay.render(progress: progress)
    }

    /// The settle's position for this frame: from the played motion, or one integration step when none is playing.
    private func advanceSettle(at time: CFTimeInterval, delta: CGFloat) {
        if let state = settleState(at: time) {
            progress = state.progress
            velocity = state.velocity
            if state.done { settle = nil; overlay.stopAnimating() }
        } else {
            stepSpring(delta)
            overlay.render(progress: progress)
        }
    }

    private func switchWithoutOverlay(_ target: Int) {
        guard isEnabled else { return }
        let savedLayout = layout
        let from = dockIndex
        reset()
        guard target != 0, let savedLayout else { return }
        layout = savedLayout
        setBase(from)
        baseIndex = min(max(from + target, 0), savedLayout.spaceIDs.count - 1)
        pumpInstantDock()
    }

    private func setBase(_ index: Int) { baseIndex = index; dockIndex = index; dockPostTime = 0 }
    private var limit: CGFloat { CGFloat(Overlay.reach) }

    private func retarget(by requested: Int) {
        guard let layout else { return }
        let destination = min(max(baseIndex + requested, 0), layout.spaceIDs.count - 1)
        let steps = destination - baseIndex
        guard steps != 0 else { return }
        baseIndex = destination
        unpackNearImages()
        #if DEBUG
        mark("destination desktop \(destination + 1) of \(layout.spaceIDs.count): \(describeContent(at: destination))")
        #endif
        progress = min(max(progress - CGFloat(steps), -limit), limit)
        didSwitch = true
        pumpDock()
        CATransaction.begin()
        assignCards()
        overlay.render(progress: progress)
        CATransaction.commit()
    }

    private func pumpDock() {
        guard isEnabled, layout != nil, dockIndex != baseIndex else { return }
        if dockPostTime > 0, !dockIsOn(dockIndex) {
            guard CACurrentMediaTime() - dockPostTime > 1 else { return }
            transitionLog.error("Dock did not complete the requested Space switch")
            followDock(readDock: true)
            return
        }
        if case .failed = postSwitch(baseIndex > dockIndex ? 1 : -1) { followDock(readDock: true) }
    }

    private func followDock(readDock: Bool) {
        guard let layout else { return }
        syncSettle()
        // Continue (or start) the played settle from wherever the correction leaves the picture.
        defer { if phase == .settling { startSettleAnimation() } }
        var actual = dockIndex
        if readDock, let live = readLayout(for: layout.screen), live.spaceIDs == layout.spaceIDs { actual = live.currentIndex }
        let moved = baseIndex - actual
        setBase(actual)
        guard moved != 0 else { return }
        unpackNearImages()
        progress = min(max(progress + CGFloat(moved), -limit), limit)
        if overlay.isVisible {
            CATransaction.begin(); assignCards(); overlay.render(progress: progress); CATransaction.commit()
        }
        if phase == .holding || phase == .revealing {
            stabilityToken += 1
            stabilityStarted = false
            liveReady = false
            overlay.alpha = 1
            phase = .settling
        }
    }

    private enum NativeStepResult { case waiting, posted, failed }
    private func postSwitch(_ target: Int) -> NativeStepResult {
        guard isEnabled, let layout, layout.spaceIDs.indices.contains(dockIndex + target) else { return .failed }
        // Never post a swipe at a stale boundary: the Dock can wedge past its last Space.
        guard let live = readLayout(for: layout.screen, after: max(captureStarted, dockPostTime)) else { return .waiting }
        guard live.spaceIDs == layout.spaceIDs, live.currentIndex == dockIndex else { return .failed }
        trace("posting native step=\(target) actual=\(live.currentIndex)")
        overlay.confirmOnAllDesktops(layout.desktopIDs)
        guard ds_post_switch(target > 0 ? DSDirectionRight : DSDirectionLeft) else { return .failed }
        mark("native switch posted \(target)")
        dockIndex += target
        dockPostTime = CACurrentMediaTime()
        lastSwitch = (layout.displayUUID, layout.spaceIDs, dockIndex, dockPostTime)
        return .posted
    }

    private func prepare() {
        guard isEnabled else { return }
        refreshToken += 1
        captureToken += 1
        captureFinished = false
        captureFailed = false
        layout = currentLayout()
        guard let layout else { return }
        setBase(layout.currentIndex)
        unpackNearImages()
        captureStarted = CACurrentMediaTime()
        let token = captureToken
        let spaceID = layout.spaceIDs[baseIndex]
        mark("capture requested")
        snapshotter.capture(screen: layout.screen, includeDock: AppSettings.shared.dockMovesWithSpace, reuseCatalog: true) { [weak self] snapshot in
            guard let self, self.isEnabled, token == self.captureToken else { return }
            self.mark("capture delivered")
            if let snapshot { self.overlayIsBelowDock = !snapshot.includesDock; self.store(snapshot, for: spaceID) }
            self.captureFinished = true
            self.captureFailed = snapshot == nil
            self.captureDidFinish()
        }
    }

    private func captureDidFinish() {
        guard isEnabled, phase == .dragging else { return }
        trace("capture finished failed=\(captureFailed)")
        if !overlay.isVisible, !captureFailed { present() }
        guard let release = pendingRelease else { return }
        pendingRelease = nil
        if overlay.isVisible { commit(target: release.target, velocity: release.velocity) }
        else { switchWithoutOverlay(release.target) }
    }

    private func readLayout(for screen: NSScreen, after: CFTimeInterval = 0) -> SpaceLayout? {
        let displayID = screen.displayID
        return layoutQueries.value(for: displayID, after: after) {
            Spaces.layout(for: screen, displayUUID: Spaces.displayUUID(for: displayID))
        }
    }

    private func currentLayout() -> SpaceLayout? {
        guard isEnabled, let screen = inputScreen ?? NSScreen.underCursor, var layout = readLayout(for: screen) else { return nil }
        if let lastSwitch, lastSwitch.displayUUID == layout.displayUUID, lastSwitch.spaceIDs == layout.spaceIDs,
           CACurrentMediaTime() - lastSwitch.time < 1, layout.spaceIDs.indices.contains(lastSwitch.index) {
            layout.currentIndex = lastSwitch.index
        }
        forgetRemovedSpaces(layout)
        return layout
    }

    private func forgetRemovedSpaces(_ layout: SpaceLayout) {
        defer { knownSpaces[layout.displayUUID] = layout.spaceIDs }
        guard let before = knownSpaces[layout.displayUUID], before != layout.spaceIDs else { return }
        let removed = Set(before).subtracting(layout.spaceIDs)
        for id in removed { cache[id] = nil; packed[id] = nil; pictureSamples[id] = nil }
        cacheOrder.removeAll { removed.contains($0) }
    }

    private func store(_ snapshot: Snapshot, for spaceID: UInt64) {
        guard isEnabled else { return }
        cache[spaceID] = snapshot
        packed[spaceID] = nil
        pictureSamples[spaceID] = nil
        cacheOrder.removeAll { $0 == spaceID }
        cacheOrder.append(spaceID)
        while cacheOrder.count > Config.snapshotCacheLimit {
            let oldest = cacheOrder.removeFirst()
            cache[oldest] = nil; packed[oldest] = nil; pictureSamples[oldest] = nil
        }
        snapshotter.sample(of: snapshot.image) { [weak self] sample in
            // Only for the picture it was made from: a newer one may have replaced it meanwhile.
            guard let self, let sample, self.cache[spaceID]?.image === snapshot.image else { return }
            self.pictureSamples[spaceID] = sample
        }
    }

    private func forgetAllImages() {
        imageUnpacker.removeAll()
        cache.removeAll(); packed.removeAll(); cacheOrder.removeAll(); pictureSamples.removeAll()
    }
    private func imageIncludesDock(_ spaceID: UInt64) -> Bool? { cache[spaceID]?.includesDock ?? packed[spaceID]?.includesDock }

    private func packFarImages(_ token: Int) {
        guard isEnabled, cache.count > 2 * Config.fullImageRadius + 1 else { return }
        let lifecycle = lifecycleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.isEnabled, lifecycle == self.lifecycleGeneration, token == self.refreshToken, self.phase == .idle, !self.overlay.isVisible else { return }
            for screen in NSScreen.screens {
                guard let layout = self.readLayout(for: screen) else { continue }
                for (index, id) in layout.spaceIDs.enumerated() where abs(index - layout.currentIndex) > Config.fullImageRadius {
                    guard let snapshot = self.cache[id], !self.packing.contains(id) else { continue }
                    self.packing.insert(id)
                    Self.packQueue.async { [weak self] in
                        let stored = PackedSnapshot(snapshot)
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.isEnabled, lifecycle == self.lifecycleGeneration else { return }
                            self.packing.remove(id)
                            guard let stored, self.phase == .idle, self.cache[id]?.image === snapshot.image else { return }
                            self.cache[id] = nil
                            self.packed[id] = stored
                        }
                    }
                }
            }
        }
    }

    private func unpackNearImages() {
        guard isEnabled, let layout, !packed.isEmpty else { return }
        for (index, id) in layout.spaceIDs.enumerated() where abs(index - baseIndex) <= Config.fullImageRadius {
            requestUnpack(for: id)
        }
    }

    private func requestUnpack(for id: UInt64) {
        guard isEnabled, let stored = packed[id] else { return }
        let lifecycle = lifecycleGeneration
        imageUnpacker.request(id, source: stored, decode: { $0.unpacked() }) { [weak self] snapshot in
            guard let self, self.isEnabled, lifecycle == self.lifecycleGeneration,
                  let current = self.packed[id], current.isSame(as: stored) else { return }
            self.packed[id] = nil
            if let snapshot { self.cache[id] = snapshot }
            else { self.cacheOrder.removeAll { $0 == id } }
            guard self.overlay.isVisible, let layout = self.layout,
                  let index = layout.spaceIDs.firstIndex(of: id), abs(index - self.baseIndex) <= Overlay.reach else { return }
            // Replace only card contents. The active spring, phase, velocity and progress keep running.
            let playing = self.settle != nil
            self.syncSettle()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.assignCards()
            self.overlay.render(progress: self.progress)
            if playing { self.startSettleAnimation() }
            CATransaction.commit()
        }
    }

    private func content(at index: Int) -> CardContent {
        guard isEnabled, let layout, layout.spaceIDs.indices.contains(index) else { return .none }
        let id = layout.spaceIDs[index]
        if let snapshot = cache[id] { return .snapshot(snapshot) }
        requestUnpack(for: id)
        // Wallpaper decoding is already scheduled off main by refreshWallpapers(). A
        // missing image must stay a placeholder, not stall a frame decoding a large file.
        return wallpapers[layout.displayID].map { .snapshot($0) } ?? .placeholder
    }

    #if DEBUG
    /// What the card at `index` shows, for the frame-detail log: a desktop's own picture (with its age) or a stand-in.
    private func describeContent(at index: Int) -> String {
        guard let layout, layout.spaceIDs.indices.contains(index) else { return "none" }
        let id = layout.spaceIDs[index]
        if let snapshot = cache[id] { return String(format: "picture %.1fs old", CACurrentMediaTime() - snapshot.capturedAt) }
        if packed[id] != nil { return "packed" }
        return wallpapers[layout.displayID] != nil ? "WALLPAPER" : "PLACEHOLDER"
    }
    #endif

    private func present() {
        guard isEnabled, let layout, !overlay.isVisible else { return }
        overlay.isBelowDock = overlayIsBelowDock
        overlay.style = AppSettings.shared.transition
        overlay.roundsCorners = AppSettings.shared.roundedCorners
        #if DEBUG
        let presentStart = CACurrentMediaTime()
        #endif
        CATransaction.begin()
        overlay.attach(to: layout.screen)
        assignCards()
        overlay.render(progress: progress)
        CATransaction.commit()
        overlay.present()
        #if DEBUG
        mark(String(format: "overlay presented (%.1fms)", (CACurrentMediaTime() - presentStart) * 1000))
        #endif
        overlay.confirmOnAllDesktops(layout.desktopIDs)
        startLink()
    }

    private func assignCards() { overlay.setCards { self.content(at: self.baseIndex + $0) } }
    private var hasNext: Bool { guard let layout else { return false }; return baseIndex + 1 < layout.spaceIDs.count }
    private var hasPrevious: Bool { layout != nil && baseIndex > 0 }
    private func constrain(_ raw: CGFloat) -> CGFloat {
        if raw > 0, !hasNext { return Self.rubberBand(raw) }
        if raw < 0, !hasPrevious { return -Self.rubberBand(-raw) }
        let limit = max(1, abs(dragOrigin))
        return min(max(raw, -limit), limit)
    }
    private static func rubberBand(_ distance: CGFloat) -> CGFloat {
        (1 - 1 / (distance * 0.55 / Config.edgeRubberBand + 1)) * Config.edgeRubberBand
    }
    private static func progress(forFingerTravel dx: CGFloat) -> CGFloat {
        let natural = (UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool) ?? true
        return (natural ? -dx : dx) * Config.travelPerTrackpadWidth * CGFloat(AppSettings.shared.sensitivity)
    }

    private func startLink() {
        guard isEnabled, link == nil, let screen = layout?.screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        let maximum = Float(max(screen.maximumFramesPerSecond, 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = 0
        #if DEBUG
        frameIntervals.removeAll(keepingCapacity: true)
        frameCosts.removeAll(keepingCapacity: true)
        #endif
    }
    private func stopLink() { link?.invalidate(); link = nil }
    @objc private func tick(_ link: CADisplayLink) {
        guard isEnabled else { shutdown(); return }
        let now = link.timestamp
        #if DEBUG
        let frameBegan = CACurrentMediaTime()
        if lastTick > 0, frameIntervals.count < 4096 { frameIntervals.append(now - lastTick) }
        frameNominal = link.duration
        if frameLog.count < 4096 { frameLog.append((now, lastTick > 0 ? now - lastTick : 0, frameBegan - now, phase)) }
        defer {
            if frameCosts.count < 4096 { frameCosts.append(CACurrentMediaTime() - frameBegan) }
        }
        #endif
        if lastTick != 0, now - lastTick > 0.15 {
            trace("display-link gap=\(String(format: "%.3f", now - lastTick))s")
        }
        let delta = lastTick == 0 ? link.duration : min(now - lastTick, 1.0 / 30)
        lastTick = now
        if phase == .settling || phase == .holding || phase == .revealing { pumpDock() }
        switch phase {
        case .settling:
            advanceSettle(at: CACurrentMediaTime(), delta: CGFloat(delta))
            // Readback competes with rendering. Validate the destination after the
            // surfaces settle, not while the custom animation is still moving.
            if isSettled { startLiveCheckIfNeeded() }
            if abs(progress) < Config.revealStartDistance {
                if liveReady { startReveal() }
                else if isSettled { progress = 0; velocity = 0; overlay.render(progress: 0); phase = .holding; phaseStart = now }
            }
        case .holding:
            startLiveCheckIfNeeded(force: now - phaseStart > 0.5)
            if liveReady { startReveal() }
        case .revealing:
            if settle != nil { advanceSettle(at: CACurrentMediaTime(), delta: CGFloat(delta)) }
            else if !isSettled { stepSpring(CGFloat(delta)); overlay.render(progress: isSettled ? 0 : progress) }
            if revealIsCut { if isSettled { reset() } }
            else {
                let alpha = 1 - CGFloat(now - phaseStart) / Config.revealDuration
                if alpha <= 0 { reset() } else { overlay.alpha = alpha }
            }
        case .dragging:
            if overlay.isVisible { overlay.render(progress: progress) }
        case .idle, .touring: break
        }
    }
    private var isSettled: Bool { TransitionMath.isSettled(progress: progress, velocity: velocity) }
    private func stepSpring(_ delta: CGFloat) {
        TransitionMath.stepSpring(progress: &progress, velocity: &velocity, delta: delta, speed: CGFloat(AppSettings.shared.speed), limit: limit)
    }

    private var dockHasLanded: Bool { dockIsOn(baseIndex) }
    private func dockIsOn(_ index: Int) -> Bool {
        guard let layout, layout.spaceIDs.indices.contains(index),
              let live = readLayout(for: layout.screen, after: dockPostTime), live.spaceIDs == layout.spaceIDs else { return false }
        if tracedActualIndex != live.currentIndex {
            tracedActualIndex = live.currentIndex
            trace("native desktop=\(live.currentIndex) expected=\(index)")
        }
        return live.currentIndex == index
    }
    private func startLiveCheckIfNeeded(force: Bool = false) {
        guard !liveReady, !stabilityStarted else { return }
        guard didSwitch else { liveReady = true; return }
        guard dockIndex == baseIndex, force || (abs(progress) < Config.liveCheckStartDistance && dockHasLanded) else { return }
        stabilityStarted = true
        lastSample = nil
        liveStableSince = nil
        // The card shows this desktop's own picture (not the wallpaper): the live desktop is ready when it looks the same.
        if let layout, layout.spaceIDs.indices.contains(baseIndex) {
            let id = layout.spaceIDs[baseIndex]
            expectedSample = cache[id] != nil || packed[id] != nil ? pictureSamples[id] : nil
        } else {
            expectedSample = nil
        }
        stabilityToken += 1
        sampleLiveDesktop(stabilityToken, deadline: CACurrentMediaTime() + Config.revealMaxWait)
    }
    private func sampleLiveDesktop(_ token: Int, deadline: CFTimeInterval) {
        guard isEnabled, token == stabilityToken, let layout else { return }
        snapshotter.sampleBelow(windowNumber: overlay.windowNumber, screen: layout.screen) { [weak self] sample in
            guard let self, self.isEnabled, token == self.stabilityToken else { return }
            let now = CACurrentMediaTime()
            var stable = false
            var sameOrigin = false
            if let sample {
                // Ready at once when every window of the picture is drawn below. Otherwise (no picture of this
                // desktop, or it has changed since) when the live desktop has stopped changing for a while.
                if let expected = self.expectedSample, Snapshotter.liveMatchesPicture(expected, sample) { stable = true }
                if let last = self.lastSample, Snapshotter.samplesMatch(last, sample) {
                    if now - (self.liveStableSince ?? now) >= Config.liveStableTime { stable = true }
                } else {
                    self.liveStableSince = now
                }
                #if DEBUG
                let versusPicture = self.expectedSample.flatMap { Snapshotter.pictureDifference($0, sample) }
                    .map { String(format: "picture diff %.1f/%.1f%%", $0.mean, $0.changed * 100) } ?? "no picture"
                self.mark(String(format: "live sample: %@, unchanged %.0fms, landed %@", versusPicture,
                                 (now - (self.liveStableSince ?? now)) * 1000, self.dockHasLanded ? "yes" : "no"))
                #endif
                self.lastSample = sample
                if let origin = self.tourOriginSample, Snapshotter.samplesMatch(origin, sample, sameDesktop: true) {
                    stable = true; sameOrigin = true
                }
            }
            if (stable || now > deadline), self.dockHasLanded {
                if sameOrigin { self.overlay.alpha = 0 }
                self.liveReady = true
                return
            }
            if now > deadline {
                self.followDock(readDock: true)
                self.liveReady = true
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.sampleLiveDesktop(token, deadline: deadline) }
        }
    }
    private func startReveal() {
        guard phase != .revealing else { return }
        guard didSwitch else { reset(); return }
        stabilityToken += 1
        stabilityStarted = false
        lastSample = nil
        phase = .revealing
        phaseStart = CACurrentMediaTime()
        revealIsCut = !overlay.canFadeOut
        mark(revealIsCut ? "reveal cut" : "reveal fade")
    }

    /// Explicit opt-in operation only: visits uncached Spaces under an opaque cover.
    /// Never call this automatically from LeNotch startup or the enabled-setting observer.
    func captureAllSpaces() {
        guard isEnabled else { return }
        if phase != .idle { abort() }
        guard let layout = currentLayout() else { return }
        guard AppSettings.shared.transition.isDrawn else { return }
        let includesDock = AppSettings.shared.dockMovesWithSpace
        guard layout.spaceIDs.contains(where: { imageIncludesDock($0) != includesDock }) else { return }
        guard layout.spaceIDs.count > 1 else { captureCurrentSpace(); return }
        self.layout = layout
        setBase(layout.currentIndex)
        tourRoute = (baseIndex > 0 ? Array((0..<baseIndex).reversed()) : [])
        tourRoute += Array(1..<layout.spaceIDs.count)
        if baseIndex < layout.spaceIDs.count - 1 { tourRoute += Array((baseIndex..<(layout.spaceIDs.count - 1)).reversed()) }
        progress = 0; velocity = 0; didSwitch = false
        pendingRelease = nil
        tourIncludesDock = includesDock
        tourToken += 1
        let token = tourToken
        phase = .touring
        let begin: (Snapshot, Overlay.Loader?) -> Void = { [weak self] cover, loader in
            guard let self, self.isTouring(token) else { return }
            self.tourOriginSample = nil
            self.store(cover, for: layout.spaceIDs[layout.currentIndex])
            self.presentCover(cover)
            self.overlay.showLoader(loader)
            self.snapshotter.sampleBelow(windowNumber: self.overlay.windowNumber, screen: layout.screen) { [weak self] sample in
                guard let self, self.isTouring(token) else { return }
                self.tourOriginSample = sample
                self.visitNextSpace(token)
            }
        }
        snapshotter.capture(screen: layout.screen, includeDock: true) { [weak self] cover in
            guard let self, self.isTouring(token), let cover else {
                if let self, self.isTouring(token) { self.reset() }
                return
            }
            let loader = self.hideMenuBarIcon?()
            if cover.patch == nil { begin(cover, loader) }
            else {
                self.snapshotter.captureBelow(windowNumber: 0, screen: layout.screen) { [weak self] full in
                    guard let self, self.isTouring(token) else { return }
                    guard let full else { self.reset(); return }
                    begin(full, loader)
                }
            }
        }
    }

    private func presentCover(_ cover: Snapshot) {
        guard isEnabled, let layout else { return }
        overlay.isBelowDock = false
        overlay.style = .lightweight
        overlay.roundsCorners = AppSettings.shared.roundedCorners
        CATransaction.begin()
        overlay.attach(to: layout.screen)
        overlay.setCards { $0 == 0 ? .snapshot(cover) : .none }
        overlay.render(progress: 0)
        CATransaction.commit()
        overlay.present()
        overlay.confirmOnAllDesktops(layout.desktopIDs)
    }
    private func isTouring(_ token: Int) -> Bool { isEnabled && phase == .touring && token == tourToken }
    private func visitNextSpace(_ token: Int) {
        guard isTouring(token) else { return }
        guard let layout, !tourRoute.isEmpty else { finishTour(); return }
        let index = tourRoute.removeFirst()
        guard case .posted = postSwitch(index > baseIndex ? 1 : -1) else { finishTour(); return }
        baseIndex = index
        let id = layout.spaceIDs[index]
        let includesDock = tourIncludesDock
        let needsCapture = imageIncludesDock(id) != includesDock
        waitForDock(token, deadline: CACurrentMediaTime() + 1) { [weak self] in
            guard let self, self.isTouring(token) else { return }
            guard needsCapture else { self.visitNextSpace(token); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Config.visitSettleTime) { [weak self] in
                guard let self, self.isTouring(token) else { return }
                let finish: (Snapshot?) -> Void = { [weak self] snapshot in
                    guard let self, self.isTouring(token) else { return }
                    if let snapshot { self.store(snapshot, for: id) }
                    self.visitNextSpace(token)
                }
                if includesDock { self.snapshotter.captureBelow(windowNumber: self.overlay.windowNumber, screen: layout.screen, completion: finish) }
                else { self.snapshotter.captureBelowDock(screen: layout.screen, completion: finish) }
            }
        }
    }
    private func waitForDock(_ token: Int, deadline: CFTimeInterval, then: @escaping () -> Void) {
        guard isTouring(token) else { return }
        if dockHasLanded { then() }
        else if CACurrentMediaTime() > deadline { finishTour() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in self?.waitForDock(token, deadline: deadline, then: then) } }
    }
    private func finishTour() {
        guard isEnabled else { return }
        tourRoute.removeAll()
        tourToken += 1
        guard let layout, overlay.isVisible else { reset(); return }
        if let live = readLayout(for: layout.screen), live.spaceIDs == layout.spaceIDs { setBase(live.currentIndex) }
        else { setBase(baseIndex) }
        didSwitch = true
        stabilityStarted = false
        liveReady = false
        phase = .holding
        phaseStart = CACurrentMediaTime()
        startLink()
    }

    private func armCompletionDeadline() {
        completionDeadline.arm { [weak self] in
            guard let self, self.isEnabled, self.phase != .idle, self.phase != .touring else { return }
            self.trace("capture/animation deadline expired")
            // Expose the actual desktop before any further WindowServer query. The native Dock gesture has already
            // been posted: discard our presentation, never issue another switch or request another screenshot.
            self.overlay.hide()
            self.recognizer.reset()
            self.reset()
        }
    }

    private func reset() {
        #if DEBUG
        if !frameIntervals.isEmpty {
            let sorted = frameIntervals.sorted()
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000
            trace(String(format: "frames=%d interval-p95=%.2fms max=%.2fms cpu-max=%.2fms",
                         frameCosts.count, p95, (sorted.last ?? 0) * 1000, (frameCosts.max() ?? 0) * 1000))
        }
        if let first = frameLog.first?.time, frameNominal > 0 {
            let screenName = layout?.screen.localizedName ?? "?"
            var lines = [String(format: "frame-detail screen=%@ nominal=%.2fms frames=%d", screenName, frameNominal * 1000, frameLog.count)]
            for mark in frameMarks { lines.append(String(format: "  mark %+.1fms %@", (mark.time - first) * 1000, mark.label)) }
            for frame in frameLog where frame.interval > frameNominal * 1.5 {
                lines.append(String(format: "  hitch %+.1fms %@ interval=%.1fms late=%.1fms", (frame.time - first) * 1000,
                                    String(describing: frame.phase), frame.interval * 1000, frame.late * 1000))
            }
            let lates = frameLog.map(\.late).sorted()
            lines.append(String(format: "  callback-late p50=%.1fms max=%.1fms", lates[lates.count / 2] * 1000, (lates.last ?? 0) * 1000))
            transitionLog.notice("\(lines.joined(separator: "\n"), privacy: .public)")
        }
        frameLog.removeAll(keepingCapacity: true)
        frameMarks.removeAll(keepingCapacity: true)
        frameIntervals.removeAll(keepingCapacity: true)
        frameCosts.removeAll(keepingCapacity: true)
        #endif
        completionDeadline.cancel()
        captureToken += 1
        imageUnpacker.invalidateCallbacks()
        stopLink()
        stopWatchdog()
        let switched = didSwitch && overlay.isVisible
        settle = nil
        if overlay.isVisible { overlay.hide() }
        stabilityToken += 1
        stabilityStarted = false
        liveReady = false
        lastSample = nil
        expectedSample = nil
        liveStableSince = nil
        refreshToken += 1
        phase = .idle
        layout = nil
        progress = 0; velocity = 0; didSwitch = false
        pendingRelease = nil
        keyPending = false
        dockPostTime = 0
        captureFinished = false; captureFailed = false
        tourRoute.removeAll()
        tourToken += 1
        tourOriginSample = nil
        if switched, Config.refreshAfterSwitch, isEnabled { refreshCurrentSpace(refreshToken) }
        if isEnabled { packFarImages(refreshToken) }
        showMenuBarIcon?()
    }
    private func refreshCurrentSpace(_ token: Int, delay: Double = 0.15,
                                     completion: ((Snapshot, NSScreen) -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isEnabled, token == self.refreshToken, self.phase == .idle, !self.overlay.isVisible,
                  let layout = self.currentLayout() else { return }
            let id = layout.spaceIDs[layout.currentIndex]
            self.snapshotter.capture(screen: layout.screen, includeDock: AppSettings.shared.dockMovesWithSpace) { [weak self] snapshot in
                guard let self, self.isEnabled, token == self.refreshToken, self.phase == .idle, let snapshot,
                      let after = self.readLayout(for: layout.screen), after.spaceIDs.indices.contains(after.currentIndex),
                      after.spaceIDs[after.currentIndex] == id else { return }
                self.store(snapshot, for: id)
                self.packFarImages(token)
                completion?(snapshot, layout.screen)
            }
        }
    }
    func captureCurrentSpace() {
        guard isEnabled else { return }
        refreshToken += 1
        refreshCurrentSpace(refreshToken)
    }
}
