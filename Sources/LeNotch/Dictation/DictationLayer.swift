import SwiftUI

/// Dictation in the notch (`PresentationMode.dictation`). It's the liquid's own: the ears pour out of the notch on the
/// shape's springs, and this content rides them inside the island's clip, the way the HUD and the activities' ears do.
/// The left ear holds the mic, the right one your voice. While it works the bars become a slow travelling wave, a check
/// marks the text landing, and a problem grows a lip under the notch for its words. Nothing here takes a press.
struct DictationLayer: View {
    let frame: FrameModel
    let director: IslandDirector

    var body: some View {
        // Its own leaf: the levels change many times a second while you speak, and only this redraws for them.
        DictationEarsView(frame: frame, indicator: director.dictation ?? .listening,
                          levels: director.sampleDictationLevels ?? DictationCoordinator.shared.levels)
    }
}

struct DictationEarsView: View {
    let frame: FrameModel
    let indicator: DictationCoordinator.Indicator
    let levels: [Float]

    var body: some View {
        let cx = FrameModel.cx, nhw = frame.notchHalfWidth, nh = frame.notchHeight, e = frame.earScale
        // The ears' slots, from each ear's end to the notch (`ActivityEarsLayer`).
        let leftX = frame.left + 13, rightX = cx + nhw + 8
        let leftW = max(cx - nhw - 8 - leftX, 0), rightW = max(frame.right - 13 - rightX, 0)
        ZStack(alignment: .topLeading) {
            slot(width: leftW, height: nh, scale: e, alignment: .leading) { leading }
                .offset(x: leftX)
            slot(width: rightW, height: nh, scale: e, alignment: .trailing) { trailing }
                .offset(x: rightX)
            if case .problem(let message) = indicator {
                // The words under the notch, showing as the lip grows to hold them.
                let lip = frame.height - nh
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: max(frame.right - frame.left - 32, 0), alignment: .leading)
                    .offset(x: frame.left + 15, y: nh + 4)   // under the mark in the left ear
                    .opacity(min(max((lip - 18) / 16, 0), 1))
            }
        }
        .frame(width: NotchContentView.size.width, height: NotchContentView.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(indicator.accessibilityText)
    }

    /// Laid out at the design size, then scaled to the notch (`EarMetrics`; 1 in a real notch).
    private func slot<Content: View>(width: Double, height: Double, scale e: Double, alignment: Alignment,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: width / e, height: height / e, alignment: alignment)
            .scaleEffect(e, anchor: .topLeading)
            .frame(width: width, height: height, alignment: .topLeading)
            .clipped()
    }

    @ViewBuilder private var leading: some View {
        switch indicator {
        case .listening, .working:
            // One view for both, so the mic stays put while it dims from listening to working.
            DictationMic(listening: indicator == .listening, level: levels.last ?? 0).entrance(.left, 0)
        case .note(let note):
            Image(systemName: note == .copied ? "doc.on.clipboard.fill" : "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(note == .copied ? Color.white : IslandColor.green)
                .symbolRenderingMode(.hierarchical)
                .entrance(.left, 0)
                .id(note)
        case .problem:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(IslandColor.orange)
                .entrance(.left, 0)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch indicator {
        case .listening, .working:
            DictationVoice(levels: levels, working: indicator == .working).entrance(.right, 0)
        case .note(let note):
            Text(note.text).font(IslandType.ear).foregroundStyle(.white.opacity(0.9))
                .entrance(.right, 0)
                .id(note)
        case .problem:
            EmptyView()
        }
    }
}

/// The left ear's mic: red while it listens, breathing a little with your voice; dimmed while the words are worked out.
struct DictationMic: View {
    let listening: Bool
    let level: Float
    @Environment(\.islandMotion) private var motion

    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(listening ? IslandColor.red : Color.white.opacity(0.45))
            .scaleEffect(listening && !motion.reduce ? 1 + CGFloat(min(max(level, 0), 1)) * 0.12 : 1)
            .animation(motion.reduce ? nil : .easeOut(duration: DictationAudioRecorder.meterInterval), value: level)
            .animation(.easeInOut(duration: 0.25), value: listening)
            .frame(width: 22, height: 22)
    }
}

/// The right ear's voice: the last moments of your level as bars, newest on the right, so speaking scrolls them like a
/// waveform; silence leaves a row of dots. While it works they settle into a slow, low travelling wave.
struct DictationVoice: View {
    let levels: [Float]
    let working: Bool
    @Environment(\.islandMotion) private var motion
    @Environment(\.revealed) private var revealed

    static let barWidth = 2.6
    static let gap = 2.2
    static let floor = 3.0
    static let ceiling = 18.0
    /// The working wave's crest: lower than a voice, so it reads as thinking rather than hearing.
    static let waveCrest = 9.0

    /// A level's bar: a floor so silence still shows, louder growing on a soft curve so quiet speech still moves.
    static func height(_ level: Float) -> Double {
        let l = level.isFinite ? Double(min(max(level, 0), 1)) : 0
        return floor + (ceiling - floor) * pow(l, 0.75)
    }

    /// The travelling wave at time `t` (seconds): one crest moving right to left, every bar a step behind the next.
    static func wave(at t: Double, count: Int) -> [Double] {
        (0..<count).map { i in
            let phase = (sin(t * 2 * .pi * 0.9 + Double(i) * 0.7) + 1) / 2
            return floor + (waveCrest - floor) * phase
        }
    }

    /// The whole run of bars, for a given count: what it takes in the ear.
    static func width(count: Int) -> Double { Double(count) * barWidth + Double(max(count - 1, 0)) * gap }

    var body: some View {
        let animated = working && revealed && !motion.reduce && !motion.stills
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
            let t = animated ? context.date.timeIntervalSinceReferenceDate : 0.35
            let heights = working ? Self.wave(at: t, count: levels.count) : levels.map(Self.height)
            HStack(alignment: .center, spacing: Self.gap) {
                ForEach(heights.indices, id: \.self) { i in
                    Capsule().frame(width: Self.barWidth, height: heights[i])
                }
            }
            .foregroundStyle(.white.opacity(working ? 0.5 : 0.92))
            .frame(height: Self.ceiling)
        }
        .animation(motion.reduce ? nil : .easeOut(duration: DictationAudioRecorder.meterInterval), value: levels)
        .animation(.easeInOut(duration: 0.3), value: working)
        .accessibilityHidden(true)
    }
}

extension DictationCoordinator.Indicator {
    var accessibilityText: String {
        switch self {
        case .listening: "Dictation is listening. Press Option D to finish, or Escape to cancel."
        case .working: "Dictation is turning your speech into text"
        case .note(let note):
            switch note {
            case .pasted: "Dictation pasted"
            case .copied: "Dictation copied to the clipboard"
            case .ready: "Dictation model ready"
            }
        case .problem(let message): message
        }
    }
}
