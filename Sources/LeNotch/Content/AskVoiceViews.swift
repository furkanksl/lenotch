import SwiftUI

/// Presentation only: the call coordinator owns audio, authentication and lifecycle.
enum AskVoicePresentation: Equatable {
    case connecting
    case listening
    case thinking
    case speaking
    case failed(String)
}

/// Lives on the island's black surface; it deliberately draws no card background.
struct AskVoiceView: View {
    let phase: AskVoicePresentation
    let muted: Bool
    let level: Double
    let transcript: String
    let onMute: () -> Void
    let onEnd: () -> Void
    let onRetry: () -> Void

    @Environment(\.islandMotion) private var motion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("ChatGPT voice")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("Experimental")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.08)))
            }
            .frame(height: 22)

            Spacer(minLength: 8)

            VoiceOrb(size: 108, active: orbActive, level: level)
                .opacity(failed ? 0.4 : (muted && phase == .listening ? 0.65 : 1))
                .frame(height: 126)

            Text(status)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: 328, minHeight: 36, maxHeight: 36, alignment: .top)
                .padding(.top, 8)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button(action: onMute) {
                    Label(muted ? "Unmute" : "Mute", systemImage: muted ? "mic.slash.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Capsule().fill(.white.opacity(muted ? 0.18 : 0.1)))
                }
                .disabled(phase == .connecting || failed)
                .opacity(phase == .connecting || failed ? 0.4 : 1)
                .accessibilityLabel(muted ? "Unmute microphone" : "Mute microphone")
                .accessibilityIdentifier("ask-voice-mute")

                if failed {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Capsule().fill(.white.opacity(0.18)))
                    }
                    .accessibilityLabel("Retry voice connection")
                    .accessibilityIdentifier("ask-voice-retry")
                }

                Button(action: onEnd) {
                    Label("End voice", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
                .accessibilityLabel("End voice conversation")
                .accessibilityIdentifier("ask-voice-end")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .buttonStyle(PressScaleStyle(pressed: 0.96, hover: 1.025))
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .frame(width: 420, height: 360)
        .transaction { transaction in
            if motion.reduce || motion.stills {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private var failed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var orbActive: Bool {
        phase == .speaking || (phase == .listening && !muted)
    }

    private var status: String {
        switch phase {
        case .connecting: "Connecting…"
        case .listening: muted ? "Microphone muted" : "Listening"
        case .thinking: "Thinking…"
        case .speaking: "Speaking"
        case .failed: "Voice couldn't connect"
        }
    }

    private var detail: String {
        if case .failed(let message) = phase {
            return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Please try again." : message
        }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && phase != .connecting { return text }
        switch phase {
        case .connecting: return "Microphone audio is sent to ChatGPT"
        case .listening: return muted ? "Unmute when you're ready." : "Go ahead. I'm listening."
        case .thinking: return "ChatGPT is working on a reply."
        case .speaking: return "ChatGPT is responding."
        case .failed: return "Please try again."
        }
    }
}

/// Shared by the voice card and its small input-field entry point. Audio levels
/// drive the only animation: there is no timer or perpetual idle animation.
struct VoiceOrb: View {
    let size: CGFloat
    let active: Bool
    let level: Double

    @Environment(\.islandMotion) private var motion

    init(size: CGFloat, active: Bool = false, level: Double = 0) {
        self.size = size
        self.active = active
        self.level = level
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [.white, Color(red: 0.73, green: 0.9, blue: 1), Color(red: 0.2, green: 0.51, blue: 0.94)],
                                     center: .init(x: 0.32, y: 0.23), startRadius: 0, endRadius: size * 0.85))

            Ellipse()
                .fill(.white.opacity(0.9))
                .frame(width: size * 0.86, height: size * 0.58)
                .rotationEffect(.degrees(-28))
                .offset(x: -size * 0.15, y: -size * 0.24)
                .blur(radius: size * 0.08)

            Ellipse()
                .fill(Color(red: 0.1, green: 0.4, blue: 0.94))
                .frame(width: size * 0.85, height: size * (0.62 + energy * 0.08))
                .rotationEffect(.degrees(-24 + energy * 12))
                .offset(x: size * 0.2, y: size * 0.28)
                .blur(radius: size * 0.09)

            Ellipse()
                .fill(Color(red: 0.59, green: 0.87, blue: 1).opacity(0.85))
                .frame(width: size * 0.8, height: size * 0.24)
                .rotationEffect(.degrees(-24))
                .offset(x: -size * 0.15, y: size * (0.24 - energy * 0.08))
                .blur(radius: size * 0.065)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: Color.blue.opacity(active ? 0.25 : 0.12), radius: size * 0.14)
        .scaleEffect(1 + energy * 0.065)
        .animation(motion.reduce || motion.stills ? nil : .easeOut(duration: motion.seconds(0.12)), value: energy)
        .accessibilityHidden(true)
    }

    private var energy: Double {
        guard active, level.isFinite, !motion.stills else { return 0 }
        return min(1, max(0, level))
    }
}
