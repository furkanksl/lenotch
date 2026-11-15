import AppKit
import SwiftUI

enum SetupPage: String, CaseIterable, Identifiable {
    case permissions, appearance, dictation, integrations

    var id: Self { self }
    var title: String {
        switch self {
        case .permissions: "Permissions"
        case .appearance: "Appearance"
        case .dictation: "Dictation"
        case .integrations: "Integrations"
        }
    }
    var symbol: String {
        switch self {
        case .permissions: "checkmark.shield"
        case .appearance: "paintpalette"
        case .dictation: "mic"
        case .integrations: "powerplug"
        }
    }
    var subtitle: String {
        switch self {
        case .permissions: "Give LeNotch access to the features you use. Everything here is optional."
        case .appearance: "Choose how album artwork and colors appear on your Mac."
        case .dictation: "Choose an on-device speech model and optional transcript cleanup."
        case .integrations: "Notifications and coding agents, connected to your notch."
        }
    }
}

/// A normal, resizable native window. Setup follows the Mac's appearance instead of the dark-only notch surface.
@MainActor
final class SetupWindowController {
    static let initialContentSize = NSSize(width: 900, height: 740)
    static let minimumContentSize = NSSize(width: 760, height: 600)
    private static let doneKey = "setup.v3.done"
    private var window: NSWindow?

    var needed: Bool { !UserDefaults.standard.bool(forKey: Self.doneKey) }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "LeNotch — Setup"
            w.titleVisibility = .hidden
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
        VStack(spacing: 0) {
            navigation
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(page.title).font(.system(size: 25, weight: .semibold))
                                .tracking(-0.65).accessibilityAddTraits(.isHeader)
                            Text(page.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .id("page-top")
                        Group {
                            switch page {
                            case .permissions: SetupPermissionsPage()
                            case .appearance: SetupAppearancePage()
                            case .dictation:
                                SetupDictationPage { page = .permissions }
                            case .integrations:
                                SetupIntegrationsPage {
                                    reviewAccess = true
                                    page = .permissions
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 760, alignment: .topLeading)
                    .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .onChange(of: page) { scroll.scrollTo("page-top", anchor: .top) }
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
        .background(SetupTheme.canvas)
        .frame(minWidth: SetupWindowController.minimumContentSize.width,
               minHeight: SetupWindowController.minimumContentSize.height)
        .tint(.accentColor)
    }

    private var navigation: some View {
        HStack(spacing: 20) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LeNotch").font(.system(size: 14, weight: .semibold)).tracking(-0.25)
                    Text("Setup").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 3) {
                ForEach(Array(SetupPage.allCases.enumerated()), id: \.element) { index, item in
                    SetupNavigationButton(page: item, selected: page == item) {
                        reviewAccess = false
                        page = item
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            .padding(4)
            .background(SetupTheme.badge, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Setup categories")
        }
        .padding(.horizontal, 32)
        .frame(height: 72)
        .overlay(alignment: .bottom) { SetupTheme.line.frame(height: 1).padding(.horizontal, 32) }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            SetupInlineNote(symbol: page == .permissions ? "arrow.clockwise" : "checkmark",
                            text: page == .permissions
                                ? "Access updates when you return from System Settings."
                                : "Preferences save automatically on this Mac.")
            Spacer(minLength: 10)
            Button("Done", action: done)
                .buttonStyle(SetupActionStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setup-done")
        }
        .padding(.horizontal, 32)
        .frame(height: 64)
        .overlay(alignment: .top) { SetupTheme.line.frame(height: 1).padding(.horizontal, 32) }
    }
}

private struct SetupNavigationButton: View {
    let page: SetupPage
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: page.symbol).font(.system(size: 12))
                    .frame(width: 15)
                Text(page.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 13).frame(height: 32)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(selected ? SetupTheme.surface : Color.primary.opacity(hovered ? 0.035 : 0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? SetupTheme.line : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("setup-\(page.rawValue)")
    }
}

