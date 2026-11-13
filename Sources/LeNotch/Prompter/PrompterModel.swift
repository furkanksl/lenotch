import Foundation
import Observation

struct PrompterScript: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var text: String

    init(id: UUID = UUID(), title: String = "", text: String = "") {
        self.id = id
        self.title = title
        self.text = text
    }
}

/// Local scripts and deterministic playback. The reader owns its clock and supplies elapsed
/// time and measured scroll extent; playback never writes to disk or resumes on launch.
@MainActor @Observable
final class PrompterModel {
    enum Phase: Equatable { case ready, countdown, playing, paused, finished }

    private(set) var scripts: [PrompterScript]
    private(set) var selectedID: UUID?
    private(set) var storageError: String?
    private(set) var phase: Phase = .ready
    private(set) var offset: Double = 0
    private(set) var maxOffset: Double = 0
    private(set) var countdownRemaining: Double = 0

    private var storedSpeed: Double = 30
    private var storedFontSize: Double = 24
    private var storedMirrored = false
    private var storedCountdownEnabled = true

    var speed: Double {
        get { storedSpeed }
        set {
            let value = Self.clamp(newValue, to: 5...120, fallback: 30)
            guard storedSpeed != value else { return }
            storedSpeed = value
            save()
        }
    }

    var fontSize: Double {
        get { storedFontSize }
        set {
            let value = Self.clamp(newValue, to: 16...48, fallback: 24)
            guard storedFontSize != value else { return }
            storedFontSize = value
            save()
        }
    }

    var mirrored: Bool {
        get { storedMirrored }
        set {
            guard storedMirrored != newValue else { return }
            storedMirrored = newValue
            save()
        }
    }

    var countdownEnabled: Bool {
        get { storedCountdownEnabled }
        set {
            guard storedCountdownEnabled != newValue else { return }
            storedCountdownEnabled = newValue
            save()
        }
    }

    var selectedScript: PrompterScript? { scripts.first { $0.id == selectedID } }
    var text: String { selectedScript?.text ?? "" }
    var title: String {
        let value = selectedScript?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Untitled" : value
    }
    var canPlay: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var progress: Double { maxOffset > 0 ? offset / maxOffset : 0 }

    @ObservationIgnored private let storageURL: URL?
    @ObservationIgnored private var needsRecoveryBackup = false
    @ObservationIgnored private var recoveryNotice: String?

    private struct Saved: Codable {
        var version: Int
        var scripts: [PrompterScript]
        var selectedID: UUID?
        var speed: Double
        var fontSize: Double
        var mirrored: Bool
        var countdownEnabled: Bool
    }

    private enum StorageFailure: LocalizedError {
        case unsupportedVersion, duplicateScripts

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "This prompts file uses an unsupported format."
            case .duplicateScripts: "The prompts file contains duplicate script identifiers."
            }
        }
    }

    nonisolated static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lenotch", isDirectory: true)
            .appendingPathComponent("prompter.json")
    }

    init(storageURL: URL? = PrompterModel.defaultStorageURL) {
        self.storageURL = storageURL
        let blank = PrompterScript()
        scripts = [blank]
        selectedID = blank.id
        restore()
    }

    func addScript() {
        let script = PrompterScript()
        scripts.append(script)
        selectedID = script.id
        contentChanged()
        save()
    }

    func selectScript(_ id: UUID) {
        guard id != selectedID, scripts.contains(where: { $0.id == id }) else { return }
        selectedID = id
        contentChanged()
        save()
    }

    func deleteScript(_ id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedID == id
        scripts.remove(at: index)
        if scripts.isEmpty { scripts = [PrompterScript()] }
        if wasSelected {
            selectedID = scripts[min(index, scripts.count - 1)].id
            contentChanged()
        }
        save()
    }

    func updateScript(title: String? = nil, text: String? = nil) {
        guard let index = scripts.firstIndex(where: { $0.id == selectedID }) else { return }
        let old = scripts[index]
        if let title { scripts[index].title = title }
        if let text { scripts[index].text = text }
        guard scripts[index] != old else { return }
        if scripts[index].text != old.text { contentChanged() }
        save()
    }

    func importText(_ text: String, title: String) {
        let script = PrompterScript(title: title, text: text)
        scripts.append(script)
        selectedID = script.id
        contentChanged()
        save()
    }

    func start() {
        guard canPlay, phase != .playing, phase != .countdown else { return }
        if phase == .finished || (maxOffset > 0 && offset >= maxOffset) { offset = 0 }
        countdownRemaining = countdownEnabled ? 3 : 0
        phase = countdownEnabled ? .countdown : .playing
    }

    func togglePlayback() {
        switch phase {
        case .playing, .countdown: pause()
        case .ready, .paused, .finished: start()
        }
    }

    func pause() {
        guard phase != .ready, phase != .finished else { return }
        phase = .paused
        countdownRemaining = 0
    }

    /// Restart keeps a running reader running, without another countdown.
    func restart() {
        offset = 0
        if phase == .finished { phase = .ready }
    }

    func stop() {
        phase = .ready
        offset = 0
        countdownRemaining = 0
    }

    /// Preserve the reading fraction across font-size changes and reader resizing. A zero
    /// extent can be the first layout pass, so layout alone must never finish playback.
    func updateExtent(_ maxOffset: Double) {
        let value = maxOffset.isFinite ? max(0, maxOffset) : 0
        guard value != self.maxOffset else { return }
        let fraction = progress
        let hadExtent = self.maxOffset > 0
        self.maxOffset = value
        offset = hadExtent ? min(value, max(0, fraction * value)) : min(offset, value)
    }

    func seek(to position: Double) {
        guard position.isFinite else { return }
        offset = min(maxOffset, max(0, position))
        if phase == .finished, offset < maxOffset { phase = .paused }
    }

    /// Use only finite, forward elapsed time. Capping a tick prevents a wake or stalled UI
    /// from skipping whole paragraphs; the reader should also reset its clock on resume.
    func advance(by seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        var elapsed = min(seconds, 0.25)
        if phase == .countdown {
            let consumed = min(countdownRemaining, elapsed)
            countdownRemaining = max(0, countdownRemaining - consumed)
            elapsed -= consumed
            guard countdownRemaining == 0 else { return }
            phase = .playing
        }
        guard phase == .playing, maxOffset > 0, elapsed > 0 else { return }
        offset = min(maxOffset, offset + speed * elapsed)
        if offset >= maxOffset { phase = .finished }
    }

    private func contentChanged() {
        phase = .paused
        offset = 0
        maxOffset = 0
        countdownRemaining = 0
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    private func restore() {
        guard let storageURL else { return }
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: storageURL))
            guard saved.version == 1 else { throw StorageFailure.unsupportedVersion }
            guard Set(saved.scripts.map(\.id)).count == saved.scripts.count else {
                throw StorageFailure.duplicateScripts
            }
            if !saved.scripts.isEmpty { scripts = saved.scripts }
            selectedID = scripts.first(where: { $0.id == saved.selectedID })?.id ?? scripts.first?.id
            storedSpeed = Self.clamp(saved.speed, to: 5...120, fallback: 30)
            storedFontSize = Self.clamp(saved.fontSize, to: 16...48, fallback: 24)
            storedMirrored = saved.mirrored
            storedCountdownEnabled = saved.countdownEnabled
        } catch CocoaError.fileReadNoSuchFile {
            // First launch: leave the file absent until the user edits a script or setting.
        } catch {
            needsRecoveryBackup = true
            storageError = "Saved prompts couldn’t be loaded. The original file is unchanged. \(error.localizedDescription)"
        }
    }

    private func save() {
        guard let storageURL else { return }
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if needsRecoveryBackup {
                let backup = directory.appendingPathComponent("prompter.recovered-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: storageURL, to: backup)
                needsRecoveryBackup = false
                recoveryNotice = "The unreadable prompts file was preserved as \(backup.lastPathComponent)."
            }
            let saved = Saved(version: 1, scripts: scripts, selectedID: selectedID, speed: speed,
                              fontSize: fontSize, mirrored: mirrored, countdownEnabled: countdownEnabled)
            try JSONEncoder().encode(saved).write(to: storageURL, options: .atomic)
            storageError = recoveryNotice
        } catch {
            storageError = "Prompts couldn’t be saved. \(error.localizedDescription)"
        }
    }
}
