import AppKit
import SwiftUI

struct SetupAppearancePage: View {
    @AppStorage(LockWallpaper.autoKey) private var lockArt = false
    @AppStorage(DesktopColors.key) private var desktopColors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.11, green: 0.25, blue: 0.22))
                    Image(systemName: "music.note").font(.system(size: 25, weight: .medium))
                        .foregroundStyle(Color(red: 0.71, green: 0.81, blue: 0.67))
                }
                .frame(width: 64, height: 64).rotationEffect(.degrees(-7))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your music, a little closer.").font(.system(size: 13, weight: .medium))
                    Text("Album artwork on the lock screen").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 124)
            .background(SetupTheme.sidebar)
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                    .fill(.black).frame(width: 85, height: 16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SetupTheme.line))
            .accessibilityHidden(true)
            .padding(.bottom, 10)

            SetupPreferenceRow(symbol: "lock.rectangle", title: "Lock-screen artwork",
                               detail: "Use the current album artwork on your lock screen. Your wallpaper is restored when you unlock.",
                               isOn: $lockArt)
                .padding(.vertical, 20)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                SetupPreferenceRow(symbol: "paintpalette", title: "Album colors on desktop",
                                   detail: "Let your desktop follow the colors of your music. Your wallpaper returns when playback stops.",
                                   isOn: $desktopColors)
                HStack(spacing: 5) {
                    ForEach(["#1B3831", "#48604F", "#9DA98E", "#DEDCC7"], id: \.self) { hex in
                        RoundedRectangle(cornerRadius: 4).fill(Color(hex: hex)).frame(width: 32, height: 19)
                    }
                }
                .padding(.leading, 41).accessibilityHidden(true)
            }
            .padding(.vertical, 20)
            Divider()
            SetupInlineNote(symbol: "arrow.uturn.backward", text: "Both are off by default. Your original wallpaper is kept so you can return to it.")
                .padding(.top, 18)
        }
    }
}

struct SetupIntegrationsPage: View {
    var reviewAccess: () -> Void
    @AppStorage(NotificationStore.enabledKey) private var notifications = false
    @State private var readable = false
    @State private var agents = HookInstaller.installed()
    @State private var confirmAgents = false
    @State private var changingAgents = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Messages & notifications")
                SetupPreferenceRow(symbol: "bell.badge", title: "Notifications in the notch",
                                   detail: "Show notifications from local notification storage. No notification account or service is connected.",
                                   isOn: $notifications)
                HStack(spacing: 8) {
                    Image(systemName: readable ? "checkmark.circle.fill" : "lock")
                        .foregroundStyle(readable ? SetupTheme.success : .secondary)
                    Text(readable ? "Full Disk Access is allowed." : "Requires Full Disk Access to read notifications.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if !readable { Button("Review access", action: reviewAccess).buttonStyle(.link) }
                }
                .font(.system(size: 11)).padding(12)
                .background(RoundedRectangle(cornerRadius: 7).strokeBorder(SetupTheme.line))
                .padding(.leading, 41)
                if notifications {
                    Text(readable ? "Set an app’s banners to None if you want its notifications only in the notch." : "Your preference is on. Notifications appear after access is allowed.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 41)
                }
                Button("Notification Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .buttonStyle(.link).font(.system(size: 11)).padding(.leading, 41)
            }
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Tools & agents")
                SetupPreferenceRow(symbol: "apple.terminal", title: "Agent sessions",
                                   detail: "Show Claude and Codex activity, with Allow and Deny in the notch.",
                                   isOn: Binding(get: { agents }, set: { value in
                                       if value { confirmAgents = true } else { changeAgents(false) }
                                   }))
                    .disabled(changingAgents)
                Text("Enabling adds hooks to Claude and Codex settings. Existing settings are backed up first; Codex asks you to trust the hook once.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 41)
                if changingAgents {
                    HStack(spacing: 7) { ProgressView().controlSize(.mini); Text("Updating hooks…") }
                        .font(.system(size: 11)).padding(.leading, 41)
                } else if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.red).padding(.leading, 41)
                        .textSelection(.enabled)
                } else if agents {
                    Label("Hooks enabled", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(SetupTheme.success).padding(.leading, 41)
                }
            }
            Divider()
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

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
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
