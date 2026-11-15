import AppKit
import XCTest
@testable import Lenotch

@MainActor
final class DictationDeliveryTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("lenotch.test.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    private func environment(blocker: DictationTextInserter.Reason? = nil,
                             pressed: @escaping @MainActor (String?) -> Void = { _ in },
                             presses: Bool = true,
                             restoreAfter: Duration = .milliseconds(20)) -> DictationTextInserter.Environment {
        let board = pasteboard!
        return .init(blocker: { blocker },
                     pressPaste: { pressed(board.string(forType: .string)); return presses },
                     settle: {},
                     restoreAfter: restoreAfter)
    }

    func testPastesTheTranscriptWithCommandVThenRestoresTheClipboard() async throws {
        pasteboard.clearContents()
        pasteboard.setString("what I copied before", forType: .string)
        var onClipboardWhenPasting: String?
        var presses = 0
        let result = await DictationTextInserter.deliver(
            "hello from dictation", pasteboard: pasteboard,
            environment: environment(pressed: { onClipboardWhenPasting = $0; presses += 1 })
        )
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(presses, 1, "⌘V is pressed exactly once")
        XCTAssertEqual(onClipboardWhenPasting, "hello from dictation", "the transcript is what ⌘V pastes")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(pasteboard.string(forType: .string), "what I copied before", "your clipboard comes back")
    }

    func testTheTranscriptIsMarkedTransientSoClipboardHistoriesSkipIt() async {
        var transient = false
        let board = pasteboard!
        _ = await DictationTextInserter.deliver(
            "private words", pasteboard: board,
            environment: environment(pressed: { _ in
                transient = board.types?.contains(.init("org.nspasteboard.TransientType")) == true
            })
        )
        XCTAssertTrue(transient)
    }

    func testDoesNotRestoreOverSomethingCopiedAfterwards() async throws {
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        _ = await DictationTextInserter.deliver("dictated", pasteboard: pasteboard,
                                                environment: environment(restoreAfter: .milliseconds(80)))
        pasteboard.clearContents()
        pasteboard.setString("copied meanwhile", forType: .string)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(pasteboard.string(forType: .string), "copied meanwhile")
    }

    func testWithoutAccessibilityTheTranscriptStaysOnTheClipboardAndNothingIsPressed() async {
        var presses = 0
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        let result = await DictationTextInserter.deliver(
            "dictated", pasteboard: pasteboard,
            environment: environment(blocker: .needsAccessibility, pressed: { _ in presses += 1 })
        )
        XCTAssertEqual(result, .copied(.needsAccessibility))
        XCTAssertEqual(presses, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated", "left there for you to paste yourself")
    }

    func testWithNoOtherAppInFrontItIsOnlyCopied() async {
        let result = await DictationTextInserter.deliver("dictated", pasteboard: pasteboard,
                                                         environment: environment(blocker: .noTargetApp))
        XCTAssertEqual(result, .copied(.noTargetApp))
    }

    func testIfThePasteKeysCannotBeCreatedTheTranscriptIsKept() async throws {
        let result = await DictationTextInserter.deliver("dictated", pasteboard: pasteboard,
                                                         environment: environment(presses: false))
        XCTAssertEqual(result, .copied(.needsAccessibility))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")
    }

    func testCancellingWhileModifiersSettleDoesNotPasteAndRestoresTheClipboard() async {
        pasteboard.clearContents()
        pasteboard.setString("previous copy", forType: .string)
        var presses = 0
        var delivery: Task<DictationTextInserter.Result, Never>?
        var env = environment(pressed: { _ in presses += 1 })
        env.settle = { delivery?.cancel() }
        let board = pasteboard!
        delivery = Task { await DictationTextInserter.deliver("discard me", pasteboard: board, environment: env) }
        let result = await delivery!.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(presses, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "previous copy")
    }

    func testCopyingWhileModifiersSettleNeverPastesTheNewClipboard() async {
        var presses = 0
        let board = pasteboard!
        var env = environment(pressed: { _ in presses += 1 })
        env.settle = {
            board.clearContents()
            board.setString("a new copy", forType: .string)
        }
        let result = await DictationTextInserter.deliver("dictation", pasteboard: board, environment: env)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(presses, 0)
        XCTAssertEqual(board.string(forType: .string), "a new copy")
    }
}
