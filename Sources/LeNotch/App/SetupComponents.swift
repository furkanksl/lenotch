import SwiftUI

/// Semantic native surfaces keep the companion window legible in both macOS appearances.
enum SetupTheme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let line = Color.primary.opacity(0.08)
    static let badge = Color.primary.opacity(0.045)
    static let success = Color(nsColor: .systemGreen)
}

struct SetupActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 13).frame(minHeight: 30)
            .foregroundStyle(primary ? (scheme == .dark ? Color.black : .white) : Color.primary)
            .background(primary ? Color.primary : Color.primary.opacity(configuration.isPressed ? 0.08 : 0.035),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(primary ? Color.clear : SetupTheme.line))
            .opacity(!enabled ? 0.45 : configuration.isPressed && primary ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

enum SetupAccessState: Equatable {
    case allowed, notAsked, denied, asking, unavailable

    var label: String {
        switch self {
        case .allowed: "Allowed"
        case .notAsked: "Not set up"
        case .denied: "Needs access"
        case .asking: "Asking…"
        case .unavailable: "Not connected"
        }
    }

    var actionTitle: String? {
        switch self {
        case .allowed, .asking: nil
        case .denied: "Open Settings"
        case .notAsked, .unavailable: "Allow"
        }
    }
}

struct SetupIconBadge: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(SetupTheme.badge, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SetupSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.system(size: 12, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            VStack(spacing: 0) { content }
                .background(SetupTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SetupTheme.line))
        }
    }
}

struct SetupPermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let state: SetupAccessState
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            SetupIconBadge(symbol: symbol)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if state == .denied {
                        Circle().fill(Color.secondary.opacity(0.6)).frame(width: 4, height: 4)
                            .accessibilityHidden(true)
                        Text(state.label).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            HStack(spacing: 6) {
                if state == .allowed {
                    Image(systemName: "checkmark").foregroundStyle(SetupTheme.success)
                        .font(.system(size: 10, weight: .semibold))
                    Text("Allowed").foregroundStyle(.secondary).font(.system(size: 12))
                } else if state == .asking {
                    ProgressView().controlSize(.mini)
                    Text(state.label).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    if let label = actionLabel ?? state.actionTitle, let action {
                        Button(action: action) {
                            Text(label).frame(minWidth: 80)
                        }
                        .buttonStyle(SetupActionStyle())
                        .accessibilityLabel("\(label) for \(title)")
                    } else {
                        Text(state.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 112, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(minHeight: 64)
        .accessibilityValue(state.label)
    }
}

struct SetupPreferenceRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SetupIconBadge(symbol: symbol)
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch).controlSize(.small).tint(.accentColor)
        }
    }
}

struct SetupInlineNote: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}
