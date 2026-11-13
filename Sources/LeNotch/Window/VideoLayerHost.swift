import AppKit
import SwiftUI

/// Sizes the video when AppKit lays out its view, not just when SwiftUI updates it.
@MainActor
final class VideoLayerHostView: NSView {
    private(set) var videoLayer: CALayer?
    var allowsWindowDragging: Bool

    init(videoLayer: CALayer, allowsWindowDragging: Bool = false) {
        self.allowsWindowDragging = allowsWindowDragging
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        attach(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        allowsWindowDragging || super.acceptsFirstMouse(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        // This layer-backed view receives the hit, so isMovableByWindowBackground alone is not enough.
        // AppKit tracks the move; the resize border and overlay controls keep their normal handling.
        let point = convert(event.locationInWindow, from: nil)
        guard allowsWindowDragging, event.type == .leftMouseDown,
              bounds.insetBy(dx: 6, dy: 6).contains(point),
              let window, window.isMovable else {
            super.mouseDown(with: event)
            return
        }
        window.performDrag(with: event)
    }

    /// Called only by the active SwiftUI host when a video enters the island or PiP.
    func attach(_ videoLayer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let previous = self.videoLayer, previous !== videoLayer, previous.superlayer === layer {
            previous.removeFromSuperlayer()
        }
        self.videoLayer = videoLayer
        if let layer, videoLayer.superlayer !== layer {
            videoLayer.removeFromSuperlayer()
            layer.addSublayer(videoLayer)
        }
        sizeVideoLayer()
        CATransaction.commit()
    }

    func detach() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let videoLayer, videoLayer.superlayer === layer { videoLayer.removeFromSuperlayer() }
        videoLayer = nil
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sizeVideoLayer()
        CATransaction.commit()
    }

    private func sizeVideoLayer() {
        // A hidden/retiring host must never take the layer back from its new host.
        guard let videoLayer, videoLayer.superlayer === layer else { return }
        videoLayer.frame = bounds
    }
}

struct VideoLayerHost: NSViewRepresentable {
    let layer: CALayer
    var allowsWindowDragging = false

    func makeNSView(context: Context) -> VideoLayerHostView {
        VideoLayerHostView(videoLayer: layer, allowsWindowDragging: allowsWindowDragging)
    }

    func updateNSView(_ view: VideoLayerHostView, context: Context) {
        view.allowsWindowDragging = allowsWindowDragging
        view.attach(layer)
    }

    static func dismantleNSView(_ view: VideoLayerHostView, coordinator: ()) { view.detach() }
}
