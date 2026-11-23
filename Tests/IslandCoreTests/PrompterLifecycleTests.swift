import IslandCore
import XCTest

final class PrompterLifecycleTests: XCTestCase {
    func testPrompterIsAPersistentOpenableLiveActivity() {
        let spec = ActivitySpec[.prompter]
        XCTAssertEqual(spec.tier, .live)
        XCTAssertNil(spec.transient)
        XCTAssertTrue(spec.opens)
        XCTAssertEqual(spec.card.width, 500)
        XCTAssertEqual(spec.card.height, 332)
    }

    func testOpeningPrompterHoldsItsCardWithoutArmingAnExpiry() {
        var island = Island()
        let effects = island.apply(.show(.prompter, opened: true))

        XCTAssertEqual(island.activity?.id, .prompter)
        XCTAssertEqual(island.mode, .card)
        XCTAssertTrue(island.opened)
        XCTAssertTrue(island.holdsOpen)
        XCTAssertEqual(island.instance(island.cardOwner)?.id, .prompter)
        XCTAssertFalse(effects.contains {
            if case .armTransient = $0 { return true }
            return false
        })
    }

    func testMusicCoexistsWithPrompterAndStoppingItLeavesTheScriptOpen() throws {
        var island = Island()
        island.apply(.startMedia)
        island.apply(.show(.prompter, opened: true))
        let serial = try XCTUnwrap(island.activity?.serial)

        XCTAssertEqual(island.arrangement.ears, .activity)
        XCTAssertTrue(island.arrangement.balls.contains(.media))
        XCTAssertTrue(island.mediaOn)

        island.apply(.stopMedia)

        XCTAssertFalse(island.mediaOn)
        XCTAssertEqual(island.activity?.serial, serial)
        XCTAssertEqual(island.mode, .card)
        XCTAssertTrue(island.opened)
        XCTAssertTrue(island.holdsOpen)
        XCTAssertEqual(island.instance(island.cardOwner)?.id, .prompter)
    }

    func testIncomingAlertPreemptsPrompterWithoutEndingItsSession() throws {
        var island = Island()
        island.apply(.show(.prompter, opened: true))
        let prompterSerial = try XCTUnwrap(island.activity?.serial)

        island.apply(.show(.incoming))
        let alertSerial = try XCTUnwrap(island.activity?.serial)

        XCTAssertEqual(island.activity?.id, .incoming)
        XCTAssertEqual(island.instance(island.cardOwner)?.id, .incoming)
        XCTAssertTrue(island.background.contains { $0.id == .prompter && $0.serial == prompterSerial })

        island.apply(.end(serial: alertSerial))

        XCTAssertEqual(island.activity?.id, .prompter)
        XCTAssertEqual(island.activity?.serial, prompterSerial)
        XCTAssertEqual(island.running.count, 1)
    }

    func testEndingBackgroundPrompterBySerialPreservesTheCallAndItsCard() throws {
        var island = Island()
        island.apply(.show(.prompter, opened: true))
        let prompterSerial = try XCTUnwrap(island.activity?.serial)
        island.apply(.show(.call, opened: true))
        let callSerial = try XCTUnwrap(island.activity?.serial)
        XCTAssertEqual(island.activity?.id, .call)
        XCTAssertTrue(island.background.contains { $0.serial == prompterSerial })

        island.apply(.end(serial: prompterSerial))

        XCTAssertEqual(island.activity?.id, .call)
        XCTAssertEqual(island.activity?.serial, callSerial)
        XCTAssertEqual(island.mode, .card)
        XCTAssertTrue(island.opened)
        XCTAssertEqual(island.instance(island.cardOwner)?.id, .call)
        XCTAssertFalse(island.running.contains { $0.id == .prompter })
    }

    func testStartingPrompterFromOpenTrayReplacesToolsWithPrompterCard() {
        for withMedia in [false, true] {
            var island = Island()
            if withMedia { island.apply(.startMedia) }
            island.apply(.openTray)
            XCTAssertTrue(island.trayShows)

            island.apply(.show(.prompter, opened: true))

            XCTAssertEqual(island.mode, .card)
            XCTAssertTrue(island.opened)
            XCTAssertFalse(island.trayOpen)
            XCTAssertFalse(island.trayOver)
            XCTAssertFalse(island.trayShows)
            XCTAssertEqual(island.cardOwner, .activity)
            XCTAssertEqual(island.instance(island.cardOwner)?.id, .prompter)
            XCTAssertTrue(island.groups(.card).activityCard)
            XCTAssertFalse(island.groups(.card).tray)
        }
    }
}
