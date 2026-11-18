import Foundation
import Observation

struct TodoItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var isDone: Bool
    var createdAt: Date
    var completedAt: Date?

    init(id: UUID = UUID(), title: String, isDone: Bool = false, createdAt: Date = Date(), completedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

struct TodoList: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var items: [TodoItem]
    var createdAt: Date

    init(id: UUID = UUID(), title: String, items: [TodoItem] = [], createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.items = items
        self.createdAt = createdAt
    }

    /// What is left, in the order it was added.
    var open: [TodoItem] { items.filter { !$0.isDone } }
    /// What is finished, the one finished last first.
    var done: [TodoItem] {
        items.filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
    var openCount: Int { items.reduce(0) { $0 + ($1.isDone ? 0 : 1) } }
}

/// The to-do lists, kept in one small JSON file on this Mac (no database, nothing leaves it). Every change is written
/// at once; a file that can't be read is left alone and set aside as a copy before the first save replaces it.
/// Unsupported formats are never replaced; edits then stay in memory only.
@MainActor @Observable
final class TodoStore {
    /// What a deletion took out, so one tap brings it back. Only the last one is kept.
    struct Removal: Equatable, Identifiable {
        struct IndexedItem: Equatable {
            let item: TodoItem
            let index: Int
        }

        enum Kind: Equatable {
            case item(TodoItem, list: UUID, index: Int)
            case completed([IndexedItem], list: UUID)
            case list(TodoList, index: Int)
        }

        let id: Int
        let kind: Kind
    }

    static let shared = TodoStore()
    static let titleLimit = 200
    static let listTitleLimit = 40
    static let starterListTitle = "Tasks"

    private(set) var lists: [TodoList]
    private(set) var selectedID: UUID?
    private(set) var storageError: String?
    private(set) var removal: Removal?

    @ObservationIgnored private let storageURL: URL?
    @ObservationIgnored private var removalSerial = 0
    @ObservationIgnored private var hasUnsupportedFormat = false
    @ObservationIgnored private var needsRecoveryBackup = false
    @ObservationIgnored private var recoveryNotice: String?

    private struct SavedVersion: Decodable {
        var version: Int
    }

    private struct Saved: Codable {
        var version: Int
        var lists: [TodoList]
        var selectedID: UUID?
    }

    private enum StorageFailure: LocalizedError {
        case unsupportedVersion, duplicateIdentifiers

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "This to-do file uses an unsupported format."
            case .duplicateIdentifiers: "The to-do file contains duplicate identifiers."
            }
        }
    }

    nonisolated static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lenotch", isDirectory: true)
            .appendingPathComponent("todos.json")
    }

    /// A first launch starts with one empty list, so the first thing to do is to type. Later launches show what was saved,
    /// including no lists at all when that is what was left.
    init(storageURL: URL? = TodoStore.defaultStorageURL) {
        self.storageURL = storageURL
        let starter = TodoList(title: Self.starterListTitle)
        lists = [starter]
        selectedID = starter.id
        restore()
    }

    // MARK: - Reading

    /// The list on screen: the chosen one, or the first when the choice is gone.
    var selected: TodoList? { lists.first { $0.id == selectedID } ?? lists.first }

    /// What is left across every list (the tools menu's badge).
    var openCount: Int { lists.reduce(0) { $0 + $1.openCount } }

    func list(_ id: UUID) -> TodoList? { lists.first { $0.id == id } }

    // MARK: - Lists

    /// Makes a list and shows it. Nil when the name is empty.
    @discardableResult
    func addList(_ title: String) -> UUID? {
        let name = Self.clean(title, limit: Self.listTitleLimit)
        guard !name.isEmpty else { return nil }
        let list = TodoList(title: name)
        lists.append(list)
        selectedID = list.id
        save()
        return list.id
    }

    func selectList(_ id: UUID) {
        guard id != selected?.id, lists.contains(where: { $0.id == id }) else { return }
        selectedID = id
        save()
    }

    /// An empty name keeps the old one.
    func renameList(_ id: UUID, to title: String) {
        let name = Self.clean(title, limit: Self.listTitleLimit)
        guard !name.isEmpty, let index = lists.firstIndex(where: { $0.id == id }), lists[index].title != name else { return }
        lists[index].title = name
        save()
    }

    func deleteList(_ id: UUID) {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        let wasShown = selected?.id == id
        let list = lists.remove(at: index)
        if wasShown { selectedID = lists.isEmpty ? nil : lists[min(index, lists.count - 1)].id }
        remember(.list(list, index: index))
        save()
    }

    // MARK: - To-dos

    /// Adds to the list on screen, or to the one named. Nil when the text is empty or there is no list.
    @discardableResult
    func addItem(_ title: String, to listID: UUID? = nil, now: Date = Date()) -> UUID? {
        let text = Self.clean(title, limit: Self.titleLimit)
        guard !text.isEmpty, let target = listID ?? selected?.id,
              let index = lists.firstIndex(where: { $0.id == target }) else { return nil }
        let item = TodoItem(title: text, createdAt: now)
        lists[index].items.append(item)
        save()
        return item.id
    }

    func toggle(_ itemID: UUID, now: Date = Date()) {
        guard let (list, item) = locate(itemID) else { return }
        let done = !lists[list].items[item].isDone
        lists[list].items[item].isDone = done
        lists[list].items[item].completedAt = done ? now : nil
        save()
    }

    /// An empty text keeps the old one.
    func renameItem(_ itemID: UUID, to title: String) {
        let text = Self.clean(title, limit: Self.titleLimit)
        guard !text.isEmpty, let (list, item) = locate(itemID), lists[list].items[item].title != text else { return }
        lists[list].items[item].title = text
        save()
    }

    func deleteItem(_ itemID: UUID) {
        guard let (list, item) = locate(itemID) else { return }
        let removed = lists[list].items.remove(at: item)
        remember(.item(removed, list: lists[list].id, index: item))
        save()
    }

    /// Takes every finished to-do out of a list.
    func clearCompleted(in listID: UUID) {
        guard let index = lists.firstIndex(where: { $0.id == listID }) else { return }
        let finished = lists[index].items.enumerated().compactMap { index, item in
            item.isDone ? Removal.IndexedItem(item: item, index: index) : nil
        }
        guard !finished.isEmpty else { return }
        lists[index].items.removeAll(where: \.isDone)
        remember(.completed(finished, list: listID))
        save()
    }

    // MARK: - Undo

    /// Puts back what the last deletion took out, where it was.
    func undo() {
        guard let removal else { return }
        self.removal = nil
        switch removal.kind {
        case .item(let item, let listID, let index):
            guard let at = lists.firstIndex(where: { $0.id == listID }) else { return }
            lists[at].items.insert(item, at: min(index, lists[at].items.count))
        case .completed(let items, let listID):
            guard let at = lists.firstIndex(where: { $0.id == listID }) else { return }
            for restored in items where !lists[at].items.contains(where: { $0.id == restored.item.id }) {
                lists[at].items.insert(restored.item, at: min(restored.index, lists[at].items.count))
            }
        case .list(let list, let index):
            lists.insert(list, at: min(index, lists.count))
            selectedID = list.id
        }
        save()
    }

    /// The deletion is final: the undo offer goes away.
    func dismissUndo() { removal = nil }

    private func remember(_ kind: Removal.Kind) {
        removalSerial += 1
        removal = Removal(id: removalSerial, kind: kind)
    }

    private func locate(_ itemID: UUID) -> (list: Int, item: Int)? {
        for list in lists.indices {
            if let item = lists[list].items.firstIndex(where: { $0.id == itemID }) { return (list, item) }
        }
        return nil
    }

    /// One line: a name or a to-do never spans lines, never starts or ends with space, never grows without end.
    nonisolated static func clean(_ text: String, limit: Int) -> String {
        let line = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(line.prefix(limit)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Storage

    /// ISO 8601 with fractional seconds, so two to-dos ticked in the same second keep their order after a restart.
    private nonisolated static let dateEncoding = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    private nonisolated static let dateDecoding = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try Date(text, strategy: Date.ISO8601FormatStyle())
    }

    private func restore() {
        guard let storageURL else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = Self.dateDecoding
            let data = try Data(contentsOf: storageURL)
            guard try decoder.decode(SavedVersion.self, from: data).version == 1 else {
                throw StorageFailure.unsupportedVersion
            }
            let saved = try decoder.decode(Saved.self, from: data)
            let ids = saved.lists.map(\.id) + saved.lists.flatMap { $0.items.map(\.id) }
            guard Set(ids).count == ids.count else { throw StorageFailure.duplicateIdentifiers }
            lists = saved.lists
            selectedID = saved.lists.first { $0.id == saved.selectedID }?.id ?? saved.lists.first?.id
        } catch StorageFailure.unsupportedVersion {
            hasUnsupportedFormat = true
            storageError = "Saved to-dos use an unsupported format. Changes stay in memory only; the original file won’t be overwritten."
        } catch CocoaError.fileReadNoSuchFile {
            // First launch: the starter list stays in memory until the first change writes the file.
        } catch {
            needsRecoveryBackup = true
            storageError = "Saved to-dos couldn’t be loaded. The original file is unchanged. \(error.localizedDescription)"
        }
    }

    private func save() {
        guard let storageURL, !hasUnsupportedFormat else { return }
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if needsRecoveryBackup {
                let sourceExists: Bool
                do {
                    _ = try FileManager.default.attributesOfItem(atPath: storageURL.path)
                    sourceExists = true
                } catch CocoaError.fileReadNoSuchFile {
                    sourceExists = false
                } catch CocoaError.fileNoSuchFile {
                    sourceExists = false
                }
                if sourceExists {
                    let backup = directory.appendingPathComponent("todos.recovered-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: storageURL, to: backup)
                    recoveryNotice = "The unreadable to-do file was preserved as \(backup.lastPathComponent)."
                }
                needsRecoveryBackup = false
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = Self.dateEncoding
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let saved = Saved(version: 1, lists: lists, selectedID: selected?.id)
            try encoder.encode(saved).write(to: storageURL, options: .atomic)
            storageError = recoveryNotice
        } catch {
            storageError = "To-dos couldn’t be saved. \(error.localizedDescription)"
        }
    }
}
