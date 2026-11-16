import IslandCore
import SwiftUI

/// The Ask arrow sends a question once connected; before that it performs the
/// same sign-in action as the text, instead of looking clickable but doing nothing.
enum AskPrimaryAction: Equatable {
    case send, connect, wait

    static func forProvider(_ provider: AgentProvider, status: ChatGPTAccountStatus) -> Self {
        guard provider == .codex else { return .send }
        switch status {
        case .connected: return .send
        case .connecting: return .wait
        case .disconnected, .error: return .connect
        }
    }
}

/// Quick Ask: text for either provider, plus connected-account voice for ChatGPT.
struct AskCardLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    let provider: AgentProvider?
    @ObservedObject private var chatGPT = ChatGPTAccount.shared
    @Environment(\.islandMotion) private var motion
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if provider != nil {
            let p = director.askProvider
            CardPlacement(frame: frame, card: Island.askCard) {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            switcher(p)
                            Spacer(minLength: 8)
                            Text("Return to ask · Esc to close").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        }
                        .frame(height: 28)
                        .rise(0)
                        field(p).rise(1)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .frame(width: Island.askCard.width, height: Island.askCard.height)
                    .foregroundStyle(.white)
                    .onChange(of: focused) { _, f in director.replyFocused = f }
                    .task {
                        // The panel has just become key: give the field the keyboard.
                        try? await Task.sleep(for: .milliseconds(60))
                        focused = director.askProvider != .codex || chatGPTReady
                    }
                    .onChange(of: chatGPT.status) { _, _ in
                        if director.askProvider == .codex && chatGPTReady { focused = true }
                    }
            }
        }
    }

    private func switcher(_ selected: AgentProvider) -> some View {
        HStack(spacing: 0) {
            ForEach(AgentProvider.backends, id: \.self) { p in
                Button { director.setAskProvider(p) } label: {
                    HStack(spacing: 6) {
                        AgentMark(provider: p, size: 15)
                        Text(p == .claude ? "Claude" : "ChatGPT")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(p == selected ? .white : .white.opacity(0.6))
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(p == selected ? 0.18 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(p == selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat")
    }

    private func field(_ p: AgentProvider) -> some View {
        let placeholder = "Ask \(p == .claude ? "Claude" : "ChatGPT")"
        return HStack(spacing: 0) {
            if p == .codex {
                Button {
                    focused = false
                    director.openAskVoice()
                } label: {
                    VoiceOrb(size: 26)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(PressScaleStyle(pressed: 0.88, hover: 1.06))
                .disabled(!chatGPT.isConnected)
                .opacity(chatGPT.isConnected ? 1 : 0.35)
                .padding(.trailing, 8)
                .help(chatGPT.isConnected ? "Start ChatGPT voice. Microphone audio is sent to ChatGPT." : "Connect ChatGPT in Setup → AI providers to use voice.")
                .accessibilityLabel("Start ChatGPT voice")
                .accessibilityIdentifier("ask-chatgpt-voice")
            }
            if p == .codex && !chatGPTReady {
                if case .connecting = chatGPT.status {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Waiting for ChatGPT sign-in…")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                        .padding(.leading, 8)
                } else {
                    Button(chatGPTSignInError == nil ? "Connect ChatGPT account…" : "Retry ChatGPT sign-in…") {
                        primaryAction(for: p)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .help(chatGPTSignInError ?? "Sign in to ChatGPT in your browser to use Ask.")
                    .accessibilityIdentifier("ask-connect-chatgpt")
                }
                Spacer(minLength: 0)
            } else if motion.stills {
                Text(placeholder).foregroundStyle(.white.opacity(0.4)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { director.closeAsk() }
                    .accessibilityLabel(placeholder)
            }
            Button { primaryAction(for: p) } label: {
                Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(p == .claude ? .white : .black)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(p == .claude ? AgentLook.clay : .white))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle(pressed: 0.85, hover: 1.06))
            .accessibilityLabel(p == .codex && !chatGPTReady ? "Connect ChatGPT account" : "Chat")
            .disabled(AskPrimaryAction.forProvider(p, status: chatGPT.status) == .wait)
        }
        .font(.system(size: 14))
        .padding(.leading, 16).padding(.trailing, 5)
        .frame(height: 40)
        .background(Capsule().fill(.white.opacity(0.1)))
        .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.35 : 0.12), lineWidth: focused ? 1 : 0.5))
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              director.askProvider != .codex || chatGPTReady else { focused = true; return }
        director.submitAsk(text)
        text = ""
        focused = false
    }

    private func primaryAction(for provider: AgentProvider) {
        switch AskPrimaryAction.forProvider(provider, status: chatGPT.status) {
        case .send: submit()
        case .connect: Task { try? await chatGPT.connect() }
        case .wait: break
        }
    }

    private var chatGPTReady: Bool {
        if case .connected = chatGPT.status { return true }
        return false
    }

    private var chatGPTSignInError: String? {
        if case .error(let message) = chatGPT.status { return message }
        return nil
    }
}

/// WebKit media must live in the visible call window, not an offscreen helper panel.
struct AskVoiceMediaHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A ball turns once each time `rolls` goes up (the barrel-roll easter egg).
struct BarrelRoll: ViewModifier {
    let rolls: Int
    @Environment(\.islandMotion) private var motion

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(motion.reduce ? 0 : Double(rolls) * 360))
            .animation(motion.reduce ? nil : .spring(duration: 0.9, bounce: 0.25), value: rolls)
    }
}
