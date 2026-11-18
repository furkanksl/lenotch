import AppKit
import SwiftUI
import XCTest
@testable import Lenotch

/// The arithmetic of a drag, with no views involved.
@MainActor
final class ToolReorderSessionTests: XCTestCase {
    private let row = ToolReorderSession.rowHeight
    private let order = TrayTool.allCases

    /// A session over the full list, with the list's top at y = 100 and the pointer taking hold mid-row.
    private func begin(_ tool: TrayTool, listTop: CGFloat = 100) -> ToolReorderSession {
        let session = ToolReorderSession()
        session.listTop = listTop
        let index = order.firstIndex(of: tool)!
        session.begin(tool, index: index, count: order.count, startY: listTop + CGFloat(index) * row + row / 2)
        return session
    }

    func testAnIdleSessionChangesNothing() {
        let session = ToolReorderSession()
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.displayOrder(order), order)
        XCTAssertNil(session.result)
        XCTAssertEqual(session.scrollStep(viewportTop: 0, viewportBottom: 600), 0)
    }

    func testTakingHoldWithoutMovingLeavesTheOrderAlone() {
        let session = begin(.todo)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.displayOrder(order), order)
        XCTAssertNil(session.result)
        XCTAssertEqual(session.draggedOffset, 0, accuracy: 0.001)
    }

    func testTheRowFollowsThePointerExactly() {
        let session = begin(.todo)
        let start = session.draggedTop
        session.move(to: session.pointerY + 17)
        XCTAssertEqual(session.draggedTop, start + 17, accuracy: 0.001)
    }

    func testDraggingDownPastHalfARowMovesItOneSlot() {
        let session = begin(.todo)
        let index = order.firstIndex(of: .todo)!
        session.move(to: session.pointerY + row * 0.4)
        XCTAssertEqual(session.targetIndex, index, "Less than half a row stays put")
        session.move(to: session.pointerY + row * 0.2)
        XCTAssertEqual(session.targetIndex, index + 1)
        XCTAssertEqual(session.result?.delta, 1)
        XCTAssertEqual(session.displayOrder(order)[index + 1], .todo)
    }

    func testDraggingUpMovesTheRowAheadOfItsNeighbours() {
        let session = begin(.notes)
        let index = order.firstIndex(of: .notes)!
        session.move(to: session.pointerY - row * 2)
        XCTAssertEqual(session.targetIndex, index - 2)
        XCTAssertEqual(session.result?.delta, -2)
        let shown = session.displayOrder(order)
        XCTAssertEqual(shown[index - 2], .notes)
        XCTAssertEqual(Set(shown), Set(order), "Nothing is lost or duplicated while dragging")
        XCTAssertEqual(shown.count, order.count)
    }

    func testTheRowStaysInsideTheList() {
        let session = begin(.chat)
        session.move(to: -5_000)
        XCTAssertEqual(session.targetIndex, 0)
        XCTAssertEqual(session.draggedTop, 0)
        session.move(to: 50_000)
        XCTAssertEqual(session.targetIndex, order.count - 1)
        XCTAssertEqual(session.draggedTop, CGFloat(order.count - 1) * row)
        XCTAssertEqual(session.displayOrder(order).last, .chat)
    }

    func testDroppingBackWhereItStartedIsNotAChange() {
        let session = begin(.shelf)
        session.move(to: session.pointerY + row * 3)
        XCTAssertNotNil(session.result)
        session.move(to: session.pointerY - row * 3)
        XCTAssertNil(session.result)
    }

    func testTheGrabPointIsKeptSoTheRowDoesNotJump() {
        let session = ToolReorderSession()
        session.listTop = 40
        // Taking hold near the bottom of the third row.
        session.begin(.prompter, index: 2, count: order.count, startY: 40 + 2 * row + row - 6)
        XCTAssertEqual(session.draggedTop, 2 * row, accuracy: 0.001)
        XCTAssertEqual(session.draggedOffset, 0, accuracy: 0.001)
    }

    func testScrollingThePageMovesTheRowWithTheContent() {
        // The pointer is still, the page scrolls 60 points up, so the list top moved up by 60.
        let session = begin(.todo)
        let before = session.draggedTop
        session.listTop -= 60
        XCTAssertEqual(session.draggedTop, before + 60, accuracy: 0.001,
                       "A held pointer over a scrolling list should carry the row further down it")
    }

    func testEdgeScrollingIsZeroInTheMiddleAndGrowsTowardTheEdges() {
        let session = begin(.todo)
        session.move(to: 300)
        XCTAssertEqual(session.scrollStep(viewportTop: 0, viewportBottom: 600), 0)
        session.move(to: 600 - 40)
        let slow = session.scrollStep(viewportTop: 0, viewportBottom: 600)
        session.move(to: 600 - 4)
        let fast = session.scrollStep(viewportTop: 0, viewportBottom: 600)
        XCTAssertGreaterThan(slow, 0)
        XCTAssertGreaterThan(fast, slow)
        XCTAssertLessThanOrEqual(fast, ToolReorderSession.maximumStep * 1.5)
        session.move(to: 10)
        XCTAssertLessThan(session.scrollStep(viewportTop: 0, viewportBottom: 600), 0)
    }

    func testCancelEndsTheDragWithoutAResult() {
        let session = begin(.todo)
        session.move(to: session.pointerY + row * 2)
        session.cancel()
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.result)
    }
}

private final class KeyableTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// The page itself, driven with mouse events through the real window system.
@MainActor
final class ToolsPageDragTests: XCTestCase {
    override func setUp() async throws { _ = NSApplication.shared }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "lenotch.test.tools-drag.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func settle(_ host: NSView, passes: Int = 24) async {
        for _ in 0..<passes {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(8))
        }
        host.displayIfNeeded()
    }

    /// Drags the row at `from` by `distance` points with a real press, a trail of moves and a release.
    private func drag(row from: Int, by distance: CGFloat, listTop: CGFloat, in window: NSWindow, host: NSView, session: ToolReorderSession? = nil) async throws {
        let height = window.contentView?.bounds.height ?? 0
        let x: CGFloat = 90
        let y = listTop + (CGFloat(from) + 0.5) * ToolReorderSession.rowHeight
        let start = NSPoint(x: x, y: height - y)
        window.sendEvent(try mouse(.leftMouseDown, at: start, in: window))
        await settle(host, passes: 2)
        probe("app active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) gr=\(host.gestureRecognizers.map { String(describing: type(of: $0)) }) subs=\(host.subviews.count)")
        if let session { probe("down active=\(window.isKeyWindow) \(session.isActive) start=\(start) listTop=\(listTop) height=\(height) key=\(window.isKeyWindow) visible=\(window.isVisible)") }
        let steps = 12
        for step in 1...steps {
            let point = NSPoint(x: x, y: start.y - distance * CGFloat(step) / CGFloat(steps))
            window.sendEvent(try mouse(.leftMouseDragged, at: point, in: window))
            await settle(host, passes: 2)
            if let session { probe("step \(step) active=\(session.isActive) pointerY=\(session.pointerY) target=\(session.targetIndex) hit=\(String(describing: host.hitTest(host.convert(point, from: nil))))") }
        }
        window.sendEvent(try mouse(.leftMouseUp, at: NSPoint(x: x, y: start.y - distance), in: window))
        await settle(host)
    }

    func testDraggingARowWithThePointerReordersItAndSavesTheOrder() async throws {
        let defaults = try isolatedDefaults()
        let model = ToolMenuModel(defaults: defaults)
        let shortcuts = ToolShortcutSettings(defaults: defaults)
        let session = ToolReorderSession()
        let host = NSHostingView(rootView: SetupToolsPage(model: model, shortcuts: shortcuts, session: session)
            .padding(24).frame(width: 700, alignment: .topLeading))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 1000)
        let window = KeyableTestWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // Far off every screen, so it can take key status without ever appearing in front of anyone.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await settle(host)

        let before = model.orderedTools
        XCTAssertGreaterThan(session.listTop, 24, "The page reports where its list sits")
        try await drag(row: 0, by: ToolReorderSession.rowHeight * 2, listTop: session.listTop, in: window, host: host, session: session)
        XCTAssertNotEqual(model.orderedTools, before, "A real press, drag and release on a row must reorder it")
        XCTAssertEqual(model.orderedTools[2], before[0], "Dragging the first row down two rows puts it third")
        XCTAssertEqual(Set(model.orderedTools), Set(before))

        let reloaded = ToolMenuModel(defaults: defaults)
        XCTAssertEqual(reloaded.orderedTools, model.orderedTools, "The new order is saved")
    }
}

func probe(_ line: String) {
    let url = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-furkankoseoglu-Desktop-fun-liquid-notch/cf7450a7-1505-46d9-bba7-b9b24371bead/scratchpad/drag-probe.log")
    let data = (line + "\n").data(using: .utf8)!
    if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
    else { try? data.write(to: url) }
}

private struct GestureProbePage: View {
    let log: @MainActor (String) -> Void
    @State private var offset: CGFloat = 0
    var body: some View {
        Color.red.frame(width: 200, height: 100)
            .contentShape(Rectangle())
            .onTapGesture { log("tap") }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { log("drag \($0.location.y)") }
                .onEnded { _ in log("end") })
            .frame(width: 400, height: 300, alignment: .topLeading)
    }
}

@MainActor
final class GestureHarnessProbeTests: XCTestCase {
    func testWhichEventPathsReachSwiftUIGestures() async throws {
        _ = NSApplication.shared
        var lines: [String] = []
        let host = NSHostingView(rootView: GestureProbePage { lines.append($0) })
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = KeyableTestWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(10)) }
        func ev(_ type: NSEvent.EventType, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 50, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        for path in ["host", "window"] {
            lines.append("--\(path)")
            func send(_ e: NSEvent) {
                switch (path, e.type) {
                case ("host", .leftMouseDown): host.mouseDown(with: e)
                case ("host", .leftMouseDragged): host.mouseDragged(with: e)
                case ("host", _): host.mouseUp(with: e)
                default: window.sendEvent(e)
                }
            }
            send(ev(.leftMouseDown, 250))
            for i in 1...6 { send(ev(.leftMouseDragged, 250 - CGFloat(i) * 8)); try? await Task.sleep(for: .milliseconds(10)) }
            send(ev(.leftMouseUp, 200))
            try? await Task.sleep(for: .milliseconds(30))
        }
        probe("harness: active=\(NSApp.isActive) key=\(window.isKeyWindow) \(lines)")
        window.close()
    }
}
