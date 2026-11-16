import IslandCore
import XCTest

/// Pure activity routing: these tests do not start a voice transport or request microphone access.
final class VoiceActivityTests: XCTestCase {
    func testVoiceIsPersistentAndDoesNotAutoOpenOrPulse() {
        let spec = ActivitySpec[.voice]
        XCTAssertEqual(spec.tier, .ongoing)
        XCTAssertEqual(spec.title, "ChatGPT voice")
        XCTAssertEqual(spec.ear, 76)
        XCTAssertEqual(spec.card, CardSize(width: 420, height: 360, radius: 34))
        XCTAssertEqual(spec.padding, 0)
        XCTAssertEqual(spec.colorHex, "#0A84FF")
        XCTAssertTrue(spec.ball)
        XCTAssertFalse(ActivityID.voice.earsOnly)
        XCTAssertNil(spec.transient)
        XCTAssertNil(spec.pulse)
        XCTAssertFalse(spec.opens)

        var island = Island()
        XCTAssertTrue(island.apply(.show(.voice)).isEmpty)
        XCTAssertFalse(island.opened)
        XCTAssertEqual(island.mode, .compact)
    }

    func testClosingAndReopeningVoiceKeepsTheSameRunningActivity() throws {
        var island = Island()
        XCTAssertTrue(island.apply(.show(.voice, opened: true)).isEmpty)
        let serial = try XCTUnwrap(island.activity?.serial)
        XCTAssertEqual(island.mode, .card)
        XCTAssertEqual(island.cardActivity?.id, .voice)

        XCTAssertTrue(island.apply(.close).isEmpty, "Minimizing must not arm a transient expiry")

        XCTAssertFalse(island.opened)
        XCTAssertEqual(island.mode, .compact)
        XCTAssertEqual(island.running.map(\.serial), [serial])
        XCTAssertEqual(island.activity?.id, .voice)

        island.apply(.open(.activity))

        XCTAssertEqual(island.mode, .card)
        XCTAssertEqual(island.cardActivity?.serial, serial)
        XCTAssertEqual(island.running.count, 1)
    }

    func testMinimizedVoiceUsesTheEarsWithoutMusic() {
        var island = Island()
        island.apply(.show(.voice, opened: true))
        island.apply(.close)

        XCTAssertEqual(island.arrangement.ears, .activity)
        XCTAssertTrue(island.arrangement.balls.isEmpty)
        XCTAssertEqual(island.heldEar, 76)
        XCTAssertTrue(island.groups(island.mode).activityEars)
        XCTAssertFalse(island.groups(island.mode).musicEars)
    }

    func testMusicKeepsTheEarsWhileVoiceWaitsInTheBubble() throws {
        var island = Island()
        island.apply(.startMedia)
        island.apply(.show(.voice, opened: true))
        let serial = try XCTUnwrap(island.activity?.serial)
        island.apply(.close)

        XCTAssertEqual(island.mode, .duo)
        XCTAssertEqual(island.arrangement.ears, .media)
        XCTAssertEqual(island.arrangement.balls, [.activity])
        XCTAssertTrue(island.groups(island.mode).musicEars)
        XCTAssertFalse(island.groups(island.mode).activityEars)

        island.apply(.open(.activity))

        XCTAssertEqual(island.mode, .card)
        XCTAssertEqual(island.cardActivity?.serial, serial)
        XCTAssertEqual(island.arrangement.ears, .media)
        XCTAssertEqual(island.cardSize(player: CardSize(width: 1, height: 1, radius: 1)), ActivitySpec[.voice].card)
        XCTAssertTrue(island.mediaOn)
    }

    func testClosingOrStoppingMediaDoesNotExpireVoice() throws {
        var island = Island()
        island.apply(.startMedia)
        island.apply(.show(.voice, opened: true))
        let serial = try XCTUnwrap(island.activity?.serial)
        island.apply(.close)
        island.apply(.open(.media))
        XCTAssertEqual(island.cardOwner, .media)

        XCTAssertTrue(island.apply(.close).isEmpty, "Closing media must not schedule voice expiry")
        XCTAssertEqual(island.running.map(\.serial), [serial])

        island.apply(.stopMedia)

        XCTAssertFalse(island.mediaOn)
        XCTAssertEqual(island.running.map(\.serial), [serial])
        XCTAssertEqual(island.arrangement.ears, .activity)
        XCTAssertEqual(island.mode, .compact)
    }

    func testExplicitEndRemovesMinimizedVoiceAndPreservesMusic() throws {
        var island = Island()
        island.apply(.startMedia)
        island.apply(.show(.voice, opened: true))
        let serial = try XCTUnwrap(island.activity?.serial)
        island.apply(.close)

        island.apply(.end(serial: serial))

        XCTAssertTrue(island.running.isEmpty)
        XCTAssertEqual(island.arrangement.ears, .media)
        XCTAssertTrue(island.arrangement.balls.isEmpty)
        XCTAssertEqual(island.mode, .compact)
        XCTAssertTrue(island.mediaOn)
    }

    func testVoiceCanReopenAndEndWhileAnAlertOwnsTheEars() throws {
        var island = Island()
        island.apply(.show(.voice, opened: true))
        let serial = try XCTUnwrap(island.activity?.serial)
        island.apply(.show(.incoming))
        let alertSerial = try XCTUnwrap(island.activity?.serial)
        let voiceParty = Party.background(serial)
        XCTAssertEqual(island.activity?.id, .incoming)
        XCTAssertTrue(island.arrangement.balls.contains(voiceParty))

        island.apply(.close)
        island.apply(.open(voiceParty))

        XCTAssertEqual(island.cardActivity?.serial, serial)
        XCTAssertEqual(island.running.count, 2)
        XCTAssertTrue(island.apply(.close).isEmpty)
        XCTAssertTrue(island.running.contains { $0.id == .voice && $0.serial == serial })

        island.apply(.open(.activity))
        island.apply(.end(serial: serial))

        XCTAssertEqual(island.activity?.serial, alertSerial)
        XCTAssertEqual(island.cardActivity?.id, .incoming)
        XCTAssertEqual(island.mode, .card)
        XCTAssertFalse(island.running.contains { $0.id == .voice })
    }

    func testTransientExpiryReturnsToTheSameMinimizedVoice() throws {
        var island = Island()
        island.apply(.show(.voice, opened: true))
        let serial = try XCTUnwrap(island.activity?.serial)
        island.apply(.close)
        island.apply(.show(.charging))
        let transientSerial = try XCTUnwrap(island.activity?.serial)

        island.apply(.transientExpired(serial: transientSerial))

        XCTAssertEqual(island.activity?.id, .voice)
        XCTAssertEqual(island.activity?.serial, serial)
        XCTAssertFalse(island.opened)
        XCTAssertEqual(island.mode, .compact)
        XCTAssertEqual(island.running.count, 1)
    }

    func testHidingVoiceKeepsItAddressableForExplicitEnd() throws {
        var island = Island()
        island.apply(.show(.voice, opened: true))
        let serial = try XCTUnwrap(island.activity?.serial)

        island.apply(.hide(.activity))

        XCTAssertFalse(island.opened)
        XCTAssertEqual(island.mode, .idle)
        XCTAssertEqual(island.arrangement.hidden, [.activity])
        XCTAssertEqual(island.instance(.activity)?.serial, serial)

        island.apply(.unhide(.activity))
        island.apply(.open(.activity))
        XCTAssertEqual(island.cardActivity?.serial, serial)

        island.apply(.end(serial: serial))
        XCTAssertTrue(island.running.isEmpty)
        XCTAssertEqual(island.mode, .idle)
    }

    func testContextChangesKeepVoiceAddressableForLifecycleCleanup() throws {
        for context in [DesktopContext(menuOpen: true), DesktopContext(fullscreen: true),
                        DesktopContext(sharing: true), DesktopContext(locked: true),
                        DesktopContext(lockScreen: true)] {
            var island = Island()
            island.apply(.show(.voice, opened: true))
            let serial = try XCTUnwrap(island.activity?.serial)

            island.apply(.context(context))

            if context.menuOpen || context.fullscreen { XCTAssertFalse(island.opened) }
            XCTAssertEqual(island.running.map(\.serial), [serial], "Context does not own audio teardown")

            // The director owns privacy teardown. It can still end the same occurrence after a context change.
            island.apply(.end(serial: serial))
            island.apply(.context(DesktopContext()))
            XCTAssertTrue(island.running.isEmpty)
            XCTAssertEqual(island.mode, .idle)
        }
    }
}
