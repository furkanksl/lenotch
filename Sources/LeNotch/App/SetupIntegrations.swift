import AppKit
import SwiftUI

// MARK: - Notifications

struct SetupNotificationsPage: View {
    var reviewAccess: () -> Void
    @AppStorage(NotificationStore.enabledKey) private var notifications = false
    @State private var readable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            SetupGroup {
                SetupToggleRow(icon: .bell, title: "Notifications in the notch",
                               detail: "Collect new ones while LeNotch runs, up to 40 per session. Existing history isn’t imported or counted as unread.",
                               isOn: $notifications) {
                    if notifications && !readable {
                        SetupStatusLine(kind: .info, text: "Your preference is on. Notifications appear once Full Disk Access is allowed.")
                    }
                }
            }
            SetupGroup("Access") {
                SetupPermissionRow(icon: .hardDrive, title: "Full Disk Access",
                                   detail: "Needed to read the notifications macOS stores.",
                                   state: readable ? .allowed : .notAsked, actionLabel: "Review", action: reviewAccess)
                SetupRow(icon: .settings, title: "Notification Settings",
                         detail: "Set an app’s banners to None to see it only in the notch.") {
                    Button {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Open")
                            SetupIconView(icon: .external, size: 12, lineWidth: 2.2)
                        }
                    }
                    .buttonStyle(SetupButtonStyle(kind: .secondary))
                    .accessibilityLabel("Open Notification Settings")
                }
            }
            SetupNote(text: "Messages and WhatsApp replies use the macOS notification’s own Reply action and need Accessibility. If Reply isn’t available, LeNotch opens the app instead. Delivery isn’t confirmed by LeNotch.")
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
        .onChange(of: notifications) {
            NotificationCenter.default.post(name: NotificationStore.toggled, object: nil)
        }
    }

    private func refresh() { readable = NotificationStore.readable }
}

// MARK: - AI & Agents

struct SetupAgentsPage: View {
    @ObservedObject private var chatGPT = ChatGPTAccount.shared
    @State private var agents = HookInstaller.installed()
    @State private var confirmAgents = false
    @State private var changingAgents = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            SetupGroup("Chat") {
                account
                SetupNote(text: "Chat can search and open web pages through ChatGPT, so your search queries are sent to it. No Codex CLI is needed. Claude answers use the Claude CLI on this Mac.")
            }
            SetupChatGPTVoiceSettings(connected: chatGPT.isConnected)
            SetupGroup("Coding agents") {
                SetupToggleRow(icon: .terminal, title: "Agent sessions",
                               detail: "Follow Claude and Codex and answer their permission requests in the notch.",
                               isOn: Binding(get: { agents }, set: { value in
                                   if value { confirmAgents = true } else { changeAgents(false) }
                               })) {
                    if changingAgents {
                        SetupStatusLine(kind: .progress, text: "Updating hooks…")
                    } else if let failure {
                        SetupStatusLine(kind: .failure, text: failure).textSelection(.enabled)
                    } else if agents {
                        SetupStatusLine(kind: .success, text: "Hooks installed")
                    }
                }
                .disabled(changingAgents)
                SetupNote(text: "Adds hooks to Claude and Codex settings and backs up the existing files first. Codex asks you to trust the hook once.")
            }
            UsageSettingsSection()
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
        .confirmationDialog("Enable agent sessions?", isPresented: $confirmAgents, titleVisibility: .visible) {
            Button("Enable agent sessions") { changeAgents(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LeNotch will add hooks to Claude and Codex settings and back up the existing files first.")
        }
    }

    /// KLOI's account card: "Signed in as" over the address, with the way out beside it.
    @ViewBuilder private var account: some View {
        switch chatGPT.status {
        case .connected(let email, _):
            HStack(spacing: 16) {
                SetupIconTile(icon: .chatGPT)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Signed in to ChatGPT as").font(.system(size: 13, weight: .semibold)).foregroundStyle(SetupTheme.textSecondary)
                    Text(email ?? "Connected").setupTitle().lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Disconnect") { chatGPT.disconnect() }.buttonStyle(SetupButtonStyle(kind: .soft))
            }
            .padding(20)
            .background(SetupTheme.row, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(SetupTheme.ring, lineWidth: 1))
            .accessibilityElement(children: .contain)
        case .connecting:
            SetupRow(icon: .chatGPT, active: false, title: "ChatGPT account", detail: "Finish signing in in your browser.") {
                HStack(spacing: 10) {
                    SetupSpinner()
                    Button("Cancel") { chatGPT.disconnect() }.buttonStyle(SetupButtonStyle(kind: .soft))
                }
            }
        case .disconnected, .error:
            SetupRow(icon: .chatGPT, active: false, title: "ChatGPT account",
                     detail: "Sign in once to chat with ChatGPT from the notch.") {
                Button("Connect") { Task { try? await chatGPT.connect() } }
                    .buttonStyle(SetupButtonStyle(kind: .primary))
                    .accessibilityLabel("Connect ChatGPT")
            } below: {
                if case .error(let message) = chatGPT.status {
                    SetupStatusLine(kind: .failure, text: message)
                }
            }
        }
    }

    private func refresh() {
        if !changingAgents { agents = HookInstaller.installed() }
    }

    private func changeAgents(_ enabled: Bool) {
        guard !changingAgents else { return }
        changingAgents = true
        // File validation and backups can block on disk; never perform them in a Toggle's UI callback.
        Task {
            let error = await Task.detached { () -> String? in
                do {
                    if enabled { try HookInstaller.install() } else { try HookInstaller.uninstall() }
                    return nil
                } catch HookInstaller.Failure.unreadable(let file) {
                    return "\(file.lastPathComponent) isn’t valid JSON. Fix it first; nothing was changed."
                } catch {
                    return "Couldn’t change the agent settings: \(error.localizedDescription)"
                }
            }.value
            failure = error
            changingAgents = false
            agents = HookInstaller.installed()
        }
    }
}

// MARK: - ChatGPT voice

struct SetupChatGPTVoiceSettings: View {
    let connected: Bool
    @AppStorage(ChatGPTVoice.preferenceKey) private var voiceID = ChatGPTVoice.cove.rawValue

    private var selection: Binding<ChatGPTVoice> {
        Binding(get: { ChatGPTVoice(rawValue: voiceID) ?? .cove }, set: { voiceID = $0.rawValue })
    }

    var body: some View {
        SetupGroup("Voice mode") {
            SetupRow(icon: .audioWave, active: connected, title: "ChatGPT voice",
                     detail: "The voice you hear in Chat. Changes apply to your next voice conversation.") {
                Picker("ChatGPT voice", selection: selection) {
                    ForEach(ChatGPTVoice.allCases) { voice in
                        Text(voice.name).tag(voice)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 140)
                .disabled(!connected)
                .accessibilityIdentifier("setup-chatgpt-voice")
            }
            SetupNote(text: connected
                      ? "End an active voice conversation and start a new one to hear your choice. Voice availability may vary by account."
                      : "Connect ChatGPT above to choose a voice and talk in Chat.")
        }
    }
}

// MARK: - Launcher

struct SetupLauncherPage: View {
    var body: some View { LauncherSettingsSection() }
}
