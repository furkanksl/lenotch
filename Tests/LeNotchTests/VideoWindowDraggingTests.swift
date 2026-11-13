import AppKit
import XCTest
@testable import Lenotch

@MainActor
final class VideoWindowDraggingTests: XCTestCase {
    func testDraggingVideoUsesNativeWindowDraggingWithoutChangingItsSize() throws {
        let (panel, host) = window(draggable: true)
        defer { panel.close() }
        let frame = panel.frame
        let event = try mouseEvent(in: panel, at: NSPoint(x: 160, y: 90))

        host.mouseDown(with: event)

        XCTAssertEqual(panel.dragEvents.count, 1)
        XCTAssertTrue(panel.dragEvents.first === event)
        XCTAssertEqual(panel.frame, frame, "the view delegates movement to AppKit, not custom frame arithmetic")
        XCTAssertTrue(host.acceptsFirstMouse(for: event), "a floating, nonactive PiP must move on the first drag")
    }

    func testNotchVideoDoesNotStartWindowDragging() throws {
        let (panel, host) = window(draggable: false)
        defer { panel.close() }
        host.mouseDown(with: try mouseEvent(in: panel, at: NSPoint(x: 160, y: 90)))
        XCTAssertTrue(panel.dragEvents.isEmpty)
    }

    func testResizeEdgesDoNotStartAMove() throws {
        let (panel, host) = window(draggable: true)
        defer { panel.close() }
        for point in [NSPoint(x: 2, y: 90), NSPoint(x: 318, y: 90),
                      NSPoint(x: 160, y: 2), NSPoint(x: 160, y: 178)] {
            host.mouseDown(with: try mouseEvent(in: panel, at: point))
        }
        XCTAssertTrue(panel.dragEvents.isEmpty, "resize borders must remain available to AppKit")
    }

    func testNonMovableWindowDoesNotStartDragging() throws {
        let (panel, host) = window(draggable: true)
        defer { panel.close() }
        panel.isMovable = false
        host.mouseDown(with: try mouseEvent(in: panel, at: NSPoint(x: 160, y: 90)))
        XCTAssertTrue(panel.dragEvents.isEmpty)
    }

    private func window(draggable: Bool) -> (DragTrackingPanel, VideoLayerHostView) {
        _ = NSApplication.shared
        let panel = DragTrackingPanel(contentRect: NSRect(x: 20, y: 20, width: 320, height: 180),
                                      styleMask: [.borderless, .resizable, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = VideoLayerHostView(videoLayer: CALayer(), allowsWindowDragging: draggable)
        panel.contentView = host
        host.frame = NSRect(origin: .zero, size: NSSize(width: 320, height: 180))
        return (panel, host)
    }

    private func mouseEvent(in window: NSWindow, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                        eventNumber: 1, clickCount: 1, pressure: 1))
    }
}

@MainActor
private final class DragTrackingPanel: NSPanel {
    var dragEvents: [NSEvent] = []

    override func performDrag(with event: NSEvent) { dragEvents.append(event) }
}
