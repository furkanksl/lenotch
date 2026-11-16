import Foundation

/// Algorithms adapted from Interspace (MIT, cnrad). This library owns no preferences: LeNotch supplies configuration
/// only after an explicit opt-in. Constructing a settings value never touches macOS or captures pixels.
public enum DesktopTransitionStyle: String, CaseIterable, Identifiable, Sendable, Codable {
    case system = "default"
    case instant, lightweight, magnetic, hexagon, stack
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "macOS default"
        case .instant: "Instant"
        case .lightweight: "Lightweight"
        case .magnetic: "Magnetic"
        case .hexagon: "Hexagon"
        case .stack: "Stack"
        }
    }
    public var detail: String {
        switch self {
        case .system: "Keep the standard macOS desktop transition."
        case .instant: "Switch immediately, without drawing an animation."
        case .lightweight: "A short slide, with no zoom."
        case .magnetic: "Desktops pull away and spring into place."
        case .hexagon: "Turn between desktops like faces of a prism."
        case .stack: "Peel the current desktop off the stack."
        }
    }
    var isCustom: Bool { self != .system }
    var isDrawn: Bool { isCustom && self != .instant }
}

typealias TransitionStyle = DesktopTransitionStyle

public struct DesktopTransitionOptions: Equatable, Sendable, Codable {
    public var style: DesktopTransitionStyle
    public var speed: Double
    public var sensitivity: Double
    public var roundedCorners: Bool
    public var moveDock: Bool
    public init(style: DesktopTransitionStyle = .lightweight, speed: Double = 1, sensitivity: Double = 1,
                roundedCorners: Bool = true, moveDock: Bool = false) {
        self.style = style
        self.speed = Self.clamped(speed, to: 0.3...2)
        self.sensitivity = Self.clamped(sensitivity, to: 0.5...2)
        self.roundedCorners = roundedCorners
        self.moveDock = moveDock
    }
    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 1
    }
}

final class AppSettings {
    static let shared = AppSettings()
    var transition = TransitionStyle.lightweight
    var speed = 1.0
    var sensitivity = 1.0
    var roundedCorners = true
    var dockMovesWithSpace = false
    static let speedRange: ClosedRange<Double> = 0.3...2
    static let sensitivityRange: ClosedRange<Double> = 0.5...2
    func apply(_ options: DesktopTransitionOptions) {
        transition = options.style
        speed = options.speed
        sensitivity = options.sensitivity
        roundedCorners = options.roundedCorners
        dockMovesWithSpace = options.moveDock
    }
}
