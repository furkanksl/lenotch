import AppKit

/// Borderless, transparent, non-activating panel that sits over the menu bar.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        animationBehavior = .none

        // Level: the menu bar is kCGMainMenuWindowLevel (24) and status items sit at
        // kCGStatusWindowLevel (25). +3 clears both so the ears draw over the menu
        // bar, while pop-up menus (101), the system HUDs and the screen saver all
        // stay above us. Same band other notch apps use.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

        // On every Space (fullscreen ones too, so alerts and the HUD can still show there),
        // never moved by Mission Control, not in Cmd-` cycling. Over a fullscreen window the
        // island hides everything else itself (`DesktopContext.fullscreen`, from ContextMonitor).
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    // AppKit nudges windows out from under the menu bar; this one belongs there.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    // Key only when text input or selection needs it; `becomesKeyOnlyIfNeeded` keeps
    // every other click from taking focus, and the panel never activates the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }

        // The accessory app has no Edit menu to dispatch these actions.
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]
        let modifiers = event.modifierFlags.intersection(shortcutModifiers)

        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("a", .command): return performSelectionAction(#selector(NSText.selectAll(_:)))
        case ("c", .command): return performSelectionAction(#selector(NSText.copy(_:)))
        case ("v", .command):
            guard let editor = firstResponder as? NSTextView, editor.isSelectable, editor.isEditable else { return false }
            editor.paste(nil)
        case ("z", .command), ("z", [.command, .shift]):
            guard let editor = firstResponder as? NSTextView, editor.isSelectable, editor.isEditable,
                  editor.allowsUndo, let undoManager = editor.undoManager else { return false }
            let previousText = editor.string
            if modifiers.contains(.shift) { undoManager.redo() }
            else { undoManager.undo() }
            // UndoManager changes the text storage without notifying SwiftUI or the Notes delegate.
            if editor.string != previousText { editor.didChangeText() }
        default: return false
        }
        return true
    }

    static func supportsTextSelection(_ view: NSView) -> Bool {
        if let editor = view as? NSTextView { return editor.isSelectable }
        // SwiftUI selectable Text uses its own AppKit responder, not an NSTextView.
        return view.acceptsFirstResponder && view.responds(to: #selector(NSText.copy(_:)))
    }

    private func performSelectionAction(_ action: Selector) -> Bool {
        guard let view = firstResponder as? NSView, Self.supportsTextSelection(view) else { return false }
        return NSApp.sendAction(action, to: view, from: nil)
    }
}
