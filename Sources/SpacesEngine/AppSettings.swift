import Foundation

/// All styles let macOS present the desktop itself.
public enum DesktopTransitionStyle: String, CaseIterable, Identifiable, Sendable, Codable {
    case system = "default"
    case instant
    case liveSlide

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .system
    }

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "macOS default"
        case .instant: "Instant"
        case .liveSlide: "Live Slide"
        }
    }
    public var detail: String {
        switch self {
        case .system: "Use the live macOS desktop animation."
        case .instant: "Ask the Dock to switch directly."
        case .liveSlide: "Pace desktop keyboard shortcuts without screen capture. Trackpad swipes stay native."
        }
    }
}

public struct DesktopTransitionOptions: Equatable, Sendable, Codable {
    public static let defaultSlideDuration: Double = 0.35
    public static let slideDurationRange: ClosedRange<Double> = 0.15...0.75

    public var style: DesktopTransitionStyle
    public var sensitivity: Double
    /// Time in seconds spent driving the slide, before the Dock settles it.
    public var slideDuration: Double

    public init(style: DesktopTransitionStyle = .system, sensitivity: Double = 1,
                slideDuration: Double = Self.defaultSlideDuration) {
        self.style = style
        self.sensitivity = Self.clamped(sensitivity, to: 0.5...2, fallback: 1)
        self.slideDuration = Self.clamped(slideDuration, to: Self.slideDurationRange, fallback: Self.defaultSlideDuration)
    }

    private enum CodingKeys: String, CodingKey { case style, sensitivity, slideDuration }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(style: try values.decode(DesktopTransitionStyle.self, forKey: .style),
                  sensitivity: try values.decode(Double.self, forKey: .sensitivity),
                  slideDuration: try values.decodeIfPresent(Double.self, forKey: .slideDuration) ?? Self.defaultSlideDuration)
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }
}
