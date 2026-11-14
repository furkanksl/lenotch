import SwiftUI
import XCTest
@testable import Lenotch

@MainActor
final class ToolIconTests: XCTestCase {
    func testEveryToolHasANonemptyVectorIncludingBothPlaybackStates() {
        XCTAssertEqual(ToolIcon.allCases.count, 9)
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

    func testIconsInheritActiveToolTint() throws {
        let renderer = ImageRenderer(content: ToolIconView(icon: .timer)
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
