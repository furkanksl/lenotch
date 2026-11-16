// Adapted from Interspace, Copyright (c) 2026 cnrad. MIT licensed.
import AppKit
import CoreMedia
import IOSurface
import ScreenCaptureKit
import VideoToolbox

struct Snapshot {
    let image: CGImage
    /// What a card shows. Core Animation hands an IOSurface to WindowServer by reference and color-matches it on the
    /// GPU. A plain full-screen CGImage is instead color-converted and copied on the main thread when it is first
    /// committed: 25-100 ms per desktop, which is the stutter. Always set off the main thread.
    var surface: IOSurface? = nil
    /// Camera-island replacement, positioned in screen-local top-left points.
    var patch: CGImage?
    var patchFrame = CGRect.zero
    var includesDock = true

    /// Layer contents for this desktop: the shared surface, or the image if one could not be made.
    var layerContents: Any { surface ?? image }
}

/// Full-screen pixels for layer contents, prepared off the main thread.
enum LayerSurface {
    /// One draw on the calling (background) queue, in the image's own color space: no conversion now, and the
    /// surface carries that color space so WindowServer matches it to each display on the GPU.
    static func make(from image: CGImage) -> IOSurface? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width, .height: height, .bytesPerElement: 4,
            .bytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4),
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        guard let surface = IOSurface(properties: properties) else { return nil }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let context = CGContext(data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: surface.bytesPerRow, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        tag(surface, with: colorSpace)
        return surface
    }

    static func tag(_ surface: IOSurface, with colorSpace: CGColorSpace) {
        if let list = colorSpace.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, list) }
    }

    /// A ScreenCaptureKit frame: its IOSurface as is, plus a CGImage over the same pixels for packing and patches.
    static func frame(from buffer: CMSampleBuffer, colorSpace: CGColorSpace) -> (image: CGImage, surface: IOSurface?)? {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image) == noErr, let image else { return nil }
        let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue()
        if let surface { tag(surface, with: image.colorSpace ?? colorSpace) }
        return (image, surface)
    }
}

/// Lossless storage for distant desktops; it keeps the original color space and pixel layout.
struct PackedSnapshot {
    private let data: NSData
    private let width: Int
    private let height: Int
    private let bitsPerComponent: Int
    private let bitsPerPixel: Int
    private let bytesPerRow: Int
    private let colorSpace: CGColorSpace
    private let bitmapInfo: CGBitmapInfo
    private let shouldInterpolate: Bool
    private let intent: CGColorRenderingIntent
    private let patch: CGImage?
    private let patchFrame: CGRect
    let includesDock: Bool

    var byteCount: Int { data.length }
    var fullByteCount: Int { bytesPerRow * height }

    init?(_ snapshot: Snapshot) {
        let image = snapshot.image
        guard let colorSpace = image.colorSpace,
              let pixels = image.dataProvider?.data as NSData?,
              pixels.length >= image.bytesPerRow * image.height,
              let compressed = try? pixels.compressed(using: .lz4),
              compressed.length * 4 < pixels.length * 3 else { return nil }
        data = compressed
        width = image.width
        height = image.height
        bitsPerComponent = image.bitsPerComponent
        bitsPerPixel = image.bitsPerPixel
        bytesPerRow = image.bytesPerRow
        self.colorSpace = colorSpace
        bitmapInfo = image.bitmapInfo
        shouldInterpolate = image.shouldInterpolate
        intent = image.renderingIntent
        patch = snapshot.patch
        patchFrame = snapshot.patchFrame
        includesDock = snapshot.includesDock
    }

    func unpacked() -> Snapshot? {
        guard let pixels = try? data.decompressed(using: .lz4), pixels.length >= bytesPerRow * height,
              let provider = CGDataProvider(data: pixels),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel,
                bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                decode: nil, shouldInterpolate: shouldInterpolate, intent: intent
              ) else { return nil }
        return Snapshot(image: image, surface: LayerSurface.make(from: image), patch: patch, patchFrame: patchFrame,
                        includesDock: includesDock)
    }

    func isSame(as other: PackedSnapshot) -> Bool { data === other.data }
}

/// A thread-safe cancellation epoch: worker results can never re-enter a disabled engine.
private final class CaptureLifetime {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var cancelled = false

    func token() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return cancelled ? nil : generation
    }

    func contains(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled && token == generation
    }

    func cancel() {
        lock.lock()
        cancelled = true
        generation &+= 1
        lock.unlock()
    }
}

/// Main-thread capture owner. ScreenCaptureKit cannot cancel an issued screenshot, so every callback
/// checks its lifetime before retaining or returning pixels. A fresh owner is used when re-enabled.
final class Snapshotter {
    private let excludedProcessIDs: Set<pid_t>
    init(excludingProcessIDs: Set<pid_t> = []) {
        excludedProcessIDs = excludingProcessIDs.union([getpid()])
    }
    private static let islandOwnerBundleID = "com.apple.MenuBarAgent"
    private static let menuBarWindowLayer = 24
    private let lifetime = CaptureLifetime()
    private struct Catalog {
        let displays: [CGDirectDisplayID: SCDisplay]
        let windows: [SCWindow]
    }
    private enum CaptureMode: Hashable {
        case display(includeDock: Bool)
        case below(windowNumber: Int, includesDock: Bool)
    }
    private struct CaptureKey: Hashable {
        let display: CGDirectDisplayID
        let mode: CaptureMode
    }
    private struct Images {
        var remaining: Int
        var screen: CGImage?
        var surface: IOSurface?
        var patch: CGImage?
    }
    private let catalogs = CaptureRequestLifecycle<Bool, Catalog>()
    /// The last display/window list. Discovery costs ~20 ms of TCC checks and a WindowServer enumeration of every
    /// window, so the capture that starts a transition reuses it. What it is used for (LeNotch's own windows, the
    /// Dock/menu-bar layers, the camera island) is the same on every Space; every other capture refreshes it.
    private var cachedCatalog: (catalog: Catalog, at: CFTimeInterval)?
    private static let catalogReuseLimit: CFTimeInterval = 300
    private var images: [UUID: Images] = [:]
    private lazy var captures = CaptureRequestLifecycle<CaptureKey, Snapshot>(onRetire: { [weak self] _, ticket in
        self?.images[ticket] = nil
    })
    private let samples = CaptureRequestLifecycle<UUID, [UInt8]>()
    private var wallpaperCache: [CGDirectDisplayID: (url: URL, size: CGSize, snapshot: Snapshot)] = [:]

    /// Terminal cancellation: erase retained pixels, callbacks, and screen/window metadata.
    func cancel() {
        lifetime.cancel()
        cachedCatalog = nil
        captures.cancel()
        catalogs.cancel()
        samples.cancel()
        images.removeAll()
        wallpaperCache.removeAll()
    }

    func refreshDisplays(completion: (() -> Void)? = nil) {
        cachedCatalog = nil
        refreshCatalog { _ in completion?() }
    }

    private func refreshCatalog(completion: @escaping (Catalog?) -> Void) {
        guard let epoch = lifetime.token(), let ticket = catalogs.begin(true, completion: completion) else { return }
        // Only on-screen windows from this refresh may enter a filter. A previous Space's windows
        // must not exclude the wrong content after a switch. Desktop windows retain wallpaper.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self, self.lifetime.contains(epoch), self.catalogs.contains(true, ticket: ticket) else { return }
                let catalog = content.map {
                    Catalog(displays: Dictionary($0.displays.map { ($0.displayID, $0) }, uniquingKeysWith: { _, last in last }),
                            windows: $0.windows)
                }
                if let catalog { self.cachedCatalog = (catalog, CACurrentMediaTime()) }
                self.catalogs.finish(true, ticket: ticket, value: catalog)
            }
        }
    }

    /// `reuseCatalog`: for the capture a transition waits on. It uses the last display/window list when there is one.
    func capture(screen: NSScreen, includeDock: Bool = true, reuseCatalog: Bool = false,
                 completion: @escaping (Snapshot?) -> Void) {
        capture(screen: screen, mode: .display(includeDock: includeDock), reuseCatalog: reuseCatalog, completion: completion)
    }

    func captureBelowDock(screen: NSScreen, completion: @escaping (Snapshot?) -> Void) {
        capture(screen: screen, mode: .display(includeDock: false), completion: completion)
    }

    func captureBelow(windowNumber: Int, screen: NSScreen, includesDock: Bool = true, completion: @escaping (Snapshot?) -> Void) {
        capture(screen: screen, mode: .below(windowNumber: windowNumber, includesDock: includesDock), completion: completion)
    }

    private func capture(screen: NSScreen, mode: CaptureMode, reuseCatalog: Bool = false,
                         completion: @escaping (Snapshot?) -> Void) {
        guard let epoch = lifetime.token() else { return }
        let key = CaptureKey(display: screen.displayID, mode: mode)
        // Start the two-second deadline BEFORE shareable-content discovery. A missing metadata
        // callback used to leave all coalesced capture clients permanently in flight.
        guard let ticket = captures.begin(key, completion: completion) else { return }
        if reuseCatalog, let cached = cachedCatalog, CACurrentMediaTime() - cached.at < Self.catalogReuseLimit,
           let display = cached.catalog.displays[key.display] {
            captureDisplay(screen: screen, display: display, catalog: cached.catalog, key: key, ticket: ticket, epoch: epoch)
            return
        }
        refreshCatalog { [weak self] catalog in
            guard let self, self.lifetime.contains(epoch), self.captures.contains(key, ticket: ticket) else { return }
            guard let catalog, let display = catalog.displays[key.display] else {
                self.captures.finish(key, ticket: ticket, value: nil)
                return
            }
            self.captureDisplay(screen: screen, display: display, catalog: catalog, key: key, ticket: ticket, epoch: epoch)
        }
    }

    private func captureDisplay(screen: NSScreen, display: SCDisplay, catalog: Catalog,
                                key: CaptureKey, ticket: UUID, epoch: UInt64) {
        let scale = screen.backingScaleFactor
        let pid = ProcessInfo.processInfo.processIdentifier
        let includesDock: Bool
        let layerLimit: Int
        switch key.mode {
        case .display(let includeDock):
            includesDock = includeDock
            layerLimit = includeDock ? Int.max : Self.dockWindowLayer
        case .below(let windowNumber, let includeDock):
            includesDock = includeDock
            // Every LeNotch window is excluded, even when AppKit hasn't exposed the overlay ID
            // in the fresh shareable list yet. No deprecated WindowServer screenshot is needed.
            layerLimit = includeDock
                ? catalog.windows.first(where: { Int($0.windowID) == windowNumber }).map { Int($0.windowLayer) }
                    ?? Int(CGShieldingWindowLevel())
                : Self.dockWindowLayer
        }
        let excluded = catalog.windows.filter {
            CaptureWindowPolicy.excludes(layer: Int($0.windowLayer), ownerPID: $0.owningApplication?.processID,
                                         ownPID: pid, below: layerLimit)
                || $0.owningApplication.map { excludedProcessIDs.contains($0.processID) } == true
        }
        let islandWindows = catalog.windows.filter { $0.owningApplication?.bundleIdentifier == Self.islandOwnerBundleID }
        let islandFrame = includesDock ? Self.islandFrame(on: screen, windows: islandWindows) : nil
        let needsFiltered = islandFrame != nil && !islandWindows.isEmpty
        images[ticket] = Images(remaining: needsFiltered ? 2 : 1)
        let receive: (Bool, CGImage?, IOSurface?) -> Void = { [weak self] isPatch, image, surface in
            DispatchQueue.main.async {
                guard let self, self.lifetime.contains(epoch), self.captures.contains(key, ticket: ticket),
                      var pending = self.images[ticket] else { return }
                if isPatch { pending.patch = image } else { pending.screen = image; pending.surface = surface }
                pending.remaining -= 1
                self.images[ticket] = pending
                guard pending.remaining == 0 else { return }
                guard let image = pending.screen ?? pending.patch else {
                    self.captures.finish(key, ticket: ticket, value: nil)
                    return
                }
                var snapshot = Snapshot(image: image, surface: pending.screen == nil ? nil : pending.surface,
                                        includesDock: includesDock)
                if pending.screen != nil, let filtered = pending.patch, let islandFrame {
                    Self.addPatch(to: &snapshot, from: filtered, islandFrame: islandFrame, scale: scale)
                }
                self.captures.finish(key, ticket: ticket, value: snapshot)
            }
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        // A sample buffer, not a CGImage: its IOSurface becomes the card without any main-thread pixel work.
        SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: filteredConfiguration(for: display, scale: scale)) { buffer, _ in
            let frame = buffer.flatMap { LayerSurface.frame(from: $0, colorSpace: Self.captureColorSpace) }
            receive(false, frame?.image, frame?.surface)
        }
        if needsFiltered {
            let filter = SCContentFilter(display: display, excludingWindows: excluded + islandWindows)
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: filteredConfiguration(for: display, scale: scale)) {
                image, _ in receive(true, image, nil)
            }
        }
    }

    private func filteredConfiguration(for display: SCDisplay, scale: CGFloat) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int((CGFloat(display.width) * scale).rounded())
        configuration.height = Int((CGFloat(display.height) * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.displayP3
        return configuration
    }

    private static let captureColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    private static func addPatch(to snapshot: inout Snapshot, from filtered: CGImage, islandFrame: CGRect, scale: CGFloat) {
        let pixels = CGRect(x: islandFrame.minX * scale, y: islandFrame.minY * scale,
                            width: islandFrame.width * scale, height: islandFrame.height * scale).integral
        guard let crop = filtered.cropping(to: pixels) else { return }
        snapshot.patch = copy(of: crop) ?? crop
        snapshot.patchFrame = CGRect(x: pixels.minX / scale, y: pixels.minY / scale,
                                     width: pixels.width / scale, height: pixels.height / scale)
    }

    private static func copy(of image: CGImage) -> CGImage? {
        guard let colorSpace = image.colorSpace, colorSpace.model == .rgb, image.bitsPerComponent == 8,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private typealias WindowListImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let windowListImage: WindowListImageFn? = {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(pointer, to: WindowListImageFn.self)
    }()
    private static let dockWindowLayer = Int(CGWindowLevelForKey(.dockWindow))
    private static let sampleQueue = DispatchQueue(label: "com.lenotch.app.spaces.sample", qos: .utility, autoreleaseFrequency: .workItem)
    private static let sampleWidth = 96
    private static let sampleHeight = 60

    func sampleBelow(windowNumber: Int, screen: NSScreen, completion: @escaping ([UInt8]?) -> Void) {
        guard let epoch = lifetime.token() else { return }
        let key = UUID()
        guard let ticket = samples.begin(key, completion: completion) else { return }
        let bounds = CGDisplayBounds(screen.displayID)
        let lifetime = self.lifetime
        Self.sampleQueue.async { [weak self] in
            guard lifetime.contains(epoch) else { return }
            var sample: [UInt8]?
            if windowNumber > 0,
               let image = Self.windowListImage?(bounds, 1 << 2, UInt32(windowNumber), 1 << 4)?.takeRetainedValue() {
                var pixels = [UInt8](repeating: 0, count: Self.sampleWidth * Self.sampleHeight)
                let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                    guard let context = CGContext(data: buffer.baseAddress, width: Self.sampleWidth, height: Self.sampleHeight,
                                                  bitsPerComponent: 8, bytesPerRow: Self.sampleWidth, space: CGColorSpaceCreateDeviceGray(),
                                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                    context.interpolationQuality = .medium
                    context.draw(image, in: CGRect(x: 0, y: 0, width: Self.sampleWidth, height: Self.sampleHeight))
                    return true
                }
                if drawn { sample = pixels }
            }
            guard lifetime.contains(epoch) else { return }
            let result = sample
            DispatchQueue.main.async { [weak self] in
                guard let self, lifetime.contains(epoch) else { return }
                self.samples.finish(key, ticket: ticket, value: result)
            }
        }
    }

    static func samplesMatch(_ a: [UInt8], _ b: [UInt8], sameDesktop: Bool = false) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var total = 0
        var changed = 0
        for index in a.indices {
            let difference = abs(Int(a[index]) - Int(b[index]))
            total += difference
            if difference > 16 { changed += 1 }
        }
        if sameDesktop { return Double(total) / Double(a.count) < 6 && changed * 12 < a.count }
        return Double(total) / Double(a.count) < 0.6 && changed * 400 < a.count
    }

    private static func islandFrame(on screen: NSScreen, windows: [SCWindow]) -> CGRect? {
        let bounds = CGDisplayBounds(screen.displayID)
        var frame: CGRect?
        for window in windows {
            let rect = window.frame
            guard Int(window.windowLayer) == menuBarWindowLayer, rect.intersects(bounds) else { continue }
            let local = rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            frame = frame.map { $0.union(local) } ?? local
        }
        return frame
    }

    private static let wallpaperQueue = DispatchQueue(label: "com.lenotch.app.spaces.wallpaper", qos: .utility, autoreleaseFrequency: .workItem)

    /// Wallpaper is only a provisional background; it never captures an unseen desktop.
    func wallpaper(for screen: NSScreen) -> Snapshot? {
        guard lifetime.token() != nil else { return nil }
        let id = screen.displayID
        let size = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                          height: screen.frame.height * screen.backingScaleFactor)
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let cached = wallpaperCache[id], cached.url == url, cached.size == size { return cached.snapshot }
        return nil
    }

    func wallpaper(for screen: NSScreen, completion: @escaping (Snapshot?) -> Void) {
        guard let epoch = lifetime.token() else { return }
        let id = screen.displayID
        let size = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                          height: screen.frame.height * screen.backingScaleFactor)
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { completion(nil); return }
        if let cached = wallpaperCache[id], cached.url == url, cached.size == size { completion(cached.snapshot); return }
        let lifetime = self.lifetime
        Self.wallpaperQueue.async { [weak self] in
            guard lifetime.contains(epoch) else { return }
            let snapshot = Self.makeWallpaper(url: url, size: size)
            guard lifetime.contains(epoch) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, lifetime.contains(epoch) else { return }
                if let snapshot { self.wallpaperCache[id] = (url, size, snapshot) }
                completion(snapshot)
            }
        }
    }

    private static func makeWallpaper(url: URL, size: CGSize) -> Snapshot? {
        guard size.width > 0, size.height > 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height))
        guard let result = context.makeImage() else { return nil }
        return Snapshot(image: result, surface: LayerSurface.make(from: result))
    }
}
