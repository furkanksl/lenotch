import IslandCore
import XCTest
@testable import Lenotch

@MainActor
final class PrompterIntegrationTests: XCTestCase {
    private func makeDirector() -> (IslandDirector, PrompterModel, ManualScheduler) {
        let model = PrompterModel(storageURL: nil)
        model.updateScript(title: "Presentation", text: "Read this script near the camera while presenting.")
        model.countdownEnabled = false
        model.stop()
        model.updateExtent(1_000)

        let director = IslandDirector(prompter: model)
        let scheduler = ManualScheduler()
        director.schedule = scheduler.schedule
        director.clock = { 0 }
        director.realTime = { 0 }
        return (director, model, scheduler)
    }

    func testExplicitStartOpensThePrompterAndStartsPlayback() {
        let (director, model, _) = makeDirector()

        director.startPrompter()

        XCTAssertTrue(director.prompter === model)
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(director.mode, .card)
        XCTAssertTrue(director.island.opened)
        XCTAssertTrue(director.island.holdsOpen)
        XCTAssertEqual(director.island.instance(director.island.cardOwner)?.id, .prompter)
        XCTAssertEqual(director.island.running.filter { $0.id == .prompter }.count, 1)
    }

    func testOpeningAReadyScriptDoesNotStartPlayback() {
        let (director, model, _) = makeDirector()

        director.openPrompter()

        XCTAssertEqual(director.mode, .card)
        XCTAssertEqual(director.island.instance(director.island.cardOwner)?.id, .prompter)
        XCTAssertEqual(model.phase, .ready)
        model.advance(by: 0.25)
        XCTAssertEqual(model.offset, 0)
    }

    func testStopResetsPlaybackAndLeavesNoActivityOrDelayedSession() {
        let (director, model, scheduler) = makeDirector()
        director.startPrompter()
        model.advance(by: 0.25)
        XCTAssertGreaterThan(model.offset, 0)

        director.stopPrompter()
        scheduler.advance(30)
        model.advance(by: 0.25)

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.offset, 0)
        XCTAssertFalse(director.island.running.contains { $0.id == .prompter })
        XCTAssertFalse(director.island.opened)
    }

    func testLeavingTheCardDoesNotCloseOrPauseTheSession() {
        let (director, model, scheduler) = makeDirector()
        director.startPrompter()
        director.pointerMoved(hit: .card, corridor: false, buttonDown: false)

        director.pointerMoved(hit: nil, corridor: false, buttonDown: false)
        scheduler.advance(3)

        XCTAssertEqual(director.mode, .card)
        XCTAssertTrue(director.island.opened)
        XCTAssertEqual(director.island.instance(director.island.cardOwner)?.id, .prompter)
        XCTAssertEqual(model.phase, .playing)
    }

    func testPointerClickOutsideDoesNotCloseThePrompter() {
        let (director, model, scheduler) = makeDirector()
        director.startPrompter()

        director.pointerUp(at: SIMD2(900, 600), hit: nil, corridor: false)
        scheduler.advance(3)

        XCTAssertTrue(director.island.opened)
        XCTAssertEqual(director.mode, .card)
        XCTAssertEqual(director.island.instance(director.island.cardOwner)?.id, .prompter)
        XCTAssertEqual(model.phase, .playing)
    }

    func testExternalAppClickDoesNotCloseThePrompter() {
        let (director, model, scheduler) = makeDirector()
        director.startPrompter()

        director.clickOutside()
        scheduler.advance(3)

        XCTAssertTrue(director.island.opened)
        XCTAssertEqual(director.mode, .card)
        XCTAssertEqual(director.island.instance(director.island.cardOwner)?.id, .prompter)
        XCTAssertEqual(model.phase, .playing)
    }

    func testIncomingAlertPausesPlaybackWithoutDiscardingTheSession() throws {
        let (director, model, _) = makeDirector()
        director.startPrompter()
        let prompterSerial = try XCTUnwrap(director.island.activity?.serial)
        model.advance(by: 0.25)
        let offset = model.offset
        XCTAssertGreaterThan(offset, 0)

        director.show(.incoming)

        XCTAssertEqual(director.island.activity?.id, .incoming)
        XCTAssertEqual(model.phase, .paused)
        XCTAssertTrue(director.island.running.contains { $0.id == .prompter && $0.serial == prompterSerial })
        model.advance(by: 0.25)
        XCTAssertEqual(model.offset, offset)
    }

    func testFullscreenHidesAndPausesThePrompterWithoutEndingIt() {
        let (director, model, _) = makeDirector()
        director.startPrompter()
        model.advance(by: 0.25)
        let offset = model.offset
        var context = director.island.context
        context.fullscreen = true

        director.setContext(context)

        XCTAssertEqual(director.mode, .idle)
        XCTAssertEqual(model.phase, .paused)
        XCTAssertTrue(director.island.running.contains { $0.id == .prompter })
        model.advance(by: 0.25)
        XCTAssertEqual(model.offset, offset)
    }

    func testLockingPausesPlaybackEvenWhenTheSessionStillExists() {
        let (director, model, _) = makeDirector()
        director.startPrompter()
        model.advance(by: 0.25)
        let offset = model.offset
        var context = director.island.context
        context.locked = true

        director.setContext(context)

        XCTAssertEqual(model.phase, .paused)
        XCTAssertTrue(director.island.running.contains { $0.id == .prompter })
        model.advance(by: 0.25)
        XCTAssertEqual(model.offset, offset)
    }

    func testStoppingBackgroundPrompterDoesNotEndTheForegroundCall() throws {
        let (director, model, _) = makeDirector()
        director.startPrompter()
        let prompterSerial = try XCTUnwrap(director.island.activity?.serial)
        director.show(.call, opened: true, sample: false)
        let callSerial = try XCTUnwrap(director.island.activity?.serial)
        XCTAssertEqual(director.island.activity?.id, .call)
        XCTAssertTrue(director.island.background.contains { $0.serial == prompterSerial })

        director.stopPrompter()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(director.island.running.contains { $0.id == .prompter })
        XCTAssertEqual(director.island.activity?.id, .call)
        XCTAssertEqual(director.island.activity?.serial, callSerial)
        XCTAssertEqual(director.mode, .card)
        XCTAssertTrue(director.island.opened)
    }

    func testReopeningAnInterruptedSessionPreservesItsPositionWithoutAutostarting() throws {
        let (director, model, _) = makeDirector()
        director.startPrompter()
        let prompterSerial = try XCTUnwrap(director.island.activity?.serial)
        model.advance(by: 0.25)
        let offset = model.offset
        director.show(.incoming)
        let alertSerial = try XCTUnwrap(director.island.activity?.serial)
        XCTAssertEqual(model.phase, .paused)
        director.end(serial: alertSerial)
        XCTAssertTrue(director.island.running.contains { $0.id == .prompter && $0.serial == prompterSerial })

        director.openPrompter()

        XCTAssertEqual(director.mode, .card)
        XCTAssertTrue(director.island.opened)
        XCTAssertEqual(director.island.instance(director.island.cardOwner)?.id, .prompter)
        XCTAssertEqual(director.island.running.filter { $0.id == .prompter }.count, 1)
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(model.offset, offset)
        model.advance(by: 0.25)
        XCTAssertEqual(model.offset, offset)
    }
}
