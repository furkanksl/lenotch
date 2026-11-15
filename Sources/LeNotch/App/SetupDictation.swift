import SwiftUI

struct SetupDictationPage: View {
    var reviewAccess: () -> Void

    @AppStorage("lenotch.dictation.model") private var selectedModel = "fluidSpeechPro"
    @AppStorage("lenotch.dictation.cleanup") private var cleanupEnabled = false
    private let dictation = DictationCoordinator.shared

    private var speechIsPreparing: Bool {
        dictation.phase == .preparing && dictation.preparingSpeechModel?.rawValue == selectedModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SetupSection(title: "Speech recognition") {
                VStack(alignment: .leading, spacing: 15) {
                    Picker("Speech model", selection: $selectedModel) {
                        Text("Fluid Speech Pro").tag("fluidSpeechPro")
                        Text("Nemotron Speech 3.5 · Ultra Fast Low Latency").tag("nemotronStreaming")
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(dictation.phase == .preparing)
                    .accessibilityIdentifier("setup-dictation-model")

                    Text(selectedModel == "nemotronStreaming"
                         ? "On-device streaming for low-latency dictation feedback."
                         : "On-device transcription after you stop speaking. Fluid Speech Pro does not show a live transcript.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(SetupTheme.line)

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Download your selected model")
                                .font(.system(size: 13, weight: .medium))
                            Text("Each model is a large download (about 650–700 MB). Dictation requires the selected model to be downloaded first.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button(speechIsPreparing ? (dictation.downloadProgress == nil ? "Loading model…" : "Downloading…")
                               : dictation.selectedModelReady ? "Speech model ready"
                               : dictation.selectedModelInstalled ? "Load speech model" : "Download speech model") {
                            Task { await dictation.prepareSelectedModel() }
                        }
                        .buttonStyle(SetupActionStyle())
                        .disabled(dictation.selectedModelReady || dictation.phase == .preparing)
                    }
                    if speechIsPreparing {
                        DictationDownloadIndicator(progress: dictation.downloadProgress,
                                                   statusMessage: dictation.statusMessage)
                    } else if dictation.phase == .failed && dictation.preparingSpeechModel?.rawValue == selectedModel {
                        Text(dictation.statusMessage).font(.system(size: 12)).foregroundStyle(.red)
                    }
                }
                .padding(18)
            }

            SetupSection(title: "Transcript cleanup", subtitle: "Optional · off by default") {
                VStack(alignment: .leading, spacing: 15) {
                    SetupPreferenceRow(
                        symbol: "text.badge.checkmark", title: "Clean up dictated text",
                        detail: "Use a separate on-device Qwen 0.8B model for punctuation and wording after transcription.",
                        isOn: $cleanupEnabled
                    )
                    Divider().overlay(SetupTheme.line)
                    HStack(alignment: .center, spacing: 12) {
                        Text("Cleanup needs its own large download (about 650 MB). Turning it on does not download it automatically; prepare it before use.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(dictation.preparingCleanup && dictation.phase == .preparing
                               ? (dictation.downloadProgress == nil ? "Loading model…" : "Downloading…")
                               : dictation.cleanupModelReady ? "Cleanup model ready"
                               : dictation.cleanupModelInstalled ? "Load cleanup model" : "Download cleanup model") {
                            Task { await dictation.prepareCleanupModel() }
                        }
                        .buttonStyle(SetupActionStyle())
                        .disabled(dictation.cleanupModelReady || dictation.phase == .preparing)
                    }
                    if dictation.preparingCleanup && dictation.phase == .preparing {
                        DictationDownloadIndicator(progress: dictation.downloadProgress,
                                                   statusMessage: dictation.statusMessage)
                    } else if dictation.preparingCleanup && dictation.phase == .failed {
                        Text(dictation.statusMessage).font(.system(size: 12)).foregroundStyle(.red)
                    }
                }
                .padding(18)
            }

            SetupSection(title: "Shortcut & access") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(dictation.shortcutUnavailable
                          ? "⌥D is in use by another app. Start dictation from the notch menu."
                          : "⌥D starts or stops dictation.", systemImage: "keyboard")
                        .font(.system(size: 13))
                    Text("Fn push-to-talk is a future experiment and is not available yet.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Text("Microphone access records your voice; Accessibility lets LeNotch press ⌘V to paste the result into the app you’re typing in. Both are requested only when you allow them.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Review permissions", action: reviewAccess)
                            .buttonStyle(SetupActionStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }

            SetupInlineNote(symbol: "lock.shield", text: "Speech recognition and cleanup run on your Mac. No analytics or audio uploads are added by these settings.")
        }
    }
}

struct DictationDownloadIndicator: View {
    let progress: Double?
    let statusMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let progress {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .accessibilityIdentifier("dictation-download-percent")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if let progress {
                ProgressView(value: progress)
                    .tint(.accentColor)
                    .accessibilityIdentifier("dictation-download-progress")
            }
        }
        .accessibilityIdentifier("dictation-model-status")
    }
}
