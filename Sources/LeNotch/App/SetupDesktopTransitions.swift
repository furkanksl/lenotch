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
                switch model.options.style {
                case .system:
                    EmptyView()
                case .instant:
                    SetupCard(fill: SetupTheme.row, padding: 16) {
                        DesktopTransitionSlider(title: "Swipe sensitivity", value: model.options.sensitivity,
                                                range: 0.5...2, step: 0.1, unit: "×", fractionDigits: 1) {
                            model.configure(sensitivity: $0)
                        }
                    }
                    SetupNote(icon: .shield, text: "Instant needs Accessibility and uses private macOS APIs that may change with system updates.")
                case .liveSlide:
                    let seconds = DesktopTransitionOptions.slideDurationRange
                    SetupCard(fill: SetupTheme.row, padding: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            DesktopTransitionSlider(title: "Slide duration", value: model.options.slideDuration * 1_000,
                                                    range: (seconds.lowerBound * 1_000)...(seconds.upperBound * 1_000),
                                                    step: 25, unit: "ms", fractionDigits: 0) {
                                model.configure(slideDuration: $0 / 1_000)
                            }
                            Text("Sets how long LeNotch drives the slide before the Dock settles it.")
                                .setupDetail()
                        }
                    }
                    SetupNote(icon: .shield, text: "Live Slide needs Accessibility and uses experimental private macOS APIs that may change with system updates.")
                }
            }
        }
    }

    private var accessibilityDetail: String {
        switch model.options.style {
        case .liveSlide: "Allow Accessibility to pace desktop keyboard shortcuts."
        case .system, .instant: "Allow Accessibility to handle desktop swipes and shortcuts."
        }
    }

    @ViewBuilder private var status: some View {
        switch model.status {
        case .off:
            SetupStatusLine(kind: .info, text: "Starts when LeNotch is running.")
        case .systemDefault:
            SetupStatusLine(kind: .info, text: "Using the standard macOS transition.")
        case .needsAccessibility:
            SetupRow(icon: .shield, active: false, title: "Permission needed", detail: accessibilityDetail) {
                Button("Open Settings") { setupOpenPrivacy("Privacy_Accessibility") }.buttonStyle(SetupButtonStyle())
            }
        case .unsupported:
            SetupStatusLine(kind: .failure, text: "Desktop controls are unavailable on this Mac. Native desktop switching is unchanged.")
        case .paused:
            SetupStatusLine(kind: .info, text: "Paused while locked or presenting, or while Reduce Motion is on. Native switching still works.")
        case .active(let keyboard, let trackpad):
            if model.options.style == .liveSlide {
                if keyboard {
                    SetupStatusLine(kind: .success, text: "Ready for desktop shortcuts.")
                } else {
                    SetupStatusLine(kind: .info, text: "Desktop shortcuts are unavailable. Native switching still works.")
                }
            } else {
                SetupStatusLine(kind: .success, text: keyboard && trackpad
                                ? "Ready for three/four-finger swipes and your desktop shortcuts."
                                : keyboard ? "Ready for desktop shortcuts. No supported trackpad was found."
                                : "Ready for three/four-finger swipes. Desktop shortcuts are unavailable.")
            }
        }
    }
}

private struct DesktopTransitionSlider: View {
    let title: String
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let fractionDigits: Int
    let commit: (Double) -> Void
    @State private var value: Double
    @State private var isEditing = false

    init(title: String, value: Double, range: ClosedRange<Double>, step: Double, unit: String, fractionDigits: Int,
         commit: @escaping (Double) -> Void) {
        self.title = title
        self.range = range
        self.step = step
        self.unit = unit
        self.fractionDigits = fractionDigits
        self.commit = commit
        _value = State(initialValue: value)
    }

    var body: some View {
        let valueFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(fractionDigits))
        VStack(spacing: 8) {
            HStack {
                Text(title).setupTitle(13)
                Spacer()
                Text(value, format: valueFormat)
                    .monospacedDigit().font(.system(size: 12)).foregroundStyle(SetupTheme.textSecondary)
                Text(unit).font(.system(size: 12)).foregroundStyle(SetupTheme.textSecondary)
            }
            // Reconfigure only after a pointer drag, or immediately for a discrete keyboard adjustment.
            Slider(value: Binding(get: { value }, set: { next in
                value = next
                if !isEditing { commit(next) }
            }), in: range, step: step) { editing in
                isEditing = editing
                if !editing { commit(value) }
            }
                .accessibilityLabel(title)
                .accessibilityValue("\(value.formatted(valueFormat)) \(unit)")
        }
    }
}
