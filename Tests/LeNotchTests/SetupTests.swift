import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

@MainActor
final class SetupTests: XCTestCase {
    func testSetupPagesKeepTheirNamesAndStableIdentity() {
        XCTAssertEqual(SetupPage.allCases, [.permissions, .appearance, .dictation, .integrations])
        XCTAssertEqual(SetupPage.allCases.map(\.title), ["Permissions", "Appearance", "Dictation", "Integrations"])
        XCTAssertEqual(SetupPage.allCases.map(\.id), SetupPage.allCases)
        XCTAssertEqual(Set(SetupPage.allCases.map(\.symbol)).count, 4)
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
        XCTAssertEqual(SetupWindowController.initialContentSize, NSSize(width: 900, height: 740))
        XCTAssertEqual(SetupWindowController.minimumContentSize, NSSize(width: 760, height: 600))
        XCTAssertGreaterThan(SetupWindowController.initialContentSize.width,
                             SetupWindowController.minimumContentSize.width)
        XCTAssertGreaterThan(SetupWindowController.initialContentSize.height,
                             SetupWindowController.minimumContentSize.height)
    }

    func testDictationDownloadPercentageIsVisibleInTheModelRow() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let indicator = DictationDownloadIndicator(
                progress: 0.47, statusMessage: "Downloading Nemotron 3.5…"
            )
            .padding(18)
            .frame(width: 548)
            .background(SetupTheme.canvas)
            .environment(\.colorScheme, scheme)
            let height = NSHostingView(rootView: indicator).fittingSize.height
            let (window, host) = makeWindow(indicator,
                                            size: NSSize(width: 548, height: height), scheme: scheme)
            defer { window.close() }
            let rendered = try await render(host, name: "dictation-download-47-\(scheme == .dark ? "dark" : "light")")
            let text = normalized(rendered.transcript)
            // OCR normalization strips punctuation such as %, but still verifies the visible digits.
            XCTAssertTrue(text.contains("47"), "The download percentage must be visible beside its model. Read: \(text)")
            XCTAssertTrue(text.contains("nemotron"), "The model name must be visible with progress. Read: \(text)")
        }
    }

    func testPermissionFiltersDistinguishAllowedFromMissingAndPendingAccess() {
        let states: [SetupAccessState] = [.notAsked, .allowed, .denied, .asking, .unavailable, .allowed]
        XCTAssertEqual(SetupPermissionFilter.allCases.map(\.id), SetupPermissionFilter.allCases)
        XCTAssertEqual(Set(SetupPermissionFilter.allCases.map(\.title)).count, 3)
        XCTAssertEqual(states.filter { SetupPermissionFilter.all.includes($0) }, states)
        XCTAssertEqual(states.filter { SetupPermissionFilter.notEnabled.includes($0) },
                       [.notAsked, .denied, .asking, .unavailable])
        XCTAssertEqual(states.filter { SetupPermissionFilter.allowed.includes($0) }, [.allowed, .allowed])
        for state in [SetupAccessState.allowed, .notAsked, .denied, .asking, .unavailable] {
            XCTAssertTrue(SetupPermissionFilter.all.includes(state), state.label)
            XCTAssertNotEqual(SetupPermissionFilter.notEnabled.includes(state),
                              SetupPermissionFilter.allowed.includes(state), state.label)
        }
    }

    func testLongPermissionRowsWrapInsideTheMinimumAndDefaultPaneWidths() {
        let cases: [(String, String, String)] = [
            ("calendar", "Calendar", "Your next meeting and its join link"),
            ("phone.fill", "Calls and the volume HUD", "Answer call banners and replace the volume and brightness HUD."),
            ("waveform", "Music bars", "System audio makes the bars move with what's playing. Nothing is recorded.")
        ]
        for width in [548.0, 696.0, 760.0] {
            for scheme in [ColorScheme.light, .dark] {
                for (symbol, title, detail) in cases {
                    let row = SetupPermissionRow(symbol: symbol, title: title, detail: detail,
                                                 state: .denied, action: {})
                        .frame(width: width)
                        .fixedSize(horizontal: false, vertical: true)
                    let host = NSHostingView(rootView: row.environment(\.colorScheme, scheme))
                    let size = host.fittingSize
                    XCTAssertEqual(size.width, width, accuracy: 0.5, title)
                    XCTAssertGreaterThanOrEqual(size.height, 64, title)
                    XCTAssertLessThanOrEqual(size.height, width == 548 ? 96 : 82,
                                             "\(title) must fit the \(width)-point pane without oversized rows")
                }
            }
        }
    }

    func testGroupedPermissionsScrollAtTheirReadableNaturalHeight() async throws {
        // Layout fixture: both optional players are present and all nine rows are allowed.
        // It must scroll, not squeeze every permission above the footer by reducing row heights.
        for width in [696.0, 760.0] {
            for scheme in [ColorScheme.light, .dark] {
                let content = permissionGroups.frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                let naturalHeight = NSHostingView(rootView: content.environment(\.colorScheme, scheme)).fittingSize.height
                XCTAssertGreaterThanOrEqual(naturalHeight, 9 * 64)
                XCTAssertLessThanOrEqual(naturalHeight, 940)
                let (fixtureWindow, fixtureHost) = makeWindow(content,
                    size: NSSize(width: width, height: naturalHeight), scheme: scheme)
                defer { fixtureWindow.close() }
                let fixture = try await render(fixtureHost,
                    name: "permission-groups-\(Int(width))-\(scheme == .dark ? "dark" : "light")")
                let fixtureText = normalized(fixture.transcript)
                XCTAssertFalse(fixtureText.contains("focus status"),
                               "The removed Focus permission must not appear in Setup")
                XCTAssertTrue(fixtureText.contains(normalized(SetupScreenCaptureAccess.title)),
                              "Video's Screen Recording permission must remain visible")
                XCTAssertTrue(fixtureText.contains("music bars"),
                              "System audio access for music bars must remain visible")
                let viewportHeight = SetupWindowController.minimumContentSize.height - 72 - 64
                let viewport = ScrollView { content }.frame(width: width, height: viewportHeight)
                let (window, host) = makeWindow(viewport,
                                              size: NSSize(width: width, height: viewportHeight), scheme: scheme)
                defer { window.close() }
                let scroll = try XCTUnwrap(descendant(of: host, matching: NSScrollView.self))
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height,
                                     "The permission list must retain readable rows and allow scrolling")
                XCTAssertEqual(document.bounds.height, naturalHeight, accuracy: 2)
            }
        }
    }

    func testPermissionRowRendersItsDescriptionAndSettingsActionWithoutOverlap() async throws {
        let title = "Calls and the volume HUD"
        let detail = "Accessibility lets LeNotch answer call banners and replace volume and brightness controls."
        for width in [548.0, 696.0] {
            for scheme in [ColorScheme.light, .dark] {
                let row = SetupPermissionRow(symbol: "phone.fill", title: title, detail: detail,
                                             state: .denied, action: {})
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(SetupTheme.canvas)
                    .environment(\.colorScheme, scheme)
                let size = NSHostingView(rootView: row).fittingSize
                let (window, host) = makeWindow(row, size: size, scheme: scheme)
                defer { window.close() }
                let rendered = try await render(host, name: "permission-row-\(Int(width))-\(scheme == .dark ? "dark" : "light")")
                // Read each column separately so Vision cannot merge the detail and action into one line.
                let accessoryBounds = NSRect(x: width - 128, y: 0, width: 128, height: size.height)
                let accessory = try recognize(rendered.image, bounds: host.bounds, region: accessoryBounds)
                let action = try XCTUnwrap(accessory.first { normalized($0.value) == "open settings" },
                                          "Settings action is not visible. Read: \(rendered.transcript)")
                let copyBounds = NSRect(x: 0, y: 0, width: width - 128, height: size.height)
                let description = try recognize(rendered.image, bounds: host.bounds, region: copyBounds)
                let copy = normalized(description.map(\.value).joined(separator: " "))
                XCTAssertTrue(copy.contains(normalized(title)), "Row title is clipped. Read: \(copy)")
                XCTAssertTrue(copy.contains(normalized(detail)), "Row detail is clipped. Read: \(copy)")
                XCTAssertTrue(copy.contains(normalized(SetupAccessState.denied.label)),
                              "Permission status must remain visible near its title. Read: \(copy)")
                XCTAssertTrue(description.allSatisfy { $0.frame.maxX < action.frame.minX },
                              "Row copy overlaps its Settings action")
                XCTAssertGreaterThan(action.frame.minX, width - 128)
                XCTAssertLessThan(action.frame.maxX, width - 8)
                XCTAssertGreaterThan(action.frame.minY, 0)
                XCTAssertLessThan(action.frame.maxY, size.height)
            }
        }
    }

    func testRemainingPagesRenderWithoutSportsNavigationInBothSizesAndThemes() async throws {
        for page in SetupPage.allCases {
            for size in [SetupWindowController.minimumContentSize, SetupWindowController.initialContentSize] {
                for scheme in [ColorScheme.light, .dark] {
                    let view = SetupView(page: page, done: {})
                        .environment(\.colorScheme, scheme)
                        .frame(width: size.width, height: size.height)
                    let (window, host) = makeWindow(view, size: size, scheme: scheme)
                    defer { window.close() }
                    let name = "\(page.rawValue)-\(Int(size.width))-\(scheme == .dark ? "dark" : "light")"
                    let rendered = try await render(host, name: name, footerHeight: 64)
                    let text = rendered.text
                    try assertWindowChrome(rendered, page: page, size: size, name: name)
                    let header = try XCTUnwrap(text.first {
                        normalized($0.value) == normalized(page.title)
                            && $0.frame.maxY < size.height - 72 && $0.frame.minY > size.height - 160
                    }, "The active page heading is missing or scrolled away in \(name). Read: \(rendered.transcript)")
                    // Vision includes glyph overhang outside the text layout's 32-point inset.
                    XCTAssertGreaterThanOrEqual(header.frame.minX, 28,
                                                "Page heading must remain within the content padding in \(name)")
                    let content = normalized(text.filter {
                        $0.frame.maxY < size.height - 72 && $0.frame.minY > 64
                    }.map(\.value).joined(separator: " "))
                    switch page {
                    case .permissions:
                        XCTAssertFalse(content.contains("focus status"), name)
                        for title in ["Everyday essentials", "Calendar", "Bluetooth"] {
                            let row = try XCTUnwrap(text.first { normalized($0.value).contains(normalized(title)) },
                                                   "Priority permission \(title) is missing in \(name). Read: \(content)")
                            XCTAssertLessThan(row.frame.maxY, header.frame.minY, name)
                            XCTAssertGreaterThan(row.frame.minY, 64, "Priority content is under the footer in \(name)")
                        }
                        let scroll = try XCTUnwrap(descendant(of: host, matching: NSScrollView.self))
                        let document = try XCTUnwrap(scroll.documentView)
                        let bottom = document.isFlipped
                            ? max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
                            : document.bounds.minY
                        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: bottom))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        let scrolled = try await render(host, name: name + "-bottom", footerHeight: 64)
                        XCTAssertFalse(normalized(scrolled.transcript).contains("focus status"), name)
                        let disk = try XCTUnwrap(scrolled.text.first { normalized($0.value).contains("full disk access") },
                                                "Full Disk Access must be reachable by scrolling in \(name). Read: \(scrolled.transcript)")
                        XCTAssertGreaterThan(disk.frame.minY, 64, "Last permission is covered by the footer in \(name)")
                        XCTAssertLessThan(disk.frame.maxY, size.height - 72, name)
                        try assertWindowChrome(scrolled, page: page, size: size, name: name + "-bottom")
                    case .appearance:
                        XCTAssertTrue(content.contains("lock screen"), "Lock-screen preference is clipped in \(name). Read: \(content)")
                        XCTAssertTrue(content.contains("desktop"), "Desktop preference is clipped in \(name). Read: \(content)")
                    case .dictation:
                        XCTAssertTrue(content.contains("fluid speech pro"), "The default speech model is missing in \(name). Read: \(content)")
                        XCTAssertTrue(content.contains("nemotron"), "The streaming speech model is missing in \(name). Read: \(content)")
                    case .integrations:
                        XCTAssertTrue(content.contains("notifications"), "Notifications are clipped in \(name). Read: \(content)")
                        XCTAssertTrue(content.contains("agent sessions"), "Agent sessions are clipped in \(name). Read: \(content)")
                        let scroll = try XCTUnwrap(descendant(of: host, matching: NSScrollView.self))
                        let document = try XCTUnwrap(scroll.documentView)
                        let offset = min(380, max(0, document.bounds.height - scroll.contentView.bounds.height))
                        let y = document.isFlipped ? offset : document.bounds.maxY - offset - scroll.contentView.bounds.height
                        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        let account = try await render(host, name: name + "-ask")
                        let visible = normalized(account.transcript)
                        XCTAssertTrue(visible.contains("chatgpt account"),
                                      "ChatGPT connection must be reachable in \(name). Read: \(visible)")
                        XCTAssertTrue(visible.contains("connect chatgpt") || visible.contains("connected"),
                                      "ChatGPT connection state/action must be visible in \(name). Read: \(visible)")
                    }
                    XCTAssertEqual(host.fittingSize.width, size.width, accuracy: 0.5)
                    XCTAssertEqual(host.fittingSize.height, size.height, accuracy: 0.5)
                }
            }
        }
    }

    private var permissionGroups: some View {
        VStack(alignment: .leading, spacing: 24) {
            SetupSection(title: "Everyday essentials") {
                permission("calendar", "Calendar", "Upcoming meetings and your daily agenda.")
                permission("headphones", "Bluetooth", "AirPods connections and battery levels.")
            }
            SetupSection(title: "Dictation") {
                permission("mic", "Microphone", "Record speech while dictation is active.")
                permission("accessibility", "Accessibility", "Insert text in your focused app.")
            }
            SetupSection(title: "Media & capture") {
                permission("music.note", "Music automation", "Fallback playback controls for Music.")
                permission("play.circle", "Spotify automation", "Fallback playback controls for Spotify.")
                permission("waveform", "Music bars", "Live waveform from system audio. Play music to test.")
                permission("play.rectangle", SetupScreenCaptureAccess.title, SetupScreenCaptureAccess.detail)
            }
            SetupSection(title: "Messages & notifications") {
                permission("externaldrive", "Full Disk Access", "Local Messages and stored macOS notifications.")
            }
        }
    }

    private func permission(_ symbol: String, _ title: String, _ detail: String) -> some View {
        SetupPermissionRow(symbol: symbol, title: title, detail: detail, state: .allowed)
    }

    private func assertWindowChrome(_ rendered: RenderedView, page: SetupPage, size: NSSize, name: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        for category in SetupPage.allCases {
            let title = normalized(category.title)
            let label = try XCTUnwrap(rendered.text.first {
                // Vision can merge adjacent tab labels in the compact four-tab navigation.
                normalized($0.value).contains(title)
                    && $0.frame.minY > size.height - 72 && $0.frame.minX > size.width * 0.35
            }, "Missing top navigation item \(category.title) in \(name). Read: \(rendered.transcript)",
                                     file: file, line: line)
            XCTAssertLessThan(label.frame.maxY, size.height - 8, name, file: file, line: line)
            XCTAssertLessThan(label.frame.maxX, size.width - 16, name, file: file, line: line)
        }
        XCTAssertFalse(rendered.text.contains { normalized($0.value).split(separator: " ").contains("sports") },
                       "Sports must stay removed from Setup in \(name)", file: file, line: line)
        let done = try XCTUnwrap(rendered.footerText.first { normalized($0.value) == "done" },
                                "Done is missing in \(name). Footer: \(rendered.footerText.map(\.value))", file: file, line: line)
        XCTAssertLessThan(done.frame.maxY, 64, "Done must stay inside the fixed footer in \(name)", file: file, line: line)
        XCTAssertGreaterThan(done.frame.minY, 8, "Done is clipped against the footer in \(name)", file: file, line: line)
        XCTAssertGreaterThan(done.frame.minX, size.width - 140, name, file: file, line: line)
        XCTAssertLessThan(done.frame.maxX, size.width - 20, name, file: file, line: line)
        let note = try XCTUnwrap(rendered.footerText.first {
            normalized($0.value).contains(page == .permissions ? "access updates" : "preferences save")
        }, "Footer note is missing in \(name). Footer: \(rendered.footerText.map(\.value))", file: file, line: line)
        XCTAssertGreaterThan(note.frame.minX, 24, name, file: file, line: line)
        XCTAssertGreaterThan(note.frame.minY, 8, name, file: file, line: line)
        XCTAssertLessThan(note.frame.maxX, done.frame.minX - 8,
                          "Footer note overlaps Done in \(name)", file: file, line: line)
    }

    private func descendant<T: NSView>(of view: NSView, matching type: T.Type) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendant(of: child, matching: type) { return match }
        }
        return nil
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
        let image: CGImage
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
        return RenderedView(image: image, text: text, footerText: footerText)
    }

    private func recognize(_ image: CGImage, bounds: NSRect, region: NSRect) throws -> [RenderedText] {
        let scaleX = CGFloat(image.width) / bounds.width
        let scaleY = CGFloat(image.height) / bounds.height
        let pixels = CGRect(x: (region.minX - bounds.minX) * scaleX,
                            y: (bounds.maxY - region.maxY) * scaleY,
                            width: region.width * scaleX, height: region.height * scaleY)
        let crop = try XCTUnwrap(image.cropping(to: pixels))
        return try recognize(crop, in: region)
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
