import SwiftUI

struct SetupDictationPage: View {
    var reviewAccess: () -> Void

    @AppStorage("lenotch.dictation.model") private var selectedModel = "fluidSpeechPro"
    @AppStorage("lenotch.dictation.cleanup") private var cleanupEnabled = false
    @AppStorage(DictationProvider.preferenceKey) private var providerID = DictationProvider.local.rawValue
    @AppStorage(DictationInputSettings.pushToTalkKey) private var pushToTalk = false
    @AppStorage(DictationInputSettings.toggleShortcutKey) private var toggleShortcut = true
    private let dictation = DictationCoordinator.shared
    @ObservedObject private var chatGPT = ChatGPTAccount.shared

    private var model: DictationModel { DictationModel(rawValue: selectedModel) ?? .fluidSpeechPro }
    private var provider: DictationProvider { DictationProvider(rawValue: providerID) ?? .local }
    private var providerIsBusy: Bool { dictation.running || dictation.phase == .preparing }

    private var speechIsPreparing: Bool {
        dictation.phase == .preparing && dictation.preparingSpeechModel?.rawValue == selectedModel
    }

    private var cleanupIsPreparing: Bool { dictation.preparingCleanup && dictation.phase == .preparing }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            SetupDictationHero(pushToTalk: pushToTalk, toggleShortcut: toggleShortcut,
                               shortcutUnavailable: dictation.shortcutUnavailable)
            .overlay(alignment: .bottomLeading) {
                SetupSegmented(selection: $providerID, options: DictationProvider.allCases.map { ($0.rawValue, $0.name) },
                               isOptionDisabled: { raw in
                    !(DictationProvider(rawValue: raw) ?? .local).isAvailable(chatGPTConnected: chatGPT.isConnected)
                })
                .disabled(providerIsBusy)
                .help(chatGPT.isConnected ? "Choose where speech is transcribed." : "Connect ChatGPT in AI providers to enable ChatGPT dictation.")
                .accessibilityIdentifier("setup-dictation-provider")
                .padding(.leading, 24).padding(.bottom, 20)
            }

            if provider == .chatGPT {
                SetupGroup("Transcription") {
                    SetupRow(icon: .mic, active: chatGPT.isConnected, title: "ChatGPT dictation",
                             detail: chatGPT.isConnected
                             ? "Uses your connected account. No speech model download. Audio is uploaded when you finish; no live text previews. Internet required."
                             : "ChatGPT is disconnected. Reconnect in AI providers or choose On this Mac to dictate.",
                             badge: chatGPT.isConnected ? SetupBadge(text: "Connected", icon: .tick) : nil) { EmptyView() }
                    SetupNote(text: "Uses ChatGPT’s transcription service. Availability may vary by account or change over time.")
                }
            } else {
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

            SetupNote(icon: .lock, text: provider == .local
                      ? "Speech recognition runs on your Mac. No audio uploads. Connect ChatGPT in AI providers to dictate without downloading a speech model."
                      : "Your recording is sent to ChatGPT for transcription. Optional cleanup still runs on this Mac. Esc cancels; audio already sent cannot be recalled.")
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
