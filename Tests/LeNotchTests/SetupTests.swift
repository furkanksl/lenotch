import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

@MainActor
final class SetupTests: XCTestCase {
    func testSetupPagesKeepTheirNamesAndStableIdentity() {
        XCTAssertEqual(SetupPage.allCases, [.permissions, .appearance, .integrations])
        XCTAssertEqual(SetupPage.allCases.map(\.title), ["Permissions", "Appearance", "Integrations"])
        XCTAssertEqual(SetupPage.allCases.map(\.id), SetupPage.allCases)
        XCTAssertEqual(Set(SetupPage.allCases.map(\.symbol)).count, 3)
        for page in SetupPage.allCases {
            XCTAssertFalse(page.symbol.isEmpty, page.rawValue)
            XCTAssertFalse(page.subtitle.isEmpty, page.rawValue)
        }
    }

    func testPermissionStatesOfferAnActionOnlyWhenAccessCanChange() {
        XCTAssertNil(SetupAccessState.allowed.actionTitle)
        XCTAssertNil(SetupAccessState.asking.actionTitle)
        XCTAssertEqual(SetupAccessState.notAsked.actionTitle, "Allow")
        XCTAssertEqual(SetupAccessState.unavailable.actionTitle, "Allow")
        XCTAssertEqual(SetupAccessState.denied.actionTitle, "Open Settings")
        let states: [SetupAccessState] = [.allowed, .notAsked, .denied, .asking, .unavailable]
        XCTAssertEqual(Set(states.map(\.label)).count, states.count)
        XCTAssertEqual(SetupAccessState.allowed.label, "Allowed")
        for state in states { XCTAssertFalse(state.label.isEmpty) }
    }

    func testWindowSizesLeaveAUsableSettingsPane() {
        XCTAssertEqual(SetupWindowController.initialContentSize, NSSize(width: 960, height: 714))
        XCTAssertEqual(SetupWindowController.minimumContentSize, NSSize(width: 800, height: 590))
        XCTAssertGreaterThan(SetupWindowController.initialContentSize.width,
                             SetupWindowController.minimumContentSize.width)
        XCTAssertGreaterThan(SetupWindowController.initialContentSize.height,
                             SetupWindowController.minimumContentSize.height)
    }

    func testLongPermissionRowsWrapInsideTheMinimumAndDefaultPaneWidths() {
        let cases: [(String, String, String)] = [
            ("calendar", "Calendar", "Your next meeting and its join link"),
            ("record.circle", "Screen recording", "Record the screen from the notch with the Record tool or ⌃⌥⌘R."),
            ("phone.fill", "Calls and the volume HUD", "Answer call banners and replace the volume and brightness HUD."),
            ("waveform", "Music bars", "System audio makes the bars move with what's playing. Nothing is recorded.")
        ]
        for width in [548.0, 708.0] {
            for scheme in [ColorScheme.light, .dark] {
                for (symbol, title, detail) in cases {
                    let row = SetupPermissionRow(symbol: symbol, title: title, detail: detail,
                                                 state: .denied, action: {})
                        .frame(width: width)
                        .fixedSize(horizontal: false, vertical: true)
                    let host = NSHostingView(rootView: row.environment(\.colorScheme, scheme))
                    let size = host.fittingSize
                    XCTAssertEqual(size.width, width, accuracy: 0.5, title)
                    XCTAssertGreaterThanOrEqual(size.height, 48, title)
                    XCTAssertLessThanOrEqual(size.height, width == 548 ? 76 : 64,
                                             "\(title) must fit the \(width)-point pane without oversized rows")
                }
            }
        }
    }

    func testGroupedPermissionsLeaveRoomForTheHeaderAndFooterAtDefaultSize() {
        // Nine rows must fit in the initial window, rather than recreating the old long form.
        let content = VStack(alignment: .leading, spacing: 18) {
            SetupSection(title: "Everyday essentials") {
                permission("message.fill", "Messages", "Read new messages with Full Disk Access.")
                permission("phone.fill", "Calls and the volume HUD", "Answer calls and show volume and brightness changes.")
                permission("calendar", "Calendar", "Your next meeting and its join link.")
            }
            SetupSection(title: "Capture and devices") {
                permission("record.circle", "Screen recording", "Record the screen from the notch.")
                permission("airpods.gen4", "Bluetooth", "AirPods connection and battery updates.")
                permission("waveform", "Music bars", "Animate with system audio. Nothing is recorded.")
            }
            SetupSection(title: "Playback and Focus") {
                permission("music.note", "Music", "Control playback when Now Playing isn't available.")
                permission("music.note.list", "Spotify", "Control playback when Now Playing isn't available.")
                permission("moon.fill", "Focus", "Show whether a Focus is enabled.")
            }
        }
        .frame(width: 708)
        .fixedSize(horizontal: false, vertical: true)
        let host = NSHostingView(rootView: content)
        XCTAssertGreaterThan(host.fittingSize.height, 9 * 48)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 594,
                                "Keep 120 points for the page header, footer and outer spacing")
    }

    func testPermissionRowRendersItsDescriptionAndSettingsActionWithoutOverlap() async throws {
        let title = "Calls and the volume HUD"
        let detail = "Accessibility lets LeNotch answer call banners and replace volume and brightness controls."
        let row = SetupPermissionRow(symbol: "phone.fill", title: title, detail: detail,
                                     state: .denied, action: {})
            .frame(width: 548)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let size = NSHostingView(rootView: row).fittingSize
        let (window, host) = makeWindow(row, size: size, scheme: .light)
        defer { window.close() }
        let rendered = try await render(host, name: "permission-row")
        let action = try XCTUnwrap(rendered.text.first { normalized($0.value) == "open settings" },
                                   "Settings action is not visible. Read: \(rendered.transcript)")
        let description = rendered.text.filter { $0.frame.maxX <= action.frame.minX }
        let copy = normalized(description.map(\.value).joined(separator: " "))
        XCTAssertTrue(copy.contains(normalized(title)), "Row title is clipped. Read: \(copy)")
        XCTAssertTrue(copy.contains(normalized(detail)), "Row detail is clipped. Read: \(copy)")
        XCTAssertTrue(rendered.text.contains { normalized($0.value).contains(normalized(SetupAccessState.denied.label)) },
                      "Permission status must remain visible beside its action. Read: \(rendered.transcript)")
        XCTAssertGreaterThan(action.frame.minX, 548 - 100)
        XCTAssertLessThan(action.frame.maxX, 548 - 8)
        XCTAssertGreaterThan(action.frame.minY, 0)
        XCTAssertLessThan(action.frame.maxY, size.height)
    }

    func testRemainingPagesRenderWithoutSportsNavigationInBothSizesAndThemes() async throws {
        for page in [SetupPage.permissions, .appearance, .integrations] {
            for size in [SetupWindowController.minimumContentSize, SetupWindowController.initialContentSize] {
                for scheme in [ColorScheme.light, .dark] {
                    let view = SetupView(page: page, done: {})
                        .environment(\.colorScheme, scheme)
                        .frame(width: size.width, height: size.height)
                    let (window, host) = makeWindow(view, size: size, scheme: scheme)
                    defer { window.close() }
                    let name = "\(page.rawValue)-\(Int(size.width))-\(scheme == .dark ? "dark" : "light")"
                    let rendered = try await render(host, name: name, footerHeight: 62)
                    let text = rendered.text
                    for category in SetupPage.allCases {
                        let title = normalized(category.title).split(separator: " ")
                        XCTAssertTrue(text.contains {
                            // Vision sometimes reads the adjacent SF Symbol as a letter prefix.
                            normalized($0.value).split(separator: " ").suffix(title.count).elementsEqual(title)
                                && $0.frame.minX > 12 && $0.frame.maxX < 192
                        }, "Missing \(category.title) navigation in \(name). Read: \(rendered.transcript)")
                    }
                    XCTAssertFalse(text.contains {
                        normalized($0.value).split(separator: " ").contains("sports") && $0.frame.minX < 192
                    }, "Sports must not appear in Setup navigation in \(name). Read: \(rendered.transcript)")
                    XCTAssertTrue(text.contains {
                        normalized($0.value) == normalized(page.title)
                            && $0.frame.minX > 192 && $0.frame.minY > size.height - 80
                    }, "The active page heading is missing or scrolled away in \(name)")
                    let content = normalized(text.filter { $0.frame.minX > 192 }.map(\.value).joined(separator: " "))
                    let expected: [String] = switch page {
                    case .permissions: ["Everyday essentials", "Accessibility", "Calendar", "Bluetooth"]
                    case .appearance: ["Lock-screen artwork", "Album colors on desktop"]
                    case .integrations: ["Notifications in the notch", "Agent sessions"]
                    }
                    for title in expected {
                        XCTAssertTrue(content.contains(normalized(title)), "\(title) is clipped in \(name). Read: \(content)")
                    }
                    let done = try XCTUnwrap(rendered.footerText.first { normalized($0.value) == "done" },
                                             "Done is not visible in \(name). Footer: \(rendered.footerText.map(\.value))")
                    XCTAssertGreaterThan(done.frame.minX, size.width - 130, name)
                    XCTAssertLessThan(done.frame.maxX, size.width - 20, name)
                    XCTAssertGreaterThan(done.frame.minY, 0, name)
                    XCTAssertLessThan(done.frame.maxY, 62, "Done must remain in the fixed footer: \(name)")
                    XCTAssertEqual(host.fittingSize.width, size.width, accuracy: 0.5)
                    XCTAssertEqual(host.fittingSize.height, size.height, accuracy: 0.5)
                }
            }
        }
    }

    private func permission(_ symbol: String, _ title: String, _ detail: String) -> some View {
        SetupPermissionRow(symbol: symbol, title: title, detail: detail, state: .notAsked, action: {})
    }

    private func makeWindow<V: View>(_ view: V, size: NSSize,
                                     scheme: ColorScheme) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        // Do not activate or front the test window, and never call the permission actions.
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private struct RenderedText {
        let value: String
        let frame: NSRect
    }

    private struct RenderedView {
        let text: [RenderedText]
        let footerText: [RenderedText]
        var transcript: String { text.map(\.value).joined(separator: " | ") }
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func render<V: View>(_ host: NSHostingView<V>, name: String,
                                footerHeight: CGFloat? = nil) async throws -> RenderedView {
        for _ in 0..<4 {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }
        host.displayIfNeeded()
        // A never-ordered NSHostingView doesn't expose SwiftUI's virtual AX children. Capture
        // its native AppKit rendering instead: OCR proves the actual text is visible, and its
        // pixel bounds check clipping and overlap without activating a window or clicking it.
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        if let directory = ProcessInfo.processInfo.environment["SETUP_SNAPSHOT_DIR"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent("\(name).png"))
        }
        let size = host.bounds.size
        let text = try recognize(image, in: NSRect(origin: .zero, size: size))
        var footerText: [RenderedText] = []
        if let footerHeight {
            // Whole-window OCR can miss a small button amid a dense permissions page. Recognize
            // the actual footer pixels separately, preserving their coordinates for clipping checks.
            let scale = CGFloat(image.height) / size.height
            let pixelHeight = ceil(footerHeight * scale)
            let footer = try XCTUnwrap(image.cropping(to: CGRect(
                x: 0, y: CGFloat(image.height) - pixelHeight, width: CGFloat(image.width), height: pixelHeight)))
            footerText = try recognize(footer, in: NSRect(x: 0, y: 0, width: size.width, height: pixelHeight / scale))
        }
        XCTAssertFalse(text.isEmpty, "\(name) native capture contains no readable text")
        return RenderedView(text: text, footerText: footerText)
    }

    private func recognize(_ image: CGImage, in bounds: NSRect) throws -> [RenderedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation -> RenderedText? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return RenderedText(value: candidate.string,
                                frame: NSRect(x: bounds.minX + box.minX * bounds.width,
                                              y: bounds.minY + box.minY * bounds.height,
                                              width: box.width * bounds.width, height: box.height * bounds.height))
        }
    }
}
