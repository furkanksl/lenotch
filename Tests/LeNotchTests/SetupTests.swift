import AppKit
import SwiftUI
import SpacesEngine
import Vision
import XCTest
@testable import Lenotch

@MainActor
final class SetupTests: XCTestCase {
    // MARK: Structure

    func testSetupPagesFormOneFlatSidebarWithTheirOwnIcons() {
        XCTAssertEqual(SetupPage.allCases, [.permissions, .appearance, .dictation, .notifications, .agents, .launcher])
        XCTAssertEqual(SetupPage.allCases.map(\.title),
                       ["Permissions", "Appearance", "Dictation", "Notifications", "AI & Agents", "Launcher"])
        XCTAssertEqual(SetupPage.allCases.map(\.id), SetupPage.allCases)
        XCTAssertEqual(Set(SetupPage.allCases.map(\.icon)).count, SetupPage.allCases.count, "each page has its own icon")
        for page in SetupPage.allCases { XCTAssertFalse(page.subtitle.isEmpty, page.rawValue) }
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

    func testWindowRunsItsContentUnderAnInvisibleTitleBarAndFinishesSetupWhenClosed() {
        XCTAssertEqual(SetupWindowController.initialContentSize, NSSize(width: 1000, height: 720))
        XCTAssertEqual(SetupWindowController.minimumContentSize, NSSize(width: 900, height: 640))

        let window = SetupWindowController.makeWindow()
        defer { window.close() }
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView), "the sidebar runs under the traffic lights, as in KLOI")
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.title, "LeNotch Setup", "still named in the Window menu and Mission Control")
        XCTAssertEqual(window.contentMinSize, SetupWindowController.minimumContentSize)

        // No Done button: closing the window is how a settings window is finished.
        let key = "setup.v3.done"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let controller = SetupWindowController()
        XCTAssertTrue(controller.needed)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertFalse(controller.needed)
    }

    func testThemePillFlipsWhatIsShowingAndOtherwiseFollowsTheMac() {
        XCTAssertNil(SetupThemeChoice.scheme(""), "until the pill is used, Setup follows the Mac")
        XCTAssertEqual(SetupThemeChoice.scheme("dark"), .dark)
        XCTAssertEqual(SetupThemeChoice.scheme("light"), .light)
        XCTAssertEqual(SetupThemeChoice.toggled(from: .light), "dark")
        XCTAssertEqual(SetupThemeChoice.toggled(from: .dark), "light")
    }

    // MARK: Icons

    func testSVGPathDataFollowsAbsoluteRelativeAndImplicitCommands() {
        XCTAssertEqual(SVGPathData.path("M5 14L8.5 17.5L19 6.5").boundingRect, CGRect(x: 5, y: 6.5, width: 14, height: 11))
        XCTAssertEqual(SVGPathData.path("m2 2 3 0 0 3z").boundingRect, CGRect(x: 2, y: 2, width: 3, height: 3),
                       "pairs after a move are relative line-tos")
        XCTAssertEqual(SVGPathData.path("M0 0H10V4h-2v2").boundingRect, CGRect(x: 0, y: 0, width: 10, height: 6))
        XCTAssertEqual(SVGPathData.path("M1.5.5L-1-2").boundingRect, CGRect(x: -1, y: -2, width: 2.5, height: 2.5),
                       "numbers can run together, separated by a dot or a sign")
        let curve = SVGPathData.path("M0 0C0 10 10 10 10 0S20 -10 20 0").boundingRect
        XCTAssertEqual(curve.minX, 0, accuracy: 0.001)
        XCTAssertEqual(curve.maxX, 20, accuracy: 0.001)
        XCTAssertEqual(curve.maxY, 7.5, accuracy: 0.01, "the first curve peaks three quarters of the way to its controls")
        XCTAssertEqual(curve.minY, -7.5, accuracy: 0.01, "the smooth curve mirrors the previous control point")
        XCTAssertTrue(SVGPathData.path("").isEmpty)
    }

    func testEveryHugeiconDrawsInsideItsGrid() {
        XCTAssertEqual(SetupIcon.allCases.count, 31)
        for icon in SetupIcon.allCases {
            let path = SetupIconShape(elements: icon.elements).path(in: CGRect(x: 0, y: 0, width: 24, height: 24))
            XCTAssertFalse(path.isEmpty, "\(icon) drew nothing")
            let bounds = path.boundingRect
            XCTAssertGreaterThanOrEqual(bounds.minX, 0.5, "\(icon)")
            XCTAssertGreaterThanOrEqual(bounds.minY, 0.5, "\(icon)")
            XCTAssertLessThanOrEqual(bounds.maxX, 23.5, "\(icon)")
            XCTAssertLessThanOrEqual(bounds.maxY, 23.5, "\(icon)")
            XCTAssertGreaterThan(bounds.width * bounds.height, 30, "\(icon) is suspiciously small: a parse stopped early")
        }
        let scaled = SetupIconShape(elements: SetupIcon.tick.elements).path(in: CGRect(x: 10, y: 20, width: 48, height: 48))
        XCTAssertEqual(scaled.boundingRect, CGRect(x: 20, y: 33, width: 28, height: 22), "scaled to the frame and placed in it")
    }

    // MARK: KLOI's surfaces

    func testSurfacesUseKLOIPaletteInBothAppearances() async throws {
        let swatches: [(name: String, color: Color, light: UInt32, dark: UInt32)] = [
            ("canvas", SetupTheme.canvas, 0xF2F1EF, 0x111110),
            ("card", SetupTheme.card, 0xFFFFFF, 0x171716),
            ("row", SetupTheme.row, 0xFAF9F7, 0x171716),
            ("accent", SetupTheme.accent, 0xFB9049, 0xFB9049),
            ("control: a plain sRGB color", Color(.sRGB, red: 251 / 255, green: 144 / 255, blue: 73 / 255), 0xFB9049, 0xFB9049),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let strip = HStack(spacing: 0) {
                ForEach(swatches.indices, id: \.self) { swatches[$0].color.frame(width: 20, height: 20) }
            }
            .environment(\.colorScheme, scheme)
            let (window, host) = makeWindow(strip, size: NSSize(width: 20 * swatches.count, height: 20), scheme: scheme)
            defer { window.close() }
            let image = try await render(host, name: "palette-\(scheme == .dark ? "dark" : "light")", requireText: false).image
            for (index, swatch) in swatches.enumerated() {
                assertPixel(image, x: CGFloat(index * 20 + 10), y: 10, in: host.bounds.size,
                            is: scheme == .dark ? swatch.dark : swatch.light, "\(swatch.name), \(scheme)")
            }
        }
    }

    func testSwitchFillsOrangeOnlyWhenOn() async throws {
        for on in [false, true] {
            let toggle = Toggle("Feature", isOn: .constant(on)).labelsHidden().toggleStyle(SetupSwitchStyle())
                .padding(4).background(SetupTheme.card)
            let (window, host) = makeWindow(toggle, size: NSSize(width: 62, height: 40), scheme: .light)
            defer { window.close() }
            let image = try await render(host, name: "switch-\(on ? "on" : "off")", requireText: false).image
            let orange = countPixels(image) { r, g, b in r > 230 && (120...170).contains(g) && b < 110 }
            if on {
                XCTAssertGreaterThan(orange, 400, "an on switch is KLOI's orange")
            } else {
                XCTAssertEqual(orange, 0, "an off switch has no orange")
            }
        }
    }

    // MARK: Rows and cards

    func testDictationProgressCardShowsThePercentage() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let card = SetupProgressCard(status: "Downloading Nemotron 3.5…", progress: 0.47)
                .frame(width: 520).padding(16).background(SetupTheme.card)
                .environment(\.colorScheme, scheme)
            let size = NSHostingView(rootView: card).fittingSize
            let (window, host) = makeWindow(card, size: size, scheme: scheme)
            defer { window.close() }
            let text = normalized(try await render(host, name: "progress-47-\(scheme == .dark ? "dark" : "light")").transcript)
            XCTAssertTrue(text.contains("47"), "The download percentage must be visible. Read: \(text)")
            XCTAssertTrue(text.contains("nemotron"), "What's downloading must be visible. Read: \(text)")
        }
    }

    func testPermissionRowShowsItsTextStateAndActionWithoutOverlap() async throws {
        let title = "Calls and the volume HUD"
        let detail = "Answer call banners and replace the volume and brightness controls."
        for width in [560.0, 640.0] {
            for scheme in [ColorScheme.light, .dark] {
                let row = SetupPermissionRow(icon: .accessibility, title: title, detail: detail, state: .denied, action: {})
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(SetupTheme.card)
                    .environment(\.colorScheme, scheme)
                let size = NSHostingView(rootView: row).fittingSize
                XCTAssertGreaterThanOrEqual(size.height, 70, "a row keeps KLOI's roomy padding")
                XCTAssertLessThanOrEqual(size.height, 110, "no oversized rows at \(width) pt")
                let (window, host) = makeWindow(row, size: size, scheme: scheme)
                defer { window.close() }
                let rendered = try await render(host, name: "permission-row-\(Int(width))-\(scheme == .dark ? "dark" : "light")")
                let actionBounds = NSRect(x: width - 150, y: 0, width: 150, height: size.height)
                let action = try XCTUnwrap(try recognize(rendered.image, bounds: host.bounds, region: actionBounds)
                    .first { normalized($0.value) == "open settings" }, "Settings action is not visible. Read: \(rendered.transcript)")
                let copy = try recognize(rendered.image, bounds: host.bounds, region: NSRect(x: 0, y: 0, width: width - 150, height: size.height))
                let words = normalized(copy.map(\.value).joined(separator: " "))
                XCTAssertTrue(words.contains(normalized(title)), "Row title is clipped. Read: \(words)")
                XCTAssertTrue(words.contains(normalized(detail)), "Row detail is clipped. Read: \(words)")
                XCTAssertTrue(words.contains("needs access"), "A denied permission says so beside its name. Read: \(words)")
                XCTAssertTrue(copy.allSatisfy { $0.frame.maxX < action.frame.minX }, "Row copy overlaps its action")
                XCTAssertLessThan(action.frame.maxX, width - 8)
            }
        }
    }

    // MARK: The window

    /// What each page must show without scrolling at the initial size (and the least it may show at the minimum).
    private func expectations(for page: SetupPage) -> (always: [String], initialOnly: [String]) {
        switch page {
        case .permissions: (["microphone", "accessibility"], ["everyday", "calendar", "bluetooth"])
        case .appearance: (["lock screen artwork", "album colors"], ["original wallpaper"])
        case .dictation: (["anywhere", "speech model", "fluid speech pro"], ["nemotron", "hold fn to talk", "toggle dictation"])
        case .notifications: (["notifications in the notch"], ["full disk access", "notification settings"])
        case .agents: (["chatgpt"], ["coding agents", "agent sessions"])
        case .launcher: (["notch preview", "configure"], ["open with"])
        }
    }

    func testEveryPageRendersOnKLOICanvasWithTheWholeSidebarInBothSizesAndThemes() async throws {
        let suite = "lenotch.test.setup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for page in SetupPage.allCases {
            for size in [SetupWindowController.minimumContentSize, SetupWindowController.initialContentSize] {
                for scheme in [ColorScheme.light, .dark] {
                    let view = SetupView(page: page)
                        .defaultAppStorage(defaults)
                        .environment(\.colorScheme, scheme)
                        .frame(width: size.width, height: size.height)
                    let (window, host) = makeWindow(view, size: size, scheme: scheme)
                    defer { window.close() }
                    let name = "\(page.rawValue)-\(Int(size.width))-\(scheme == .dark ? "dark" : "light")"
                    let rendered = try await render(host, name: name)
                    let sidebar = rendered.text.filter { $0.frame.maxX < 240 }
                    let sidebarWords = normalized(sidebar.map(\.value).joined(separator: " "))
                    // Every destination, the selected one included, stays readable in the sidebar.
                    for item in SetupPage.allCases {
                        // Vision reads the "I" of "AI" as an "l"; the rest of the name is enough to find it.
                        let key = item == .agents ? "agents" : normalized(item.title)
                        XCTAssertTrue(sidebarWords.contains(key),
                                      "Sidebar is missing \(item.title) in \(name). Read: \(sidebarWords)")
                    }
                    XCTAssertTrue(sidebarWords.contains("lenotch"), "The brand sits atop the sidebar in \(name)")
                    XCTAssertTrue(sidebarWords.contains("theme"), "The theme pill sits at its foot in \(name)")

                    let detail = normalized(rendered.text.filter { $0.frame.minX > 250 }.map(\.value).joined(separator: " "))
                    let heading = page == .agents ? "agents" : normalized(page.title)
                    XCTAssertTrue(detail.contains(heading), "\(page.title) heading is missing in \(name). Read: \(detail)")
                    let expected = expectations(for: page)
                    for phrase in expected.always + (size == SetupWindowController.initialContentSize ? expected.initialOnly : []) {
                        XCTAssertTrue(detail.contains(phrase), "\(page.title) is missing \"\(phrase)\" in \(name). Read: \(detail)")
                    }
                    let words = " " + normalized(rendered.transcript) + " "
                    for removed in ["sports", "focus status", "done"] {
                        XCTAssertFalse(words.contains(" \(removed) "), "\(removed) must stay out of Setup in \(name)")
                    }
                    if page == .dictation {
                        for hidden in ["cleanup", "clean up dictated text", "qwen"] {
                            XCTAssertFalse(words.contains(hidden), "\(hidden) must stay hidden in \(name)")
                        }
                    }

                    // KLOI's surfaces: the canvas around the sidebar, the white (or #171716) card for the page.
                    assertPixel(rendered.image, x: 120, y: size.height - 150, in: size,
                                is: scheme == .dark ? 0x111110 : 0xF2F1EF, "sidebar canvas in \(name)")
                    assertPixel(rendered.image, x: size.width - 30, y: size.height / 2, in: size,
                                is: scheme == .dark ? 0x171716 : 0xFFFFFF, "page card in \(name)")
                    assertPixel(rendered.image, x: size.width - 8, y: size.height / 2, in: size,
                                is: scheme == .dark ? 0x111110 : 0xF2F1EF, "canvas margin right of the card in \(name)")
                }
            }
        }
    }

    func testDictationExplainsFnModeAndMenuOnlyModeInBothThemes() async throws {
        let suite = "lenotch.test.setup.shortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: DictationInputSettings.toggleShortcutKey)
        for pushToTalk in [false, true] {
            defaults.set(pushToTalk, forKey: DictationInputSettings.pushToTalkKey)
            for scheme in [ColorScheme.light, .dark] {
                let size = SetupWindowController.minimumContentSize
                let view = SetupView(page: .dictation)
                    .defaultAppStorage(defaults)
                    .environment(\.colorScheme, scheme)
                    .frame(width: size.width, height: size.height)
                let (window, host) = makeWindow(view, size: size, scheme: scheme)
                defer { window.close() }
                let rendered = try await render(host, name: "dictation-fn-\(pushToTalk)-\(scheme)")
                let words = normalized(rendered.transcript)
                XCTAssertTrue(words.contains(pushToTalk ? "hold fn to talk" : "dictate from the notch"), words)
                XCTAssertTrue(words.contains(pushToTalk ? "release to paste" : "notch menu"), words)
                XCTAssertTrue(words.contains("esc cancels"), words)
                XCTAssertFalse(words.contains("cleanup"), "Cleanup remains hidden in both shortcut modes")
            }
        }
    }

    // MARK: Pixels

    func testDesktopTransitionControlsRenderWithoutStartingTheSystemEngine() async throws {
        let suite = "lenotch.test.setup.spaces.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DesktopTransitionsModel(defaults: defaults) {
            XCTFail("Rendering settings must never create system controls")
            return DesktopTransitionsEngine()
        }
        for enabled in [false, true] {
            model.setEnabled(enabled)
            for scheme in [ColorScheme.light, .dark] {
                let view = ScrollView {
                    SetupDesktopTransitions(model: model).padding(24)
                }
                .frame(width: 640, height: 760).background(SetupTheme.card)
                .environment(\.colorScheme, scheme)
                let (window, host) = makeWindow(view, size: NSSize(width: 640, height: 760), scheme: scheme)
                defer { window.close() }
                let result = try await render(host, name: "desktop-transitions-\(enabled)-\(scheme)")
                let words = normalized(result.transcript)
                XCTAssertTrue(words.contains("custom desktop transitions"), words)
                if enabled {
                    for text in ["transition", "lightweight", "animation speed", "swipe sensitivity", "rounded desktop corners"] {
                        XCTAssertTrue(words.contains(text), "Missing \(text): \(words)")
                    }
                } else {
                    XCTAssertTrue(words.contains("off by default"), words)
                    XCTAssertFalse(words.contains("animation speed"), "No configuration clutter while disabled")
                }
            }
        }
        XCTAssertEqual(model.status, .off)
    }

    /// Checks one pixel against a hex color. `x` and `y` are in points from the top-left. The capture is color-matched
    /// into sRGB first: the offscreen bitmap is tagged with the display's space, so its raw numbers aren't sRGB.
    private func assertPixel(_ image: CGImage, x: CGFloat, y: CGFloat, in size: NSSize, is hex: UInt32, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let pixels = srgbPixels(image)
        let scale = CGFloat(image.width) / size.width
        let px = min(Int(x * scale), image.width - 1), py = min(Int(y * scale), image.height - 1)
        let offset = (py * image.width + px) * 4
        let actual = [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
        let wanted = [Int(hex >> 16 & 0xFF), Int(hex >> 8 & 0xFF), Int(hex & 0xFF)]
        XCTAssertTrue(zip(actual, wanted).allSatisfy { abs($0 - $1) <= 3 },
                      "\(message): got \(actual), wanted \(wanted)", file: file, line: line)
    }

    /// RGBA bytes, top row first, color-matched into sRGB.
    private func srgbPixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func countPixels(_ image: CGImage, where test: (Int, Int, Int) -> Bool) -> Int {
        let pixels = srgbPixels(image)
        return stride(from: 0, to: pixels.count, by: 4).filter {
            test(Int(pixels[$0]), Int(pixels[$0 + 1]), Int(pixels[$0 + 2]))
        }.count
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
        var transcript: String { text.map(\.value).joined(separator: " | ") }
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func render<V: View>(_ host: NSHostingView<V>, name: String, requireText: Bool = true) async throws -> RenderedView {
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
        if requireText { XCTAssertFalse(text.isEmpty, "\(name) native capture contains no readable text") }
        return RenderedView(image: image, text: text)
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
