import CoreGraphics

/// Transition tuning adapted from Interspace (MIT). AppSettings supplies the user's style and speed.
enum Config {
    static let travelPerTrackpadWidth: CGFloat = 0.9
    static let commitThreshold: CGFloat = 0.25
    static let flickVelocity: CGFloat = 1.5
    static let flickMinProgress: CGFloat = 0.03
    static let directionSlop: CGFloat = 0.015
    static let edgeRubberBand: CGFloat = 0.12

    static let springResponse: CGFloat = 0.19
    static let springDamping: CGFloat = 1.0
    static let revealDuration: CGFloat = 0.08
    static let fadeSafeTime: Double = 0.8
    static let revealStartDistance: CGFloat = 0.0015
    static let liveCheckStartDistance: CGFloat = 0.2
    static let revealMaxWait: Double = 0.6

    static let scaleInset: CGFloat = 0.06
    static let fallbackCornerRadius: CGFloat = 12
    static let gap: CGFloat = 28
    static let scaleDistance: CGFloat = 0.36
    static let dimAmount: CGFloat = 0.3

    static let hexPerspective: CGFloat = 2.0
    static let hexPushback: CGFloat = 0.2
    static let hexDim: CGFloat = 0.45
    static let magneticInset: CGFloat = 0.22
    static let stackInset: CGFloat = 0.05
    static let stackDim: CGFloat = 0.4
    static let stackShadow: CGFloat = 0.5
    static let stackShadowRadius: CGFloat = 40

    static let captureOnTouchDown = true
    static let snapshotMaxAge: Double = 0.25
    static let refreshAfterSwitch = true
    static let snapshotCacheLimit = 16
    static let fullImageRadius = 3
    /// Enabling a feature must never tour or switch the user's desktops behind their back.
    static let captureSpacesAtLaunch = false
    static let visitSettleTime: Double = 0.35
}
