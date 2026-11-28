import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Lenotch

@MainActor
final class NotchPanelShortcutTests: XCTestCase {
    func testEditShortcutsActOnTheFocusedMultilineEditor() throws {
        _ = NSApplication.shared
        let panel = NotchPanel()
        defer { panel.close() }
        let editor = ClipboardEditor(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        defer { editor.clipboard.releaseGlobally() }
        panel.contentView = editor
        editor.isRichText = false
        editor.string = "First line\nCafé 👋"
        XCTAssertTrue(panel.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(panel.performKeyEquivalent(with: try shortcut("a", kVK_ANSI_A, in: panel)))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (editor.string as NSString).length))

        XCTAssertTrue(panel.performKeyEquivalent(with: try shortcut("c", kVK_ANSI_C, in: panel)))
        XCTAssertEqual(editor.clipboard.string(forType: .string), "First line\nCafé 👋")

        editor.string = "Replace me"
        editor.selectAll(nil)
        XCTAssertTrue(panel.performKeyEquivalent(with: try shortcut("v", kVK_ANSI_V, in: panel)))
        XCTAssertEqual(editor.string, "First line\nCafé 👋")
    }

    func testSelectAllReachesAOneLineFieldEditorAndLeavesOtherKeysAlone() throws {
        _ = NSApplication.shared
        let panel = NotchPanel()
        defer { panel.close() }
        let field = NSTextField(string: "Pick up groceries")
        panel.contentView = field
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let caret = NSRange(location: 1, length: 0)
        editor.setSelectedRange(caret)

        XCTAssertFalse(panel.performKeyEquivalent(with: try shortcut("a", kVK_ANSI_A, in: panel, modifiers: [])))
        XCTAssertFalse(panel.performKeyEquivalent(with: try shortcut("A", kVK_ANSI_A, in: panel, modifiers: [.command, .shift])))
        XCTAssertEqual(editor.selectedRange(), caret)
        XCTAssertTrue(panel.performKeyEquivalent(with: try shortcut("a", kVK_ANSI_A, in: panel)))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: field.stringValue.utf16.count))

        XCTAssertTrue(panel.makeFirstResponder(nil))
        XCTAssertFalse(panel.performKeyEquivalent(with: try shortcut("a", kVK_ANSI_A, in: panel)))
    }

    func testUndoAndRedoUpdateTheFocusedSwiftUITextFieldAndItsBinding() async throws {
        _ = NSApplication.shared
        let panel = NotchPanel()
        defer { panel.close() }
        var draft = "Buy"
        let host = NSHostingView(rootView: TextField("Add to-dos", text: Binding(get: { draft }, set: { draft = $0 }))
            .textFieldStyle(.plain))
        panel.setContentSize(NSSize(width: 240, height: 40))
        panel.contentView = host
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            if textField(in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let field = try XCTUnwrap(textField(in: host))
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.insertText(" coffee", replacementRange: editor.selectedRange())
        XCTAssertEqual(draft, "Buy coffee")

        XCTAssertFalse(panel.performKeyEquivalent(with: try shortcut("z", kVK_ANSI_Z, in: panel,
                                                                      modifiers: [.command, .option])))
        XCTAssertEqual(draft, "Buy coffee")
        XCTAssertTrue(panel.performKeyEquivalent(with: try shortcut("z", kVK_ANSI_Z, in: panel)))
        XCTAssertEqual(editor.string, "Buy")
        XCTAssertEqual(draft, "Buy", "The draft used for submission must match the displayed text")

        XCTAssertTrue(panel.performKeyEquivalent(with: try shortcut("Z", kVK_ANSI_Z, in: panel,
                                                                     modifiers: [.command, .shift])))
        XCTAssertEqual(editor.string, "Buy coffee")
        XCTAssertEqual(draft, "Buy coffee")
    }

    func testSelectAllAndCopyReachAReadOnlySelectionResponder() throws {
        _ = NSApplication.shared
        let panel = NotchPanel()
        defer { panel.close() }
        let selection = SelectionView()
        panel.contentView = selection
        XCTAssertTrue(panel.makeFirstResponder(selection))

        XCTAssertTrue(panel.performKeyEquivalent(with: try shortcut("a", kVK_ANSI_A, in: panel)))
        XCTAssertTrue(panel.performKeyEquivalent(with: try shortcut("c", kVK_ANSI_C, in: panel)))
        XCTAssertFalse(panel.performKeyEquivalent(with: try shortcut("v", kVK_ANSI_V, in: panel)))
        XCTAssertEqual(selection.actions, ["selectAll", "copy"])
    }

    private final class SelectionView: NSView {
        var actions: [String] = []
        override var acceptsFirstResponder: Bool { true }
        override func selectAll(_ sender: Any?) { actions.append("selectAll") }
        @objc func copy(_ sender: Any?) { actions.append("copy") }
    }

    private func textField(in view: NSView) -> NSTextField? {
        (view as? NSTextField) ?? view.subviews.lazy.compactMap { self.textField(in: $0) }.first
    }

    private func shortcut(_ character: String, _ keyCode: Int, in panel: NotchPanel,
                          modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: panel.windowNumber, context: nil, characters: character,
                                      charactersIgnoringModifiers: character, isARepeat: false, keyCode: UInt16(keyCode)))
    }

    /// Exercise the responder actions without changing the user's clipboard.
    private final class ClipboardEditor: NSTextView {
        let clipboard = NSPasteboard.withUniqueName()

        override func copy(_ sender: Any?) {
            clipboard.clearContents()
            clipboard.setString((string as NSString).substring(with: selectedRange()), forType: .string)
        }

        override func paste(_ sender: Any?) {
            guard let text = clipboard.string(forType: .string) else { return }
            insertText(text, replacementRange: selectedRange())
        }
    }
}
