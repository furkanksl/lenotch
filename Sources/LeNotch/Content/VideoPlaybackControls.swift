import SwiftUI

/// Shared by the notch and PiP. Dragging previews a position locally; only release sends a seek.
struct VideoTransportControls: View {
    let playback: VideoPlaybackState
    var showsTimeline = false
    var compact = false
    var onInteractionChange: ((Bool) -> Void)?

    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var showingSubtitles = false
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable { case back, play, forward, subtitles, timeline }

    private var length: Double? {
        guard let duration = playback.duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    private var canSeek: Bool { playback.available && playback.canSeek }
    private var interacting: Bool { scrubbing || showingSubtitles || focusedControl != nil }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !playback.playing || scrubbing)) { _ in
            VStack(spacing: 8) {
                if showsTimeline { timeline }
                transport
            }
            .padding(.horizontal, compact ? 14 : 16)
            .padding(.top, compact ? 8 : 12)
            .padding(.bottom, compact ? 10 : 12)
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.65), .black.opacity(0.84)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.top, -24)
                    .allowsHitTesting(false)
            }
        }
        .foregroundStyle(.white)
        .onChange(of: showingSubtitles) { _, _ in updateInteraction() }
        .onChange(of: focusedControl) { _, _ in onInteractionChange?(interacting) }
        .onChange(of: canSeek) { _, allowed in
            if !allowed, scrubbing { scrubbing = false; updateInteraction() }
        }
        .onDisappear {
            if scrubbing || showingSubtitles { playback.scrub(false) }
            onInteractionChange?(false)
        }
    }

    private var timeline: some View {
        let duration = length ?? 1
        let position = scrubbing ? scrubPosition : min(max(playback.elapsed, 0), duration)
        return VStack(spacing: 2) {
            Slider(value: Binding(get: { position }, set: { value in
                guard canSeek, length != nil else { return }
                if scrubbing {
                    scrubPosition = value
                } else {
                    // Native keyboard and accessibility adjustments don't always begin a drag.
                    playback.seek(to: value)
                }
            }), in: 0...duration, onEditingChanged: editTimeline)
                .controlSize(.mini)
                .tint(.white)
                .frame(height: 14)
                .disabled(!canSeek || length == nil)
                .focused($focusedControl, equals: .timeline)
                .accessibilityLabel("Video progress")
                .accessibilityValue(timelineDescription)
                .help(canSeek && length != nil ? "Seek in the video" : "Seeking is unavailable for this video")
            HStack(spacing: 8) {
                Text(VideoTime.string(scrubbing ? scrubPosition : playback.elapsed))
                Spacer(minLength: 8)
                Text(length.map(VideoTime.string) ?? "--:--")
            }
            .font(.system(size: compact ? 10 : 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.72))
            .accessibilityHidden(true)
        }
    }

    private var timelineDescription: String {
        let elapsed = VideoTime.string(scrubbing ? scrubPosition : playback.elapsed)
        return length.map { "\(elapsed) of \(VideoTime.string($0))" } ?? "\(elapsed), duration unavailable"
    }

    private var transport: some View {
        ZStack {
            HStack(spacing: 16) {
                button("gobackward.10", "Back 10 seconds", control: .back, disabled: !canSeek) {
                    playback.skip(-10)
                }
                button(playback.playing ? "pause.fill" : "play.fill", playback.playing ? "Pause" : "Play",
                       control: .play, diameter: 44, disabled: !playback.available) {
                    playback.togglePlaying()
                }
                button("goforward.10", "Forward 10 seconds", control: .forward, disabled: !canSeek) {
                    playback.skip(10)
                }
            }
            HStack {
                Spacer(minLength: 0)
                button(playback.subtitles.name == nil ? "captions.bubble" : "captions.bubble.fill", "Subtitles",
                       control: .subtitles) { showingSubtitles.toggle() }
                    .popover(isPresented: $showingSubtitles, arrowEdge: .top) { subtitleSettings }
            }
        }
        .frame(height: 44)
    }

    private var subtitleSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subtitles").font(.system(size: 13, weight: .semibold))
            Text("Captions enabled in the original video player appear here automatically.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if let name = playback.subtitles.name {
                HStack(alignment: .top, spacing: 10) {
                    Label(name, systemImage: "doc.text")
                        .font(.system(size: 12)).lineLimit(2).help(name)
                    Spacer(minLength: 0)
                    Button("Remove") { playback.subtitles.clear() }
                        .controlSize(.small)
                        .help("Remove imported subtitles")
                }
            }
            Button { playback.subtitles.importFile() } label: {
                Label("Import subtitle file…", systemImage: "doc.badge.plus")
            }
            .controlSize(.small)
            .help("Import .srt or .vtt subtitles")
            Text("Choose an .srt or .vtt file timed to this video.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error = playback.subtitles.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Subtitle error: \(error)")
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .preferredColorScheme(.dark)
    }

    private func button(_ symbol: String, _ label: String, control: Control, diameter: CGFloat = 32,
                        disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: control == .play ? 17 : 19, weight: .medium))
                .offset(x: control == .play && !playback.playing ? 1 : 0)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(.white.opacity(control == .play ? 0.16 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(VideoTransportButtonStyle())
        .focused($focusedControl, equals: control)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func editTimeline(_ editing: Bool) {
        if editing {
            guard canSeek, let length else { return }
            scrubPosition = min(max(playback.elapsed, 0), length)
            scrubbing = true
        } else if scrubbing {
            if canSeek, length != nil { playback.seek(to: scrubPosition) }
            scrubbing = false
        }
        updateInteraction()
    }

    private func updateInteraction() {
        playback.scrub(scrubbing || showingSubtitles)
        onInteractionChange?(interacting)
    }
}

private struct VideoTransportButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

/// Imported captions are separate from the mirrored picture and never intercept window dragging.
struct VideoSubtitleOverlay: View {
    let playback: VideoPlaybackState
    var bottomInset: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 0.25, paused: !playback.playing)) { _ in
                if !playback.subtitles.cues.isEmpty, let text = playback.subtitles.text(at: playback.elapsed) {
                    VStack {
                        Spacer(minLength: 0)
                        Text(text)
                            .font(.system(size: min(max(geometry.size.width / 30, 13), 17), weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            .padding(.horizontal, 16)
                            .padding(.bottom, bottomInset)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

enum VideoTime {
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(min(max(seconds, 0), Double(Int.max / 2)))
        let second = String(format: "%02d", total % 60)
        if total >= 3_600 {
            return "\(total / 3_600):\(String(format: "%02d", total / 60 % 60)):\(second)"
        }
        return "\(total / 60):\(second)"
    }
}
