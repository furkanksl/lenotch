import Foundation
import CoreGraphics

/// Raw trackpad frames to horizontal three/four-finger drags. Distances are trackpad widths.
final class SwipeRecognizer {
    var onArm: (() -> Void)?
    var onDisarm: (() -> Void)?
    var onBegin: (() -> Void)?
    var onChange: ((_ dx: CGFloat) -> Void)?
    var onEnd: ((_ velocity: CGFloat, _ cancelled: Bool) -> Void)?

    private enum State { case idle, pending, active, ignored }
    private static let fingerRange = 3...4
    private var state = State.idle
    private var device: UInt = 0
    private var fingerCount = 0
    private var start = CGPoint.zero
    private var origin: CGFloat = 0
    private var lastDX: CGFloat = 0
    private var history: [(time: Double, dx: CGFloat)] = []

    func handle(_ frame: TouchFrame) {
        guard frame.timestamp.isFinite, frame.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
        if state != .idle, frame.device != device { return }
        let count = frame.points.count
        let centroid = Self.centroid(of: frame.points)
        switch state {
        case .idle:
            guard count >= Self.fingerRange.lowerBound else { return }
            device = frame.device
            guard count <= Self.fingerRange.upperBound else { state = .ignored; return }
            state = .pending
            fingerCount = count
            start = centroid
            onArm?()
        case .pending:
            if count < Self.fingerRange.lowerBound {
                state = .idle
                onDisarm?()
                return
            }
            if count > Self.fingerRange.upperBound {
                state = .ignored
                onDisarm?()
                return
            }
            if count != fingerCount {
                fingerCount = count
                start = centroid
                return
            }
            let dx = centroid.x - start.x
            let dy = centroid.y - start.y
            if abs(dx) >= Config.directionSlop, abs(dx) > abs(dy) * 1.2 {
                state = .active
                origin = centroid.x
                lastDX = 0
                history = [(frame.timestamp, 0)]
                onBegin?()
            } else if abs(dy) >= Config.directionSlop {
                state = .ignored
                onDisarm?()
            }
        case .active:
            if count < Self.fingerRange.lowerBound {
                let velocity = releaseVelocity(at: frame.timestamp)
                state = .idle
                onEnd?(velocity, false)
                return
            }
            if count > Self.fingerRange.upperBound {
                state = .ignored
                onEnd?(0, true)
                return
            }
            if count != fingerCount {
                fingerCount = count
                origin = centroid.x - lastDX
            }
            let dx = centroid.x - origin
            lastDX = dx
            history.append((frame.timestamp, dx))
            while let first = history.first, frame.timestamp - first.time > 0.1, history.count > 2 {
                history.removeFirst()
            }
            onChange?(dx)
        case .ignored:
            if count < Self.fingerRange.lowerBound { state = .idle }
        }
    }

    func cancel() {
        if state == .active { onEnd?(0, true) }
        if state == .pending { onDisarm?() }
        reset()
    }

    /// Forget the gesture without callbacks when the owner already handles snapping or shutdown.
    func reset() {
        state = .idle
        history.removeAll(keepingCapacity: true)
    }

    private func releaseVelocity(at time: Double) -> CGFloat {
        guard let first = history.first, let last = history.last else { return 0 }
        let span = last.time - first.time
        guard span > 0.012, time - last.time < 0.08 else { return 0 }
        return (last.dx - first.dx) / CGFloat(span)
    }

    private static func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}
