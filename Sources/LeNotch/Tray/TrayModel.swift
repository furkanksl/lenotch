import AppKit
import Observation

/// What's in the tray (design `docs/superpowers/specs/2026-11-01-idle-tray-design.md`): the page showing, the
/// clipboard's recent text, the files on the shelf, and the user's shortcuts. The island
/// decides when the tray shows; this decides what's in it.
@MainActor @Observable
final class TrayModel {
    enum Page: String, CaseIterable, Sendable { case main, timer, clipboard, shelf, shortcuts, today, prompter, launcher, usage, system, todo, notifications }

    struct Clip: Equatable, Identifiable {
        let id: Int
        let text: String
        var isLink: Bool { text.hasPrefix("http://") || text.hasPrefix("https://") }
    }

    private(set) var page: Page = .main
    /// The page the next opening starts at (the Shelf when a file is dragged in).
    @ObservationIgnored var nextPage: Page = .main
    private(set) var clips: [Clip] = []
    private(set) var files: [URL] = []
    /// The user's shortcuts (nil until listed).
    private(set) var shortcuts: [String]?
    /// A row that just ran or copied, shown with a check for a moment.
    private(set) var done: String?

    // Wiring
    @ObservationIgnored var copyToPasteboard: ((String) -> Void)?
    @ObservationIgnored var runShortcut: ((String) -> Void)?
    @ObservationIgnored var listShortcuts: (() -> Void)?
    @ObservationIgnored private var clipSerial = 0
    @ObservationIgnored private var doneClear: Task<Void, Never>?

    static let maxClips = 8

    /// The tray just appeared: it starts at the grid, or wherever a drag asked for.
    func opened() {
        page = nextPage
        nextPage = .main
        done = nil
        if page == .shortcuts { listShortcuts?() }
    }

    /// A page was chosen (the large day shrinks when its page is left).
    @ObservationIgnored var onGo: ((Page) -> Void)?

    func go(_ p: Page) {
        page = p
        onGo?(p)
        done = nil
        if p == .shortcuts { listShortcuts?() }
    }

    // MARK: - Clipboard

    func addClip(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        clipSerial += 1
        clips = Array(([Clip(id: clipSerial, text: t)] + clips.filter { $0.text != t }).prefix(Self.maxClips))
    }

    func copy(_ clip: Clip) {
        copyToPasteboard?(clip.text)
        flash("clip\(clip.id)")
    }

    func clearClips() { clips = [] }

    // MARK: - Shelf

    func addFiles(_ urls: [URL]) {
        let new = urls.filter { u in !files.contains(u) }
        files = new + files
        page = .shelf
    }

    func clearFiles() { files = [] }

    // MARK: - Shortcuts

    func shortcutsListed(_ names: [String]) { shortcuts = names }

    /// The first four of the user's shortcuts.
    var pinnedShortcuts: [String] { Array((shortcuts ?? []).prefix(4)) }

    func run(_ name: String) {
        runShortcut?(name)
        flash("sc\(name)")
    }

    private func flash(_ key: String) {
        done = key
        doneClear?.cancel()
        doneClear = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, self?.done == key else { return }
            self?.done = nil
        }
    }
}
