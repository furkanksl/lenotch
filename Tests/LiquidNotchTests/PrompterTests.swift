import Foundation
import XCTest
@testable import Lenotch

@MainActor
final class PrompterTests: XCTestCase {
    private func temporaryStorage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lenotch-prompter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("prompter.json")
    }

    private func reader(countdown: Bool = false) -> PrompterModel {
        let model = PrompterModel(storageURL: nil)
        model.updateScript(title: "My talk", text: "The opening lines of a presentation.")
        model.countdownEnabled = countdown
        model.updateExtent(300)
        return model
    }

    private func tick(_ model: PrompterModel, times: Int) {
        for _ in 0..<times { model.advance(by: 0.25) }
    }

    func testStartsWithAnEmptyEditableScriptWithoutCreatingAFile() throws {
        let url = try temporaryStorage()
        let model = PrompterModel(storageURL: url)
        XCTAssertEqual(model.scripts.count, 1)
        XCTAssertEqual(model.selectedScript?.id, model.selectedID)
        XCTAssertEqual(model.title, "Untitled")
        XCTAssertEqual(model.text, "")
        XCTAssertFalse(model.canPlay)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.storageError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testScriptsSelectionAndSettingsRestoreWithoutPlayback() throws {
        let url = try temporaryStorage()
        let model = PrompterModel(storageURL: url)
        model.updateScript(title: "Opening", text: "Welcome, everyone.")
        let opening = try XCTUnwrap(model.selectedID)
        model.addScript()
        model.updateScript(title: "Closing", text: "Thank you for listening.")
        model.selectScript(opening)
        model.speed = 52
        model.fontSize = 32
        model.mirrored = true
        model.countdownEnabled = false
        model.updateExtent(200)
        model.start()
        model.advance(by: 0.25)
        XCTAssertEqual(model.phase, .playing)

        let restored = PrompterModel(storageURL: url)
        XCTAssertEqual(restored.scripts, model.scripts)
        XCTAssertEqual(restored.selectedID, opening)
        XCTAssertEqual(restored.title, "Opening")
        XCTAssertEqual(restored.text, "Welcome, everyone.")
        XCTAssertEqual(restored.speed, 52)
        XCTAssertEqual(restored.fontSize, 32)
        XCTAssertTrue(restored.mirrored)
        XCTAssertFalse(restored.countdownEnabled)
        XCTAssertEqual(restored.phase, .ready)
        XCTAssertEqual(restored.offset, 0)
        XCTAssertEqual(restored.maxOffset, 0)
        XCTAssertEqual(restored.countdownRemaining, 0)
        XCTAssertNil(restored.storageError)
    }

    func testPauseAndResumeKeepPositionAndPlaybackNeverWrites() throws {
        let url = try temporaryStorage()
        let model = PrompterModel(storageURL: url)
        model.updateScript(text: "A saved presentation.")
        model.countdownEnabled = false
        model.updateExtent(300)
        let saved = try Data(contentsOf: url)
        let modified = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        model.togglePlayback()
        tick(model, times: 4)
        XCTAssertEqual(model.offset, 30, accuracy: 0.001)
        model.togglePlayback()
        XCTAssertEqual(model.phase, .paused)
        tick(model, times: 4)
        XCTAssertEqual(model.offset, 30, accuracy: 0.001)
        model.togglePlayback()
        tick(model, times: 2)
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.offset, 45, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: url), saved)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, modified)
    }

    func testRestartCompletionAndStartingAgain() {
        let model = reader()
        model.updateExtent(30)
        model.start()
        tick(model, times: 2)
        model.restart()
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.offset, 0)
        tick(model, times: 4)
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.offset, 30)
        XCTAssertEqual(model.progress, 1)
        model.pause()
        XCTAssertEqual(model.phase, .finished)
        model.start()
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.offset, 0)
        tick(model, times: 4)
        model.restart()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.offset, 0)
        model.start()
        model.advance(by: 0.25)
        model.stop()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.offset, 0)
        XCTAssertEqual(model.countdownRemaining, 0)
    }

    func testCountdownPauseAndResume() {
        let model = reader(countdown: true)
        model.start()
        XCTAssertEqual(model.phase, .countdown)
        XCTAssertEqual(model.countdownRemaining, 3)
        tick(model, times: 4)
        XCTAssertEqual(model.countdownRemaining, 2)
        XCTAssertEqual(model.offset, 0)
        model.togglePlayback()
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(model.countdownRemaining, 0)
        tick(model, times: 4)
        XCTAssertEqual(model.offset, 0)
        model.togglePlayback()
        XCTAssertEqual(model.countdownRemaining, 3)
        tick(model, times: 12)
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.countdownRemaining, 0)
        XCTAssertEqual(model.offset, 0)
        model.advance(by: 0.25)
        XCTAssertEqual(model.offset, 7.5, accuracy: 0.001)
        model.restart()
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.countdownRemaining, 0)
    }

    func testCountdownUsesRemainderOfTheTransitionTick() {
        let model = reader(countdown: true)
        model.start()
        tick(model, times: 11)
        model.advance(by: 0.2)
        model.advance(by: 0.15)
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.offset, 3, accuracy: 0.001)
    }

    func testEmptyAndWhitespaceScriptsCannotPlay() {
        let model = PrompterModel(storageURL: nil)
        model.start()
        XCTAssertEqual(model.phase, .ready)
        model.pause()
        XCTAssertEqual(model.phase, .ready)
        model.updateScript(text: " \t\n ")
        XCTAssertFalse(model.canPlay)
        model.togglePlayback()
        model.advance(by: 0.25)
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(model.offset, 0)
    }

    func testPreferencesRejectNonfiniteValuesAndClampSupportedRanges() {
        let model = PrompterModel(storageURL: nil)
        model.speed = -10
        model.fontSize = -10
        XCTAssertEqual(model.speed, 5)
        XCTAssertEqual(model.fontSize, 16)
        model.speed = 1_000
        model.fontSize = 1_000
        XCTAssertEqual(model.speed, 120)
        XCTAssertEqual(model.fontSize, 48)
        for invalid in [Double.nan, .infinity, -.infinity] {
            model.speed = invalid
            model.fontSize = invalid
            XCTAssertEqual(model.speed, 30)
            XCTAssertEqual(model.fontSize, 24)
        }
    }

    func testInvalidTimeIsIgnoredAndBackgroundStallsAreCapped() {
        let model = reader()
        model.start()
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            model.advance(by: invalid)
        }
        XCTAssertEqual(model.offset, 0)
        model.advance(by: 120)
        XCTAssertEqual(model.offset, 7.5, accuracy: 0.001)
        model.advance(by: 0.125)
        XCTAssertEqual(model.offset, 11.25, accuracy: 0.001)
    }

    func testExtentValidationDoesNotFinishBeforeLayout() {
        let model = reader()
        model.updateExtent(0)
        model.start()
        tick(model, times: 4)
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.offset, 0)
        XCTAssertEqual(model.progress, 0)
        for invalid in [Double.nan, .infinity, -.infinity, -50] {
            model.updateExtent(invalid)
            XCTAssertEqual(model.maxOffset, 0)
            XCTAssertEqual(model.offset, 0)
            XCTAssertEqual(model.phase, .playing)
        }
        model.updateExtent(20)
        tick(model, times: 4)
        XCTAssertEqual(model.offset, 20)
        XCTAssertEqual(model.phase, .finished)
    }

    func testFontSizeAndViewportChangesKeepReadingFraction() {
        let model = reader()
        model.seek(to: 75)
        model.start()
        model.fontSize = 36
        XCTAssertEqual(model.offset, 75)
        model.updateExtent(600)
        XCTAssertEqual(model.offset, 150)
        XCTAssertEqual(model.progress, 0.25)
        XCTAssertEqual(model.phase, .playing)
        model.updateExtent(100)
        XCTAssertEqual(model.offset, 25)
        XCTAssertEqual(model.phase, .playing)
    }

    func testSeekingClampsWithoutStartingOrPausingPlayback() {
        let model = reader()
        model.seek(to: 1_000)
        XCTAssertEqual(model.offset, 300)
        XCTAssertEqual(model.phase, .paused)
        model.seek(to: -50)
        XCTAssertEqual(model.offset, 0)
        model.start()
        model.seek(to: 100)
        XCTAssertEqual(model.phase, .playing)
        for invalid in [Double.nan, .infinity, -.infinity] { model.seek(to: invalid) }
        XCTAssertEqual(model.offset, 100)
        model.seek(to: 300)
        XCTAssertEqual(model.phase, .playing)
        model.advance(by: 0.25)
        XCTAssertEqual(model.phase, .finished)
        model.seek(to: 250)
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(model.offset, 250)
    }

    func testEditingTextAndSwitchingScriptsPauseAndResetButRenamingDoesNot() throws {
        let model = reader()
        let first = try XCTUnwrap(model.selectedID)
        model.start()
        model.advance(by: 0.25)
        model.updateScript(title: "Renamed")
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.offset, 7.5)
        model.updateScript(text: model.text)
        XCTAssertEqual(model.phase, .playing)
        model.updateScript(text: "A revised opening.")
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(model.offset, 0)
        XCTAssertEqual(model.maxOffset, 0)
        model.importText("The next chapter.", title: "Chapter 2")
        let second = try XCTUnwrap(model.selectedID)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.text, "The next chapter.")
        model.updateExtent(100)
        model.start()
        model.advance(by: 0.25)
        model.selectScript(second)
        model.selectScript(UUID())
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.offset, 7.5)
        model.selectScript(first)
        XCTAssertEqual(model.title, "Renamed")
        XCTAssertEqual(model.text, "A revised opening.")
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(model.offset, 0)
        XCTAssertEqual(model.maxOffset, 0)
    }

    func testDeletingScriptsKeepsAValidSelectionAndBlankFinalEditor() throws {
        let model = reader()
        let first = try XCTUnwrap(model.selectedID)
        model.addScript()
        let second = try XCTUnwrap(model.selectedID)
        XCTAssertEqual(model.title, "Untitled")
        XCTAssertFalse(model.canPlay)
        model.updateScript(text: "The second script.")
        model.updateExtent(100)
        model.start()
        model.advance(by: 0.25)
        model.deleteScript(first)
        XCTAssertEqual(model.scripts.count, 1)
        XCTAssertEqual(model.selectedID, second)
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.offset, 7.5)
        model.deleteScript(UUID())
        XCTAssertEqual(model.scripts.count, 1)
        model.deleteScript(second)
        XCTAssertEqual(model.scripts.count, 1)
        XCTAssertNotEqual(model.selectedID, second)
        XCTAssertEqual(model.selectedScript?.id, model.selectedID)
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(model.offset, 0)
        XCTAssertEqual(model.text, "")
        XCTAssertFalse(model.canPlay)
    }

    func testRestoringClampsPreferencesAndRepairsMissingSelection() throws {
        let url = try temporaryStorage()
        let id = UUID()
        let json: [String: Any] = [
            "version": 1,
            "scripts": [["id": id.uuidString, "title": "A script", "text": "Its body."]],
            "selectedID": UUID().uuidString,
            "speed": -100,
            "fontSize": 1_000,
            "mirrored": false,
            "countdownEnabled": true,
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let model = PrompterModel(storageURL: url)
        XCTAssertEqual(model.selectedID, id)
        XCTAssertEqual(model.speed, 5)
        XCTAssertEqual(model.fontSize, 48)
        XCTAssertNil(model.storageError)
    }

    func testMalformedJSONIsUntouchedUntilAnEditAndBackedUpBeforeRecovery() throws {
        let url = try temporaryStorage()
        let malformed = Data("{ not valid JSON".utf8)
        try malformed.write(to: url)
        let model = PrompterModel(storageURL: url)
        XCTAssertNotNil(model.storageError)
        XCTAssertEqual(model.text, "")
        XCTAssertEqual(try Data(contentsOf: url), malformed)
        model.updateScript(text: "A recovered presentation.")
        let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                                includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("prompter.recovered-") })
        XCTAssertEqual(try Data(contentsOf: backup), malformed)
        XCTAssertNotNil(model.storageError, "Keep the recovery notice visible in this session.")
        let restored = PrompterModel(storageURL: url)
        XCTAssertEqual(restored.text, "A recovered presentation.")
        XCTAssertNil(restored.storageError)
    }

    func testUnsupportedVersionsAndDuplicateScriptIDsAreNotLoadedOrOverwritten() throws {
        let url = try temporaryStorage()
        let id = UUID().uuidString
        for (version, count) in [(2, 1), (1, 2)] {
            let json: [String: Any] = [
                "version": version,
                "scripts": Array(repeating: ["id": id, "title": "Talk", "text": "Words."], count: count),
                "selectedID": id,
                "speed": 30,
                "fontSize": 24,
                "mirrored": false,
                "countdownEnabled": true,
            ]
            let data = try JSONSerialization.data(withJSONObject: json)
            try data.write(to: url)
            let model = PrompterModel(storageURL: url)
            XCTAssertNotNil(model.storageError)
            XCTAssertEqual(model.text, "")
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testWriteFailuresAreReportedWithoutLosingTheInMemoryScript() throws {
        let parent = try temporaryStorage()
        try Data("not a directory".utf8).write(to: parent)
        let model = PrompterModel(storageURL: parent.appendingPathComponent("prompter.json"))
        model.updateScript(text: "Keep this draft in memory.")
        XCTAssertEqual(model.text, "Keep this draft in memory.")
        XCTAssertNotNil(model.storageError)
        XCTAssertEqual(try String(contentsOf: parent, encoding: .utf8), "not a directory")
    }
}
