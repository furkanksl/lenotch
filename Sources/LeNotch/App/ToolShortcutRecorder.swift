import AppKit
import SwiftUI
import Synchronization

/// Event-tap callbacks read this off the main thread. Recording must not trigger Chat or Fn dictation
/// while the user is trying a chord in Settings.
enum ToolShortcutRecordingGate {
    private static let state = Mutex(false)
    static var isRecording: Bool { state.withLock { $0 } }
    static func setRecording(_ value: Bool) { state.withLock { $0 = value } }
}

struct ToolShortcutRecorder: View {
    let target: ToolShortcutTarget
    let settings: ToolShortcutSettings
    @Binding var recordingTarget: ToolShortcutTarget?
    var compact = false
    var reportError: (String?) -> Void = { _ in }
    @State private var error: String?
    @State private var hovered = false
    private var recording: Bool { recordingTarget == target }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 4) {
                Button {
                    showError(nil)
                    if recording { stop() }
                    else {
                        settings.beginRecording()
                        recordingTarget = target
                    }
                } label: {
                    HStack(spacing: 6) {
                        if recording {
                            Circle().fill(SetupTheme.accent).frame(width: 5, height: 5)
                            Text("Press keys").font(.system(size: 11, weight: .medium))
                            Text("esc").font(.system(size: 9)).foregroundStyle(SetupTheme.textTertiary)
                        } else {
                            Text(settings.binding(for: target)?.display ?? (compact ? "Add shortcut" : "Not set"))
                                .font(.system(size: compact && settings.binding(for: target) == nil ? 11 : 12,
                                              weight: .medium, design: settings.binding(for: target) == nil ? .default : .monospaced))
                        }
                    }
                        .foregroundStyle(recording ? SetupTheme.accent : emptyCompact ? SetupTheme.textTertiary : SetupTheme.text)
                        .frame(minWidth: compact ? 94 : 88, minHeight: compact ? 29 : 32, alignment: .leading)
                        .padding(.horizontal, compact ? 8 : 9)
                        .background(emptyCompact && !hovered ? .clear : SetupTheme.fill, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(recording ? SetupTheme.accent : emptyCompact && !hovered ? .clear : SetupTheme.ringStrong, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityLabel("Change \(target.title) shortcut")
                .accessibilityValue(recording ? "Recording shortcut" : settings.binding(for: target)?.display ?? "Not set")
                .help("Click, then press a shortcut. Escape cancels; Delete clears it.")
                .overlay {
                    if recording {
                        ShortcutCaptureInput(capture: receive, cancel: stop)
                            .frame(width: 1, height: 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                if !compact, let message = error ?? settings.failures[target] {
                    Text(message).font(.system(size: 11)).foregroundStyle(SetupTheme.accent)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 190)
                        .accessibilityLabel(message)
                }
            }
            if !compact { Menu {
                Button("Use default\(target.defaultBinding.map { " (\($0.display))" } ?? " (None)")") {
                    stop()
                    if !settings.reset(target) { showError("That shortcut is already assigned to another tool.") }
                }
                Button("Clear shortcut") {
                    stop()
                    _ = settings.setBinding(nil, for: target)
                    showError(nil)
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SetupTheme.textSecondary).frame(width: 24, height: 30)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("\(target.title) shortcut options")
            }
        }
        .onDisappear(perform: stop)
        .onChange(of: settings.isRecording) { _, active in
            if !active, recording { recordingTarget = nil }
        }
    }

    private var emptyCompact: Bool { compact && !recording && settings.binding(for: target) == nil }
    private func showError(_ message: String?) { error = message; reportError(message) }

    private func receive(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty && [51, 117].contains(event.keyCode) {
            _ = settings.setBinding(nil, for: target)
            showError(nil)
            stop()
            return
        }
        guard let binding = ToolKeyBinding.from(event: event) else {
            showError("Use a letter, number, or supported key with ⌥, ⌃, or ⌘.")
            return
        }
        if let message = settings.validationError(for: binding, target: target) {
            showError(message)
            return
        }
        guard settings.setBinding(binding, for: target) else { return }
        showError(nil)
        stop()
    }

    private func stop() {
        guard recording else { return }
        recordingTarget = nil
        settings.endRecording()
    }
}

/// Captures keys only in this Settings control, never with a global event tap. Command chords go
/// through performKeyEquivalent before menu actions, so recording ⌘N cannot create something else.
struct ShortcutCaptureInput: NSViewRepresentable {
    let capture: (NSEvent) -> Void
    let cancel: () -> Void
    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.capture = capture
        view.cancel = cancel
        return view
    }
    func updateNSView(_ view: ShortcutCaptureView, context: Context) {
        view.capture = capture
        view.cancel = cancel
    }
    static func dismantleNSView(_ view: ShortcutCaptureView, coordinator: ()) { view.finish() }
}

final class ShortcutCaptureView: NSView {
    var capture: ((NSEvent) -> Void)?
    var cancel: (() -> Void)?
    private weak var previousResponder: NSResponder?
    private var resignObserver: ShortcutWindowObserver?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resignObserver = nil
        guard let window else { return }
        previousResponder = window.firstResponder
        let token = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel?() }
        }
        resignObserver = ShortcutWindowObserver(token)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) { receive(event) }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { cancel?() }
        return resigned
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        receive(event)
        return true
    }
    private func receive(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { cancel?() }
        else if event.keyCode == 48 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            let owner = window
            cancel?()
            if event.modifierFlags.contains(.shift) { owner?.selectPreviousKeyView(self) }
            else { owner?.selectNextKeyView(self) }
        }
        else { capture?(event) }
    }
    func finish() {
        resignObserver = nil
        capture = nil
        cancel = nil
        if window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
    }
}

/// NotificationCenter permits observer removal from any thread; ownership also covers a native
/// recorder being released without SwiftUI's normal dismantle callback.
private final class ShortcutWindowObserver: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
