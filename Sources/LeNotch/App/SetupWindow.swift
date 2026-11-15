import AppKit
import SwiftUI

enum SetupPage: String, CaseIterable, Identifiable {
    case permissions, appearance, dictation, notifications, agents, launcher

    var id: Self { self }

    var title: String {
        switch self {
        case .permissions: "Permissions"
        case .appearance: "Appearance"
        case .dictation: "Dictation"
        case .notifications: "Notifications"
        case .agents: "AI & Agents"
        case .launcher: "Launcher"
        }
    }

    var icon: SetupIcon {
        switch self {
        case .permissions: .shield
        case .appearance: .palette
        case .dictation: .mic
        case .notifications: .bell
        case .agents: .aiBrain
        case .launcher: .grid
        }
    }

    var subtitle: String {
        switch self {
        case .permissions: "Allow only what you use. Every permission is optional, and macOS keeps track of each one."
        case .appearance: "Bring your music to the lock screen and desktop. Your wallpaper always comes back."
        case .dictation: "Speak in any app. Speech is recognized on this Mac with a model you choose."
        case .notifications: "Show new notifications in the notch as they arrive."
        case .agents: "Ask ChatGPT from the notch, and follow your Claude and Codex sessions."
        case .launcher: "Open your apps, folders and websites straight from the notch."
        }
    }
}

/// Setup's window: KLOI's settings layout, with the traffic lights over the sidebar and no title bar of its own.
/// Closing the window finishes setup; there is nothing to confirm.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let initialContentSize = NSSize(width: 1000, height: 720)
    static let minimumContentSize = NSSize(width: 900, height: 640)
    private static let doneKey = "setup.v3.done"
    private var window: NSWindow?

    var needed: Bool { !UserDefaults.standard.bool(forKey: Self.doneKey) }

    static func makeWindow(page: SetupPage = .permissions) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: initialContentSize),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "LeNotch Setup"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentMinSize = minimumContentSize
        w.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .setupHex(0x111110) : .setupHex(0xF2F1EF)
        }
        w.contentView = ContentHostingView(rootView: SetupView(page: page))
        return w
    }

    func show() {
        if window == nil {
            let w = Self.makeWindow()
            w.delegate = self
            // Only the frame is persisted. Visiting Setup never changes a feature or requests access by itself.
            w.setFrameAutosaveName("LeNotch.Setup.v4")
            if !w.setFrameUsingName("LeNotch.Setup.v4") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
    }
}

/// Setup's own light or dark choice, from the theme pill. Empty follows the Mac.
enum SetupThemeChoice {
    static let key = "lenotch.setup.theme"

    static func scheme(_ stored: String) -> ColorScheme? {
        switch stored {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    /// The pill flips whatever is showing now.
    static func toggled(from showing: ColorScheme) -> String { showing == .dark ? "light" : "dark" }
}

struct SetupView: View {
    @State private var page: SetupPage
    @State private var revealFullDiskAccess = false
    @AppStorage(SetupThemeChoice.key) private var theme = ""

    init(page: SetupPage = .permissions) {
        _page = State(initialValue: page)
    }

    var body: some View {
        let scheme = SetupThemeChoice.scheme(theme)
        HStack(spacing: 0) {
            SetupSidebar(page: $page) { revealFullDiskAccess = false }
                .frame(width: 240)
            content
                .padding(.top, 20).padding(.trailing, 20).padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SetupTheme.canvas)
        .ignoresSafeArea()
        .frame(minWidth: SetupWindowController.minimumContentSize.width,
               minHeight: SetupWindowController.minimumContentSize.height)
        .background(SetupWindowAppearance(scheme: scheme))
        .modifier(SetupSchemeOverride(scheme: scheme))
        .tint(SetupTheme.accent)
    }

    private var cardShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: .init(topLeading: 48, bottomLeading: 48, bottomTrailing: 16, topTrailing: 16),
                               style: .continuous)
    }

    private var content: some View {
        ScrollViewReader { scroll in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 40) {
                    SetupPageHeader(title: page.title, subtitle: page.subtitle)
                    pageBody(scroll)
                }
                .frame(maxWidth: 640, alignment: .topLeading)
                .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 64)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            // A new page starts at its top.
            .id(page)
        }
        .background(SetupTheme.card)
        .clipShape(cardShape)
        .overlay(cardShape.strokeBorder(SetupTheme.ink(0.03, 0.08), lineWidth: 1))
    }

    @ViewBuilder private func pageBody(_ scroll: ScrollViewProxy) -> some View {
        switch page {
        case .permissions: SetupPermissionsPage(revealFullDiskAccess: $revealFullDiskAccess, scroll: scroll)
        case .appearance: SetupAppearancePage()
        case .dictation: SetupDictationPage { open(.permissions) }
        case .notifications:
            SetupNotificationsPage {
                revealFullDiskAccess = true
                page = .permissions
            }
        case .agents: SetupAgentsPage()
        case .launcher: SetupLauncherPage()
        }
    }

    private func open(_ item: SetupPage) {
        revealFullDiskAccess = false
        page = item
    }
}

// MARK: - Sidebar

private struct SetupSidebar: View {
    @Binding var page: SetupPage
    var onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("LeNotch").font(.system(size: 18, weight: .heavy)).tracking(-0.45)
                    .foregroundStyle(SetupTheme.ink(1, 1))
            }
            .padding(.horizontal, 32).padding(.top, 48).padding(.bottom, 24)
            .accessibilityElement(children: .combine)

            VStack(spacing: 6) {
                ForEach(Array(SetupPage.allCases.enumerated()), id: \.element) { index, item in
                    SetupNavItem(page: item, selected: page == item) {
                        onSelect()
                        page = item
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Setup categories")

            Spacer(minLength: 16)

            HStack {
                Text("Theme").font(.system(size: 13, weight: .bold)).tracking(-0.3).foregroundStyle(SetupTheme.ink(0.75, 0.8))
                Spacer(minLength: 8)
                SetupThemeToggle()
            }
            .padding(8).padding(.leading, 8)
            .background(SetupTheme.ink(0.025, 0.035), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(SetupTheme.ink(0.04, 0.06), lineWidth: 1))
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SetupWindowDragArea())
    }
}

private struct SetupNavItem: View {
    let page: SetupPage
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SetupIconView(icon: page.icon, size: 22, lineWidth: 1.65)
                    .foregroundStyle(selected ? SetupTheme.ink(0.8, 0.85)
                                     : hovered ? SetupTheme.ink(0.6, 0.65) : SetupTheme.ink(0.4, 0.35))
                Text(page.title).font(.system(size: 13, weight: .medium)).tracking(-0.3)
                    .foregroundStyle(selected ? SetupTheme.ink(0.85, 0.9)
                                     : hovered ? SetupTheme.ink(0.75, 0.75) : SetupTheme.ink(0.55, 0.45))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? SetupTheme.ink(0.035, 0.06) : hovered ? SetupTheme.ink(0.025, 0.04) : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(SetupTheme.accent).frame(width: 2, height: 16) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("setup-\(page.rawValue)")
    }
}

/// KLOI's theme pill: a sliding knob over a sun and a moon.
private struct SetupThemeToggle: View {
    @AppStorage(SetupThemeChoice.key) private var theme = ""
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dark = scheme == .dark
        let spring: Animation? = reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.5)
        Button {
            withAnimation(spring) { theme = SetupThemeChoice.toggled(from: scheme) }
        } label: {
            ZStack(alignment: .leading) {
                Circle()
                    .fill(LinearGradient(colors: dark ? [.setupHex(0x222222), .setupHex(0x1A1A1A)] : [.white, .setupHex(0xF9F9F8)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05), lineWidth: 1))
                    .shadow(color: .black.opacity(dark ? 0.4 : 0.08), radius: 3, y: 2)
                    .frame(width: 32, height: 32)
                    .offset(x: dark ? 32 : 0)
                HStack(spacing: 0) {
                    SetupIconView(icon: .sun, size: 16, lineWidth: 1.5)
                        .foregroundStyle(dark ? Color.white.opacity(0.5) : .black)
                        .rotationEffect(.degrees(dark ? -90 : 0)).scaleEffect(dark ? 0.75 : 1).opacity(dark ? 0.7 : 1)
                        .frame(width: 32, height: 32)
                    SetupIconView(icon: .moon, size: 16, lineWidth: 1.5)
                        .foregroundStyle(dark ? Color.white : .black.opacity(0.4))
                        .rotationEffect(.degrees(dark ? 0 : 90)).scaleEffect(dark ? 1 : 0.75).opacity(dark ? 1 : 0.7)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(4)
            .background(dark ? Color.setupHex(0x1A1A1A) : Color.black.opacity(0.03), in: Capsule())
            .overlay(Capsule().strokeBorder(dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(SetupPressScale())
        .animation(spring, value: dark)
        .accessibilityLabel("Toggle theme")
        .accessibilityValue(dark ? "Dark" : "Light")
    }
}

private struct SetupPressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Window plumbing

/// Lets the sidebar move the window, as KLOI's does, without taking clicks from its controls.
private struct SetupWindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Applies Setup's own theme to its window, so AppKit-drawn parts and every dynamic color agree.
/// Following the Mac leaves the window as it is.
private struct SetupWindowAppearance: NSViewRepresentable {
    let scheme: ColorScheme?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let scheme else { return }
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        DispatchQueue.main.async { nsView.window?.appearance = appearance }
    }
}

private struct SetupSchemeOverride: ViewModifier {
    let scheme: ColorScheme?

    func body(content: Content) -> some View {
        if let scheme { content.environment(\.colorScheme, scheme) } else { content }
    }
}
