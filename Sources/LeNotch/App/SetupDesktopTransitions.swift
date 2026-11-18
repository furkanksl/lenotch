import SwiftUI
import SpacesEngine

/// Merely visiting Appearance must not start the desktop-switching helper or install input hooks.
struct SetupDesktopTransitions: View {
    @Bindable var model: DesktopTransitionsModel

    init(model: DesktopTransitionsModel = .shared) { self.model = model }

    var body: some View {
        SetupGroup("Desktop switching") {
            SetupToggleRow(icon: .grid, title: "Desktop transition controls",
                           detail: "Choose how Spaces switch with trackpad swipes and your desktop shortcuts. Off by default.",
                           isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
            if model.enabled {
                status
                SetupRow(icon: .palette, title: "Transition", detail: model.options.style.detail) {
                    Menu {
                        ForEach(DesktopTransitionStyle.allCases) { style in
                            Button {
                                model.configure(style: style)
                            } label: {
                                if style == model.options.style { Label(style.title, systemImage: "checkmark") }
                                else { Text(style.title) }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(model.options.style.title)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(SetupButtonStyle(kind: .soft))
                    .accessibilityLabel("Desktop transition style")
                }
                if model.options.style == .instant {
                    SetupCard(fill: SetupTheme.row, padding: 16) {
                        DesktopTransitionSlider(title: "Swipe sensitivity", value: model.options.sensitivity, range: 0.5...2) {
                            model.configure(sensitivity: $0)
                        }
                    }
                    SetupNote(icon: .shield, text: "Instant needs Accessibility and uses private macOS APIs that may change with system updates.")
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.status {
        case .off:
            SetupStatusLine(kind: .info, text: "Starts when LeNotch is running.")
        case .systemDefault:
            SetupStatusLine(kind: .info, text: "Using the standard macOS transition.")
        case .needsAccessibility:
            SetupRow(icon: .shield, active: false, title: "Permission needed",
                     detail: "Allow Accessibility to handle desktop swipes and shortcuts.") {
                Button("Open Settings") { setupOpenPrivacy("Privacy_Accessibility") }.buttonStyle(SetupButtonStyle())
            }
        case .unsupported:
            SetupStatusLine(kind: .failure, text: "Desktop controls are unavailable on this Mac. Native desktop switching is unchanged.")
        case .paused:
            SetupStatusLine(kind: .info, text: "Paused while locked or presenting, or while Reduce Motion is on. Native switching still works.")
        case .active(let keyboard, let trackpad):
            SetupStatusLine(kind: .success, text: keyboard && trackpad
                            ? "Ready for three/four-finger swipes and your desktop shortcuts."
                            : keyboard ? "Ready for desktop shortcuts. No supported trackpad was found."
                            : "Ready for three/four-finger swipes. Desktop shortcuts are unavailable.")
        }
    }
}

private struct DesktopTransitionSlider: View {
    let title: String
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var value: Double

    init(title: String, value: Double, range: ClosedRange<Double>, commit: @escaping (Double) -> Void) {
        self.title = title
        self.range = range
        self.commit = commit
        _value = State(initialValue: value)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).setupTitle(13)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit().font(.system(size: 12)).foregroundStyle(SetupTheme.textSecondary)
                Text("×").font(.system(size: 12)).foregroundStyle(SetupTheme.textSecondary)
            }
            // Reconfigure only on release: an in-flight drag must not repeatedly tear down/reinstall input taps.
            Slider(value: $value, in: range, step: 0.1) { editing in if !editing { commit(value) } }
                .accessibilityLabel(title)
        }
    }
}
