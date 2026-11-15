import AppKit
import SwiftUI

/// Dictation in the notch (`PresentationMode.dictation`). It's the liquid's own: the ears pour out of the notch on the
/// shape's springs and this content rides them inside the island's clip, laid out like the music ears: the mic where
/// the cover sits, four bars where the music's bars sit. As the model hears you, your words fill a lip under the notch,
/// the newest on its last line. While it works the bars become a slow wave, a check marks the text landing, and a
/// problem's message takes the lip. Nothing here takes a press.
struct DictationLayer: View {
    let frame: FrameModel
    let director: IslandDirector

    var body: some View {
        DictationEarsView(frame: frame, indicator: director.dictation ?? .listening,
                          meter: director.sampleDictationMeter ?? DictationCoordinator.shared.meter,
                          lipText: director.dictationLipText, lipLines: director.dictationLipLines,
                          textWidth: director.dictationTextWidth)
    }
}

struct DictationEarsView: View {
    let frame: FrameModel
    let indicator: DictationCoordinator.Indicator
    let meter: DictationMeter
    var lipText: String?
    var lipLines = 0
    var textWidth = 0.0

    var body: some View {
        let cx = FrameModel.cx, nh = frame.notchHeight, e = frame.earScale
        let l = frame.left, r = frame.right
        ZStack(alignment: .topLeading) {
            // Where the music ears put the cover (left) and the bars (right), at the ear scale (`EarMetrics`).
            leading(e)
                .frame(width: 22 * e, height: 22 * e)
                .offset(x: l + 11, y: (nh - 22 * e) / 2)
            trailing(e)
                .offset(x: r - 11 - trailingWidth(e), y: (nh - trailingHeight(e)) / 2)
            if let lipText {
                // As the lip grows to hold them, centred under the notch at the ears' resting width.
                let open = min(max((frame.height - nh - 8) / 12, 0), 1)
                DictationLipText(text: lipText, lines: max(lipLines, 1), width: textWidth, dimmed: indicator == .working)
                    .offset(x: cx + frame.mainX - textWidth / 2, y: nh + DictationText.top)
                    .opacity(open)
            }
        }
        .frame(width: NotchContentView.size.width, height: NotchContentView.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(indicator.accessibilityText)
        .accessibilityValue(lipText ?? "")
    }

    private func trailingWidth(_ e: Double) -> Double {
        if case .note(let note) = indicator { return DictationNoteLabel.width(note.text) }
        return DictationVoice.size.width * e
    }

    private func trailingHeight(_ e: Double) -> Double {
        if case .note = indicator { return 16 }
        return DictationVoice.size.height * e
    }

    @ViewBuilder private func leading(_ e: Double) -> some View {
        switch indicator {
        case .listening, .working:
            // One view for both, so the mic stays put while it dims from listening to working.
            DictationMic(listening: indicator == .listening, level: meter.level, scale: e).entrance(.left, 0)
        case .note(let note):
            Image(systemName: note == .copied ? "doc.on.clipboard.fill" : "checkmark.circle.fill")
                .font(.system(size: 17 * e, weight: .semibold))
                .foregroundStyle(note == .copied ? Color.white : IslandColor.green)
                .symbolRenderingMode(.hierarchical)
                .entrance(.left, 0)
                .id(note)
        case .problem:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 17 * e, weight: .semibold))
                .foregroundStyle(IslandColor.orange)
                .entrance(.left, 0)
        }
    }

    @ViewBuilder private func trailing(_ e: Double) -> some View {
        switch indicator {
        case .listening, .working:
            DictationVoice(meter: meter, working: indicator == .working)
                .scaleEffect(e, anchor: .topLeading)
                .frame(width: DictationVoice.size.width * e, height: DictationVoice.size.height * e, alignment: .topLeading)
                .entrance(.right, 0)
        case .note(let note):
            DictationNoteLabel(text: note.text).entrance(.right, 0).id(note)
        case .problem:
            EmptyView()
        }
    }
}

/// The text under the notch, and how big it is. The shape (`ShapeTargets`, through `IslandDirector.dictationLipLines`)
/// and the view measure it the same way, so the lip is always as tall as its lines.
enum DictationText {
    static let size = 13.0
    static let lineSpacing = 1.0
    /// From the notch's bottom edge to the first line.
    static let top = 2.0
    /// Each side, inside the ears' resting width.
    static let inset = 16.0
    static let maxLines = 2

    static var font: Font { .system(size: size, weight: .medium) }

    /// One more line's height (measured, so it matches how AppKit and SwiftUI set this font).
    static let lineHeight: Double = height("A\nA", width: 1000) - height("A", width: 1000)

    /// How many lines `text` takes at `width`: one or two. Longer text shows its last two lines.
    static func lines(_ text: String, width: Double) -> Int {
        guard !text.isEmpty, width > 0 else { return 0 }
        return height(tail(text), width: width) > height("A", width: width) + lineHeight / 2 ? maxLines : 1
    }

    /// The last words of a long transcript: only the last two lines show, so earlier ones needn't be laid out.
    static func tail(_ text: String, limit: Int = 280) -> String {
        guard text.count > limit else { return text }
        let cut = text.suffix(limit)
        guard let space = cut.firstIndex(of: " ") else { return String(cut) }
        return String(cut[cut.index(after: space)...])
    }

    static func height(_ text: String, width: Double) -> Double {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium), .paragraphStyle: style,
        ])
        return string.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading]).height
    }
}

/// Your words, newest on the last line: text that outgrows the lip scrolls up out of it under a soft fade.
struct DictationLipText: View {
    let text: String
    let lines: Int
    let width: Double
    var dimmed = false

    var body: some View {
        let box = Double(lines) * DictationText.lineHeight
        let shown = DictationText.tail(text)
        ViewThatFits(in: .vertical) {
            // Fits: from the top.
            label(shown)
            // Too long: the last lines, the earlier ones fading out above them.
            label(shown)
                .frame(width: width, height: box, alignment: .bottomLeading)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .frame(width: width, height: box, alignment: .topLeading)
        .foregroundStyle(.white.opacity(dimmed ? 0.55 : 0.92))
        .animation(.easeOut(duration: 0.25), value: dimmed)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(DictationText.font)
            .lineSpacing(DictationText.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
    }
}

/// The left ear's mic: red while it listens, breathing a little with your voice; dimmed while the words are worked out.
struct DictationMic: View {
    let listening: Bool
    let level: Float
    var scale = 1.0
    @Environment(\.islandMotion) private var motion

    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 15 * scale, weight: .semibold))
            .foregroundStyle(listening ? IslandColor.red : Color.white.opacity(0.45))
            .scaleEffect(listening && !motion.reduce ? 1 + CGFloat(min(max(level.isFinite ? level : 0, 0), 1)) * 0.12 : 1)
            .animation(motion.reduce ? nil : .easeOut(duration: DictationAudioRecorder.meterInterval), value: level)
            .animation(.easeInOut(duration: 0.25), value: listening)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The right ear's voice: the music ears' four bars (`BarsView`), each one band of your voice, the way the music bars
/// follow a song. Silence rests them at the music bars' floor. While it works they become a slow, low wave.
struct DictationVoice: View {
    let meter: DictationMeter
    let working: Bool
    @Environment(\.islandMotion) private var motion
    @Environment(\.revealed) private var revealed

    /// The music ears' bars: 18 × 13 pt, four 3 pt bars 2 pt apart, from a shared baseline.
    static let size = CGSize(width: 18, height: 13)
    /// The working wave's crest, a fraction of the height: lower than a voice, so it reads as thinking, not hearing.
    static let waveCrest = 0.6

    /// Each bar's height, 0…1: its band, while the mic hears more than the room. The music bars' floor otherwise.
    static func heights(_ meter: DictationMeter) -> [Double] {
        let level = meter.level.isFinite ? Double(meter.level) : 0
        let speaking = min(max((level - 0.03) / 0.12, 0), 1)
        return (0..<DictationMeter.bandCount).map { i in
            let band = i < meter.bands.count && meter.bands[i].isFinite ? Double(meter.bands[i]) : 0
            return EqualizerBars.floor + (1 - EqualizerBars.floor) * min(max(band, 0), 1) * speaking
        }
    }

    /// The travelling wave at time `t` (seconds): one crest moving left to right, each bar a step behind the last.
    static func wave(at t: Double) -> [Double] {
        (0..<DictationMeter.bandCount).map { i in
            let phase = (sin(t * 2 * .pi * 0.8 - Double(i) * 0.9) + 1) / 2
            return EqualizerBars.floor + (waveCrest - EqualizerBars.floor) * phase
        }
    }

    var body: some View {
        let animated = working && revealed && !motion.reduce && !motion.stills
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
            let heights = working ? Self.wave(at: animated ? context.date.timeIntervalSinceReferenceDate : 0.3)
                                  : Self.heights(meter)
            let rects = BarsView.rects(in: Self.size, heights: heights)
            ZStack(alignment: .topLeading) {
                ForEach(rects.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .frame(width: rects[i].width, height: rects[i].height)
                        .offset(x: rects[i].minX, y: rects[i].minY)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .foregroundStyle(.white.opacity(working ? 0.5 : 0.92))
        }
        .animation(motion.reduce || working ? nil : .easeOut(duration: DictationAudioRecorder.meterInterval), value: meter)
        .animation(.easeInOut(duration: 0.3), value: working)
        .accessibilityHidden(true)
    }
}

/// The right ear's word after a run ("Pasted"), right-aligned at the ear's end.
struct DictationNoteLabel: View {
    let text: String

    static func width(_ text: String) -> Double {
        ceil(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).size().width) + 1
    }

    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            .fixedSize()
            .frame(width: Self.width(text), height: 16, alignment: .trailing)
    }
}

extension DictationCoordinator.Indicator {
    var accessibilityText: String {
        switch self {
        case .listening: "Dictation is listening. Release Fn for push-to-talk, or use your toggle shortcut to finish. Escape cancels."
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
