import Foundation

/// Both styles let macOS present the desktop itself.
public enum DesktopTransitionStyle: String, CaseIterable, Identifiable, Sendable, Codable {
    case system = "default"
    case instant

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .system
    }

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "macOS default"
        case .instant: "Instant"
        }
    }
    public var detail: String {
        switch self {
        case .system: "Use the live macOS desktop animation."
        case .instant: "Ask the Dock to switch directly."
        }
    }
}

public struct DesktopTransitionOptions: Equatable, Sendable, Codable {
    public var style: DesktopTransitionStyle
    public var sensitivity: Double

    public init(style: DesktopTransitionStyle = .system, sensitivity: Double = 1) {
        self.style = style
        self.sensitivity = Self.clamped(sensitivity, to: 0.5...2)
    }

    private enum CodingKeys: String, CodingKey { case style, sensitivity }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(style: try values.decode(DesktopTransitionStyle.self, forKey: .style),
                  sensitivity: try values.decode(Double.self, forKey: .sensitivity))
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 1
    }
}
