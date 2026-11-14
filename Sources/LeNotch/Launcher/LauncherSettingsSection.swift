import SwiftUI

extension Notification.Name {
    static let launcherShortcutChanged = Notification.Name("lenotch.launcher.shortcut.changed")
}

/// Reusable inside Setup's normal scrolling preferences, sharing the same model and
/// native editor as the notch's Configure action. Merely rendering never opens anything.
struct LauncherSettingsSection: View {
    let model: LauncherModel
    @AppStorage("lenotch.launcher.shortcut") private var shortcut = true

    init(model: LauncherModel = .shared) { self.model = model }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Launcher").font(.system(size: 13, weight: .semibold))
                    Text("\(model.items.count) / \(LauncherModel.maximumItems)")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
                Text("Choose apps, folders, and websites to open from the notch.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Configure…") { LauncherEditor.shared.show(model: model) }
                .controlSize(.regular).accessibilityLabel("Configure Launcher")
        }
        Toggle("Open Launcher with ⌥A", isOn: $shortcut).toggleStyle(.switch).controlSize(.small)
            .font(.system(size: 12))
            .onChange(of: shortcut) { NotificationCenter.default.post(name: .launcherShortcutChanged, object: nil) }
        if shortcut && model.shortcutUnavailable {
            Text("⌥A is already in use. Launcher is still available in Tools.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
    }
}
