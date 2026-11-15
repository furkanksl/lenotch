import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts dictated text where you were typing the way you would yourself: the transcript goes on the clipboard, ⌘V is
/// pressed in the frontmost app, and your previous clipboard comes back.
///
/// Writing the focused field's selected text through Accessibility is deliberately not used: Chrome, Electron and most
/// web fields answer "success" without inserting anything, so that reply can't be trusted. ⌘V behaves the same everywhere.
@MainActor
enum DictationTextInserter {
    enum Result: Equatable {
        case pasted
        /// Left on the clipboard only, for the stated reason.
        case copied(Reason)
    }

    enum Reason: Equatable {
        /// Pressing ⌘V for you needs the Accessibility permission.
        case needsAccessibility
        /// No other app is in front, so there is nothing to paste into.
        case noTargetApp
    }

    /// What the insertion depends on, so tests can run it without sending real key presses.
    struct Environment {
        /// Why ⌘V can't be pressed right now, or nil when it can.
        var blocker: @MainActor () -> Reason?
        /// Presses ⌘V. False when the key events couldn't be created.
        var pressPaste: @MainActor () -> Bool
        /// Waits for the keys of the shortcut that ended the dictation (⌥D) to come up, so ⌥ isn't held during the paste.
        var settle: @MainActor () async -> Void
        /// How long the transcript stays on the clipboard before the previous contents return.
        var restoreAfter: Duration

        static let live = Environment(
            blocker: DictationTextInserter.liveBlocker,
            pressPaste: DictationTextInserter.pressCommandV,
            settle: DictationTextInserter.waitForModifierRelease,
            restoreAfter: .milliseconds(1_500)
        )
    }

    static func deliver(_ text: String, pasteboard: NSPasteboard = .general,
                        environment: Environment = .live) async -> Result {
        let blocker = environment.blocker()
        // Only a paste needs the old clipboard back; when we can't paste, the transcript stays for you to paste.
        let previous = blocker == nil ? snapshot(of: pasteboard) : nil
        writeTemporaryTranscript(text, to: pasteboard)
        if let blocker { return .copied(blocker) }

        let changeCount = pasteboard.changeCount
        await environment.settle()
        // The frontmost app can change while we wait.
        if let blocker = environment.blocker() { return .copied(blocker) }
        guard environment.pressPaste() else { return .copied(.needsAccessibility) }

        if let previous, previous.restorable, !previous.items.isEmpty {
            let delay = environment.restoreAfter
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                // Something else was copied in the meantime: leave that alone.
                guard pasteboard.changeCount == changeCount else { return }
                pasteboard.clearContents()
                pasteboard.writeObjects(previous.items)
            }
        }
        return .pasted
    }

    // MARK: Live environment

    private static func liveBlocker() -> Reason? {
        guard AXIsProcessTrusted() else { return .needsAccessibility }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .noTargetApp }
        return nil
    }

    private static func pressCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// The transcript is ready a few hundred milliseconds after ⌥D, so ⌥ is often still down. Give it up to 0.6 s.
    private static func waitForModifierRelease() async {
        let held: CGEventFlags = [.maskAlternate, .maskShift, .maskControl, .maskCommand]
        for _ in 0..<12 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Clipboard

    /// Copies the clipboard eagerly: its items become invalid after `clearContents()`.
    private static func snapshot(of pasteboard: NSPasteboard) -> (items: [NSPasteboardItem], restorable: Bool) {
        var items: [NSPasteboardItem] = []
        var restorable = true
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { restorable = false; continue }
                copy.setData(data, forType: type)
            }
            items.append(copy)
        }
        return (items, restorable)
    }

    private static func writeTemporaryTranscript(_ text: String, to pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Keep dictated text out of clipboard history (this app's and other compliant managers').
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}
