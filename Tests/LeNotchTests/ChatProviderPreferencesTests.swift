import Foundation
import IslandCore
import XCTest
@testable import Lenotch

@MainActor
final class ChatProviderPreferencesTests: XCTestCase {
    func testFreshLaunchDefaultsToChatGPTWithoutRequiringAnAccount() {
        let defaults = isolatedChatDefaults()
        let director = IslandDirector(voiceAccountConnected: { false }, chatDefaults: defaults)
        defer { director.stopAll() }
        director.openAsk()
        XCTAssertEqual(director.askProvider, .codex)
        XCTAssertEqual(director.island.askOpen, .codex)
    }

    func testTabSelectionIsRestoredByANewDirectorForEitherProvider() {
        let defaults = isolatedChatDefaults()
        for provider in [AgentProvider.claude, .codex] {
            let first = IslandDirector(chatDefaults: defaults)
            first.openAsk()
            first.setAskProvider(provider)
            first.closeAsk()
            first.stopAll()

            let relaunched = IslandDirector(chatDefaults: defaults)
            defer { relaunched.stopAll() }
            XCTAssertEqual(relaunched.askProvider, provider)
            relaunched.openAsk()
            XCTAssertEqual(relaunched.island.askOpen, provider)
        }
    }

    func testExplicitProviderOpeningAlsoPersistsSelection() {
        let defaults = isolatedChatDefaults()
        let first = IslandDirector(chatDefaults: defaults)
        first.openAsk(.claude)
        first.stopAll()
        let relaunched = IslandDirector(chatDefaults: defaults)
        defer { relaunched.stopAll() }
        relaunched.openAsk()
        XCTAssertEqual(relaunched.island.askOpen, .claude)
        XCTAssertEqual(defaults.string(forKey: ChatPreferences.providerKey), AgentProvider.claude.rawValue)
    }

    func testInvalidStoredOrNonSelectableProviderFallsBackToChatGPT() {
        let defaults = isolatedChatDefaults()
        for value in ["unknown", AgentProvider.ask.rawValue, ""] {
            defaults.set(value, forKey: ChatPreferences.providerKey)
            let director = IslandDirector(chatDefaults: defaults)
            XCTAssertEqual(director.askProvider, .codex)
            director.setAskProvider(.ask)
            XCTAssertEqual(director.askProvider, .codex)
            XCTAssertEqual(defaults.string(forKey: ChatPreferences.providerKey), value)
            director.stopAll()
        }
    }
}

extension XCTestCase {
    /// Provider tests must not change the tab restored by the user's running app.
    func isolatedChatDefaults() -> UserDefaults {
        let suite = "lenotch.test.chat.provider.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }
}
