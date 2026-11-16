import Foundation
import IslandCore

enum ChatPreferences {
    static let providerKey = "lenotch.chat.provider"

    static func provider(in defaults: UserDefaults = .standard) -> AgentProvider {
        guard let rawValue = defaults.string(forKey: providerKey),
              let provider = AgentProvider(rawValue: rawValue), provider != .ask else { return .codex }
        return provider
    }
}
