import AppKit
import SwiftUI

struct SetupAppearancePage: View {
    @AppStorage(LockWallpaper.autoKey) private var lockArt = false
    @AppStorage(DesktopColors.key) private var desktopColors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    lockScreenSetting.frame(minWidth: 260, maxWidth: .infinity)
                    desktopSetting.frame(minWidth: 260, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 28) {
                    lockScreenSetting
                    desktopSetting
                }
            }
            SetupInlineNote(symbol: "arrow.uturn.backward", text: "Your original wallpaper is saved and restored automatically.")
        }
    }

    private var lockScreenSetting: some View {
        VStack(alignment: .leading, spacing: 14) {
            previewLabel("Lock screen")
            SetupWallpaperPreview(desktop: false)
            wallpaperToggle("Lock-screen artwork", isOn: $lockArt)
            Text("Show album artwork while music is playing. Wallpaper returns on unlock.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var desktopSetting: some View {
        VStack(alignment: .leading, spacing: 14) {
            previewLabel("Desktop")
            SetupWallpaperPreview(desktop: true)
            wallpaperToggle("Album colors on desktop", isOn: $desktopColors)
            Text("Use colors from the playing album. Wallpaper returns when playback stops.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private func wallpaperToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch).controlSize(.small).tint(Color.primary)
    }
}

/// Schematic wallpaper treatments, not a representation of the user's current music or desktop.
private struct SetupWallpaperPreview: View {
    let desktop: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var albumColors: [Color] {
        [Color(red: 0.28, green: 0.39, blue: 0.33), Color(red: 0.53, green: 0.60, blue: 0.53)]
    }

    var body: some View {
        ZStack {
            SetupTheme.canvas
            if desktop {
                LinearGradient(colors: [albumColors[0].opacity(colorScheme == .dark ? 0.40 : 0.20),
                                        SetupTheme.canvas, albumColors[1].opacity(0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack {
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(0..<5) { _ in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.primary.opacity(0.15)).frame(width: 13, height: 13)
                        }
                    }
                    .padding(5)
                    .background(SetupTheme.surface.opacity(0.90), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(SetupTheme.line))
                    .padding(.bottom, 9)
                }
            } else {
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: albumColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                                .padding(12)
                        }
                        .frame(width: 51, height: 51)
                    Capsule().fill(Color.primary.opacity(0.20)).frame(width: 47, height: 3)
                    Capsule().fill(Color.primary.opacity(0.10)).frame(width: 31, height: 3)
                }
                .padding(.top, 12)
            }
        }
        .frame(height: 154)
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
                .fill(.black).frame(width: 63, height: 11)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SetupTheme.line))
        .accessibilityHidden(true)
    }
}

struct SetupIntegrationsPage: View {
    var reviewAccess: () -> Void
    @ObservedObject private var chatGPT = ChatGPTAccount.shared
    @AppStorage(NotificationStore.enabledKey) private var notifications = false
    @State private var readable = false
    @State private var agents = HookInstaller.installed()
    @State private var confirmAgents = false
    @State private var changingAgents = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SetupSection(title: "Notifications") {
                SetupPreferenceRow(symbol: "bell.badge", title: "Notifications in the notch",
                                   detail: "Collect new notifications while LeNotch is running, up to 40 per session. Existing history isn’t imported or counted as unread.",
                                   isOn: $notifications)
                    .padding(18)
                Divider().overlay(SetupTheme.line)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: readable ? "checkmark.circle" : "lock")
                            .foregroundStyle(readable ? SetupTheme.success : .secondary)
                            .font(.system(size: 13))
                            .accessibilityHidden(true)
                        Text(readable ? "Full Disk Access is allowed." : "Requires Full Disk Access to read notifications.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if !readable {
                            Button("Review access", action: reviewAccess)
                                .buttonStyle(SetupActionStyle())
                        }
                    }
                    if notifications {
                        Text(readable ? "Set an app’s banners to None to show its notifications only in the notch." : "Your preference is on. Notifications appear after access is allowed.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Notification Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                    .buttonStyle(SetupActionStyle())
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SetupInlineNote(symbol: "arrowshape.turn.up.left", text: "Messages and WhatsApp replies use the matching macOS notification’s Reply action and need Accessibility. If Reply isn’t available, open the app instead. Delivery isn’t confirmed by LeNotch.")
            SetupSection(title: "Claude & Codex") {
                SetupPreferenceRow(symbol: "apple.terminal", title: "Agent sessions",
                                   detail: "See coding activity and respond to permission requests in the notch.",
                                   isOn: Binding(get: { agents }, set: { value in
                                       if value { confirmAgents = true } else { changeAgents(false) }
                                   }))
                    .disabled(changingAgents)
                    .padding(18)
                Divider().overlay(SetupTheme.line)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Adds hooks to Claude and Codex settings. Existing files are backed up first.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Codex asks you to trust the hook once.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if changingAgents {
                        HStack(spacing: 7) { ProgressView().controlSize(.mini); Text("Updating hooks…") }
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else if agents {
                        Label("Hooks enabled", systemImage: "checkmark.circle")
                            .font(.system(size: 12)).foregroundStyle(SetupTheme.success)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SetupSection(title: "Ask AI") {
                HStack(spacing: 12) {
                    SetupIconBadge(symbol: "sparkles")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ChatGPT account").font(.system(size: 13, weight: .medium))
                        Text("Ask can search and open web pages through ChatGPT. Search queries are sent to ChatGPT; no Codex CLI is needed.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if case .connected = chatGPT.status {
                        Label("Connected", systemImage: "checkmark")
                            .font(.system(size: 12)).foregroundStyle(SetupTheme.success)
                    } else if case .connecting = chatGPT.status {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Not connected").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                Divider().overlay(SetupTheme.line)
                HStack(spacing: 12) {
                    switch chatGPT.status {
                    case .connected(let email, _):
                        if let email { Text(email).lineLimit(1).textSelection(.enabled) }
                        Spacer(minLength: 8)
                        Button("Disconnect") { chatGPT.disconnect() }
                    case .connecting:
                        Text("Finish signing in in your browser.")
                        Spacer(minLength: 8)
                        Button("Cancel") { chatGPT.disconnect() }
                    case .disconnected, .error:
                        Button("Connect ChatGPT…") { Task { try? await chatGPT.connect() } }
                        Spacer(minLength: 8)
                    }
                }
                .buttonStyle(SetupActionStyle())
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(18)
                if case .error(let message) = chatGPT.status {
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 18).padding(.bottom, 18)
                }
            }
            LauncherSettingsSection()
            UsageSettingsSection()
            SetupInlineNote(symbol: "text.alignleft", text: "Prompter works locally and doesn’t need any permissions.")
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
        .onChange(of: notifications) {
            NotificationCenter.default.post(name: NotificationStore.toggled, object: nil)
        }
        .confirmationDialog("Enable agent sessions?", isPresented: $confirmAgents, titleVisibility: .visible) {
            Button("Enable agent sessions") { changeAgents(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LeNotch will add hooks to Claude and Codex settings and back up the existing files first.")
        }
    }

    private func refresh() {
        readable = NotificationStore.readable
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
