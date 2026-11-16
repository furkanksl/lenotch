import Foundation

/// ChatGPT voice names also exposed by Codex's RealtimeVoice protocol.
enum ChatGPTVoice: String, CaseIterable, Identifiable {
    case arbor, breeze, cove, ember, juniper, maple, sol, spruce, vale

    static let preferenceKey = "lenotch.chatgpt.voice"
    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .cove
    }
}
