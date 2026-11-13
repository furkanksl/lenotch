import SwiftUI

/// Semantic native surfaces keep the companion window legible in both macOS appearances.
enum SetupTheme {
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let pane = Color(nsColor: .textBackgroundColor)
    static let line = Color.primary.opacity(0.10)
    static let badge = Color.primary.opacity(0.055)
    static let success = Color(nsColor: .systemGreen)
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
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 29, height: 29)
            .background(SetupTheme.badge, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SetupSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .background(SetupTheme.pane)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SetupTheme.line))
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
        HStack(spacing: 11) {
            SetupIconBadge(symbol: symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                if state == .allowed {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(SetupTheme.success).font(.system(size: 11))
                } else if state == .asking {
                    ProgressView().controlSize(.mini)
                    Text(state.label).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ViewThatFits(in: .horizontal) {
                        Text(state.label).font(.system(size: 10)).foregroundStyle(.secondary)
                        Color.clear.frame(width: 0, height: 0)
                    }
                    if let label = actionLabel ?? state.actionTitle, let action {
                        Button(action: action) {
                            Text(label).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                                .frame(minWidth: 76)
                        }
                        .controlSize(.small)
                        .accessibilityLabel("\(label) for \(title)")
                    }
                }
            }
            .frame(width: 184, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) { SetupTheme.line.frame(height: 0.5).padding(.leading, 52) }
    }
}

struct SetupPreferenceRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SetupIconBadge(symbol: symbol)
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch).controlSize(.small)
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
