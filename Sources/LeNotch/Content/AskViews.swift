import IslandCore
import SwiftUI

/// Text-only Quick Ask: a provider switch, keyboard hint, and capsule field with its send button.
struct AskCardLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    let provider: AgentProvider?
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
                    focused = true
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
        .accessibilityLabel("Ask")
    }

    private func field(_ p: AgentProvider) -> some View {
        let placeholder = "Ask \(p == .claude ? "Claude" : "ChatGPT")"
        return HStack(spacing: 0) {
            if motion.stills {
                Text(placeholder).foregroundStyle(.white.opacity(0.4)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { director.closeAsk() }
                    .accessibilityLabel(placeholder)
            }
            Button(action: submit) {
                Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(p == .claude ? .white : .black)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(p == .claude ? AgentLook.clay : .white))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle(pressed: 0.85, hover: 1.06))
            .accessibilityLabel("Ask")
        }
        .font(.system(size: 14))
        .padding(.leading, 16).padding(.trailing, 5)
        .frame(height: 40)
        .background(Capsule().fill(.white.opacity(0.1)))
        .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.35 : 0.12), lineWidth: focused ? 1 : 0.5))
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { focused = true; return }
        director.submitAsk(text)
        text = ""
        focused = false
    }
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
