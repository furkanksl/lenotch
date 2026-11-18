import IslandCore
import SwiftUI
import XCTest
@testable import Lenotch

@MainActor
final class ToolIconTests: XCTestCase {
    func testEveryToolHasANonemptyVector() {
        XCTAssertEqual(ToolIcon.allCases, [
            .ask, .dictation, .timer, .prompter, .today, .launcher,
            .clipboard, .shelf, .shortcuts, .usage, .system, .todo, .notes, .inbox,
        ], "Every tool must have a Hugeicons vector, including newly added tools")
        for icon in ToolIcon.allCases {
            let path = ToolIconShape(icon: icon).path(in: CGRect(x: 0, y: 0, width: 24, height: 24))
            XCTAssertFalse(path.isEmpty, "\(icon) must not disappear if an external asset cannot load")
            let bounds = path.boundingRect
            XCTAssertGreaterThan(bounds.width, 4, "\(icon)")
            XCTAssertGreaterThan(bounds.height, 4, "\(icon)")
            XCTAssertGreaterThanOrEqual(bounds.minX, 0, "\(icon)")
            XCTAssertGreaterThanOrEqual(bounds.minY, 0, "\(icon)")
            XCTAssertLessThanOrEqual(bounds.maxX, 24, "\(icon)")
            XCTAssertLessThanOrEqual(bounds.maxY, 24, "\(icon)")
        }
    }

    func testNewToolsHaveThePublishedHugeiconsBoundsAndDistinctGeometry() {
        let box = CGRect(x: 0, y: 0, width: 24, height: 24)
        let launcher = ToolIconShape(icon: .launcher).path(in: box)
        let usage = ToolIconShape(icon: .usage).path(in: box)
        let inbox = ToolIconShape(icon: .inbox).path(in: box)
        // @hugeicons/core-free-icons@4.4.0: DashboardSquare01Icon, PieChart08Icon,
        // Notification01Icon. These are three distinct native paths, not fallbacks.
        XCTAssertEqual(launcher.boundingRect, CGRect(x: 3, y: 3, width: 18, height: 18))
        XCTAssertEqual(usage.boundingRect, CGRect(x: 2, y: 2, width: 20, height: 20))
        XCTAssertEqual(inbox.boundingRect, CGRect(x: 3, y: 2.5, width: 18, height: 19))
        XCTAssertNotEqual(launcher, usage)
        XCTAssertNotEqual(usage, inbox)
        XCTAssertNotEqual(inbox, launcher)
    }

    func testVectorsFitWithoutStretchingInANonsquareContainer() {
        for icon in ToolIcon.allCases {
            let square = ToolIconShape(icon: icon).path(in: CGRect(x: 0, y: 0, width: 24, height: 24)).boundingRect
            let wide = ToolIconShape(icon: icon).path(in: CGRect(x: 10, y: 20, width: 96, height: 48)).boundingRect
            XCTAssertEqual(wide.width, square.width * 2, accuracy: 0.01, "\(icon)")
            XCTAssertEqual(wide.height, square.height * 2, accuracy: 0.01, "\(icon)")
            XCTAssertEqual(wide.minX, 34 + square.minX * 2, accuracy: 0.01, "\(icon)")
            XCTAssertEqual(wide.minY, 20 + square.minY * 2, accuracy: 0.01, "\(icon)")
        }
    }

    func testNotesMenuIconIsDistinctFromClipboardAndToDo() {
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        let path = ToolIconShape(icon: .notes).path(in: rect)
        XCTAssertFalse(path.isEmpty)
        for other in [ToolIcon.clipboard, .todo] {
            XCTAssertNotEqual(path, ToolIconShape(icon: other).path(in: rect),
                              "Notes should not reuse the \(other) icon")
        }
    }

    func testAllIconsRenderAtActualToolSizeAtStandardAndRetinaScale() throws {
        for scale in [1.0, 2.0] {
            for icon in ToolIcon.allCases {
                let renderer = ImageRenderer(content: ToolIconView(icon: icon)
                    .foregroundStyle(.white).frame(width: 20, height: 20))
                renderer.scale = scale
                let image = try XCTUnwrap(renderer.cgImage, "\(icon) at \(scale)x")
                XCTAssertEqual(image.width, Int(20 * scale))
                XCTAssertEqual(image.height, Int(20 * scale))
                let pixels = try rgba(image)
                let visible = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 32 }
                XCTAssertGreaterThan(visible.count, Int(12 * scale), "\(icon) must visibly render at tool size")
                XCTAssertLessThan(visible.count, image.width * image.height / 2,
                                  "\(icon) must remain an outline, not an opaque rectangular image")
            }
        }
    }

    func testEveryActualToolsGridButtonContainsVisibleIconPixels() throws {
        let suite = "lenotch.test.toolicons.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let director = IslandDirector(prompter: PrompterModel(storageURL: nil), chatDefaults: defaults,
                                      toolMenu: ToolMenuModel(defaults: defaults))
        let scheduler = ManualScheduler()
        director.schedule = scheduler.schedule
        director.clock = { 0 }
        director.realTime = { 0 }
        director.openTray()
        let card = director.presentationCard(player: CardSize(width: 520, height: 240, radius: 32))
        let frame = FrameModel()
        frame.cardHalfWidth = card.halfWidth
        frame.cardHeight = card.height
        frame.cardTop = 80
        frame.cardRadius = card.radius
        let rows = director.toolMenu.rows
        let view = TrayLayer(frame: frame, director: director, card: card)
            .environment(\.islandMotion, IslandMotion(reduce: true, stills: true))
            .frame(width: NotchContentView.size.width, height: NotchContentView.size.height)
            .background(.black)
        for scale in [1.0, 2.0] {
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            let image = try XCTUnwrap(renderer.cgImage)
            for (rowIndex, row) in rows.enumerated() {
                let leading = Double(ToolMenuModel.columns - row.count) / 2
                for (column, tool) in row.enumerated() {
                    let name = tool.menuLabel
                    let centerX = FrameModel.cx - card.halfWidth + 20
                        + (card.width - 40) / Double(ToolMenuModel.columns) * (leading + Double(column) + 0.5)
                    let top = frame.cardTop + ToolMenuModel.margin
                        + (ToolMenuModel.rowHeight + ToolMenuModel.rowSpacing) * Double(rowIndex)
                    let crop = try XCTUnwrap(image.cropping(to: CGRect(
                        x: (centerX - 12) * scale, y: (top + 8) * scale,
                        width: 24 * scale, height: 24 * scale
                    )), "\(name) icon region must be inside the card")
                    let pixels = try rgba(crop)
                    let foreground = stride(from: 0, to: pixels.count, by: 4).filter {
                        pixels[$0] > 160 && pixels[$0 + 1] > 160
                            && pixels[$0 + 2] > 160 && pixels[$0 + 3] > 200
                    }
                    XCTAssertGreaterThan(foreground.count, Int(12 * scale),
                                         "\(name) must render an icon, not only a background and label, at \(scale)x")
                }
            }
        }
    }

    func testIconsInheritActiveToolTint() throws {
        let renderer = ImageRenderer(content: ToolIconView(icon: .dictation)
            .foregroundStyle(Color.green).frame(width: 24, height: 24))
        let image = try XCTUnwrap(renderer.cgImage)
        let pixels = try rgba(image)
        let colored = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 3] > 100 }
        XCTAssertFalse(colored.isEmpty)
        for i in colored {
            XCTAssertGreaterThan(pixels[i + 1], pixels[i], "active icons must inherit the tool's tint")
            XCTAssertGreaterThan(pixels[i + 1], pixels[i + 2])
        }
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                 bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
