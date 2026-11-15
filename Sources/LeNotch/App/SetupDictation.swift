import SwiftUI

struct SetupDictationPage: View {
    var reviewAccess: () -> Void

    @AppStorage("lenotch.dictation.model") private var selectedModel = "fluidSpeechPro"
    @AppStorage("lenotch.dictation.cleanup") private var cleanupEnabled = false
    @AppStorage(DictationInputSettings.pushToTalkKey) private var pushToTalk = false
    @AppStorage(DictationInputSettings.toggleShortcutKey) private var toggleShortcut = true
    private let dictation = DictationCoordinator.shared

    private var model: DictationModel { DictationModel(rawValue: selectedModel) ?? .fluidSpeechPro }

    private var speechIsPreparing: Bool {
        dictation.phase == .preparing && dictation.preparingSpeechModel?.rawValue == selectedModel
    }

    private var cleanupIsPreparing: Bool { dictation.preparingCleanup && dictation.phase == .preparing }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            SetupDictationHero(pushToTalk: pushToTalk, toggleShortcut: toggleShortcut,
                               shortcutUnavailable: dictation.shortcutUnavailable)

            SetupGroup(title: "Speech model") {
                SetupSegmented(selection: $selectedModel, options: [
                    ("fluidSpeechPro", "Fluid Speech Pro"), ("nemotronStreaming", "Nemotron 3.5"),
                ])
                .disabled(dictation.phase == .preparing)
                .accessibilityIdentifier("setup-dictation-model")
            } content: {
                SetupRow(icon: .audioWave, active: dictation.selectedModelReady, title: model.name,
                         detail: model == .nemotronStreaming
                         ? "Native streaming: your words appear as you speak. About 700 MB."
                         : "Live previews as you speak; refines the transcript when you stop. About 650 MB.",
                         badge: dictation.selectedModelReady ? SetupBadge(text: "Ready", icon: .tick) : nil) {
                    if !dictation.selectedModelReady {
                        Button(speechIsPreparing ? (dictation.downloadProgress == nil ? "Loading…" : "Downloading…")
                               : dictation.selectedModelInstalled ? "Load" : "Download") {
                            Task { await dictation.prepareSelectedModel() }
                        }
                        .buttonStyle(SetupButtonStyle(kind: .primary))
                        .disabled(dictation.phase == .preparing)
                    }
                } below: {
                    if dictation.phase == .failed && dictation.preparingSpeechModel?.rawValue == selectedModel {
                        SetupStatusLine(kind: .failure, text: dictation.statusMessage)
                    }
                }
                if speechIsPreparing {
                    SetupProgressCard(status: dictation.statusMessage, progress: dictation.downloadProgress)
                }
            }

            if DictationCleanup.isAvailable {
                SetupGroup("Cleanup") {
                    SetupToggleRow(icon: .magicWand, title: "Clean up dictated text",
                                   detail: "A separate on-device Qwen 0.8B model fixes punctuation and wording.",
                                   isOn: $cleanupEnabled)
                    SetupRow(icon: .download, active: dictation.cleanupModelReady, title: "Cleanup model",
                             detail: "About 650 MB. Turning cleanup on doesn’t download it.",
                             badge: dictation.cleanupModelReady ? SetupBadge(text: "Ready", icon: .tick) : nil) {
                        if !dictation.cleanupModelReady {
                            Button(cleanupIsPreparing ? (dictation.downloadProgress == nil ? "Loading…" : "Downloading…")
                                   : dictation.cleanupModelInstalled ? "Load" : "Download") {
                                Task { await dictation.prepareCleanupModel() }
                            }
                            .buttonStyle(SetupButtonStyle(kind: .secondary))
                            .disabled(dictation.phase == .preparing)
                        }
                    } below: {
                        if dictation.preparingCleanup && dictation.phase == .failed {
                            SetupStatusLine(kind: .failure, text: dictation.statusMessage)
                        }
                    }
                    if cleanupIsPreparing {
                        SetupProgressCard(status: dictation.statusMessage, progress: dictation.downloadProgress)
                    }
                }
            }

            SetupGroup("Shortcuts") {
                SetupToggleRow(icon: .mic, title: "Hold Fn to talk",
                               detail: "Hold the Fn / Globe key while speaking. Release to finish and paste. Off by default.",
                               isOn: $pushToTalk) {
                    if pushToTalk && dictation.pushToTalkUnavailable {
                        SetupStatusLine(kind: .info, text: "Fn needs Accessibility access. Review permissions below; LeNotch will retry automatically.")
                    }
                }
                SetupToggleRow(icon: .keyboard, title: "Toggle dictation with ⌥D",
                               detail: "Press once to start, and again to finish. Independent of push-to-talk.",
                               isOn: $toggleShortcut) {
                    if toggleShortcut && dictation.shortcutUnavailable {
                        SetupStatusLine(kind: .info, text: "⌥D is in use by another app. Start dictation from the notch menu instead.")
                    }
                }
                if pushToTalk {
                    SetupNote(text: "Esc cancels. Fn-key combinations cancel the hold and keep their normal action. If macOS also opens Emoji or Dictation, set “Press 🌐 key to” to “Do Nothing” in Keyboard settings. LeNotch doesn’t change that setting.")
                }
            }

            SetupGroup("Access") {
                SetupRow(icon: .shield, title: "Microphone & Accessibility",
                         detail: "The microphone hears you; Accessibility lets LeNotch press ⌘V to paste.") {
                    Button("Review", action: reviewAccess).buttonStyle(SetupButtonStyle(kind: .secondary))
                }
            }

            SetupNote(icon: .lock, text: "Speech recognition runs on your Mac. No analytics or audio uploads are added by these settings.")
        }
        .onChange(of: pushToTalk) { NotificationCenter.default.post(name: .dictationShortcutsChanged, object: nil) }
        .onChange(of: toggleShortcut) { NotificationCenter.default.post(name: .dictationShortcutsChanged, object: nil) }
    }
}

/// KLOI's "Summon" bento: a warm gradient card with the shortcut's keys tilted in its corner.
private struct SetupDictationHero: View {
    let pushToTalk: Bool
    let toggleShortcut: Bool
    let shortcutUnavailable: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pushToTalk ? "Hold Fn to talk" : toggleShortcut ? "Press ⌥D anywhere" : "Dictate from the notch")
                    .font(.system(size: 16, weight: .heavy)).tracking(-0.4)
                    .foregroundStyle(SetupTheme.text)
                Text(pushToTalk ? "Hold while you speak, release to paste. Esc cancels."
                     : !toggleShortcut ? "Start and finish from the notch menu, or enable a shortcut below. Esc cancels."
                     : shortcutUnavailable
                     ? "⌥D is in use by another app. Start dictation from the notch menu instead."
                     : "Speak, press it again, and your words are pasted where you’re typing. Esc cancels.")
                    .setupDetail().frame(maxWidth: 270, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(alignment: .bottom, spacing: 6) {
                if pushToTalk {
                    SetupKeycap(symbol: "fn", name: "globe", width: 58)
                } else if toggleShortcut {
                    SetupKeycap(symbol: "⌥", name: "option", width: 58)
                    SetupKeycap(symbol: "D", width: 52)
                }
            }
            .rotationEffect(.degrees(-12))
            .padding(.trailing, 18).padding(.bottom, 6)
            .accessibilityHidden(true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background {
            ZStack {
                LinearGradient(colors: dark ? [.setupHex(0x1F1D1A), .setupHex(0x151412)] : [.setupHex(0xFAF9F7), .setupHex(0xF2F1EF)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if dark {
                    RadialGradient(colors: [SetupTheme.accent.opacity(0.13), .clear], center: UnitPoint(x: 0.82, y: 0.2),
                                   startRadius: 0, endRadius: 240)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(SetupTheme.ink(0.04, 0.06), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
