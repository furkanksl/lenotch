import CoreGraphics
import Foundation

/// One deterministic clock drives the fluid silhouette and the contents of every drop.
/// Sampling by elapsed time also makes intermediate animation frames testable without sleeps.
struct LauncherDropMotion {
    static let openingDuration = 1.15
    static let closingDuration = 0.85
    private var starts: [Spring] = []
    private(set) var opening = false
    private(set) var startedAt = 0.0

    mutating func transition(opening: Bool, count: Int, at time: Double) {
        let current = (0..<count).map { sample(index: $0, count: count, at: time) }
        self.opening = opening
        startedAt = time
        starts = current.map { previous in
            var spring = Spring(previous.value, config: Self.config(opening: opening), epsilon: 0.0001)
            spring.velocity = previous.velocity
            spring.target = opening ? 1 : 0
            return spring
        }
    }

    func sample(index: Int, count: Int, at time: Double) -> Spring {
        guard starts.indices.contains(index) else { return Spring(0, config: .liquid) }
        var spring = starts[index]
        // A clearly readable release sequence, not five icons radiating at once.
        let delay = opening ? Double(max(0, count - 1 - index)) * 0.11 : Double(index) * 0.05
        spring.step(max(0, time - startedAt - delay))
        return spring
    }

    func progress(index: Int, count: Int, at time: Double, settled: Bool) -> Double {
        settled ? (opening ? 1 : 0) : sample(index: index, count: count, at: time).value
    }

    private static func config(opening: Bool) -> SpringConfig {
        let frequency = 2 * Double.pi / (opening ? 0.46 : 0.4)
        let damping = opening ? 0.82 : 1.0
        return SpringConfig(stiffness: frequency * frequency, damping: 2 * damping * frequency)
    }
}

struct LauncherDropPose {
    let center: CGPoint
    let radius: CGFloat
    let progress: Double

    init(layout: LauncherFanLayout, index: Int, count: Int, progress: Double) {
        let target = layout.center(index: index, count: count)
        let origin = layout.origin(index: index, count: count)
        self.progress = progress
        center = CGPoint(x: origin.x + (target.x - origin.x) * progress,
                         y: origin.y + (target.y - origin.y) * progress)
        radius = 12 + 24 * min(max(progress, 0), 1.05)
    }

    var reveal: Double { min(max((progress - 0.3) / 0.7, 0), 1) }
    var scale: Double { 0.55 + 0.45 * reveal }
    var tail: Double { max(0, 1 - progress) }
    var isFluid: Bool { progress > 0.001 && abs(progress - 1) >= 0.015 }

    func trailingDrops(layout: LauncherFanLayout, index: Int, count: Int) -> [(center: CGPoint, radius: CGFloat)] {
        guard isFluid, tail > 0.02 else { return [] }
        return [(0.34, 0.62), (0.66, 0.78)].map { fraction, size in
            let pose = LauncherDropPose(layout: layout, index: index, count: count, progress: progress * fraction)
            return (pose.center, radius * size * tail)
        }
    }
}
