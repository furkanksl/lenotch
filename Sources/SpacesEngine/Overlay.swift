// Adapted from Interspace, Copyright (c) 2026 cnrad. MIT licensed.
// LeNotch owns this overlay only while the optional Spaces engine is enabled.
import AppKit
import QuartzCore

enum CardContent {
    case none
    case placeholder
    case snapshot(Snapshot)
}

final class TransitionCard {
    let container = CALayer()
    private let content = CALayer()
    private let image = CALayer()
    private let patch = CALayer()
    private let dim = CALayer()
    private var patchFrame = CGRect.zero
    private var geometry: (size: CGSize, radius: CGFloat)?
    var isPresent = false

    init() {
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        container.isDoubleSided = false
        container.allowsEdgeAntialiasing = true
        container.shadowColor = CGColor(gray: 0, alpha: 1)
        container.shadowOffset = .zero
        container.shadowRadius = Config.stackShadowRadius
        content.masksToBounds = true
        content.cornerCurve = .continuous
        content.backgroundColor = CGColor(gray: 0.11, alpha: 1)
        image.contentsGravity = .resize
        image.minificationFilter = .trilinear
        patch.contentsGravity = .resize
        patch.minificationFilter = .trilinear
        dim.backgroundColor = CGColor(gray: 0, alpha: 1)
        content.addSublayer(image)
        content.addSublayer(patch)
        content.addSublayer(dim)
        container.addSublayer(content)
    }

    func layout(size: CGSize, cornerRadius: CGFloat) {
        guard geometry?.size != size || geometry?.radius != cornerRadius else { return }
        geometry = (size, cornerRadius)
        let bounds = CGRect(origin: .zero, size: size)
        container.bounds = bounds
        content.frame = bounds
        content.cornerRadius = cornerRadius
        container.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        image.frame = bounds
        dim.frame = bounds
        layoutPatch()
    }

    func set(_ value: CardContent) {
        switch value {
        case .none:
            isPresent = false
            container.isHidden = true
            image.contents = nil
            patch.contents = nil
            patchFrame = .zero
        case .placeholder:
            isPresent = true
            container.isHidden = false
            image.contents = nil
            patch.contents = nil
            patchFrame = .zero
        case .snapshot(let snapshot):
            isPresent = true
            container.isHidden = false
            image.contents = snapshot.layerContents
            patch.contents = snapshot.patch
            patchFrame = snapshot.patchFrame
        }
        layoutPatch()
    }

    private func layoutPatch() {
        let bounds = content.bounds
        patch.frame = CGRect(
            x: patchFrame.minX, y: bounds.height - patchFrame.maxY,
            width: patchFrame.width, height: patchFrame.height
        )
    }

    func apply(_ placement: CardPlacement) {
        container.isHidden = placement.hidden
        container.position = placement.position
        container.zPosition = placement.zPosition
        container.transform = placement.transform
        container.shadowOpacity = placement.shadow
        dim.opacity = placement.dim
    }

    static let animationKey = "lenotch.settle"

    /// Hands a whole precomputed motion to the render server. The model is left at the last placement, so removing
    /// the animations (or their end) shows exactly where the motion stops. Only properties that change are animated.
    func animate(_ placements: [CardPlacement], keyTimes: [NSNumber], discreteKeyTimes: [NSNumber],
                 duration: CFTimeInterval, beginTime: CFTimeInterval) {
        guard let last = placements.last else { return }
        apply(last)
        guard placements.contains(where: { !$0.hidden }) else { return }
        func add(_ layer: CALayer, _ keyPath: String, _ values: [Any], discrete: Bool = false) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = discrete ? discreteKeyTimes : keyTimes
            animation.calculationMode = discrete ? .discrete : .linear
            animation.duration = duration
            animation.beginTime = beginTime
            // Hold the first frame until the commit reaches the render server: never flash the end state.
            animation.fillMode = .backwards
            layer.add(animation, forKey: "\(Self.animationKey).\(keyPath)")
        }
        let first = placements[0]
        if placements.contains(where: { $0.hidden != first.hidden }) {
            add(container, "hidden", placements.map { NSNumber(value: $0.hidden) }, discrete: true)
        }
        if placements.contains(where: { $0.position != first.position }) {
            add(container, "position", placements.map { NSValue(point: $0.position) })
        }
        if placements.contains(where: { !CATransform3DEqualToTransform($0.transform, first.transform) }) {
            add(container, "transform", placements.map { NSValue(caTransform3D: $0.transform) })
        }
        if placements.contains(where: { $0.zPosition != first.zPosition }) {
            add(container, "zPosition", placements.map { NSNumber(value: Double($0.zPosition)) })
        }
        if placements.contains(where: { $0.shadow != first.shadow }) {
            add(container, "shadowOpacity", placements.map { NSNumber(value: $0.shadow) })
        }
        if placements.contains(where: { $0.dim != first.dim }) {
            add(dim, "opacity", placements.map { NSNumber(value: $0.dim) })
        }
    }

    func stopAnimating() {
        for key in ["hidden", "position", "transform", "zPosition", "shadowOpacity"] {
            container.removeAnimation(forKey: "\(Self.animationKey).\(key)")
        }
        dim.removeAnimation(forKey: "\(Self.animationKey).opacity")
    }
}

/// Where one card is for a given progress, as plain values: applied at once, or as one frame of an animation.
struct CardPlacement {
    var hidden: Bool
    var position = CGPoint.zero
    var transform = CATransform3DIdentity
    var zPosition: CGFloat = 0
    var shadow: Float = 0
    var dim: Float = 0
}

final class Overlay {
    struct Loader {
        let frame: CGRect
        let color: CGColor
    }

    static let reach = 2
    private let root = CALayer()
    private let cards = (-reach...reach).map { _ in TransitionCard() }
    private var panel: NSPanel
    private var loaderLayer: CALayer?
    private var screen: NSScreen?
    private var size = CGSize.zero
    private var screenCornerRadius: CGFloat = 0
    private(set) var isVisible = false
    private(set) var presentedAt: CFTimeInterval = 0
    private var membershipGeneration = 0
    private var membershipPending = false
    /// The desktop list this window was last confirmed to be on. macOS drops a window from "all desktops" only when
    /// the list of desktops changes, so the same list needs no new WindowServer query before the window is shown.
    private var verifiedMembership: (windowNumber: Int, desktopIDs: [UInt64])?
    var canFadeOut: Bool { TransitionHandoff.canFade(coveredFor: CACurrentMediaTime() - presentedAt) }
    var style: TransitionStyle = .lightweight { didSet { if style != oldValue { layoutCards() } } }
    var roundsCorners = true { didSet { if roundsCorners != oldValue { layoutCards() } } }
    var isBelowDock = false {
        didSet {
            guard isBelowDock != oldValue else { return }
            panel.level = isBelowDock ? .init(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1) : .init(rawValue: Int(CGShieldingWindowLevel()))
        }
    }
    var windowNumber: Int { panel.windowNumber }
    var alpha: CGFloat {
        get { panel.alphaValue }
        set { panel.alphaValue = newValue }
    }

    init() {
        panel = Self.makePanel(root: root)
        root.backgroundColor = CGColor(gray: 0.04, alpha: 1)
        root.contentsGravity = .resize
        root.isOpaque = true
        root.masksToBounds = true
        let actions: [String: CAAction] = Dictionary(uniqueKeysWithValues: [
            "position", "bounds", "transform", "sublayerTransform", "opacity", "cornerRadius",
            "contents", "hidden", "zPosition", "shadowOpacity", "shadowPath"
        ].map { ($0, NSNull() as CAAction) })
        root.actions = actions
        for card in cards {
            root.addSublayer(card.container)
            Self.disableActions(card.container, actions)
        }
    }

    private static func disableActions(_ layer: CALayer, _ actions: [String: CAAction]) {
        layer.actions = actions
        layer.sublayers?.forEach { disableActions($0, actions) }
    }

    private static func makePanel(root: CALayer) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .init(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.alphaValue = 0
        let view = NSView()
        view.wantsLayer = true
        view.layer = root
        panel.contentView = view
        return panel
    }

    /// The window must stay on every desktop: the Dock switches below it. macOS takes a window out of "all desktops"
    /// when a desktop is removed, and WindowServer reports a window's desktops only while it is on screen. So this is
    /// asked after the window is shown, off the main thread, and a window that lost a desktop is replaced in place.
    /// The same desktop list is not asked again for the same window. Nothing ever waits for the answer.
    func confirmOnAllDesktops(_ desktopIDs: [UInt64]) {
        guard isVisible, !membershipPending else { return }
        let number = panel.windowNumber
        if let verified = verifiedMembership, verified.windowNumber == number, verified.desktopIDs == desktopIDs { return }
        membershipPending = true
        let generation = membershipGeneration
        Spaces.queryQueue.async { [weak self] in
            let current = Spaces.spaces(ofWindow: number)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.membershipPending = false
                guard generation == self.membershipGeneration, self.isVisible, self.panel.windowNumber == number,
                      !current.isEmpty else { return }
                if Set(current).isSuperset(of: desktopIDs) {
                    self.verifiedMembership = (number, desktopIDs)
                } else {
                    self.verifiedMembership = nil
                    self.recreatePanel()
                }
            }
        }
    }

    private func recreatePanel() {
        let old = panel
        let wasVisible = isVisible
        let oldAlpha = old.alphaValue
        old.contentView?.layer = nil
        panel = Self.makePanel(root: root)
        panel.level = old.level
        panel.setFrame(old.frame, display: true)
        panel.alphaValue = wasVisible ? oldAlpha : 0
        if wasVisible { panel.orderFrontRegardless() }
        old.orderOut(nil)
        old.close()
    }

    func attach(to screen: NSScreen) {
        self.screen = screen
        size = screen.frame.size
        screenCornerRadius = Self.displayCornerRadius(screen)
        // A window change waiting in AppKit makes the next layer commit wait for a WindowServer fence: a synchronous
        // round trip on the transition's critical path. Change the frame only when the display actually differs.
        if panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: false)
            panel.contentView?.frame = CGRect(origin: .zero, size: size)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        layoutCards()
        CATransaction.commit()
    }

    private func layoutCards() {
        guard size.width > 0, size.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = style == .hexagon || !roundsCorners ? 0 : screenCornerRadius
        for card in cards { card.layout(size: size, cornerRadius: radius) }
        CATransaction.commit()
    }

    func setCards(_ content: (Int) -> CardContent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for offset in -Self.reach...Self.reach { cards[offset + Self.reach].set(content(offset)) }
        CATransaction.commit()
    }

    /// A precomputed motion is playing in the render server (see `animate(progress:interval:beginTime:)`).
    private(set) var isAnimating = false

    func render(progress: CGFloat) {
        if isAnimating { stopAnimating() }
        let placements = self.placements(progress: progress)
        for (index, card) in cards.enumerated() { card.apply(placements[index]) }
    }

    /// Plays `samples` (progress at a fixed `interval`, starting at `beginTime` on the media clock) without the main
    /// thread: WindowServer interpolates every display frame itself, so a busy main thread or a slow commit no longer
    /// drops frames of the motion. `render(progress:)` or `stopAnimating()` interrupt it; the model ends at the last sample.
    func animate(progress samples: [CGFloat], interval: CFTimeInterval, beginTime: CFTimeInterval) {
        guard samples.count >= 2 else { render(progress: samples.first ?? 0); return }
        if isAnimating { stopAnimating() }
        let frames = samples.map { placements(progress: $0) }
        let last = Double(samples.count - 1)
        let keyTimes = (0..<samples.count).map { NSNumber(value: Double($0) / last) }
        let discreteKeyTimes = (0...samples.count).map { NSNumber(value: min(Double($0) / last, 1)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, card) in cards.enumerated() {
            card.animate(frames.map { $0[index] }, keyTimes: keyTimes, discreteKeyTimes: discreteKeyTimes,
                         duration: interval * last, beginTime: beginTime)
        }
        CATransaction.commit()
        isAnimating = true
    }

    func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for card in cards { card.stopAnimating() }
        CATransaction.commit()
    }

    private func placements(progress: CGFloat) -> [CardPlacement] {
        let width = size.width
        let gap = Config.gap / max(width, 1)
        let centre = CGPoint(x: width / 2, y: size.height / 2)
        func scaled(_ scale: CGFloat) -> CATransform3D { CATransform3DMakeScale(scale, scale, 1) }
        let scale = TransitionMath.scale(progress: progress)
        let stride = width * scale + Config.gap
        return (-Self.reach...Self.reach).map { offset in
            let present = cards[offset + Self.reach].isPresent
            let distance = CGFloat(offset) - progress
            switch style {
            case .hexagon:
                let radius = width * TransitionMath.hexApothem
                var transform = CATransform3DIdentity
                transform.m34 = -1 / (width * Config.hexPerspective)
                transform = CATransform3DTranslate(transform, 0, 0, -radius - width * TransitionMath.hexPushback(progress: progress))
                transform = CATransform3DRotate(transform, distance * TransitionMath.hexFaceAngle, 0, 1, 0)
                transform = CATransform3DTranslate(transform, 0, 0, radius)
                return CardPlacement(hidden: !present || abs(distance) > 1.4, position: centre, transform: transform,
                                     dim: Float(TransitionMath.hexDim(offset: distance)))
            case .magnetic:
                let x = TransitionMath.magneticPosition(offset: distance, gap: gap)
                return CardPlacement(hidden: !present || abs(distance) > 1.02,
                                     position: CGPoint(x: width / 2 + x * width, y: centre.y),
                                     transform: scaled(TransitionMath.magneticScale(offset: distance)),
                                     dim: Float(TransitionMath.dim(offCentre: abs(distance))))
            case .stack:
                return CardPlacement(hidden: !present || distance > 1.02 || distance < -1,
                                     position: CGPoint(x: width / 2 + TransitionMath.stackSlide(offset: distance) * width, y: centre.y),
                                     transform: scaled(TransitionMath.stackScale(offset: distance)),
                                     zPosition: CGFloat(offset) * 10,
                                     shadow: Float(TransitionMath.stackShadow(offset: distance)),
                                     dim: Float(TransitionMath.stackDim(offset: distance)))
            default:
                return CardPlacement(hidden: !present || abs(distance) > 1.05,
                                     position: CGPoint(x: width / 2 + distance * stride, y: centre.y),
                                     transform: scaled(scale),
                                     dim: Float(TransitionMath.dim(offCentre: abs(distance))))
            }
        }
    }

    func present() {
        CATransaction.flush()
        if panel.alphaValue != 1 { alpha = 1 }
        panel.orderFrontRegardless()
        presentedAt = CACurrentMediaTime()
        isVisible = true
    }

    /// Shows the window once at zero alpha, then removes it, so the first real transition does not pay for
    /// WindowServer's first-time setup. A transition that starts meanwhile keeps the window.
    func warmUp(on screen: NSScreen, with snapshot: Snapshot) {
        guard !isVisible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attach(to: screen)
        setCards { $0 == 0 ? .snapshot(snapshot) : .none }
        render(progress: 0)
        CATransaction.commit()
        panel.alphaValue = 0
        CATransaction.flush()
        panel.orderFrontRegardless()
        let generation = membershipGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !self.isVisible, generation == self.membershipGeneration else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.setCards { _ in .none }
        }
    }

    /// Used only by an explicit cache tour, never by LeNotch's normal startup.
    func showLoader(_ loader: Loader?) {
        loaderLayer?.removeFromSuperlayer()
        loaderLayer = nil
        guard let loader, panel.frame.contains(loader.frame) else { return }
        let layer = CAShapeLayer()
        let radius: CGFloat = 5
        layer.bounds = CGRect(x: 0, y: 0, width: radius * 2 + 2, height: radius * 2 + 2)
        layer.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: radius * 2, height: radius * 2), transform: nil)
        layer.fillColor = nil
        layer.strokeColor = loader.color
        layer.lineWidth = 1.5
        layer.strokeEnd = 0.72
        layer.lineCap = .round
        layer.position = CGPoint(x: loader.frame.midX - panel.frame.minX, y: loader.frame.midY - panel.frame.minY)
        layer.zPosition = 10_000
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = CGFloat.pi * 2
        spin.duration = 0.8
        spin.repeatCount = .infinity
        root.addSublayer(layer)
        layer.add(spin, forKey: "spin")
        loaderLayer = layer
    }

    func hide() {
        membershipGeneration += 1
        stopAnimating()
        panel.orderOut(nil)
        // Ready for the next presentation while nothing waits: `present()` then only orders the window in.
        panel.alphaValue = 1
        showLoader(nil)
        isVisible = false
        setCards { _ in .none }
    }

    /// Releases screen-sized textures and display references when the feature is disabled.
    func shutdown() {
        hide()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.contents = nil
        CATransaction.commit()
        screen = nil
        size = .zero
    }

    private static func displayCornerRadius(_ screen: NSScreen) -> CGFloat {
        let selector = NSSelectorFromString("_cornerRadius")
        if screen.responds(to: selector), let method = class_getInstanceMethod(NSScreen.self, selector) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> CGFloat
            let radius = unsafeBitCast(method_getImplementation(method), to: Getter.self)(screen, selector)
            if radius > 0 { return radius }
        }
        return Config.fallbackCornerRadius
    }
}
