import XCTest
@testable import SpacesEngine

final class DesktopTransitionCacheTests: XCTestCase {
    func testCardLookupOnlySchedulesDecodeAndWaitsForDelivery() {
        var workers: [() -> Void] = []
        var deliveries: [() -> Void] = []
        let unpacker = TransitionImageUnpacker<UInt64, String, String>(
            worker: { workers.append($0) }, deliver: { deliveries.append($0) }, sameSource: ==)
        var decodes = 0
        var cache: [UInt64: String] = [:]
        func content() -> String {
            if let image = cache[7] { return image }
            unpacker.request(7, source: "packed", decode: { source in decodes += 1; return "decoded \(source)" }) {
                cache[7] = $0
            }
            return "wallpaper"
        }

        for _ in 0..<20 { XCTAssertEqual(content(), "wallpaper") }
        XCTAssertEqual(workers.count, 1, "Repeated render passes must share one background decode")
        XCTAssertEqual(decodes, 0, "A cache miss must never decode on the render/gesture call stack")
        workers.removeFirst()()
        XCTAssertEqual(decodes, 1)
        XCTAssertEqual(content(), "wallpaper", "A worker cannot mutate the main-thread cache")
        XCTAssertEqual(workers.count, 0)
        deliveries.removeFirst()()
        XCTAssertEqual(content(), "decoded packed")
        XCTAssertEqual(decodes, 1)
    }

    func testResetInvalidatesOldPresentationButRapidReopenReusesSameDecode() {
        var workers: [() -> Void] = []
        var deliveries: [() -> Void] = []
        let unpacker = TransitionImageUnpacker<UInt64, Int, Int>(
            worker: { workers.append($0) }, deliver: { deliveries.append($0) }, sameSource: ==)
        var oldUpdates = 0, currentUpdates = 0
        unpacker.request(7, source: 1, decode: { $0 }) { _ in oldUpdates += 1 }
        unpacker.invalidateCallbacks()
        unpacker.request(7, source: 1, decode: { _ in XCTFail("Duplicate decode"); return 0 }) { _ in currentUpdates += 1 }
        XCTAssertEqual(workers.count, 1)
        workers.removeFirst()()
        deliveries.removeFirst()()
        XCTAssertEqual(oldUpdates, 0)
        XCTAssertEqual(currentUpdates, 1)
    }

    func testResetWithoutReopenDoesNotRepaintFromAnAlreadyQueuedDelivery() {
        var workers: [() -> Void] = []
        var deliveries: [() -> Void] = []
        let unpacker = TransitionImageUnpacker<UInt64, Int, Int>(
            worker: { workers.append($0) }, deliver: { deliveries.append($0) }, sameSource: ==)
        var updates = 0
        unpacker.request(7, source: 1, decode: { $0 }) { _ in updates += 1 }
        workers.removeFirst()()
        unpacker.invalidateCallbacks()
        deliveries.removeFirst()()
        XCTAssertEqual(updates, 0)
    }

    func testNewPackedImageForSameSpaceWaitsForPreviousDecodeAndNeverDisplaysIt() {
        var workers: [() -> Void] = []
        var deliveries: [() -> Void] = []
        let unpacker = TransitionImageUnpacker<UInt64, Int, Int>(
            worker: { workers.append($0) }, deliver: { deliveries.append($0) }, sameSource: ==)
        var updates: [Int] = []
        unpacker.request(7, source: 1, decode: { $0 }) { updates.append($0) }
        unpacker.request(7, source: 2, decode: { $0 }) { updates.append($0) }
        unpacker.request(7, source: 2, decode: { $0 }) { updates.append($0) }
        XCTAssertEqual(workers.count, 1)
        workers.removeFirst()()
        deliveries.removeFirst()()
        XCTAssertTrue(updates.isEmpty, "The previous snapshot cannot overwrite its replacement")
        XCTAssertEqual(workers.count, 1)
        workers.removeFirst()()
        deliveries.removeFirst()()
        XCTAssertEqual(updates, [2])
    }

    func testShutdownDiscardsOldJobsWithoutRemovingNewJobForSameSpace() {
        var workers: [() -> Void] = []
        var deliveries: [() -> Void] = []
        let unpacker = TransitionImageUnpacker<UInt64, Int, Int>(
            worker: { workers.append($0) }, deliver: { deliveries.append($0) }, sameSource: ==)
        var updates: [Int] = []
        unpacker.request(7, source: 1, decode: { $0 }) { updates.append($0) }
        workers.removeFirst()()
        unpacker.removeAll()
        unpacker.request(7, source: 2, decode: { $0 }) { updates.append($0) }
        deliveries.removeFirst()()
        XCTAssertTrue(updates.isEmpty)
        workers.removeFirst()()
        deliveries.removeFirst()()
        XCTAssertEqual(updates, [2])
    }
}
