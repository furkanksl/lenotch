import AppKit
import SwiftUI
import XCTest
@testable import Lenotch

@MainActor
final class PrompterReaderTests: XCTestCase {
    func testNativeReaderLaysOutWrappedScriptWithoutOpeningAnEditor() async throws {
        let model = PrompterModel(storageURL: nil)
        let script = Array(repeating: "Keep your eyes near the camera and speak at a natural pace.", count: 20).joined(separator: "\n\n")
        model.updateScript(title: "A presentation", text: script)
        let director = IslandDirector(prompter: model)
        director.openPrompter()
        let host = NSHostingView(rootView: PrompterCard(director: director).frame(width: 464, height: 292))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 464, height: 292),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        // The representable publishes measured layout after SwiftUI's current update, not during it.
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }

        let scroll = try XCTUnwrap(descendant(of: host, matching: NSScrollView.self))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertEqual(text.string, script)
        XCTAssertFalse(text.isEditable)
        XCTAssertFalse(text.isSelectable)
        XCTAssertGreaterThan(scroll.contentSize.width, 400)
        XCTAssertGreaterThan(scroll.contentSize.height, 100)
        XCTAssertGreaterThan(text.frame.height, scroll.contentSize.height)
        XCTAssertGreaterThan(model.maxOffset, 0)
        XCTAssertEqual(Double(try XCTUnwrap(text.font).pointSize), model.fontSize)
        XCTAssertEqual(host.fittingSize.height, 292, accuracy: 0.5)
    }

    private func descendant<T: NSView>(of view: NSView, matching type: T.Type) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(of: $0, matching: type) }.first
    }
}
