import AppKit
import SwiftUI
import XCTest
@testable import Lenotch

/// Exercises the running SwiftUI fields, rather than the still-rendering substitute or store methods.
/// All accessibility access and key events stay inside this process's owned window.
@MainActor
final class TodoInputTests: XCTestCase {
    func testNewListButtonMovesFromComposerToNativeNameFieldAndReturnCreatesList() async throws {
        let page = try await TodoInputWindow()
        defer { page.close() }

        let composer = try await page.field("Add to \(TodoStore.starterListTitle)")
        try await page.focus(composer)
        try page.type("Keep this draft")
        try await page.pressButton("New list")

        let name = try await page.field("New list")
        try await page.wait("New list must take focus from the composer") { name.currentEditor() != nil }
        XCTAssertTrue(page.director.replyFocused)
        try page.type("Weekend")
        try page.key(.return)

        try await page.wait("Return must create and select the list") { page.store.selected?.title == "Weekend" }
        XCTAssertEqual(page.store.lists.map(\.title), [TodoStore.starterListTitle, "Weekend"])
        XCTAssertTrue(page.store.selected?.items.isEmpty == true)
        XCTAssertNil(page.nativeField("New list"), "Submitting must close the temporary name field")
        let restoredComposer = try await page.field("Add to Weekend")
        XCTAssertEqual(restoredComposer.stringValue, "Keep this draft",
                       "Opening a list editor must not submit or erase the composer draft")
    }

    func testReturnAddsTwoTodosAndKeepsTheRealComposerReadyForMoreTyping() async throws {
        let page = try await TodoInputWindow()
        defer { page.close() }
        let composer = try await page.field("Add to \(TodoStore.starterListTitle)")
        try await page.focus(composer)

        for title in ["Buy coffee", "Call the dentist"] {
            try page.type(title)
            try page.key(.return)
            try await page.wait("Return must add \(title) and clear the composer") {
                page.store.selected?.items.last?.title == title && composer.stringValue.isEmpty
            }
            try await page.wait("Return must retain the composer field editor") { composer.currentEditor() != nil }
            XCTAssertTrue(page.director.replyFocused, "The tray must stay open for consecutive entry")
            XCTAssertTrue(page.window.isKeyWindow)
        }

        try page.type("An unfinished third task")
        XCTAssertEqual(composer.stringValue, "An unfinished third task")
        XCTAssertEqual(page.store.selected?.items.map(\.title), ["Buy coffee", "Call the dentist"])
        XCTAssertEqual(page.store.selected?.items.map(\.isDone), [false, false])
    }

    func testEscapeCancelsListRenameButMovingOutsideTheEditorCommitsIt() async throws {
        let page = try await TodoInputWindow()
        defer { page.close() }
        let listID = try XCTUnwrap(page.store.selectedID)

        try await page.performCustomAction("Rename")
        let cancelled = try await page.field("List name")
        try await page.wait("Rename must focus the native list field") { cancelled.currentEditor() != nil }
        try page.replaceText("Do not save this name")
        try page.key(.escape)
        try await page.wait("Escape must remove the list editor and release typing") {
            page.nativeField("List name") == nil && !page.director.replyFocused
        }
        XCTAssertEqual(page.store.selected?.title, TodoStore.starterListTitle)
        XCTAssertEqual(page.store.selectedID, listID)

        try await page.performCustomAction("Rename")
        let committed = try await page.field("List name")
        try await page.wait("The second rename must regain focus") { committed.currentEditor() != nil }
        try page.replaceText("Errands")
        let composer = try await page.field("Add to \(TodoStore.starterListTitle)")
        try await page.focus(composer)
        try await page.wait("Leaving a rename field must commit instead of cancelling") {
            page.store.selected?.title == "Errands" && page.nativeField("List name") == nil
        }
        XCTAssertEqual(page.store.selectedID, listID)
        XCTAssertEqual(page.store.lists.count, 1)
        XCTAssertTrue(page.director.replyFocused, "Moving into the composer must retain typing ownership")
        try page.type("A task after renaming")
        try page.key(.return)
        try await page.wait("The composer must still submit after an outside-focus commit") {
            page.store.selected?.items.first?.title == "A task after renaming"
        }
    }

    func testEscapeCancelsTodoRenameButMovingOutsideTheEditorCommitsIt() async throws {
        let page = try await TodoInputWindow()
        defer { page.close() }
        let composer = try await page.field("Add to \(TodoStore.starterListTitle)")
        try await page.focus(composer)
        try page.type("Original task")
        try page.key(.return)
        try await page.wait("The task must exist before editing") { page.store.selected?.items.count == 1 }
        let itemID = try XCTUnwrap(page.store.selected?.items.first?.id)

        try await page.performCustomAction("Edit")
        let cancelled = try await page.field("To-do")
        try await page.wait("Task rename must focus its native editor") { cancelled.currentEditor() != nil }
        try page.replaceText("Do not save this task")
        try page.key(.escape)
        try await page.wait("Escape must remove the task editor") { page.nativeField("To-do") == nil }
        XCTAssertEqual(page.store.selected?.items.first?.title, "Original task")

        try await page.performCustomAction("Edit")
        let committed = try await page.field("To-do")
        try await page.wait("Task rename must regain focus") { committed.currentEditor() != nil }
        try page.replaceText("Updated task")
        try await page.focus(composer)
        try await page.wait("Leaving the task editor must commit the title") {
            page.store.selected?.items.first?.title == "Updated task" && page.nativeField("To-do") == nil
        }
        XCTAssertEqual(page.store.selected?.items.first?.id, itemID)
        XCTAssertEqual(page.store.selected?.items.count, 1)
        XCTAssertTrue(page.director.replyFocused)
    }
}

@MainActor
private final class TodoInputWindow {
    enum Key { case `return`, escape }

    let store = TodoStore(storageURL: nil)
    let director: IslandDirector
    let window: NSWindow
    let host: NSHostingView<AnyView>
    private let defaults: UserDefaults
    private let suiteName = "TodoInputTests.\(UUID().uuidString)"
    private let previousPolicy: NSApplication.ActivationPolicy

    init() async throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        director = IslandDirector(prompter: PrompterModel(storageURL: nil), chatDefaults: defaults, todos: store)
        director.tray.go(.todo)
        host = NSHostingView(rootView: AnyView(
            TodoPage(tray: director.tray, director: director, store: store)
                .padding(16).frame(width: 420, height: 360)
                .environment(\.islandMotion, IslandMotion(reduce: true, stills: false))
                .environment(\.colorScheme, .dark).background(.black)
        ))
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 420, height: 360),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "To-do native input regression test"
        window.level = .floating
        window.contentView = host
        previousPolicy = NSApplication.shared.activationPolicy()
        if previousPolicy == .prohibited { NSApp.setActivationPolicy(.accessory) }
        director.onWantsKey = { [weak window] in
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        director.onYieldsKey = { [weak window] in
            window?.makeFirstResponder(nil)
            window?.resignKey()
        }
        director.onWantsKey?()
        window.orderFrontRegardless()
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            if window.isKeyWindow && window.occlusionState.contains(.visible) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let reason = "Native To-do input needs an unoccluded key test window; "
            + "key=\(window.isKeyWindow), visible=\(window.occlusionState.contains(.visible))."
        close()
        throw XCTSkip(reason)
    }

    func close() {
        director.onWantsKey = nil
        director.onYieldsKey = nil
        window.orderOut(nil)
        window.close()
        defaults.removePersistentDomain(forName: suiteName)
        if previousPolicy == .prohibited { NSApp.setActivationPolicy(previousPolicy) }
    }

    func wait(_ message: String, until condition: () -> Bool,
              file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message + "\n" + accessibilitySummary, file: file, line: line)
        throw InputFailure.timedOut
    }

    func field(_ placeholder: String) async throws -> NSTextField {
        try await wait("Missing real TextField: \(placeholder)") { nativeField(placeholder) != nil }
        return try XCTUnwrap(nativeField(placeholder))
    }

    func nativeField(_ placeholder: String) -> NSTextField? {
        views(in: host).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == placeholder || $0.accessibilityLabel() == placeholder
        }
    }

    func focus(_ field: NSTextField) async throws {
        director.onWantsKey?()
        field.setAccessibilityFocused(true)
        try await wait("Focusing the real field must install its field editor") { field.currentEditor() != nil }
    }

    func type(_ text: String) throws {
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "Typing must reach the real field editor")
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    func replaceText(_ text: String) throws {
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        try type(text)
    }

    func key(_ key: Key) throws {
        XCTAssertTrue(window.isKeyWindow, "Key input must only reach this test's key window")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  characters: key == .return ? "\r" : "\u{1B}",
                                                  charactersIgnoringModifiers: key == .return ? "\r" : "\u{1B}",
                                                  isARepeat: false, keyCode: key == .return ? 36 : 53))
        window.sendEvent(event)
    }

    func pressButton(_ label: String) async throws {
        try await wait("Missing accessible button: \(label)") {
            nodes.contains { $0.accessibilityRole() == .button && $0.accessibilityLabel() == label }
        }
        let button = try XCTUnwrap(nodes.first { $0.accessibilityRole() == .button && $0.accessibilityLabel() == label })
        XCTAssertTrue(button.accessibilityPerformPress(), "The real \(label) button must accept its press action")
    }

    func performCustomAction(_ name: String) async throws {
        try await wait("Missing local accessibility action: \(name)") {
            nodes.contains { $0.accessibilityCustomActions()?.contains { $0.name == name } == true }
        }
        let action = try XCTUnwrap(nodes.flatMap { $0.accessibilityCustomActions() ?? [] }.first { $0.name == name })
        if let handler = action.handler {
            XCTAssertTrue(handler(), "The actual SwiftUI \(name) action must succeed")
        } else {
            let target = try XCTUnwrap(action.target as? NSObject)
            let selector = try XCTUnwrap(action.selector)
            typealias Action = @convention(c) (AnyObject, Selector, NSAccessibilityCustomAction) -> Bool
            let invoke = unsafeBitCast(target.method(for: selector), to: Action.self)
            XCTAssertTrue(invoke(target, selector, action), "The actual SwiftUI \(name) action must succeed")
        }
    }

    private func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views(in: $0) } }

    private var nodes: [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ value: Any) {
            guard result.count < 300, let object = value as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let element = object as? any NSAccessibilityProtocol {
                result.append(element)
                (element.accessibilityChildren() ?? []).forEach(visit)
            }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(host)
        return result
    }

    private var accessibilitySummary: String {
        nodes.map { "\($0.accessibilityRole()?.rawValue ?? "?"): \($0.accessibilityLabel() ?? "") \($0.accessibilityValue() ?? "")" }
            .joined(separator: "\n")
    }

    private enum InputFailure: Error { case timedOut }
}
