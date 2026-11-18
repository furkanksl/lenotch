import AppKit
import IslandCore
import SwiftUI
import Vision
import XCTest
@testable import Lenotch

@MainActor
final class SystemUsagePresentationTests: XCTestCase {
    func testSamplingFollowsTheVisiblePageAndStopsOnCloseAndLock() {
        let director = IslandDirector(prompter: PrompterModel(storageURL: nil))
        let scheduler = ManualScheduler()
        director.schedule = scheduler.schedule
        defer { director.stopAll() }
        XCTAssertFalse(director.systemUsage.isMonitoring)
        director.openTray()
        XCTAssertFalse(director.systemUsage.isMonitoring)
        director.tray.go(.system)
        XCTAssertTrue(director.systemUsage.isMonitoring)
        let size = director.presentationCard(player: .init(width: 520, height: 240, radius: 32))
        XCTAssertEqual(size.width, 400)
        XCTAssertEqual(size.height, 208)
        director.tray.go(.main)
        XCTAssertFalse(director.systemUsage.isMonitoring)
        director.tray.go(.system)
        director.clickOutside()
        XCTAssertFalse(director.systemUsage.isMonitoring)
        director.openTray(at: .system)
        XCTAssertTrue(director.systemUsage.isMonitoring)
        director.systemContextChanged(.init(locked: true))
        XCTAssertFalse(director.systemUsage.isMonitoring)
    }

    func testNotificationPageStillRoutesWithoutSystemSampling() {
        let director = IslandDirector(prompter: PrompterModel(storageURL: nil))
        defer { director.stopAll() }
        director.openTray(at: .notifications)
        XCTAssertEqual(director.tray.page, .notifications)
        XCTAssertTrue(director.groups.tray)
        XCTAssertFalse(director.systemUsage.isMonitoring)
    }

    func testNativeSystemPageFitsAndRendersMetricsInBothAppearanceModes() async throws {
        let model = SystemUsageModel(sampler: PresentationSampler(), pollingInterval: .seconds(30), baselineInterval: .milliseconds(1))
        model.start()
        defer { model.stop() }
        for _ in 0..<100 where model.snapshot.cpuFraction == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try XCTUnwrap(model.snapshot.cpuFraction), 0.25, accuracy: 0.001)
        for scheme in [ColorScheme.light, .dark] {
            for reduce in [false, true] {
                let view = SystemUsagePage(model: model, back: {})
                    .frame(width: 360, height: 168)
                    .padding(20)
                    .background(.black)
                    .environment(\.colorScheme, scheme)
                    .environment(\.islandMotion, IslandMotion(reduce: reduce, stills: reduce))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.width, 800)
                XCTAssertEqual(image.height, 416)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: image).perform([request])
                let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ").lowercased()
                for label in ["system", "cpu", "memory", "storage", "25%", "50%", "gb"] {
                    XCTAssertTrue(words.contains(label), "Missing \(label) in \(scheme) reduceMotion=\(reduce): \(words)")
                }
                XCTAssertFalse(words.contains("inbox"))
                XCTAssertFalse(words.contains("this mac"), "The header carries no status label")
                XCTAssertFalse(words.contains("live"), "The header carries no status label")
                XCTAssertFalse(words.contains("unavailable"))
            }
        }
    }

    /// The icon tile must sit on the middle of what each row actually shows, from the top of the capitals to the
    /// bottom of the bar. A text box carries ascender space above its capitals, so centering the boxes alone
    /// leaves the tile visibly high.
    func testIconTilesAreVerticallyCenteredOnEachRowsVisibleContent() async throws {
        let model = SystemUsageModel(sampler: PresentationSampler(), pollingInterval: .seconds(30), baselineInterval: .milliseconds(1))
        model.start()
        defer { model.stop() }
        for _ in 0..<100 where model.snapshot.cpuFraction == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(model.snapshot.cpuFraction)
        let scale = 4.0
        let size = CGSize(width: 360, height: 168)
        let view = SystemUsagePage(model: model, back: {})
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .environment(\.islandMotion, IslandMotion(reduce: true, stills: true))
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        func brightness(_ x: Int, _ y: Int) -> Double {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
            return Double(max(c.redComponent, c.greenComponent, c.blueComponent))
        }
        let top = Int(36 * scale), bottom = bitmap.pixelsHigh   // below the header row
        // Tiles: runs of lit pixels down the tile column.
        let tileColumn = Int(15 * scale)
        var tiles: [ClosedRange<Int>] = []
        var start: Int?
        for y in top..<bottom {
            let lit = brightness(tileColumn, y) > 0.03
            if lit, start == nil { start = y }
            if !lit, let s = start { tiles.append(s...(y - 1)); start = nil }
        }
        if let s = start { tiles.append(s...(bottom - 1)) }
        XCTAssertEqual(tiles.count, 3, "CPU, Memory and Storage each have an icon tile")
        guard tiles.count == 3 else { return }
        let centers = tiles.map { Double($0.lowerBound + $0.upperBound + 1) / 2 }
        for (index, name) in ["CPU", "Memory", "Storage"].enumerated() {
            let lower = index == 0 ? Double(top) : (centers[index - 1] + centers[index]) / 2
            let upper = index == 2 ? Double(bottom) : (centers[index] + centers[index + 1]) / 2
            // Ink: bright text and the filled part of the bar.
            var first: Int?, last: Int?
            for y in Int(lower)..<Int(upper) {
                var lit = false
                for x in Int(40 * scale)..<Int(size.width * scale) where brightness(x, y) > 0.3 { lit = true; break }
                if lit { first = first ?? y; last = y }
            }
            let inkCenter = try XCTUnwrap(first.flatMap { f in last.map { (Double(f) + Double($0) + 1) / 2 } }, name)
            let offset = (centers[index] - inkCenter) / scale
            XCTAssertEqual(offset, 0, accuracy: 0.3,
                           "\(name): the tile center is \(offset) pt from the center of the row's visible content")
        }
    }

    func testSeverityLimitsDifferPerMetricAndNeverFlagAnUnknownReading() {
        let cpu = SystemUsageThresholds.processor, memory = SystemUsageThresholds.memory, storage = SystemUsageThresholds.storage
        XCTAssertEqual(cpu.level(for: 0.74), .normal)
        XCTAssertEqual(cpu.level(for: 0.75), .warning)
        XCTAssertEqual(cpu.level(for: 0.90), .critical)
        // The same 82% is routine for a busy CPU, notable for memory, and still fine for a disk.
        XCTAssertEqual(cpu.level(for: 0.82), .warning)
        XCTAssertEqual(memory.level(for: 0.82), .warning)
        XCTAssertEqual(storage.level(for: 0.82), .normal)
        XCTAssertEqual(storage.level(for: 0.96), .critical)
        for thresholds in [cpu, memory, storage] {
            XCTAssertEqual(thresholds.level(for: nil), .normal, "A missing reading must not look like a warning")
            XCTAssertLessThan(thresholds.warning, thresholds.critical)
        }
    }

    func testBarFillTracksTheValueKeepsTinyValuesVisibleAndLeavesAnUnknownReadingEmpty() throws {
        func pixels(_ fraction: Double?) throws -> (fill: (Double, Double, Double), track: (Double, Double, Double), cap: (Double, Double, Double)) {
            let view = SystemUsageBar(fraction: fraction, tint: Color(red: 0, green: 1, blue: 0))
                .frame(width: 200, height: SystemUsageBar.height)
                .background(Color.black)
                .environment(\.islandMotion, IslandMotion(reduce: true, stills: true))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            func color(_ x: Int) throws -> (Double, Double, Double) {
                let c = try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                return (c.redComponent, c.greenComponent, c.blueComponent)
            }
            return (try color(40), try color(180), try color(5))
        }
        let half = try pixels(0.5)
        XCTAssertGreaterThan(half.fill.1, 0.5, "Inside the value the track is filled with the tint")
        XCTAssertLessThan(half.track.1, 0.2, "Beyond the value the bare track stays dark")
        let tiny = try pixels(0.01)
        XCTAssertGreaterThan(tiny.cap.1, 0.3, "1% still draws a visible rounded cap, not a sliver")
        let unknown = try pixels(nil)
        XCTAssertLessThan(unknown.fill.1, 0.2, "An unknown reading draws only the track")
        let empty = try pixels(0)
        XCTAssertLessThan(empty.cap.1, 0.2, "Zero draws nothing, rather than a misleading cap")
        let full = try pixels(1)
        XCTAssertGreaterThan(full.track.1, 0.5, "A full bar reaches the far end")
    }
}

private actor PresentationSampler: SystemUsageSampling {
    private var sampleCount: UInt32 = 0
    func sample(includeStorage: Bool) async throws -> SystemUsageReading {
        sampleCount += 1
        return SystemUsageReading(cpu: .init(user: sampleCount * 25, system: 0, idle: sampleCount * 75, nice: 0),
                                  memory: .init(usedBytes: 8 * 1_073_741_824, totalBytes: 16 * 1_073_741_824),
                                  storage: includeStorage ? .init(usage: SystemCapacityUsage(usedBytes: 250_000_000_000, totalBytes: 500_000_000_000)!,
                                                                  name: "Macintosh HD", includesReclaimableSpace: true) : nil)
    }
}
