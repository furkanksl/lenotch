import SwiftUI
import SpacesEngine

/// The desktop engine is controlled only here; merely visiting Appearance must not activate taps or capture pixels.
struct SetupDesktopTransitions: View {
    @Bindable var model: DesktopTransitionsModel

    init(model: DesktopTransitionsModel = .shared) { self.model = model }

    var body: some View {
        SetupGroup("Desktop switching") {
            SetupToggleRow(icon: .grid, title: "Custom desktop transitions",
                           detail: "Change how Spaces switch with trackpad swipes and your desktop shortcuts. Off by default.",
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
                if model.options.style != .system {
                    SetupCard(fill: SetupTheme.row, padding: 16) {
                        VStack(alignment: .leading, spacing: 18) {
                            DesktopTransitionSlider(title: "Animation speed", value: model.options.speed, range: 0.3...2) {
                                model.configure(speed: $0)
                            }
                            DesktopTransitionSlider(title: "Swipe sensitivity", value: model.options.sensitivity, range: 0.5...2) {
                                model.configure(sensitivity: $0)
                            }
                        }
                    }
                    if model.options.style != .instant {
                        SetupToggleRow(icon: .grid, title: "Rounded desktop corners",
                                       detail: "Round desktop snapshots during a transition.",
                                       isOn: Binding(get: { model.options.roundedCorners }, set: { model.configure(roundedCorners: $0) }))
                        SetupToggleRow(icon: .grid, title: "Move Dock with the desktop",
                                       detail: "Include the Dock and menu bar in the moving desktop image.",
                                       isOn: Binding(get: { model.options.moveDock }, set: { model.configure(moveDock: $0) }))
                    }
                }
                SetupNote(icon: .shield, text: "Uses private macOS APIs, so future updates may affect compatibility. Accessibility handles swipes and shortcuts; drawn transitions also need Screen Recording. Desktop snapshots stay in memory and are cleared when disabled, locked or presenting. A desktop not yet captured may show its wallpaper. LeNotch never tours your desktops to preload them.")
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
            permission("Allow Accessibility to handle desktop swipes and shortcuts.", pane: "Privacy_Accessibility")
        case .needsScreenRecording:
            permission("Allow Screen Recording for desktop snapshots. No recordings are saved.", pane: "Privacy_ScreenCapture")
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

    private func permission(_ text: String, pane: String) -> some View {
        SetupRow(icon: .shield, active: false, title: "Permission needed", detail: text) {
            Button("Open Settings") { setupOpenPrivacy(pane) }.buttonStyle(SetupButtonStyle())
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
