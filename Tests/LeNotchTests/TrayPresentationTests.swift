import AppKit
import IslandCore
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

@MainActor
final class TrayPresentationTests: XCTestCase {
    private func director() -> IslandDirector {
        let director = IslandDirector(prompter: PrompterModel(storageURL: nil))
        let scheduler = ManualScheduler()
        director.schedule = scheduler.schedule
        director.clock = { 0 }
        director.realTime = { 0 }
        return director
    }

    private func assertToolsOnly(_ director: IslandDirector, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(director.mode, .card, file: file, line: line)
        XCTAssertTrue(director.groups.tray, file: file, line: line)
        XCTAssertFalse(director.groups.player, file: file, line: line)
        XCTAssertFalse(director.groups.musicEars, file: file, line: line)
        XCTAssertFalse(director.groups.playerFocus, file: file, line: line)
        XCTAssertFalse(director.groups.videoFocus, file: file, line: line)
        let card = director.island.cardSize(player: CardSize(width: 520, height: 240, radius: 32))
        XCTAssertEqual(card.width, 372, file: file, line: line)
        XCTAssertEqual(card.height, 168, file: file, line: line)

        var context = TargetContext()
        context.card = card
        let targets = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: Tuning(), context: context)
        let shape = targets.resting(director.mode)
        XCTAssertEqual(shape.cardHalfWidth * 2, 372, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(shape.cardHeight, 168, accuracy: 0.01, file: file, line: line)
    }

    func testOpeningToolsDoesNotSendPlaybackCommandsOrChangePlaybackState() {
        for playing in [false, true] {
            let director = director()
            director.startMusic()
            if !playing { director.togglePlaying() }
            var playbackCommands = 0
            director.sendCommand = { _ in playbackCommands += 1 }
            director.sendCommandTo = { _, _ in playbackCommands += 1 }

            director.openTray()

            assertToolsOnly(director)
            XCTAssertEqual(director.playing, playing)
            XCTAssertTrue(director.island.mediaOn)
            XCTAssertEqual(playbackCommands, 0)
        }
    }

    func testToolsReplaceAnOpenPlayerAndFocusedLyrics() {
        for focused in [false, true] {
            let director = director()
            director.startMusic()
            if focused { director.openFocus() } else { director.openCard(.media) }
            XCTAssertTrue(director.groups.player || director.groups.playerFocus)

            director.openTray()

            assertToolsOnly(director)
            XCTAssertTrue(director.playing)
        }
    }

    func testMediaStartingAndStoppingDoesNotDismissTheSelectedToolsPage() {
        let director = director()
        director.openTray(at: .shelf)
        assertToolsOnly(director)
        XCTAssertEqual(director.tray.page, .shelf)

        director.startMusic()
        assertToolsOnly(director)
        XCTAssertEqual(director.tray.page, .shelf)

        director.stopMusic()
        assertToolsOnly(director)
        XCTAssertEqual(director.tray.page, .shelf)
    }

    func testToolsPlaybackButtonPausesAndResumesWithoutOpeningThePlayer() {
        let director = director()
        director.startMusic()
        director.openTray()

        director.trayPause()
        XCTAssertFalse(director.playing)
        assertToolsOnly(director)

        director.trayPause()
        XCTAssertTrue(director.playing)
        assertToolsOnly(director)
    }

    func testReturningToMusicClosesTheToolsAndRestoresThePlayer() {
        let director = director()
        director.startMusic()
        director.openTray()
        director.openCard(.media)

        XCTAssertTrue(director.groups.player)
        XCTAssertFalse(director.groups.tray)
        XCTAssertFalse(director.island.trayOpen)
        XCTAssertTrue(director.playing)
    }

    func testNativeToolsGridFitsTheStandaloneCardWhileMusicIsPlaying() throws {
        let director = director()
        director.startMusic()
        director.openTray()
        let card = director.island.cardSize(player: CardSize(width: 520, height: 240, radius: 32))
        let frame = FrameModel()
        frame.cardHalfWidth = card.halfWidth
        frame.cardHeight = card.height
        frame.cardTop = 80
        frame.cardRadius = card.radius
        let view = TrayLayer(frame: frame, director: director, card: card)
            .environment(\.islandMotion, IslandMotion(reduce: true, stills: true))
            .frame(width: NotchContentView.size.width, height: NotchContentView.size.height)
            .background(.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.01
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = request.results ?? []
        let labels = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        for label in ["Ask", "Timer", "Prompter", "Today", "Pause", "Clipboard", "Shelf", "Shortcuts"] {
            XCTAssertTrue(labels.contains(label.lowercased()), "Missing tools label \(label): \(labels)")
        }

        // The two rows must remain inside the narrow card, not in a displaced player-side column.
        let cardRect = CGRect(x: FrameModel.cx - card.halfWidth, y: frame.cardTop, width: card.width, height: card.height)
        for observation in observations {
            let box = observation.boundingBox
            let rendered = CGRect(x: box.minX * NotchContentView.size.width,
                                  y: (1 - box.maxY) * NotchContentView.size.height,
                                  width: box.width * NotchContentView.size.width,
                                  height: box.height * NotchContentView.size.height)
            XCTAssertTrue(cardRect.insetBy(dx: -1, dy: -1).contains(rendered), "A tools label extends outside the standalone card")
        }
    }
}
