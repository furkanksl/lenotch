import AppKit
import QuartzCore

/// Fixed-step snap spring driven by the display refresh, adapted from Interspace.
final class Spring {
    private var value: CGFloat
    private var velocity: CGFloat
    private let speed: CGFloat
    private let response: CGFloat
    private let limit: CGFloat
    private var tick: ((CGFloat) -> Void)?
    private var completion: (() -> Void)?
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0

    init(
        from: CGFloat, velocity: CGFloat, speed: CGFloat,
        response: CGFloat = Config.springResponse, limit: CGFloat = 1,
        tick: @escaping (CGFloat) -> Void, completion: @escaping () -> Void
    ) {
        value = from
        self.velocity = min(max(velocity, -TransitionMath.maxReleaseVelocity), TransitionMath.maxReleaseVelocity)
        self.speed = speed
        self.response = response
        self.limit = limit
        self.tick = tick
        self.completion = completion
    }

    func start(screen: NSScreen) {
        link?.invalidate()
        lastTime = CACurrentMediaTime()
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.invalidate()
        link = nil
        tick = nil
        completion = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let delta = CGFloat(min(max(now - lastTime, 0), 1.0 / 30))
        lastTime = now
        TransitionMath.stepSpring(
            progress: &value, velocity: &velocity, delta: delta,
            response: response, speed: speed, limit: limit
        )
        if TransitionMath.isSettled(progress: value, velocity: velocity) {
            tick?(0)
            let done = completion
            stop()
            done?()
        } else {
            tick?(value)
        }
    }
}
