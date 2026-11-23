import AppKit
import XCTest
@testable import Lenotch

@MainActor
final class ContextMenuTests: XCTestCase {
    func testContextClickRecognizesRightClickAndControlLeftClickOnly() {
        XCTAssertTrue(NotchContextMenuPolicy.isContextClick(type: .rightMouseDown, modifiers: []))
        XCTAssertTrue(NotchContextMenuPolicy.isContextClick(type: .rightMouseDown, modifiers: [.option]))
        XCTAssertTrue(NotchContextMenuPolicy.isContextClick(type: .leftMouseDown, modifiers: [.control]))
        XCTAssertTrue(NotchContextMenuPolicy.isContextClick(type: .leftMouseDown, modifiers: [.control, .capsLock]))

        XCTAssertFalse(NotchContextMenuPolicy.isContextClick(type: .leftMouseDown, modifiers: []))
        XCTAssertFalse(NotchContextMenuPolicy.isContextClick(type: .leftMouseDown, modifiers: [.control, .command]))
        XCTAssertFalse(NotchContextMenuPolicy.isContextClick(type: .leftMouseDown, modifiers: [.control, .option]))
        XCTAssertFalse(NotchContextMenuPolicy.isContextClick(type: .leftMouseDown, modifiers: [.control, .shift]))
        XCTAssertFalse(NotchContextMenuPolicy.isContextClick(type: .mouseMoved, modifiers: [.control]))
    }

    func testTopEdgeClampingCoversSubpixelOvershootOnlyWithoutScreenAbove() {
        let panelFrame = NSRect(x: 376, y: 562, width: 760, height: 420) // maxY == 982

        // Slamming cursor to top pixel with slight overshoot clamps to y = 0 when no display is above.
        let clamped = NotchContextMenuPolicy.clampedPanelPoint(
            NSPoint(x: 756, y: 983.5),
            panelFrame: panelFrame,
            hasScreenAbove: false
        )
        XCTAssertEqual(clamped.x, 380, accuracy: 0.001)
        XCTAssertEqual(clamped.y, 0, accuracy: 0.001)

        // Larger negative y (beyond 2 pt tolerance) is not clamped.
        let farAbove = NotchContextMenuPolicy.clampedPanelPoint(
            NSPoint(x: 756, y: 986),
            panelFrame: panelFrame,
            hasScreenAbove: false
        )
        XCTAssertEqual(farAbove.y, -4, accuracy: 0.001)

        // When another display sits above this screen, moving past maxY stays negative so clicks aren't stolen.
        let upperDisplay = NotchContextMenuPolicy.clampedPanelPoint(
            NSPoint(x: 756, y: 983),
            panelFrame: panelFrame,
            hasScreenAbove: true
        )
        XCTAssertEqual(upperDisplay.y, -1, accuracy: 0.001)
    }

    func testIslandMenuAlwaysOpensOnEarsAndBubblesButRespectsCardTextAndSwiftUIMenus() {
        XCTAssertFalse(NotchContextMenuPolicy.shouldShowIslandMenu(region: nil, isTextInput: false, cardHasOwnContextMenu: false))

        // Ears and bubbles always open the app's context menu, even while editing text or viewing Notes/To-do.
        for region in [HitRegion.ears, .bubble(0), .bubble(1), .bubble(2)] {
            XCTAssertTrue(NotchContextMenuPolicy.shouldShowIslandMenu(region: region, isTextInput: true, cardHasOwnContextMenu: true))
            XCTAssertTrue(NotchContextMenuPolicy.shouldShowIslandMenu(region: region, isTextInput: false, cardHasOwnContextMenu: false))
        }

        // Card background opens the island menu, while text inputs and Notes/To-do defer to native/SwiftUI menus.
        XCTAssertTrue(NotchContextMenuPolicy.shouldShowIslandMenu(region: .card, isTextInput: false, cardHasOwnContextMenu: false))
        XCTAssertFalse(NotchContextMenuPolicy.shouldShowIslandMenu(region: .card, isTextInput: true, cardHasOwnContextMenu: false))
        XCTAssertFalse(NotchContextMenuPolicy.shouldShowIslandMenu(region: .card, isTextInput: false, cardHasOwnContextMenu: true))
    }
}
