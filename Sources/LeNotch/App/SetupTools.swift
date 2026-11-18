import SwiftUI

/// Setup's Tools page: one switch per tool in the notch's menu. Off removes the tool's button and nothing else.
struct SetupToolsPage: View {
    let model: ToolMenuModel

    init(model: ToolMenuModel = .shared) { self.model = model }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            SetupGroup(title: "Tools menu", accessory: {
                SetupBadge(text: "\(model.visible.count) of \(TrayTool.allCases.count) shown", tone: .neutral)
            }, content: {
                ForEach(TrayTool.allCases) { tool in
                    SetupToolRow(tool: tool, isOn: isOn(tool), locked: !model.canDisable(tool))
                }
            })
            VStack(alignment: .leading, spacing: 8) {
                if model.visible.count == 1 {
                    SetupNote(icon: .info, text: "At least one tool stays on, or the menu would be empty.")
                }
                SetupNote(icon: .info,
                          text: "The menu shows five tools a row and grows a row when it needs one. Turning a tool off hides its button only: its shortcut, dropping files on the notch, and notifications arriving all keep working.")
            }
        }
    }
}

extension SetupToolsPage {
    /// A tool's switch: it reads the shared menu, and a flip writes the choice back (the last tool on refuses to go off).
    func isOn(_ tool: TrayTool) -> Binding<Bool> {
        Binding(get: { model.isEnabled(tool) }, set: { model.setEnabled(tool, $0) })
    }
}

/// A tool's switch row. Its tile is the icon the notch's menu draws, so the list reads like the menu.
struct SetupToolRow: View {
    let tool: TrayTool
    @Binding var isOn: Bool
    /// The last tool on: its switch can't be turned off.
    var locked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Button(action: flip) {
                HStack(alignment: .center, spacing: 16) {
                    SetupToolTile(icon: tool.icon, active: isOn)
                    SetupRowText(title: tool.title, detail: tool.detail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle(tool.title, isOn: $isOn).labelsHidden().toggleStyle(SetupSwitchStyle())
        }
        .modifier(SetupRowSurface(hoverable: !locked))
        .disabled(locked)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-tool-\(tool.rawValue)")
    }

    private func flip() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { isOn.toggle() }
    }
}

/// A tool's leading tile, the same 44-point tile `SetupIconTile` draws, around the notch's own icon.
struct SetupToolTile: View {
    let icon: ToolIcon
    var active = true

    var body: some View {
        ToolIconView(icon: icon)
            .frame(width: 22, height: 22)
            .foregroundStyle(active ? SetupTheme.text : SetupTheme.textTertiary)
            .frame(width: 44, height: 44)
            .background(active ? SetupTheme.card : SetupTheme.fill,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(active ? SetupTheme.ringStrong : SetupTheme.ring, lineWidth: 1))
            .shadow(color: .black.opacity(active ? 0.04 : 0), radius: 4, y: 2)
            .accessibilityHidden(true)
    }
}
