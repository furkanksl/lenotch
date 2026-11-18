import AppKit
import CDockSwipe
import QuartzCore

/// Decides when another Dock event is safe. Only a freshly observed landing can authorize a second step.
struct InstantSpaceRun {
    enum Action: Equatable { case wait, stop, step(Int) }

    let displayUUID: String
    let spaceIDs: [UInt64]
    let origin: Int
    private(set) var expectedIndex: Int
    private(set) var awaitingLanding = false

    init(displayUUID: String, spaceIDs: [UInt64], index: Int) {
        self.displayUUID = displayUUID
        self.spaceIDs = spaceIDs
        origin = index
        expectedIndex = index
    }

    mutating func next(displayUUID: String, spaceIDs: [UInt64], index: Int, offset: Int) -> Action {
        guard self.displayUUID == displayUUID, self.spaceIDs == spaceIDs,
              spaceIDs.indices.contains(index) else { return .stop }
        guard index == expectedIndex else { return awaitingLanding ? .wait : .stop }
        awaitingLanding = false
        let target = min(max(origin + offset, 0), spaceIDs.count - 1)
        return target == index ? .stop : .step((target - index).signum())
    }

    mutating func posted(_ direction: Int) {
        expectedIndex += direction
        awaitingLanding = true
    }
}

/// Drives the existing Instant gesture through the Dock. LeNotch never renders the desktop.
@MainActor
final class TransitionController {
    var onActivityChanged: ((Bool) -> Void)?
    var isTransitioning: Bool { run?.awaitingLanding == true }

    private let sensitivity: CGFloat
    private let recognizer = SwipeRecognizer()
    private let queries = TransitionQueryCache<CGDirectDisplayID, SpaceLayout>(worker: { work in
        Spaces.queryQueue.async(execute: DispatchWorkItem(block: work))
    })
    private var screen: NSScreen?
    private var run: InstantSpaceRun?
    private var held = false
    private var offset = 0
    private var swipeDirection = 0
    private var queryAfter: CFTimeInterval = 0
    private var deadline: CFTimeInterval = 0
    private var timer: Timer?

    init(initialLayout: SpaceLayout, sensitivity: Double) {
        self.sensitivity = CGFloat(sensitivity)
        queries.seed(initialLayout, for: initialLayout.displayID)
        recognizer.onArm = { [weak self] in self?.warmLayout() }
        recognizer.onBegin = { [weak self] in self?.beginSwipe() }
        recognizer.onChange = { [weak self] travel in self?.changeSwipe(travel) }
        recognizer.onEnd = { [weak self] _, cancelled in self?.endSwipe(cancelled: cancelled) }
    }

    func receive(fingers: TouchFrame) { recognizer.handle(fingers) }

    func keyboardStep(_ direction: Int) {
        guard direction != 0, screen == nil, !held else { return }
        begin(on: NSScreen.underCursor)
        offset = direction.signum()
        pump()
    }

    func spacesChanged() {
        if !isTransitioning { queries.invalidate() }
        if let screen { _ = readLayout(for: screen, after: queryAfter) }
    }

    func displaysChanged() {
        queries.invalidate()
        recognizer.reset()
        finish()
    }

    func shutdown() { displaysChanged() }

    private func warmLayout() {
        if let screen = NSScreen.underCursor { _ = readLayout(for: screen, after: 0) }
    }

    private func begin(on screen: NSScreen?) {
        self.screen = screen
        queryAfter = CACurrentMediaTime()
        deadline = queryAfter + 1.2
    }

    private func beginSwipe() {
        guard screen == nil else { return }
        begin(on: NSScreen.underCursor)
        held = screen != nil
    }

    private func changeSwipe(_ dx: CGFloat) {
        guard held else { return }
        let natural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
        let travel = (natural ? -dx : dx) * 0.9 * sensitivity
        // Ignore outliers from a trackpad reconnect; a gesture should never queue an unbounded jump.
        guard travel.isFinite, abs(travel) <= 2 else { return }
        if swipeDirection == 0 {
            guard travel != 0 else { return }
            swipeDirection = travel > 0 ? 1 : -1
            // A long press before the first movement doesn't spend the first switch's time budget.
            begin(on: screen)
        }
        let forward = travel * CGFloat(swipeDirection) + 1
        var steps = offset * swipeDirection
        while forward >= CGFloat(steps + 1) { steps += 1 }
        while forward < CGFloat(steps) - 0.15 { steps -= 1 }
        let wanted = steps * swipeDirection
        guard wanted != offset else { return }
        offset = wanted
        if !isTransitioning {
            queryAfter = CACurrentMediaTime()
            deadline = queryAfter + 1.2
        }
        pump()
    }

    private func endSwipe(cancelled: Bool) {
        guard held else { return }
        held = false
        if cancelled || swipeDirection == 0 { finish(); return }
        pump()
    }

    private func readLayout(for screen: NSScreen, after: CFTimeInterval) -> SpaceLayout? {
        let displayID = screen.displayID
        return queries.value(for: displayID, after: after) { Spaces.layout(for: displayID) }
    }

    private func pump() {
        guard let screen else { finish(); return }
        let now = CACurrentMediaTime()
        guard now < deadline, NSScreen.underCursor?.displayID == screen.displayID else { finish(); return }
        guard let live = readLayout(for: screen, after: queryAfter) else { wait(); return }
        let wasTransitioning = isTransitioning
        var next = run ?? InstantSpaceRun(displayUUID: live.displayUUID, spaceIDs: live.spaceIDs, index: live.currentIndex)
        let action = next.next(displayUUID: live.displayUUID, spaceIDs: live.spaceIDs, index: live.currentIndex, offset: offset)
        switch action {
        case .wait:
            wait()
        case .stop:
            // Keep the origin while the gesture is held, unless the layout changed externally.
            guard held, live.displayUUID == next.displayUUID, live.spaceIDs == next.spaceIDs,
                  live.currentIndex == next.expectedIndex else { finish(); return }
            run = next
            stopTimer()
            if wasTransitioning { onActivityChanged?(false) }
        case .step(let direction):
            guard ds_post_switch(direction > 0 ? DSDirectionRight : DSDirectionLeft) else { finish(); return }
            next.posted(direction)
            run = next
            queryAfter = CACurrentMediaTime()
            deadline = queryAfter + 1.2
            wait()
            if !wasTransitioning { onActivityChanged?(true) }
        }
    }

    private func wait() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func finish() {
        let wasTransitioning = isTransitioning
        stopTimer()
        screen = nil
        run = nil
        held = false
        offset = 0
        swipeDirection = 0
        if wasTransitioning { onActivityChanged?(false) }
    }
}
