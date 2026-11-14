import AppKit
import IslandCore
import SwiftUI
import XCTest
@testable import Lenotch

@MainActor final class LauncherFanTests: XCTestCase {
    private func model(count: Int = 5, opener: LauncherModel.Opener? = nil) throws -> LauncherModel {
        let model = LauncherModel(defaults: nil, opener: opener)
        for index in 0..<count { try model.addLink("https://example.com/\(index)", title: "Item \(index)") }
        return model
    }

    private var geometry: NotchGeometry {
        NotchGeometry(displayID: 1, screenFrame: NSRect(x: -1440, y: 120, width: 1440, height: 900),
                      notchMinX: -815, notchMaxX: -625, notchHeight: 34, scale: 2, isVirtual: true)
    }

    func testFanMirrorsScreenshotWithHighEdgesAndDroppingCenter() {
        let layout = LauncherFanLayout()
        let points = (0..<5).map { layout.center(index: $0, count: 5) }
        XCTAssertEqual(points[0].y, points[4].y)
        XCTAssertEqual(points[1].y, points[3].y)
        XCTAssertGreaterThan(points[2].y, points[1].y)
        XCTAssertGreaterThan(points[1].y, points[0].y)
        for index in 0..<5 {
            XCTAssertGreaterThan(points[index].y, layout.origin(index: index, count: 5).y)
            XCTAssertTrue(layout.contains(points[index], count: 5))
            if index > 0 {
                XCTAssertGreaterThan(hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y), 100)
            }
        }
        XCTAssertFalse(layout.contains(CGPoint(x: 12, y: 190), count: 5))
        XCTAssertFalse(layout.contains(CGPoint(x: layout.width / 2, y: 70), count: 5))
        XCTAssertTrue(layout.contains(CGPoint(x: layout.controls.midX, y: layout.controls.midY), count: 5))
    }

    func testSingleItemIsCenteredAndAllItemsStayInsideAvailableDisplayWidth() {
        for width in [CGFloat(480), 680, 900] {
            let layout = LauncherFanLayout(width: width)
            XCTAssertEqual(layout.center(index: 0, count: 1).x, width / 2)
            for count in 1...5 {
                for index in 0..<count {
                    let point = layout.center(index: index, count: count)
                    XCTAssertGreaterThanOrEqual(point.x - 50, 0)
                    XCTAssertLessThanOrEqual(point.x + 50, width)
                    XCTAssertLessThan(point.y + 53, layout.controls.minY)
                }
            }
        }
    }

    func testPagingKeepsEveryConfiguredItemReachableAndKeyboardSelectionWraps() throws {
        let model = try model(count: 21), state = LauncherFanState(model: model)
        XCTAssertEqual(state.pages, 5)
        var visited: [UUID] = []
        for _ in 0..<state.pages { visited += state.items.map(\.id); state.changePage(1) }
        XCTAssertEqual(visited, model.items.map(\.id))
        state.reset()
        state.moveSelection(-1)
        XCTAssertEqual(state.selection?.id, state.items.last?.id)
        state.moveSelection(1)
        XCTAssertEqual(state.selection?.id, state.items.first?.id)
        state.changePage(1)
        XCTAssertNil(state.selection)
    }

    func testShortcutAndToolsRequestFanWithoutOpeningAnyTrayCard() {
        let director = IslandDirector()
        var showed = 0, toggled = 0
        director.onShowLauncher = { showed += 1 }
        director.onToggleLauncher = { toggled += 1 }
        director.toggleLauncher()
        XCTAssertEqual(toggled, 1)
        XCTAssertFalse(director.island.trayShows)
        director.showTool(.launcher)
        XCTAssertEqual(showed, 1)
        director.tray.go(.launcher)
        XCTAssertEqual(showed, 2)
        XCTAssertEqual(director.tray.page, .main)
        XCTAssertFalse(director.island.trayShows)
    }

    func testContextDismissesFanAndPreventsReopeningWhileLockedOrPresenting() {
        let director = IslandDirector()
        var showed = 0, dismissed = 0
        director.onShowLauncher = { showed += 1 }
        director.onDismissLauncher = { dismissed += 1 }
        var context = DesktopContext()
        context.locked = true
        director.setContext(context)
        director.showTool(.launcher)
        XCTAssertEqual(showed, 0)
        XCTAssertEqual(dismissed, 1)
        context.locked = false; context.sharing = true
        director.setContext(context)
        director.showTool(.launcher)
        XCTAssertEqual(showed, 0)
    }

    func testTransparentPanelIsAnchoredToSelectedDisplayAndRapidReopenSurvivesOldClose() async throws {
        let controller = LauncherFanController(model: try model())
        defer { controller.stop() }
        controller.updateGeometry(geometry)
        controller.show()
        XCTAssertTrue(controller.isOpen)
        XCTAssertEqual(controller.panel.frame.midX, geometry.notchCenterX)
        XCTAssertEqual(controller.panel.frame.maxY, geometry.screenFrame.maxY)
        XCTAssertFalse(controller.panel.isOpaque)
        XCTAssertEqual(controller.panel.backgroundColor?.alphaComponent, 0)
        XCTAssertFalse(controller.contains(screenPoint: NSPoint(x: controller.panel.frame.minX + 5, y: controller.panel.frame.minY + 5)))
        controller.hide()
        controller.show()
        try await Task.sleep(for: .milliseconds(230))
        XCTAssertTrue(controller.isOpen)
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertTrue(controller.state.presented)
        controller.updateGeometry(nil)
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(controller.panel.isVisible)
    }

    func testLaunchFailureStaysOpenAndSuccessfulLaunchDismissesWithoutDuplicateOpen() async throws {
        var opens = 0
        let model = try model(opener: { _, _ in opens += 1; await Task.yield() })
        let controller = LauncherFanController(model: model)
        defer { controller.stop() }
        controller.updateGeometry(geometry); controller.show()
        let item = try XCTUnwrap(model.items.first)
        controller.launch(item); controller.launch(item)
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.isOpen && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(opens, 1)
        XCTAssertFalse(controller.isOpen)

        let failing = try self.model(opener: { _, _ in throw LauncherError.cannotOpen })
        let failure = LauncherFanController(model: failing)
        defer { failure.stop() }
        failure.updateGeometry(geometry); failure.show()
        failure.launch(try XCTUnwrap(failing.items.first))
        let failureDeadline = ContinuousClock.now + .seconds(2)
        while failing.errorMessage == nil && ContinuousClock.now < failureDeadline { await Task.yield() }
        XCTAssertNotNil(failing.errorMessage)
        XCTAssertTrue(failure.isOpen)
    }

    func testEscapeToggleAndOutsideClickDismissWithoutTakingTransparentGaps() throws {
        let controller = LauncherFanController(model: try model())
        defer { controller.stop() }
        controller.updateGeometry(geometry); controller.show()
        XCTAssertFalse(controller.handleKey(0, modifiers: .command))
        XCTAssertTrue(controller.handleKey(124))
        XCTAssertEqual(controller.state.selection?.id, controller.state.items.first?.id)
        XCTAssertTrue(controller.handleKey(53))
        XCTAssertFalse(controller.isOpen)
        controller.toggle(); XCTAssertTrue(controller.isOpen)
        controller.state.finishTransition()
        let target = controller.state.layout.center(index: 0, count: 5)
        controller.dismissIfOutside(NSPoint(x: controller.panel.frame.minX + target.x, y: controller.panel.frame.maxY - target.y))
        XCTAssertTrue(controller.isOpen)
        controller.dismissIfOutside(NSPoint(x: controller.panel.frame.minX - 10, y: controller.panel.frame.minY - 10))
        XCTAssertFalse(controller.isOpen)
        controller.toggle(); XCTAssertTrue(controller.isOpen)
        controller.toggle(); XCTAssertFalse(controller.isOpen)
    }

    func testFanRendersTransparentGapsRatherThanABlackRectangularCard() throws {
        let state = LauncherFanState(model: try model())
        state.presented = true
        for reduce in [false, true] {
            let view = LauncherView(state: state, reduceMotion: reduce, onClose: {}, onConfigure: {}, onLaunch: { _ in })
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            for point in [CGPoint(x: 4, y: 4), CGPoint(x: 340, y: 70), CGPoint(x: 10, y: 200)] {
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: Int(point.x * 2), y: Int(point.y * 2))).alphaComponent, 0.01)
            }
            let target = state.layout.center(index: 2, count: 5)
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: Int(target.x * 2), y: Int((target.y - 16) * 2))).alphaComponent, 0.9)
        }
    }

    func testShortcutOmitsControlsAndTheirHitAreaButToolsRetainsThem() throws {
        let controller = LauncherFanController(model: try model())
        defer { controller.stop() }
        controller.updateGeometry(geometry)
        controller.toggle(showsControls: false)
        controller.state.finishTransition()
        XCTAssertFalse(controller.state.showsControls)
        let controls = controller.state.layout.controls
        let screenPoint = NSPoint(x: controller.panel.frame.minX + controls.midX,
                                  y: controller.panel.frame.maxY - controls.midY)
        XCTAssertFalse(controller.contains(screenPoint: screenPoint), "Hidden controls must not intercept clicks")
        XCTAssertTrue(controller.handleKey(53))
        XCTAssertFalse(controller.isOpen)
        controller.show()
        controller.state.finishTransition()
        XCTAssertTrue(controller.state.showsControls)
        XCTAssertTrue(controller.contains(screenPoint: screenPoint))
        controller.hide(animated: false)
        controller.toggle(showsControls: false)
        XCTAssertFalse(controller.state.showsControls, "Shortcut presentation must reset the previous Tools presentation")
        controller.toggle(showsControls: false)
        XCTAssertFalse(controller.isOpen)
    }

    func testShortcutLauncherKeepsExtraPagesReachableWithoutTheControls() throws {
        let controller = LauncherFanController(model: try model(count: 7))
        defer { controller.stop() }
        controller.updateGeometry(geometry)
        controller.toggle(showsControls: false)
        controller.state.finishTransition()
        XCTAssertFalse(controller.state.showsControls)
        XCTAssertTrue(controller.handleKey(121))
        XCTAssertEqual(controller.state.page, 1)
        XCTAssertEqual(controller.state.items.count, 2)
        XCTAssertTrue(controller.handleKey(116))
        XCTAssertEqual(controller.state.page, 0)
    }

    func testShortcutRenderingRemovesTheEntireBottomPill() throws {
        for count in [5, 7] {
            let state = LauncherFanState(model: try model(count: count))
            state.presented = true
            for showsControls in [true, false] {
                state.showsControls = showsControls
                let view = LauncherView(state: state, reduceMotion: true, onClose: {}, onConfigure: {}, onLaunch: { _ in })
                let renderer = ImageRenderer(content: view); renderer.scale = 2
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                let controls = state.layout.controls
                let alpha = try XCTUnwrap(bitmap.colorAt(x: Int(controls.midX * 2), y: Int((controls.midY + 10) * 2))).alphaComponent
                if showsControls { XCTAssertGreaterThan(alpha, 0.85) }
                else { XCTAssertLessThan(alpha, 0.01, "Shortcut launcher must render no settings/close pill, including with multiple pages") }
            }
        }
    }
}
