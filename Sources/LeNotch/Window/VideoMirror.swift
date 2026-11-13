import AppKit
import CoreImage
import CoreMedia
import OSLog
import ScreenCaptureKit

/// Watching a video in the island (owner, 11-11: "if it's a video, click on its card and you can watch it from the
/// island"): a live mirror of the video in its browser window, through ScreenCaptureKit. The video keeps playing in its
/// tab, with its own sound; only the picture comes here. Screen Recording access is required, but no file is recorded.
///
/// Where the video sits in the window isn't known, so the first half second is watched small and the part that moves is
/// taken as the video (16:9 around it); then the stream crops to it at full resolution. Nothing moving (paused): the
/// whole window. The browser only paints the tab in front of its window: on another tab the mirror says so.
@MainActor @Observable
final class VideoMirror {
    enum State: Equatable { case idle, finding, showing, needsPermission, notFound, otherTab, failed(String) }
    private(set) var state: State = .idle
    /// The video's shape once found (width over height), for the view's fit.
    private(set) var aspect = 16.0 / 9
    /// Each window owns a display layer. They share immutable images from one capture stream, so a late update from
    /// the disappearing notch host cannot reparent the floating window's video into a hidden view.
    @ObservationIgnored let layer: CALayer = VideoMirror.makeLayer()
    @ObservationIgnored let pipLayer: CALayer = VideoMirror.makeLayer()

    private static func makeLayer() -> CALayer {
        let l = CALayer()
        l.contentsGravity = .resizeAspect
        l.backgroundColor = NSColor.black.cgColor
        return l
    }

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: Output?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private static let log = Logger(subsystem: "com.lenotch.app", category: "video")

    func start(app: String, title: String) {
        stop()
        guard CGPreflightScreenCaptureAccess() else { state = .needsPermission; return }
        state = .finding
        let session = generation
        task = Task { [weak self] in await self?.run(app: app, title: title, session: session) }
    }

    func stop() {
        task?.cancel(); task = nil
        generation = UUID()
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil; output = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        pipLayer.contents = nil
        CATransaction.commit()
        state = .idle
    }

    private func run(app: String, title: String, session: UUID) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            guard isCurrent(session) else { return }
            state = .notFound; return
        }
        guard isCurrent(session) else { return }
        let windows = content.windows.filter { $0.owningApplication?.bundleIdentifier == app && $0.frame.width > 200 && $0.windowLayer == 0 }
        let key = String(title.prefix(40))
        let window = windows.first { ($0.title ?? "").localizedCaseInsensitiveContains(key) }
        guard let window = window ?? windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            state = .notFound; return
        }
        if !key.isEmpty, !(window.title ?? "").localizedCaseInsensitiveContains(key) {
            Self.log.notice("video: its tab isn't the one in front of its window")
            state = .otherTab
            return
        }
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 4
        // Small first, to find the part that moves.
        let small = 480.0, k = small / window.frame.width
        config.width = Int(small); config.height = Int(window.frame.height * k)
        // Retaining an IOSurface alone doesn't stop the capture pool from reusing its pixels before the main queue
        // presents it. Decode on a serial capture queue, then hand an independent CGImage to the presentation thread.
        let out = Output(cells: (32, 18), onFrame: { [weak self] image in
            Task { @MainActor [weak self] in self?.show(image, session: session) }
        }, onFailure: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(session) else { return }
                self.state = .failed("Video capture stopped. Bring the video window forward and try again.")
                Self.log.notice("video: stream stopped unexpectedly")
            }
        })
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: out)
        self.stream = stream
        output = out
        do {
            try stream.addStreamOutput(out, type: .screen,
                                       sampleHandlerQueue: DispatchQueue(label: "com.lenotch.app.video.frames", qos: .userInitiated))
            try await stream.startCapture()
        } catch {
            guard isCurrent(session) else { return }
            Self.log.notice("video: capture failed (\(error.localizedDescription, privacy: .public))")
            state = CGPreflightScreenCaptureAccess()
                ? .failed("Couldn’t capture the video window. Bring it forward and try again.") : .needsPermission
            return
        }
        guard isCurrent(session) else {
            try? await stream.stopCapture()
            return
        }
        do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
        guard isCurrent(session) else { return }
        // The moving part, in the window's points, made 16:9 around its middle.
        let found = out.movingBox().map { box -> CGRect in
            let r = CGRect(x: box.minX * window.frame.width, y: box.minY * window.frame.height,
                           width: box.width * window.frame.width, height: box.height * window.frame.height)
            return Self.sixteenNine(around: r, within: CGRect(origin: .zero, size: window.frame.size))
        }
        let crop = found ?? CGRect(origin: .zero, size: window.frame.size)
        Self.log.notice("video: \(found == nil ? "nothing moving, the whole window" : "found the video", privacy: .public) \(Int(crop.width))×\(Int(crop.height))")
        let full = SCStreamConfiguration()
        full.pixelFormat = kCVPixelFormatType_32BGRA
        full.showsCursor = false
        full.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        full.queueDepth = 4
        full.sourceRect = crop
        full.width = Int(min(crop.width * scale, 1280)); full.height = Int(Double(full.width) * crop.height / crop.width)
        out.finding = false
        do {
            try await stream.updateConfiguration(full)
            guard isCurrent(session) else { return }
            aspect = crop.width / max(crop.height, 1)
        } catch {
            // Keep the already-visible full-window preview if this system can't apply the crop.
            Self.log.notice("video: crop unavailable; keeping the window preview")
        }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        guard isCurrent(session), state == .finding else { return }
        state = .failed("No video frames received. Bring the video window forward and try again.")
    }

    private func isCurrent(_ session: UUID) -> Bool { generation == session && !Task.isCancelled }

    private func show(_ image: CGImage, session: UUID) {
        guard isCurrent(session), state == .showing || state == .finding else { return }
        display(image)
        if state != .showing {
            state = .showing
            aspect = Double(image.width) / Double(max(image.height, 1))
            Self.log.notice("video: displaying the first captured frame")
        }
    }

    /// Deliver the same decoded image to both presentation targets without moving layers between native windows.
    func display(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        pipLayer.contents = image
        CATransaction.commit()
    }

    /// Also used by the native renderer regression tests with synthetic video frames (no screen access needed).
    static func present(_ image: CGImage, on layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }

    /// A 16:9 rectangle covering `r`, centred on it, kept inside `bounds`.
    nonisolated static func sixteenNine(around r: CGRect, within bounds: CGRect) -> CGRect {
        var w = r.width, h = r.height
        if w / max(h, 1) > 16.0 / 9 { h = w * 9 / 16 } else { w = h * 16 / 9 }
        w = min(w, bounds.width); h = min(h, bounds.height)
        var x = r.midX - w / 2, y = r.midY - h / 2
        x = min(max(x, bounds.minX), bounds.maxX - w); y = min(max(y, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Receives frames; while finding, adds up how much each cell of a coarse grid changes from frame to frame.
    final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        private let onFrame: @Sendable (CGImage) -> Void
        private let onFailure: @Sendable () -> Void
        private let context = CIContext(options: [.cacheIntermediates: false])
        private var isFinding = true
        var finding: Bool {
            get { lock.withLock { isFinding } }
            set { lock.withLock { isFinding = newValue } }
        }
        private let cells: (Int, Int)
        private var last: [Double]?
        private var motion: [Double]
        private let lock = NSLock()

        init(cells: (Int, Int), onFrame: @escaping @Sendable (CGImage) -> Void,
             onFailure: @escaping @Sendable () -> Void = {}) {
            self.cells = cells
            self.onFrame = onFrame
            self.onFailure = onFailure
            motion = Array(repeating: 0, count: cells.0 * cells.1)
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen else { return }
            receive(sample)
        }

        func stream(_ stream: SCStream, didStopWithError error: any Error) { onFailure() }

        /// ScreenCaptureKit can send idle/blank/status-only buffers as well as real pictures. Keep the last good frame.
        func receive(_ sample: CMSampleBuffer) {
            autoreleasepool {
                guard sample.isValid,
                      let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                      let status = info.first?[.status] as? Int,
                      status == SCFrameStatus.complete.rawValue,
                      let pb = CMSampleBufferGetImageBuffer(sample),
                      CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return }
                if finding { measure(pb) }
                let image = CIImage(cvPixelBuffer: pb)
                // Force an independent snapshot before ScreenCaptureKit reuses its pixel buffer. Core Animation can
                // display it reliably even after the capture callback and buffer pool have moved to the next frame.
                guard let rendered = context.createCGImage(image, from: image.extent, format: .BGRA8,
                                                          colorSpace: CGColorSpaceCreateDeviceRGB(), deferred: false) else { return }
                onFrame(rendered)
            }
        }

        private func measure(_ pb: CVPixelBuffer) {
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
            let p = base.assumingMemoryBound(to: UInt8.self)
            var lum = Array(repeating: 0.0, count: cells.0 * cells.1)
            for cy in 0..<cells.1 {
                for cx in 0..<cells.0 {
                    // A few samples per cell are enough to see change.
                    var sum = 0.0
                    for sy in 0..<3 { for sx in 0..<3 {
                        let x = min(w - 1, (cx * 3 + sx) * w / (cells.0 * 3)), y = min(h - 1, (cy * 3 + sy) * h / (cells.1 * 3))
                        let o = y * row + x * 4
                        sum += Double(p[o]) + Double(p[o + 1]) * 2 + Double(p[o + 2])
                    } }
                    lum[cy * cells.0 + cx] = sum
                }
            }
            lock.lock(); defer { lock.unlock() }
            if let last { for i in lum.indices { motion[i] += abs(lum[i] - last[i]) } }
            last = lum
        }

        /// The changing cells' bounding box, as fractions of the window (top-left origin); nil if nothing moves.
        func movingBox() -> CGRect? {
            lock.lock(); let m = motion; lock.unlock()
            guard let top = m.max(), top > 0 else { return nil }
            var minX = cells.0, minY = cells.1, maxX = -1, maxY = -1, count = 0
            for cy in 0..<cells.1 { for cx in 0..<cells.0 where m[cy * cells.0 + cx] > top * 0.2 {
                minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy); count += 1
            } }
            guard count >= 4 else { return nil }      // a blinking caret or a spinner isn't a video
            return CGRect(x: Double(minX) / Double(cells.0), y: Double(minY) / Double(cells.1),
                          width: Double(maxX - minX + 1) / Double(cells.0), height: Double(maxY - minY + 1) / Double(cells.1))
        }
    }
}
