import AppKit
import Observation

struct LauncherItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case application, folder, link

        var label: String {
            switch self {
            case .application: "Application"
            case .folder: "Folder"
            case .link: "Website"
            }
        }

        var symbol: String {
            switch self {
            case .application: "app"
            case .folder: "folder.fill"
            case .link: "globe"
            }
        }
    }

    let id: UUID
    var title: String
    let url: URL
    let kind: Kind
    /// Ordinary bookmarks follow local moves without granting unrelated access. LeNotch
    /// is not sandboxed; no security-scoped entitlement or persistent access is needed.
    var bookmark: Data?
}

enum LauncherError: LocalizedError, Equatable {
    case unsupportedURL, invalidWebsite, unsupportedFile, missingFile, duplicate, full, titleTooLong
    case invalidTitle, cannotOpen, unknownItem, invalidStorage

    var errorDescription: String? {
        switch self {
        case .unsupportedURL: "Choose a local application, a folder, or an http/https website."
        case .invalidWebsite: "Enter a complete http:// or https:// address without a username or password."
        case .unsupportedFile: "Choose an application or folder. Individual files and other packages are not supported."
        case .missingFile: "This item is no longer available. Choose it again in Configure Launcher."
        case .duplicate: "This item is already in your Launcher."
        case .full: "Launcher holds up to \(LauncherModel.maximumItems) items. Remove an item before adding another."
        case .titleTooLong: "Use a name with no more than 64 characters."
        case .invalidTitle: "Use a name without control characters."
        case .cannotOpen: "macOS could not open this item. Check that it is available and try again."
        case .unknownItem: "This item is no longer in your Launcher."
        case .invalidStorage: "Some saved Launcher items could not be read. Check your configured items."
        }
    }
}

/// User-chosen destinations only. Opening delegates to Launch Services, never a shell,
/// and validates the destination again so changed/deleted files fail explicitly.
@MainActor @Observable
final class LauncherModel {
    typealias Opener = @MainActor (URL, LauncherItem.Kind) async throws -> Void

    static let shared = LauncherModel()
    nonisolated static let maximumItems = 21
    nonisolated static let defaultStorageKey = "lenotch.launcher.v1"
    private(set) var items: [LauncherItem] = []
    private(set) var launchingID: UUID?
    private(set) var errorMessage: String?
    var shortcutUnavailable = false
    var isLaunching: Bool { launchingID != nil }

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let opener: Opener

    private struct Saved: Codable {
        let version: Int
        let items: [LauncherItem]
    }

    init(defaults: UserDefaults? = .standard, storageKey: String = LauncherModel.defaultStorageKey,
         opener: Opener? = nil) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.opener = opener ?? Self.openWithWorkspace
        restore()
    }

    @discardableResult
    func add(url: URL, title: String? = nil) throws -> LauncherItem {
        let (url, kind) = try Self.validate(url)
        guard !items.contains(where: { Self.identity($0.url) == Self.identity(url) }) else {
            throw LauncherError.duplicate
        }
        guard items.count < Self.maximumItems else { throw LauncherError.full }
        let item = LauncherItem(id: UUID(), title: try Self.title(title, for: url, kind: kind),
                                url: url, kind: kind, bookmark: Self.bookmark(for: url))
        items.append(item)
        errorMessage = nil
        save()
        return item
    }

    @discardableResult
    func addLink(_ address: String, title: String? = nil) throws -> LauncherItem {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw LauncherError.invalidWebsite
        }
        return try add(url: url, title: title)
    }

    func rename(_ id: UUID, title: String) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw LauncherError.unknownItem }
        let value = try Self.title(title, for: items[index].url, kind: items[index].kind)
        guard value != items[index].title else { return }
        items[index].title = value
        save()
    }

    func remove(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        errorMessage = nil
        save()
    }

    /// Uses SwiftUI's destination-before-removal semantics without depending on SwiftUI.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard destination >= 0, destination <= items.count,
              !source.isEmpty, source.allSatisfy({ items.indices.contains($0) }) else { return }
        let moving = source.sorted().map { items[$0] }
        var reordered = items.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = destination - source.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: insertion)
        guard reordered != items else { return }
        items = reordered
        save()
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), offset != 0 else { return }
        // UI uses one-step moves; bounding first avoids integer overflow for injected input.
        let bounded = min(max(offset, -items.count), items.count)
        let destination = min(max(0, index + bounded), items.count - 1)
        guard index != destination else { return }
        let item = items.remove(at: index)
        items.insert(item, at: destination)
        save()
    }

    @discardableResult
    func launch(_ item: LauncherItem) async -> Bool {
        guard !isLaunching else { return false }
        guard let current = items.first(where: { $0.id == item.id }) else {
            errorMessage = LauncherError.unknownItem.localizedDescription
            return false
        }
        launchingID = current.id
        errorMessage = nil
        defer { launchingID = nil }
        do {
            try Task.checkCancellation()
            let resolved = Self.resolve(current)
            let accessing = resolved.startAccessingSecurityScopedResource()
            defer { if accessing { resolved.stopAccessingSecurityScopedResource() } }
            let (url, kind) = try Self.validate(resolved)
            guard kind == current.kind else { throw LauncherError.unsupportedFile }
            try await opener(url, kind)
            return true
        } catch is CancellationError {
            return false
        } catch {
            // A Launch Services NSError can contain filesystem details. Keep the card
            // concise and actionable, while retaining specific local validation errors.
            errorMessage = (error as? LauncherError)?.localizedDescription
                ?? LauncherError.cannotOpen.localizedDescription
            return false
        }
    }

    func clearError() { errorMessage = nil }

    func icon(for item: LauncherItem) -> NSImage? {
        if item.url.isFileURL { return NSWorkspace.shared.icon(forFile: item.url.path) }
        return NSImage(systemSymbolName: item.kind.symbol, accessibilityDescription: nil)
    }

    /// No custom schemes, network file URLs, credentials, loose files, or package documents.
    /// Symbolic links resolve to their real destination before type checks and persistence.
    static func validate(_ source: URL) throws -> (URL, LauncherItem.Kind) {
        guard safeShape(source, kind: nil) else { throw LauncherError.unsupportedURL }
        if !source.isFileURL { return (source, .link) }
        let url = source.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { throw LauncherError.missingFile }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values.isDirectory == true else { throw LauncherError.unsupportedFile }
        if url.pathExtension.lowercased() == "app" { return (url, .application) }
        guard values.isPackage != true else { throw LauncherError.unsupportedFile }
        return (url, .folder)
    }

    private static func safeShape(_ url: URL, kind: LauncherItem.Kind?) -> Bool {
        guard !url.absoluteString.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        if url.isFileURL {
            return kind != .link && (url.host == nil || url.host == "" || url.host == "localhost")
                && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
        }
        guard kind == nil || kind == .link,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }),
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        return true
    }

    private static func identity(_ url: URL) -> String {
        if url.isFileURL { return url.standardizedFileURL.resolvingSymlinksInPath().path }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) { components.port = nil }
        if components.path.isEmpty { components.path = "/" }
        return components.string ?? url.absoluteString
    }

    private static func title(_ title: String?, for url: URL, kind: LauncherItem.Kind) throws -> String {
        guard !(title ?? "").unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { throw LauncherError.invalidTitle }
        let custom = (title ?? "").split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard custom.count <= 64 else { throw LauncherError.titleTooLong }
        if !custom.isEmpty { return custom }
        let fallback = kind == .link ? (url.host ?? "Website")
            : kind == .application ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        return String((fallback.isEmpty ? kind.label : fallback).prefix(64))
    }

    private static func bookmark(for url: URL) -> Data? {
        guard url.isFileURL else { return nil }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolve(_ item: LauncherItem) -> URL {
        guard item.url.isFileURL, let bookmark = item.bookmark else { return item.url }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { return item.url }
        return resolved
    }

    private func restore() {
        guard let data = defaults?.data(forKey: storageKey) else { return }
        guard data.count <= 1_000_000, let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == 1, saved.items.count <= Self.maximumItems else {
            errorMessage = LauncherError.invalidStorage.localizedDescription
            return
        }
        var ids = Set<UUID>(), destinations = Set<String>()
        for item in saved.items {
            guard Self.safeShape(item.url, kind: item.kind),
                  item.kind != .application || item.url.pathExtension.lowercased() == "app",
                  !item.title.isEmpty, item.title.count <= 64,
                  !item.title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !ids.contains(item.id), !destinations.contains(Self.identity(item.url)) else {
                errorMessage = LauncherError.invalidStorage.localizedDescription
                continue
            }
            ids.insert(item.id)
            destinations.insert(Self.identity(item.url))
            items.append(item)
        }
    }

    private func save() {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(Saved(version: 1, items: items)) else {
            errorMessage = "Launcher changes could not be saved."
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private static func openWithWorkspace(_ url: URL, kind: LauncherItem.Kind) async throws {
        if kind == .application {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: url, configuration: .init()) { application, error in
                    if let error { continuation.resume(throwing: error) }
                    else if application != nil { continuation.resume() }
                    else { continuation.resume(throwing: LauncherError.cannotOpen) }
                }
            }
        } else if !NSWorkspace.shared.open(url) {
            throw LauncherError.cannotOpen
        }
    }
}
