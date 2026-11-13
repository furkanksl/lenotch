import AppKit
import SwiftUI

enum SetupPage: String, CaseIterable, Identifiable {
    case permissions, appearance, integrations

    var id: Self { self }
    var title: String {
        switch self {
        case .permissions: "Permissions"
        case .appearance: "Appearance"
        case .integrations: "Integrations"
        }
    }
    var symbol: String {
        switch self {
        case .permissions: "checkmark.shield"
        case .appearance: "paintpalette"
        case .integrations: "powerplug"
        }
    }
    var subtitle: String {
        switch self {
        case .permissions: "Every permission is optional. Allow only what you want to use."
        case .appearance: "A little personality, only where you want it."
        case .integrations: "Bring the things you use into the notch."
        }
    }
}

/// A normal, resizable native window. Setup follows the Mac's appearance instead of the dark-only notch surface.
@MainActor
final class SetupWindowController {
    static let initialContentSize = NSSize(width: 960, height: 714)
    static let minimumContentSize = NSSize(width: 800, height: 590)
    private static let doneKey = "setup.v3.done"
    private var window: NSWindow?

    var needed: Bool { !UserDefaults.standard.bool(forKey: Self.doneKey) }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "LeNotch — Setup"
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unifiedCompact
            w.backgroundColor = .windowBackgroundColor
            w.isReleasedWhenClosed = false
            w.contentMinSize = Self.minimumContentSize
            w.contentView = ContentHostingView(rootView: SetupView { [weak self] in self?.finish() })
            // Only the frame is persisted. Visiting Setup never changes a feature or requests access by itself.
            w.setFrameAutosaveName("LeNotch.Setup")
            if !w.setFrameUsingName("LeNotch.Setup") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.close()
    }
}

struct SetupView: View {
    private let done: () -> Void
    @State private var page: SetupPage
    @State private var reviewAccess = false

    init(page: SetupPage = .permissions, done: @escaping () -> Void) {
        self.done = done
        _page = State(initialValue: page)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            SetupTheme.line.frame(width: 1)
            VStack(spacing: 0) {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(page.title).font(.system(size: 22, weight: .semibold))
                                    .tracking(-0.5).accessibilityAddTraits(.isHeader)
                                Text(page.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("page-top")
                            Group {
                                switch page {
                                case .permissions: SetupPermissionsPage()
                                case .appearance: SetupAppearancePage()
                                case .integrations:
                                    SetupIntegrationsPage {
                                        reviewAccess = true
                                        page = .permissions
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 18)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .onChange(of: page) {
                        scroll.scrollTo("page-top", anchor: .top)
                    }
                    .task(id: page) {
                        // The destination is inserted with its page; wait for that layout before scrolling to it.
                        guard reviewAccess, page == .permissions else { return }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        scroll.scrollTo("full-disk-access", anchor: .bottom)
                        reviewAccess = false
                    }
                }
                footer
            }
            .background(SetupTheme.pane)
        }
        .frame(minWidth: SetupWindowController.minimumContentSize.width,
               minHeight: SetupWindowController.minimumContentSize.height)
        .tint(.accentColor)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LeNotch").font(.system(size: 15, weight: .semibold)).tracking(-0.3)
                    Text("Your notch, your way.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4).padding(.top, 25).padding(.bottom, 29)
            VStack(spacing: 4) {
                ForEach(SetupPage.allCases) { item in
                    SetupNavigationButton(page: item, selected: page == item) {
                        reviewAccess = false
                        page = item
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Setup categories")
            Spacer(minLength: 30)
            VStack(alignment: .leading, spacing: 12) {
                Text("A little more from\nthe space you already have.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                Text("macOS setup").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 4)
            }
            .padding(.horizontal, 10).padding(.bottom, 22)
        }
        .padding(.horizontal, 12)
        .frame(width: 192)
        .background(SetupTheme.sidebar)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            SetupInlineNote(symbol: page == .permissions ? "arrow.triangle.2.circlepath" : "info.circle",
                            text: page == .permissions
                                ? "Access is rechecked when you return from System Settings."
                                : "All features are optional. Preferences save automatically.")
            Spacer(minLength: 10)
            Button("Done", action: done)
                .buttonStyle(.borderedProminent).controlSize(.regular)
                .frame(minWidth: 72)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setup-done")
        }
        .padding(.horizontal, 30)
        .frame(height: 62)
        .background(SetupTheme.sidebar)
        .overlay(alignment: .top) { SetupTheme.line.frame(height: 1) }
    }
}

private struct SetupNavigationButton: View {
    let page: SetupPage
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol).font(.system(size: 14))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(page.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 36)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(Color.primary.opacity(selected ? 0.09 : hovered ? 0.045 : 0),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("setup-\(page.rawValue)")
    }
}

