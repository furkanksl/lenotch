#if DEBUG
import AppKit
import SwiftUI

/// Development builds only. `com.lenotch.app.debug.tools-drag-selftest` (object: an output folder) opens the real
/// Settings window on the Tools page and drives it with real mouse events: a drag down two rows, then a drag held
/// at the bottom edge so the page has to scroll. It writes `report.txt` and PNGs of what it saw into the folder and
/// puts the menu order back afterwards. Posted from a small tool, since the shell can't synthesize HID events.
@MainActor
enum ToolsDragSelfTest {
    private static var observer: NSObjectProtocol?
    private static var running = false

    static func install() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.lenotch.app.debug.tools-drag-selftest"), object: nil, queue: .main
        ) { note in
            let folder = note.object as? String ?? NSTemporaryDirectory()
            Task { @MainActor in await run(into: URL(fileURLWithPath: folder, isDirectory: true)) }
        }
    }

    private static func run(into folder: URL) async {
        guard !running else { return }
        running = true
        defer { running = false }
        var report: [String] = []
        func note(_ line: String) { report.append(line) }
        defer { try? report.joined(separator: "\n").appending("\n").write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8) }

        let model = ToolMenuModel.shared
        let original = model.orderedTools
        let visibilityAtStart = Dictionary(uniqueKeysWithValues: TrayTool.allCases.map { ($0, model.isEnabled($0)) })
        let window = SetupWindowController.makeWindow(page: .tools)
        window.setFrameOrigin(NSPoint(x: 120, y: 80))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        for _ in 0..<40 where !(NSApp.isActive && window.isKeyWindow) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(150))
        }
        try? await Task.sleep(for: .milliseconds(900))
        note("app active=\(NSApp.isActive) window key=\(window.isKeyWindow) frame=\(window.frame)")

        guard NSApp.isActive && window.isKeyWindow else {
            note("INCONCLUSIVE macOS never let the app become active (another app is being used?). Nothing was tested.")
            window.close(); return
        }
        guard let session = ToolReorderSession.live, let content = window.contentView else {
            note("FAIL no live reorder session; the Tools page did not appear")
            window.close(); return
        }
        let scroll = firstScrollView(in: content)
        let height = content.bounds.height
        note("content=\(content.bounds.size) listTop=\(session.listTop) scrollView=\(String(describing: scroll?.frame))")
        func snapshot(_ name: String) {
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
        }
        func event(_ type: NSEvent.EventType, x: CGFloat, topY: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: height - topY), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let x = (scroll.map { window.contentView!.convert($0.bounds, from: $0).minX } ?? 240) + 170
        let row = ToolReorderSession.rowHeight
        snapshot("0-before")

        // A: plain drags in both directions, one straight after another like a real user would do them.
        func drag(index: Int, by rows: Int, pause: Int, shot: String? = nil) async -> Bool {
            let before = model.orderedTools
            let startY = session.listTop + (CGFloat(index) + 0.5) * row
            let endY = startY + CGFloat(rows) * row
            window.sendEvent(event(.leftMouseDown, x: x, topY: startY))
            try? await Task.sleep(for: .milliseconds(40))
            for step in 1...18 {
                window.sendEvent(event(.leftMouseDragged, x: x, topY: startY + (endY - startY) * CGFloat(step) / 18))
                try? await Task.sleep(for: .milliseconds(16))
                if step == 11, let shot { snapshot(shot) }
            }
            window.sendEvent(event(.leftMouseUp, x: x, topY: endY))
            try? await Task.sleep(for: .milliseconds(pause))
            var expected = before
            let tool = expected.remove(at: index)
            expected.insert(tool, at: index + rows)
            let ok = model.orderedTools == expected && !session.isActive
            note("A drag row \(index) by \(rows): \(ok ? "OK" : "FAIL") moved \(tool.rawValue) to \(model.orderedTools.firstIndex(of: tool) ?? -1) (wanted \(index + rows)) active=\(session.isActive)")
            return ok
        }
        snapshot("0b-before-A")
        _ = await drag(index: 0, by: 2, pause: 400, shot: "1-mid-drag")
        snapshot("2-after-drop")
        _ = await drag(index: 5, by: -3, pause: 150)
        _ = await drag(index: 1, by: 1, pause: 150)
        _ = await drag(index: 4, by: 3, pause: 150)
        _ = await drag(index: 3, by: -3, pause: 150)
        let afterA = model.orderedTools
        note("A saved=\(UserDefaults.standard.stringArray(forKey: ToolMenuModel.orderStorageKey) == afterA.map(\.rawValue))")

        // B: hold near the bottom edge; the page should scroll and the row should keep sinking.
        if let scroll {
            let clip = scroll.contentView
            let viewportBottom = height - (content.convert(scroll.bounds, from: scroll).minY)
            let before = clip.bounds.origin.y
            let grabbed = afterA[0]
            let y0 = session.listTop + row / 2
            window.sendEvent(event(.leftMouseDown, x: x, topY: y0))
            try? await Task.sleep(for: .milliseconds(60))
            note("B pressed at y=\(y0) listTop=\(session.listTop) active=\(session.isActive)")
            let edge = viewportBottom - 8
            let travel = edge - y0
            for step in 1...20 {
                window.sendEvent(event(.leftMouseDragged, x: x, topY: y0 + travel * CGFloat(step) / 20))
                try? await Task.sleep(for: .milliseconds(16))
                if step % 5 == 0 { note("B step \(step) active=\(session.isActive) pointerY=\(session.pointerY) target=\(session.targetIndex) listTop=\(session.listTop)") }
            }
            for _ in 0..<45 {
                window.sendEvent(event(.leftMouseDragged, x: x, topY: edge))
                try? await Task.sleep(for: .milliseconds(30))
            }
            note("B held at bottom: scrollOffset \(before) -> \(clip.bounds.origin.y) active=\(session.isActive) target=\(session.targetIndex) viewportBottom=\(viewportBottom)")
            snapshot("3-edge-scroll")
            window.sendEvent(event(.leftMouseUp, x: x, topY: edge))
            try? await Task.sleep(for: .milliseconds(500))
            note("B result: \(grabbed.rawValue) now at index \(model.orderedTools.firstIndex(of: grabbed) ?? -1) scrollOffset=\(clip.bounds.origin.y)")
            clip.scroll(to: NSPoint(x: 0, y: 0)); scroll.reflectScrolledClipView(clip)
        } else {
            note("B skipped: no NSScrollView found")
        }

        // C: a real click on a visibility switch, then on it again.
        let cardMinX = scroll.map { content.convert($0.bounds, from: $0).minX } ?? 240
        let switchX = cardMinX + 10 + 40 + 640 - 34 - 32
        let recorderX = cardMinX + 10 + 40 + 640 - 34 - 64 - 56
        func click(x: CGFloat, rowIndex: Int) async {
            let y = session.listTop + (CGFloat(rowIndex) + 0.5) * row
            window.sendEvent(event(.leftMouseDown, x: x, topY: y))
            try? await Task.sleep(for: .milliseconds(40))
            window.sendEvent(event(.leftMouseUp, x: x, topY: y))
            try? await Task.sleep(for: .milliseconds(250))
        }
        let toggled = model.orderedTools[2]
        let wasOn = model.isEnabled(toggled)
        await click(x: switchX, rowIndex: 2)
        let flipped = model.isEnabled(toggled) != wasOn
        await click(x: switchX, rowIndex: 2)
        note("C switch click: \(flipped ? "OK" : "FAIL") \(toggled.rawValue) \(wasOn) -> \(!wasOn) -> \(model.isEnabled(toggled)) (back to \(wasOn): \(model.isEnabled(toggled) == wasOn))")

        // D: a click on a shortcut starts recording; Escape stops it and leaves the shortcut alone.
        let recordingTarget = ToolShortcutTarget(rawValue: model.orderedTools[3].rawValue)!
        let bindingBefore = ToolShortcutSettings.shared.binding(for: recordingTarget)
        await click(x: recorderX, rowIndex: 3)
        let started = ToolShortcutSettings.shared.isRecording
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        window.sendEvent(escape)
        try? await Task.sleep(for: .milliseconds(250))
        note("D recorder click: starts=\(started ? "OK" : "FAIL") afterEscape recording=\(ToolShortcutSettings.shared.isRecording) binding unchanged=\(ToolShortcutSettings.shared.binding(for: recordingTarget) == bindingBefore)")

        // E: pressing on a switch and dragging must not reorder anything.
        let orderBeforeE = model.orderedTools
        window.sendEvent(event(.leftMouseDown, x: switchX, topY: session.listTop + 4.5 * row))
        for step in 1...10 {
            window.sendEvent(event(.leftMouseDragged, x: switchX, topY: session.listTop + 4.5 * row + CGFloat(step) * row / 4))
            try? await Task.sleep(for: .milliseconds(16))
        }
        window.sendEvent(event(.leftMouseUp, x: switchX, topY: session.listTop + 4.5 * row + 2.5 * row))
        try? await Task.sleep(for: .milliseconds(300))
        note("E drag from a switch: \(model.orderedTools == orderBeforeE ? "OK (no reorder)" : "FAIL (reordered)")")
        // Whatever E toggled goes back.
        for tool in TrayTool.allCases where model.isEnabled(tool) != (visibilityAtStart[tool] ?? model.isEnabled(tool)) {
            model.setEnabled(tool, visibilityAtStart[tool]!)
        }

        // Put the order back exactly as it was.
        for (target, tool) in original.enumerated() {
            if let now = model.orderedTools.firstIndex(of: tool), now != target { model.move(tool, by: target - now) }
        }
        note("restored order=\(model.orderedTools == original) visibility=\(TrayTool.allCases.allSatisfy { model.isEnabled($0) == visibilityAtStart[$0] })")
        try? await Task.sleep(for: .milliseconds(300))
        snapshot("4-restored")
        window.close()
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = firstScrollView(in: sub) { return found } }
        return nil
    }
}
#endif
