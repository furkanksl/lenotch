import CoreGraphics

/// Interspace's transition geometry, shared by the overlay and its non-capturing previews.
enum TransitionMath {
    static let maxReleaseVelocity: CGFloat = 8

    static func engage(progress: CGFloat) -> CGFloat {
        let travel = abs(progress - progress.rounded())
        let x = min(max(travel / Config.scaleDistance, 0), 1)
        return x * x * (3 - 2 * x)
    }

    static func scale(progress: CGFloat) -> CGFloat {
        1 - Config.scaleInset * engage(progress: progress)
    }

    static func dim(offCentre: CGFloat) -> CGFloat {
        Config.dimAmount * min(max(offCentre, 0), 1)
    }

    static let hexFaceAngle = CGFloat.pi / 3
    static let hexApothem: CGFloat = 0.5 / tan(CGFloat.pi / 6)

    static func hexPushback(progress: CGFloat) -> CGFloat {
        Config.hexPushback * engage(progress: progress)
    }

    static func hexDim(offset: CGFloat) -> CGFloat {
        Config.hexDim * min(abs(offset), 1)
    }

    static func hexProject(
        x: CGFloat, y: CGFloat, offset: CGFloat, progress: CGFloat
    ) -> (x: CGFloat, y: CGFloat, scale: CGFloat) {
        let angle = offset * hexFaceAngle
        let turnedX = x * cos(angle) + hexApothem * sin(angle)
        let depth = -x * sin(angle) + hexApothem * cos(angle) - hexApothem - hexPushback(progress: progress)
        let scale = Config.hexPerspective / (Config.hexPerspective - depth)
        return (turnedX * scale, y * scale, scale)
    }

    static func magneticScale(offset: CGFloat) -> CGFloat {
        let x = min(abs(offset), 1)
        return 1 - Config.magneticInset * x * x * (3 - 2 * x)
    }

    static func magneticPosition(offset: CGFloat, gap: CGFloat) -> CGFloat {
        let t = abs(offset)
        let sign: CGFloat = offset < 0 ? -1 : 1
        let far = magneticScale(offset: 1)
        if t <= 1 {
            let pair = (magneticScale(offset: t) + magneticScale(offset: 1 - t)) / 2 + gap
            return sign * t * pair
        }
        let oneStep = (1 + far) / 2 + gap
        return sign * (oneStep + (t - 1) * (far + gap))
    }

    static func stackSlide(offset: CGFloat) -> CGFloat { min(max(offset, 0), 1) }
    static func stackCover(offset: CGFloat) -> CGFloat { min(max(-offset, 0), 1) }
    static func stackScale(offset: CGFloat) -> CGFloat { 1 - Config.stackInset * stackCover(offset: offset) }
    static func stackDim(offset: CGFloat) -> CGFloat { Config.stackDim * stackCover(offset: offset) }
    static func stackShadow(offset: CGFloat) -> CGFloat {
        Config.stackShadow * min((1 - stackSlide(offset: offset)) * 8, 1)
    }

    static func isSettled(progress: CGFloat, velocity: CGFloat) -> Bool {
        abs(progress) < 0.001 && abs(velocity) < 0.02
    }

    static func stepSpring(
        progress: inout CGFloat, velocity: inout CGFloat, delta: CGFloat,
        response: CGFloat = Config.springResponse, speed: CGFloat, limit: CGFloat = 1
    ) {
        let omega = 2 * CGFloat.pi / response * speed
        let stiffness = omega * omega
        let damping = 2 * Config.springDamping * omega
        var remaining = delta
        while remaining > 0 {
            let step = min(remaining, 0.002)
            velocity += (-stiffness * progress - damping * velocity) * step
            progress += velocity * step
            remaining -= step
        }
        if progress > limit {
            progress = limit
            velocity = min(velocity, 0)
        } else if progress < -limit {
            progress = -limit
            velocity = max(velocity, 0)
        }
    }
}
