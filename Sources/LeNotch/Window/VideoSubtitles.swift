import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct SubtitleCue: Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
}

/// Parses plain subtitle text only. Formatting never becomes HTML or executable content.
enum SubtitleParser {
    static func parse(_ text: String) -> [SubtitleCue] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.first == "\u{FEFF}" { normalized.removeFirst() }

        var result: [SubtitleCue] = []
        var block: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let cue = cue(in: block) { result.append(cue) }
                block.removeAll(keepingCapacity: true)
            } else {
                block.append(line)
            }
        }
        if let cue = cue(in: block) { result.append(cue) }

        // Keep source order for simultaneous cues, such as two speakers.
        return result.enumerated().sorted {
            if $0.element.start == $1.element.start { return $0.offset < $1.offset }
            return $0.element.start < $1.element.start
        }.map(\.element)
    }

    private static func cue(in lines: [String]) -> SubtitleCue? {
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { return nil }
        let marker = first.split(whereSeparator: \.isWhitespace).first.map(String.init)
        guard marker != "WEBVTT", marker != "NOTE", first != "STYLE", first != "REGION"
        else { return nil }

        // A cue starts with its timing line or one optional SRT number / WebVTT identifier.
        let timingIndex: Int
        if first.contains("-->") {
            timingIndex = 0
        } else if lines.count > 1, lines[1].contains("-->") {
            timingIndex = 1
        } else {
            return nil
        }
        let timing = lines[timingIndex].components(separatedBy: "-->")
        guard timing.count == 2,
              let start = timestamp(timing[0].trimmingCharacters(in: .whitespaces)),
              let endToken = timing[1].split(whereSeparator: \.isWhitespace).first,
              let end = timestamp(String(endToken)), end > start
        else { return nil }

        let rawText = lines.dropFirst(timingIndex + 1).joined(separator: "\n")
        let plainText = readableText(rawText)
        guard !plainText.isEmpty else { return nil }
        return SubtitleCue(start: start, end: end, text: plainText)
    }

    private static func timestamp(_ value: String) -> Double? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsParts = parts[parts.count - 1].split(
            omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "," }
        )
        guard secondsParts.count == 2, secondsParts[0].count == 2,
              secondsParts[1].count == 3,
              parts[parts.count - 2].count == 2,
              parts.dropLast().allSatisfy({ digits($0) }),
              secondsParts.allSatisfy({ digits($0) }),
              let minutes = Double(parts[parts.count - 2]), minutes < 60,
              let seconds = Double(secondsParts[0]), seconds < 60,
              let milliseconds = Double(secondsParts[1])
        else { return nil }

        var hours = 0.0
        if parts.count == 3 {
            guard parts[0].count >= 2, let parsedHours = Double(parts[0]) else { return nil }
            hours = parsedHours
        }
        let total = hours * 3_600 + minutes * 60 + seconds + milliseconds / 1_000
        return total.isFinite && total >= 0 ? total : nil
    }

    private static func digits(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func readableText(_ value: String) -> String {
        let withoutScripts = value.replacingOccurrences(
            of: #"<(script|style)\b[^>]*>[\s\S]*?</\1\s*>"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        let withoutComments = withoutScripts.replacingOccurrences(
            of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression
        )
        let withLineBreaks = withoutComments.replacingOccurrences(
            of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        let withoutTags = withLineBreaks.replacingOccurrences(
            of: #"</?[A-Za-z][^>]*>|<[0-9]{2,}:[^>]*>"#,
            with: "", options: .regularExpression
        )
        return decodeEntities(withoutTags).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static let entities = try? NSRegularExpression(
        pattern: #"&(#(?:[xX][0-9A-Fa-f]+|[0-9]+)|amp|lt|gt|nbsp|quot|apos);"#
    )

    private static func decodeEntities(_ value: String) -> String {
        guard let entities else { return value }
        let original = value as NSString
        let output = NSMutableString(string: value)
        // Decode once. An escaped literal such as &amp;lt; must remain &lt;.
        for match in entities.matches(in: value, range: NSRange(location: 0, length: original.length)).reversed() {
            let entity = original.substring(with: match.range(at: 1))
            let replacement: String?
            switch entity {
            case "amp": replacement = "&"
            case "lt": replacement = "<"
            case "gt": replacement = ">"
            case "nbsp": replacement = " "
            case "quot": replacement = "\""
            case "apos": replacement = "'"
            default:
                let hexadecimal = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                let number = UInt32(entity.dropFirst(hexadecimal ? 2 : 1), radix: hexadecimal ? 16 : 10)
                replacement = number.flatMap(UnicodeScalar.init).map(String.init)
            }
            if let replacement { output.replaceCharacters(in: match.range, with: replacement) }
        }
        return output as String
    }
}

/// Optional, local captions timed against the source player's playback position.
/// Captions already visible in that player are mirrored without importing anything.
@MainActor @Observable
final class VideoSubtitles {
    private(set) var name: String?
    private(set) var cues: [SubtitleCue] = []
    private(set) var error: String?

    @ObservationIgnored private var maximumEnds: [Double] = []
    @ObservationIgnored private var importPanel: NSOpenPanel?
    private static let maximumFileBytes = 2_000_000

    /// Opens a picker only in response to the user's explicit Import action.
    func importFile() {
        if let importPanel {
            importPanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import subtitles"
        panel.prompt = "Import"
        panel.message = "Choose a local .srt or .vtt file. Captions already shown by your video player are mirrored automatically."
        panel.allowedContentTypes = ["srt", "vtt"].compactMap {
            UTType(filenameExtension: $0, conformingTo: .plainText)
        }
        panel.allowsOtherFileTypes = false
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        importPanel = panel
        NSApp.activate()
        panel.begin { [weak self] response in
            guard let self else { return }
            defer { self.importPanel = nil }
            guard response == .OK, let url = panel.url else { return }
            self.load(from: url)
        }
    }

    func load(from url: URL) {
        guard url.isFileURL, ["srt", "vtt"].contains(url.pathExtension.lowercased()) else {
            error = "Choose a local .srt or .vtt subtitle file."
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                error = "Choose a subtitle file, not a folder."
                return
            }
            guard (values.fileSize ?? 0) <= Self.maximumFileBytes else {
                error = "Choose a subtitle file no larger than 2 MB."
                return
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            // Cap reads too, in case the file grows after checking its size.
            while data.count <= Self.maximumFileBytes {
                let remaining = Self.maximumFileBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard data.count <= Self.maximumFileBytes else {
                error = "Choose a subtitle file no larger than 2 MB."
                return
            }

            let text: String?
            if data.starts(with: [0xFF, 0xFE]) {
                text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
            } else if data.starts(with: [0xFE, 0xFF]) {
                text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
            } else {
                text = String(data: data, encoding: .utf8)
            }
            guard let text else {
                error = "The subtitles could not be decoded. Save the file as UTF-8 or UTF-16 text and import it again."
                return
            }
            let parsed = SubtitleParser.parse(text)
            guard !parsed.isEmpty else {
                error = "No timed captions were found. Choose an SRT or WebVTT file with valid cue times."
                return
            }

            var latestEnd = 0.0
            maximumEnds = parsed.map { cue in
                latestEnd = max(latestEnd, cue.end)
                return latestEnd
            }
            cues = parsed
            name = url.lastPathComponent
            error = nil
        } catch {
            // Avoid displaying a raw path or the underlying filesystem error.
            self.error = "Could not read the subtitle file. Check its permissions or choose another .srt or .vtt file."
        }
    }

    func clear() {
        name = nil
        cues = []
        maximumEnds = []
        error = nil
    }

    func text(at seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0, !cues.isEmpty else { return nil }

        // Find the first cue starting after this time and skip captions whose latest
        // possible end has already passed. Seeks can move in either direction.
        var low = 0
        var high = cues.count
        while low < high {
            let middle = low + (high - low) / 2
            if cues[middle].start <= seconds { low = middle + 1 } else { high = middle }
        }
        let upper = low
        low = 0
        high = upper
        while low < high {
            let middle = low + (high - low) / 2
            if maximumEnds[middle] <= seconds { low = middle + 1 } else { high = middle }
        }

        var seen = Set<String>()
        var lines: [String] = []
        for cue in cues[low..<upper] where cue.end > seconds {
            for line in cue.text.components(separatedBy: "\n") where seen.insert(line).inserted {
                lines.append(line)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
