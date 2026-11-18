import AppKit
import Carbon.HIToolbox
import SwiftUI
import Synchronization
import Vision
import XCTest
@testable import Lenotch

/// These checks send events only to this process's own views. They never register a hotkey,
/// post global input, bring a window forward, or write to the user's preferences.
@MainActor
final class ToolShortcutRecorderTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
    }

    private func settings() throws -> ToolShortcutSettings {
        let suite = "lenotch.test.shortcut-recorder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return ToolShortcutSettings(defaults: defaults)
    }

    private func event(_ key: Int = kVK_ANSI_T, flags: NSEvent.ModifierFlags = .option,
                       repeating: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "t", charactersIgnoringModifiers: "t",
                                      isARepeat: repeating, keyCode: UInt16(key)))
    }

    private func window(content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    func testKeyDownCapturesTheOriginalEventWithItsModifiers() throws {
        let recorder = ShortcutCaptureView()
        var captured: [NSEvent] = []
        recorder.capture = { captured.append($0) }
        let key = try event(kVK_ANSI_N, flags: [.command, .shift])
        recorder.keyDown(with: key)
        XCTAssertTrue(recorder.acceptsFirstResponder)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured.first === key, "Capture must retain the actual physical key and modifiers")
    }

    func testAutoRepeatCannotCaptureOrCancelRecording() throws {
        let recorder = ShortcutCaptureView()
        var captures = 0
        var cancellations = 0
        recorder.capture = { _ in captures += 1 }
        recorder.cancel = { cancellations += 1 }
        recorder.keyDown(with: try event(repeating: true))
        recorder.keyDown(with: try event(kVK_Escape, flags: [], repeating: true))
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(cancellations, 0)
    }

    func testEscapeCancelsInsteadOfBecomingABinding() throws {
        let recorder = ShortcutCaptureView()
        var captures = 0
        var cancellations = 0
        recorder.capture = { _ in captures += 1 }
        recorder.cancel = { cancellations += 1 }
        recorder.keyDown(with: try event(kVK_Escape, flags: []))
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(cancellations, 1)
    }

    func testCommandEquivalentIsInterceptedOnlyWhileRecorderIsFirstResponder() throws {
        let content = NSView()
        let window = window(content: content)
        let recorder = ShortcutCaptureView()
        content.addSubview(recorder)
        defer { recorder.finish(); window.close() }
        var captured: [NSEvent] = []
        recorder.capture = { captured.append($0) }
        let command = try event(kVK_ANSI_N, flags: .command)

        XCTAssertFalse(recorder.performKeyEquivalent(with: command))
        XCTAssertTrue(captured.isEmpty)
        XCTAssertTrue(window.makeFirstResponder(recorder))
        XCTAssertTrue(recorder.performKeyEquivalent(with: command), "Command chords must not reach menu actions while recording")
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured.first === command)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(recorder.performKeyEquivalent(with: command))
        XCTAssertEqual(captured.count, 1)
    }

    func testRepeatedCommandEquivalentIsSwallowedWithoutCapturingTwice() throws {
        let content = NSView()
        let window = window(content: content)
        let recorder = ShortcutCaptureView()
        content.addSubview(recorder)
        defer { recorder.finish(); window.close() }
        var captures = 0
        recorder.capture = { _ in captures += 1 }
        XCTAssertTrue(window.makeFirstResponder(recorder))
        XCTAssertTrue(recorder.performKeyEquivalent(with: try event(flags: .command, repeating: true)))
        XCTAssertEqual(captures, 0)
    }

    func testLosingWindowFocusCancelsAndFinishRemovesTheObserver() {
        let content = NSView()
        let window = window(content: content)
        let recorder = ShortcutCaptureView()
        content.addSubview(recorder)
        defer { recorder.finish(); window.close() }
        var cancellations = 0
        recorder.cancel = { cancellations += 1 }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(cancellations, 1)
        recorder.finish()
        recorder.cancel = { cancellations += 1 }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(cancellations, 1, "A dismantled recorder must no longer observe its old window")
    }

    func testFinishRestoresThePreviousResponderAndClearsCallbacks() throws {
        let content = NSView()
        let window = window(content: content)
        let previous = ShortcutTestResponder()
        content.addSubview(previous)
        XCTAssertTrue(window.makeFirstResponder(previous))
        let recorder = ShortcutCaptureView()
        content.addSubview(recorder)
        defer { recorder.finish(); window.close() }
        XCTAssertTrue(window.makeFirstResponder(recorder))
        recorder.capture = { _ in XCTFail("A dismantled recorder cannot capture keys") }
        recorder.cancel = { XCTFail("A dismantled recorder cannot cancel") }
        recorder.finish()
        XCTAssertTrue(window.firstResponder === previous)
        XCTAssertNil(recorder.capture)
        XCTAssertNil(recorder.cancel)
        recorder.keyDown(with: try event())
        recorder.keyDown(with: try event(kVK_Escape, flags: []))
    }

    func testRecordingPassesAskAndFnThroughWithoutTriggeringEitherFeature() throws {
        let settings = try settings()
        let calls = Mutex((asks: 0, fn: 0, levels: 0))
        let tap = HardwareKeyEventTap(onLevel: { _ in calls.withLock { $0.levels += 1 } },
                                      onAsk: { calls.withLock { $0.asks += 1 } },
                                      onFn: { _ in calls.withLock { $0.fn += 1 } })
        tap.setFnEnabled(true)
        settings.beginRecording()
        defer { settings.endRecording(); ToolShortcutRecordingGate.setRecording(false) }
        XCTAssertTrue(ToolShortcutRecordingGate.isRecording)

        let space = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: true))
        space.flags = .maskAlternate
        let original = try XCTUnwrap(space.data) as Data
        XCTAssertTrue(try XCTUnwrap(tap.route(.keyDown, event: space)).takeUnretainedValue() === space)
        XCTAssertEqual(try XCTUnwrap(space.data) as Data, original)
        let release = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: false))
        XCTAssertNotNil(tap.route(.keyUp, event: release))

        for flags: CGEventFlags in [[.maskSecondaryFn, .maskNonCoalesced], [.maskNonCoalesced]] {
            let fn = try XCTUnwrap(CGEvent(source: nil))
            fn.type = .flagsChanged
            fn.flags = flags
            fn.setIntegerValueField(.keyboardEventKeycode, value: 63)
            XCTAssertTrue(try XCTUnwrap(tap.route(.flagsChanged, event: fn)).takeUnretainedValue() === fn)
        }
        let result = calls.withLock { $0 }
        XCTAssertEqual(result.asks, 0)
        XCTAssertEqual(result.fn, 0)
        XCTAssertEqual(result.levels, 0)
    }

    func testLegacyOptionSpacePassesThroughWhenTheUnifiedShortcutOwnsChat() throws {
        let calls = Mutex(0)
        let tap = HardwareKeyEventTap(onLevel: { _ in }, onAsk: { calls.withLock { $0 += 1 } },
                                      interceptsLegacyAskShortcut: false)
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: true))
        down.flags = .maskAlternate
        XCTAssertTrue(try XCTUnwrap(tap.route(.keyDown, event: down)).takeUnretainedValue() === down)
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertNotNil(tap.route(.keyDown, event: down))
        let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: false))
        up.flags = .maskAlternate
        XCTAssertTrue(try XCTUnwrap(tap.route(.keyUp, event: up)).takeUnretainedValue() === up)
        XCTAssertEqual(calls.withLock { $0 }, 0, "The legacy handler must not double-fire the configurable Chat shortcut")
    }

    func testToolsPageExposesAllNamedRecorderButtonsAndConfiguredValuesInBothThemes() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let settings = try settings()
            let suite = "lenotch.test.shortcut-page.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = ToolMenuModel(defaults: defaults)
            let host = NSHostingView(rootView: SetupToolsPage(model: model, shortcuts: settings)
                .padding(32).frame(width: 640).environment(\.colorScheme, scheme))
            let window = window(content: host)
            defer { window.close() }
            try await prepareAccessibilityHost(host)
            let buttons = accessibilityNodes(host).filter { $0.accessibilityRole() == .button }
            let recorders = buttons.filter { $0.accessibilityLabel()?.hasPrefix("Change ") == true }
            XCTAssertEqual(recorders.count, 13)
            for target in ToolShortcutTarget.allCases {
                let button = try XCTUnwrap(recorders.first { $0.accessibilityLabel() == "Change \(target.title) shortcut" })
                XCTAssertEqual(button.accessibilityValue() as? String, settings.binding(for: target)?.display ?? "Not set")
            }
            XCTAssertFalse(accessibilityNodes(host).contains { $0.accessibilityLabel()?.hasSuffix("shortcut options") == true },
                           "The unified rows use compact recorders, not a second options column")
            XCTAssertFalse(settings.isRecording, "Displaying Settings must not begin recording or register shortcuts")
        }
    }

    func testRealRecorderButtonStartsRecordingAndEscapeLeavesTheSavedBindingAlone() async throws {
        let settings = try settings()
        let host = NSHostingView(rootView: ShortcutRecorderTestPage(target: .todo, settings: settings).padding(24))
        let window = window(content: host)
        defer { settings.endRecording(); window.close() }
        try await prepareAccessibilityHost(host)
        try press("Change To-do shortcut", in: host)
        await layout(host)
        XCTAssertTrue(settings.isRecording)
        let capture = try XCTUnwrap(views(host).compactMap { $0 as? ShortcutCaptureView }.first)
        capture.keyDown(with: try event(kVK_Escape, flags: []))
        await layout(host)
        XCTAssertFalse(settings.isRecording)
        XCTAssertEqual(settings.binding(for: .todo), ToolShortcutTarget.todo.defaultBinding)
        XCTAssertTrue(views(host).compactMap { $0 as? ShortcutCaptureView }.isEmpty)
    }

    func testRealRecorderSavesACommandChordAndUpdatesItsAccessibleValue() async throws {
        let settings = try settings()
        let host = NSHostingView(rootView: ShortcutRecorderTestPage(target: .notes, settings: settings).padding(24))
        let window = window(content: host)
        defer { settings.endRecording(); window.close() }
        try await prepareAccessibilityHost(host)
        try press("Change Notes shortcut", in: host)
        await layout(host)
        let capture = try XCTUnwrap(views(host).compactMap { $0 as? ShortcutCaptureView }.first)
        XCTAssertTrue(window.makeFirstResponder(capture))
        XCTAssertTrue(capture.performKeyEquivalent(with: try event(kVK_ANSI_N, flags: [.command, .shift])))
        await layout(host)
        XCTAssertEqual(settings.binding(for: .notes), ToolKeyBinding(keyCode: kVK_ANSI_N, modifiers: cmdKey | shiftKey))
        XCTAssertFalse(settings.isRecording)
        let button = try XCTUnwrap(accessibilityNodes(host).first { $0.accessibilityLabel() == "Change Notes shortcut" })
        XCTAssertEqual(button.accessibilityValue() as? String, "⇧⌘N")
    }

    func testDeleteClearsOnlyTheSelectedShortcutThroughTheRealRecorder() async throws {
        let settings = try settings()
        let host = NSHostingView(rootView: ShortcutRecorderTestPage(target: .clipboard, settings: settings).padding(24))
        let window = window(content: host)
        defer { settings.endRecording(); window.close() }
        try await prepareAccessibilityHost(host)
        try press("Change Clipboard shortcut", in: host)
        await layout(host)
        let capture = try XCTUnwrap(views(host).compactMap { $0 as? ShortcutCaptureView }.first)
        capture.keyDown(with: try event(kVK_Delete, flags: []))
        await layout(host)
        XCTAssertNil(settings.binding(for: .clipboard))
        XCTAssertEqual(settings.binding(for: .todo), ToolShortcutTarget.todo.defaultBinding)
        XCTAssertEqual(settings.binding(for: .notes), ToolShortcutTarget.notes.defaultBinding)
        XCTAssertFalse(settings.isRecording)
        let button = try XCTUnwrap(accessibilityNodes(host).first { $0.accessibilityLabel() == "Change Clipboard shortcut" })
        XCTAssertEqual(button.accessibilityValue() as? String, "Not set")
    }

    func testSwitchingRowsLeavesExactlyOneRecorderAndSavesToTheSelectedTool() async throws {
        let settings = try settings()
        let suite = "lenotch.test.shortcut-page-switch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: SetupToolsPage(model: ToolMenuModel(defaults: defaults), shortcuts: settings))
        let window = window(content: host)
        defer { settings.endRecording(); window.close() }
        try await prepareAccessibilityHost(host)
        try press("Change To-do shortcut", in: host)
        await layout(host)
        XCTAssertTrue(settings.isRecording)
        XCTAssertEqual(views(host).compactMap { $0 as? ShortcutCaptureView }.count, 1)
        try press("Change Notes shortcut", in: host)
        await layout(host)
        XCTAssertTrue(settings.isRecording)
        let captures = views(host).compactMap { $0 as? ShortcutCaptureView }
        XCTAssertEqual(captures.count, 1, "Switching rows must dismantle the previous native recorder")
        try XCTUnwrap(captures.first).keyDown(with: try event(kVK_ANSI_N, flags: [.command, .shift]))
        await layout(host)
        XCTAssertEqual(settings.binding(for: .todo), ToolShortcutTarget.todo.defaultBinding)
        XCTAssertEqual(settings.binding(for: .notes), ToolKeyBinding(keyCode: kVK_ANSI_N, modifiers: cmdKey | shiftKey))
        XCTAssertFalse(settings.isRecording)
    }

    func testRemovingRecorderPageCancelsRecordingAndReleasesTheInputGate() async throws {
        let settings = try settings()
        let host = NSHostingView(rootView: AnyView(ShortcutRecorderTestPage(target: .notes, settings: settings)))
        let window = window(content: host)
        defer { settings.endRecording(); window.close() }
        try await prepareAccessibilityHost(host)
        try press("Change Notes shortcut", in: host)
        await layout(host)
        XCTAssertTrue(settings.isRecording)
        XCTAssertTrue(ToolShortcutRecordingGate.isRecording)
        host.rootView = AnyView(Text("Settings closed"))
        await layout(host)
        XCTAssertFalse(settings.isRecording)
        XCTAssertFalse(ToolShortcutRecordingGate.isRecording)
        XCTAssertEqual(settings.binding(for: .notes), ToolShortcutTarget.notes.defaultBinding)
    }

    func testUnifiedToolListRendersAllToolsAndShortcutControlsInBothThemes() throws {
        let settings = try settings()
        let suite = "lenotch.test.shortcut-page-ocr.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for scheme in [ColorScheme.light, .dark] {
            let view = SetupToolsPage(model: ToolMenuModel(defaults: defaults), shortcuts: settings)
                .padding(24).frame(width: 700, height: 1760, alignment: .topLeading)
                .background(scheme == .dark ? Color(red: 0.09, green: 0.09, blue: 0.086) : .white)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let rows = (request.results ?? []).compactMap { observation -> (text: String, bounds: CGRect)? in
                guard let text = observation.topCandidates(1).first?.string.lowercased() else { return nil }
                return (text, observation.boundingBox)
            }
            let text = rows.map(\.text).joined(separator: " ")
            for label in ["your tools", "shortcut", "in menu", "restore order", "preview menu"] {
                XCTAssertTrue(text.contains(label), "Missing \(label) in \(scheme): \(text)")
            }
            XCTAssertEqual(ToolShortcutTarget.allCases.count, 13)
            // The dedicated menu/row tests verify every title's pixel position. Here use
            // representative enabled rows: Vision may omit dimmed hidden-tool labels.
            for target in [ToolShortcutTarget.chat, .clipboard, .todo, .notes] {
                let title = target.title.lowercased()
                // Vision can group the icon, name and shortcut into one observation. Match
                // complete words in the transcript instead of relying on OCR line breaks.
                let name = target == .todo ? "to[\\s\\p{Pd}]*do" : NSRegularExpression.escapedPattern(for: title)
                let pattern = "(?<![\\p{L}\\p{N}])\(name)(?![\\p{L}\\p{N}])"
                XCTAssertNotNil(text.range(of: pattern, options: .regularExpression),
                                "Missing tool \(title) in \(scheme): \(text)")
            }
            let emptyControls = try NSRegularExpression(pattern: "\\badd\\s+shortcut\\b")
                .numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertEqual(emptyControls, 7,
                           "Tools without default bindings still expose assignment: \(text)")
            XCTAssertFalse(text.contains("keyboard shortcuts"), "Do not restore a separate shortcut section: \(text)")
            XCTAssertFalse(text.contains("open from anywhere"), "Rows should use the compact unified recorder: \(text)")
            XCTAssertTrue(text.contains("fn hold works independently"), text)
            XCTAssertFalse(settings.isRecording)
        }
    }

    private func prepareAccessibilityHost(_ host: NSView) async throws {
        // Merely attaching NSHostingView to an unordered window can leave its SwiftUI AX tree
        // empty. Order only this owned window behind the user's windows; never activate it.
        host.window?.orderBack(nil)
        for _ in 0..<8 {
            await layout(host)
            let nodes = accessibilityNodes(host)
            if nodes.contains(where: {
                guard let role = $0.accessibilityRole() else { return false }
                // AppKit may expose a native Menu's shell even when SwiftUI's content tree is
                // still entirely AXUnknown. That shell does not make the recorder controls testable.
                if role == .button { return !($0.accessibilityLabel() ?? "").isEmpty }
                if role == .staticText { return !($0.accessibilityValue() as? String ?? "").isEmpty }
                return false
            }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let summary = accessibilityNodes(host).prefix(12).map {
            "\($0.accessibilityRole()?.rawValue ?? "nil"):\($0.accessibilityLabel() ?? "nil")"
        }.joined(separator: ", ")
        throw XCTSkip("SwiftUI accessibility controls are unavailable in this owned non-key test window; "
                      + "visible=\(host.window?.isVisible ?? false), nodes=[\(summary)]. "
                      + "Native recorder events and headless rendering are tested separately.")
    }

    private func layout(_ host: NSView) async {
        for _ in 0..<12 {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }
        host.displayIfNeeded()
    }

    private func views(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views($0) }
    }

    private func accessibilityNodes(_ host: NSView) -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any) {
            guard result.count < 500, let object = value as? NSObject,
                  seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let element = object as? any NSAccessibilityProtocol {
                result.append(element)
                (element.accessibilityChildren() ?? []).forEach(visit)
            }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(host)
        return result
    }

    private func press(_ label: String, in host: NSView) throws {
        let nodes = accessibilityNodes(host)
        let summary = nodes.prefix(35).map {
            "\($0.accessibilityRole()?.rawValue ?? "nil"):\($0.accessibilityLabel() ?? "nil"):\(String(describing: $0.accessibilityValue()))"
        }.joined(separator: ", ")
        let button = try XCTUnwrap(nodes.first {
            $0.accessibilityRole() == .button && $0.accessibilityLabel() == label
        }, "Missing \(label) in \(summary)")
        XCTAssertTrue(button.accessibilityPerformPress(), "The real recorder button must accept its local press action")
    }
}

private final class ShortcutTestResponder: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private struct ShortcutRecorderTestPage: View {
    let target: ToolShortcutTarget
    let settings: ToolShortcutSettings
    @State private var recordingTarget: ToolShortcutTarget?

    var body: some View {
        ToolShortcutRecorder(target: target, settings: settings, recordingTarget: $recordingTarget)
    }
}
