import SwiftUI

/// Dictation lives in the notch's own row, like the volume HUD: the notch widens into ears, a mic on the left and the
/// level (or a quiet spinner) on the right. No text, no timer. Only a problem that needs words gets a small card.
/// The layer never takes hits or focus, so recording can't pull focus from the app you're dictating into.
struct DictationStatusLayer: View {
    let frame: FrameModel
    let reduceMotion: Bool

    private let dictation = DictationCoordinator.shared

    var body: some View {
        let indicator = dictation.indicator
        ZStack(alignment: .topLeading) {
            switch indicator {
            case nil:
                EmptyView()
            case .problem(let message)?:
                DictationShelf(message: message, notchHalfWidth: frame.notchHalfWidth, notchHeight: frame.notchHeight)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            case let indicator?:
                DictationEars(indicator: indicator, level: dictation.level,
                              notchHalfWidth: frame.notchHalfWidth, notchHeight: frame.notchHeight,
                              reduceMotion: reduceMotion)
                    .transition(.modifier(active: DictationGrow(amount: 0), identity: DictationGrow(amount: 1)))
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: indicator.map { $0.isShelf ? 2 : 1 } ?? 0)
    }
}

extension DictationCoordinator.Indicator {
    var isShelf: Bool {
        if case .problem = self { return true }
        return false
    }

    /// Changes when the ears' content should cross-fade; the download percentage ticking doesn't count.
    var slotKey: String {
        switch self {
        case .listening: "listening"
        case .working: "working"
        case .downloading: "downloading"
        case .note(let note): note == .ready ? "ready" : "copied"
        case .problem: "problem"
        }
    }

    var accessibilityText: String {
        switch self {
        case .listening: "Dictation listening. Press Option D to finish."
        case .working: "Dictation processing"
        case .downloading(let progress): "Downloading the dictation model, \(Int(progress * 100)) percent"
        case .note(let note): note == .ready ? "Dictation model ready" : "Copied to the clipboard"
        case .problem(let message): message
        }
    }
}

/// The notch's own size growing out to the ears' (and back), instead of a second island appearing.
struct DictationGrow: ViewModifier {
    /// 0 is about the notch's own width, 1 is the ears.
    let amount: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 0.5 + 0.5 * amount, y: 1, anchor: .center)
            .opacity(amount)
    }
}

/// The notch widened into ears: flat on top, where it meets the screen edge, with the island's own rounded bottom.
struct DictationEars: View {
    let indicator: DictationCoordinator.Indicator
    let level: Float
    let notchHalfWidth: Double
    let notchHeight: Double
    let reduceMotion: Bool

    /// How far each ear reaches past the notch: the island's own ears (`Tuning.earExtent`).
    static let reach: CGFloat = 60

    /// Black, from one point above the screen edge to two below the notch's row: the same 2 pt the resting notch wears.
    static func shape(radius: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: radius, bottomTrailing: radius), style: .continuous)
    }

    var body: some View {
        let row = CGFloat(notchHeight)
        let scale = EarMetrics.scale(notchHeight: notchHeight)
        let height = row + 3
        ZStack(alignment: .top) {
            Self.shape(radius: EarMetrics.radius(18, notchHeight: notchHeight)).fill(.black)
            HStack(spacing: 0) {
                slot { leading(scale) }
                Spacer(minLength: 0)
                slot { trailing(scale) }
            }
            .frame(height: row)
            .padding(.top, 1)
        }
        .frame(width: (CGFloat(notchHalfWidth) + Self.reach) * 2, height: height)
        .position(x: FrameModel.cx, y: height / 2 - 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: indicator.slotKey)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(indicator.accessibilityText)
    }

    private func slot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack { content().id(indicator.slotKey).transition(.opacity) }
            .frame(width: Self.reach)
    }

    @ViewBuilder private func leading(_ e: Double) -> some View {
        switch indicator {
        case .listening: glyph("mic.fill", IslandColor.red, e)
        case .working: glyph("mic.fill", .white.opacity(0.45), e)
        case .downloading: glyph("arrow.down.circle", .white.opacity(0.9), e)
        case .note(let note): note == .ready ? glyph("checkmark.circle.fill", IslandColor.green, e)
                                             : glyph("doc.on.clipboard", .white.opacity(0.9), e)
        case .problem: EmptyView()
        }
    }

    @ViewBuilder private func trailing(_ e: Double) -> some View {
        switch indicator {
        case .listening: DictationLevelBars(level: level, reduceMotion: reduceMotion)
        case .working: DictationSpinner(reduceMotion: reduceMotion)
        case .downloading(let progress): label("\(Int(progress * 100))%", e)
        case .note(let note): label(note.text, e)
        case .problem: EmptyView()
        }
    }

    private func glyph(_ name: String, _ color: Color, _ e: Double) -> some View {
        Image(systemName: name)
            .font(.system(size: 13 * e, weight: .semibold))
            .foregroundStyle(color)
    }

    private func label(_ text: String, _ e: Double) -> some View {
        Text(text)
            .font(.system(size: 12 * e, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
    }
}

/// A problem that needs words: a small card hanging from the notch.
struct DictationShelf: View {
    let message: String
    let notchHalfWidth: Double
    let notchHeight: Double

    private let width: CGFloat = 300
    private let height: CGFloat = 70

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandColor.orange)
                .frame(width: 18)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, 17)
        .frame(width: width, height: height, alignment: .topLeading)
        .background {
            DictationNotchExtension(topWidth: min(width - 36, CGFloat(notchHalfWidth) * 2))
                .fill(.black)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 7)
        }
        // Overlap the liquid shape by 5 pt so there is no gap below the hardware cutout.
        .position(x: FrameModel.cx, y: CGFloat(notchHeight) - 5 + height / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}

/// Narrow where it meets the notch and gently broadens into the card.
struct DictationNotchExtension: Shape {
    let topWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topWidth, rect.width))
        let inset = (rect.width - top) / 2
        let shoulder = min(18, rect.height * 0.28)
        let radius = min(22, rect.height * 0.38)
        var path = Path()
        path.move(to: CGPoint(x: inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + shoulder),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: inset, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Responds to the captured microphone level; no synthetic or endless waveform loop.
struct DictationLevelBars: View {
    let level: Float
    let reduceMotion: Bool

    static func heights(for level: Float) -> [CGFloat] {
        let normalized = CGFloat(max(0, min(1, level)))
        return [0.46, 0.76, 1, 0.7, 0.42].map { 3 + 15 * normalized * $0 }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(Self.heights(for: level).enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(.white.opacity(0.92))
                    .frame(width: 2.5, height: height)
            }
        }
        .frame(width: 25, height: 20)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

/// A small ring, drawn by hand: the system spinner follows the window's appearance and goes dark on black.
struct DictationSpinner: View {
    let reduceMotion: Bool
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}
