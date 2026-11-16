import Foundation

/// Codex frameless quicksilver v2 uses context append, not public Realtime function outputs.
enum ChatGPTVoiceDelegation {
    static func messages(id: String, text: String) throws -> [[String: Any]] {
        guard !id.isEmpty, id.utf8.count <= 256, !text.isEmpty, text.utf8.count <= 128 * 1024 else {
            throw ChatGPTVoiceTransportError.bridge("The voice task result was invalid.")
        }
        var chunks: [String] = [], chunk = "", size = 0
        // Match Codex's 500-byte append limit without splitting Unicode scalars.
        for scalar in text.unicodeScalars {
            let string = String(scalar), bytes = string.utf8.count
            if size + bytes > 500 { chunks.append(chunk); chunk = ""; size = 0 }
            chunk += string
            size += bytes
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks.map { [
            "type": "delegation.context.append", "delegation_item_id": id,
            "channel": "speakable", "content": [["type": "input_text", "text": $0]],
        ] }
    }
}
