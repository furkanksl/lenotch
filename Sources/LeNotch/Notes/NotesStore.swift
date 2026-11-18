import Foundation
import Observation

struct NoteItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "", body: String = "", createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    var displayTitle: String {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Untitled note" : text
    }

    var preview: String {
        body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "No text yet"
    }
}

/// Notes are written to one local JSON file after each change. Unreadable files are backed up before replacement;
/// unsupported versions stay untouched, with edits available in memory only.
@MainActor @Observable
final class NotesStore {
    struct Removal: Equatable, Identifiable {
        let id: Int
        let note: NoteItem
        let index: Int
    }

    static let shared = NotesStore()
    static let titleLimit = 120
    static let bodyLimit = 200_000

    private(set) var notes: [NoteItem] = []
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
        var notes: [NoteItem]
        var selectedID: UUID?
    }

    private enum StorageFailure: LocalizedError {
        case unsupportedVersion, duplicateIdentifiers

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "This notes file uses an unsupported format."
            case .duplicateIdentifiers: "The notes file contains duplicate identifiers."
            }
        }
    }

    nonisolated static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lenotch", isDirectory: true)
            .appendingPathComponent("notes.json")
    }

    /// A fresh store opens the empty notes index and creates no file until the first change.
    init(storageURL: URL? = NotesStore.defaultStorageURL) {
        self.storageURL = storageURL
        restore()
    }

    /// Nil means the notes index is open, even when notes exist.
    var selected: NoteItem? { notes.first { $0.id == selectedID } }

    var orderedNotes: [NoteItem] {
        notes.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    @discardableResult
    func addNote(now: Date = Date()) -> UUID {
        let note = NoteItem(createdAt: now)
        notes.append(note)
        selectedID = note.id
        save()
        return note.id
    }

    func select(_ id: UUID?) {
        guard id != selectedID, id == nil || notes.contains(where: { $0.id == id }) else { return }
        selectedID = id
        save()
    }

    func updateTitle(_ id: UUID, to title: String, now: Date = Date()) {
        // Preserve a trailing space while typing a multiword title. displayTitle trims only for
        // presentation; feeding trimmed text back into a live TextField eats every space keystroke.
        let text = title.components(separatedBy: .newlines).joined(separator: " ")
        let name = String(text.prefix(Self.titleLimit))
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].title != name else { return }
        notes[index].title = name
        notes[index].updatedAt = now
        save()
    }

    func updateBody(_ id: UUID, to body: String, now: Date = Date()) {
        let text = String(body.prefix(Self.bodyLimit))
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].body != text else { return }
        notes[index].body = text
        notes[index].updatedAt = now
        save()
    }

    func delete(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let note = notes.remove(at: index)
        if selectedID == id { selectedID = nil }
        removalSerial += 1
        removal = Removal(id: removalSerial, note: note, index: index)
        save()
    }

    func undo() {
        guard let removal else { return }
        self.removal = nil
        notes.insert(removal.note, at: min(removal.index, notes.count))
        selectedID = removal.note.id
        save()
    }

    func dismissUndo() { removal = nil }

    // MARK: - Storage

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
            let ids = saved.notes.map(\.id)
            guard Set(ids).count == ids.count else { throw StorageFailure.duplicateIdentifiers }
            notes = saved.notes
            selectedID = saved.notes.first { $0.id == saved.selectedID }?.id
        } catch StorageFailure.unsupportedVersion {
            hasUnsupportedFormat = true
            storageError = "Saved notes use an unsupported format. Changes stay in memory only; the original file won’t be overwritten."
        } catch CocoaError.fileReadNoSuchFile {
            // The first note creates the file, not opening the tool.
        } catch {
            needsRecoveryBackup = true
            storageError = "Saved notes couldn’t be loaded. The original file is unchanged. \(error.localizedDescription)"
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
                    let backup = directory.appendingPathComponent("notes.recovered-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: storageURL, to: backup)
                    recoveryNotice = "The unreadable notes file was preserved as \(backup.lastPathComponent)."
                }
                needsRecoveryBackup = false
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = Self.dateEncoding
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let saved = Saved(version: 1, notes: notes, selectedID: selectedID)
            try encoder.encode(saved).write(to: storageURL, options: .atomic)
            storageError = recoveryNotice
        } catch {
            storageError = "Notes couldn’t be saved. \(error.localizedDescription)"
        }
    }
}
