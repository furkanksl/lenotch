import SwiftUI

extension Notification.Name {
    static let launcherShortcutChanged = Notification.Name("lenotch.launcher.shortcut.changed")
}

/// Setup's Launcher page, sharing the same model and editor as the notch's Configure action. Merely rendering never
/// opens anything.
struct LauncherSettingsSection: View {
    let model: LauncherModel
    let toolMenu: ToolMenuModel
    @AppStorage("lenotch.launcher.shortcut") private var shortcut = true

    init(model: LauncherModel = .shared, toolMenu: ToolMenuModel = .shared) {
        self.model = model
        self.toolMenu = toolMenu
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            LauncherPreviewCard(model: model)
            SetupGroup("Shortcut") {
                SetupToggleRow(icon: .keyboard, title: "Open with ⌥A",
                               detail: "Fan your places out of the notch from any app.", isOn: $shortcut) {
                    if shortcut && model.shortcutUnavailable {
                        SetupStatusLine(kind: .info, text: toolMenu.isEnabled(.launcher)
                                        ? "⌥A is already in use. Launcher is still available in Tools."
                                        : "⌥A is already in use. Turn Launcher on in the Tools page to open it from the notch's menu.")
                    }
                }
                .onChange(of: shortcut) { NotificationCenter.default.post(name: .launcherShortcutChanged, object: nil) }
            }
        }
    }
}

/// KLOI's "Notch Preview" card: a caps header with the count, the places as they line up in the notch, and a footer
/// with the way to change them.
private struct LauncherPreviewCard: View {
    let model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("NOTCH PREVIEW").font(.system(size: 13, weight: .bold)).tracking(0.4)
                    .foregroundStyle(SetupTheme.textTertiary)
                Spacer()
                SetupBadge(text: "\(model.items.count) of \(LauncherModel.maximumItems)", tone: .neutral)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .overlay(alignment: .bottom) { SetupTheme.ring.frame(height: 1) }

            Group {
                if model.items.isEmpty {
                    VStack(spacing: 6) {
                        SetupIconView(icon: .grid, size: 26, lineWidth: 1.45).foregroundStyle(SetupTheme.textFaint)
                        Text("No places yet").setupTitle(14)
                        Text("Add the apps, folders and websites you open most.").setupDetail()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 4) {
                            ForEach(model.items) { item in
                                VStack(spacing: 6) {
                                    Group {
                                        if let image = model.icon(for: item) {
                                            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                                        } else {
                                            SetupIconView(icon: .grid, size: 22, lineWidth: 1.45)
                                        }
                                    }
                                    .frame(width: 32, height: 32)
                                    .frame(width: 52, height: 52)
                                    .background(SetupTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SetupTheme.ringStrong, lineWidth: 1))
                                    .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
                                    Text(item.title).font(.system(size: 11, weight: .semibold)).tracking(-0.2)
                                        .foregroundStyle(SetupTheme.ink(0.6, 0.68)).lineLimit(1).frame(maxWidth: 64)
                                }
                                .frame(width: 70)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(item.title)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(minHeight: 150)

            HStack(spacing: 12) {
                Text("Add places and set their order in the editor.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(SetupTheme.textSecondary)
                Spacer(minLength: 8)
                Button("Configure…") { LauncherEditor.shared.show(model: model) }
                    .buttonStyle(SetupButtonStyle(kind: .primary))
                    .accessibilityLabel("Configure Launcher")
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(SetupTheme.ink(0.01, 0.015))
            .overlay(alignment: .top) { SetupTheme.ring.frame(height: 1) }
        }
        .background(SetupTheme.row)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(SetupTheme.ring, lineWidth: 1))
    }
}
