import AppKit
import SwiftUI

/// The reader occupies the activity card, while editing happens in a normal native window.
struct PrompterCard: View {
    let director: IslandDirector
    @Environment(\.islandMotion) private var motion
    @Environment(\.revealed) private var revealed
    @State private var visible = false
    @State private var words = 0

    private var model: PrompterModel { director.prompter }
    private var playing: Bool { model.phase == .playing || model.phase == .countdown }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(IslandColor.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title.isEmpty ? "Prompter" : model.title)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(words) \(words == 1 ? "word" : "words")")
                        .font(.system(size: 10)).foregroundStyle(IslandColor.secondary)
                }
                Spacer(minLength: 6)
                PrompterIconButton(symbol: "square.and.pencil", label: "Edit script", help: "Edit script (E)") {
                    model.pause()
                    director.editPrompter()
                }
                PrompterIconButton(symbol: "xmark", label: "Close prompter", help: "Close prompter (Escape)") {
                    director.stopPrompter()
                }
            }
            .frame(height: 30)

            ZStack {
                if model.canPlay {
                    Group {
                        if motion.stills {
                            // ImageRenderer cannot capture AppKit-backed views. Match the native reader's
                            // typography in the existing offscreen-still path; live playback always uses AppKit.
                            Text(model.text)
                                .font(.system(size: model.fontSize, weight: .medium))
                                .lineSpacing(model.fontSize * 0.28)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 2).padding(.top, 8)
                                .offset(y: -model.offset)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            PrompterReader(
                                model: model, text: model.text, fontSize: model.fontSize,
                                offset: model.offset, advancing: playing, visible: visible && revealed,
                                onStop: { director.stopPrompter() },
                                onEdit: { model.pause(); director.editPrompter() }
                            )
                        }
                    }
                    // Only this text viewport is mirrored, never the buttons or countdown.
                    .scaleEffect(x: model.mirrored ? -1 : 1, y: 1)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.07),
                            .init(color: .black, location: 0.87),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .help("Click the script for keyboard controls. Space to pause, R to restart, ↑ or ↓ to change speed.")

                    if model.phase == .countdown {
                        Color.black.opacity(0.75)
                        VStack(spacing: 4) {
                            Text("\(max(1, Int(model.countdownRemaining.rounded(.up))))")
                                .font(.system(size: 48, weight: .semibold).monospacedDigit())
                                .foregroundStyle(IslandColor.green)
                            Text("Get ready").font(.system(size: 12)).foregroundStyle(IslandColor.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .allowsHitTesting(false)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 24, weight: .light)).foregroundStyle(IslandColor.secondary)
                        Text("Add a script to begin").font(.system(size: 15, weight: .medium))
                        Button("Write or import a script") { director.editPrompter() }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(IslandColor.green)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    PrompterIconButton(
                        symbol: playing ? "pause.fill" : "play.fill",
                        label: playing ? "Pause prompter" : model.phase == .finished ? "Replay script" : "Play prompter",
                        help: "Play or pause (Space)", prominent: true
                    ) { model.togglePlayback() }
                    .disabled(!model.canPlay)
                    PrompterIconButton(symbol: "arrow.counterclockwise", label: "Restart script", help: "Restart script (R)") {
                        model.restart()
                    }
                    .disabled(!model.canPlay)
                    Spacer(minLength: 2)
                    PrompterStepper(label: "Scroll speed", value: model.speed, range: 5...120, step: 5, suffix: "pt/s") {
                        model.speed = $0
                    }
                    PrompterStepper(label: "Text size", value: model.fontSize, range: 16...48, step: 2, suffix: "pt") {
                        model.fontSize = $0
                    }
                    PrompterIconButton(
                        symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                        label: model.mirrored ? "Turn off mirrored text" : "Mirror text",
                        help: "Mirror text for a teleprompter display", selected: model.mirrored
                    ) { model.mirrored.toggle() }
                }
                .frame(height: 30)

                HStack(spacing: 8) {
                    Text(status).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(model.phase == .paused ? IslandColor.orange : IslandColor.secondary)
                        .frame(minWidth: 42, alignment: .leading)
                    LineBar(progress: model.progress, tint: IslandColor.green).frame(height: 3)
                    Text("\(Int((model.progress * 100).rounded()))%")
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(IslandColor.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(status), \(Int((model.progress * 100).rounded())) percent complete")
            }
        }
        // The 332-point activity card reserves 20 points above and below its content.
        .frame(height: 292)
        .foregroundStyle(.white)
        .onAppear { visible = true; countWords() }
        .onChange(of: model.text) { _, _ in countWords() }
        .onDisappear { visible = false; model.pause() }
    }

    private func countWords() { words = model.text.split(whereSeparator: \.isWhitespace).count }

    private var status: String {
        switch model.phase {
        case .ready: "Ready"
        case .countdown: "Starting"
        case .playing: "Reading"
        case .paused: "Paused"
        case .finished: "Finished"
        }
    }
}

private struct PrompterIconButton: View {
    let symbol: String
    let label: String
    var help: String = ""
    var prominent = false
    var selected = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? .black : selected ? IslandColor.green : .white)
                .frame(width: 30, height: 30)
                .background(Capsule().fill(prominent ? IslandColor.green : .white.opacity(selected ? 0.18 : 0.12)))
                .contentShape(Capsule()).opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(PressScaleStyle(pressed: 0.94, hover: 1.04))
        .help(help.isEmpty ? label : help)
        .accessibilityLabel(label)
    }
}

private struct PrompterStepper: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", label: "Decrease \(label.lowercased())", enabled: value > range.lowerBound) {
                set(max(range.lowerBound, value - step))
            }
            Text("\(Int(value.rounded())) \(suffix)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .frame(width: suffix == "pt/s" ? 48 : 38)
                .accessibilityLabel("\(label), \(Int(value.rounded())) \(suffix)")
            stepButton("plus", label: "Increase \(label.lowercased())", enabled: value < range.upperBound) {
                set(min(range.upperBound, value + step))
            }
        }
        .background(Capsule().fill(.white.opacity(0.08)))
        .help(label)
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                .frame(width: 22, height: 28).contentShape(Rectangle())
                .foregroundStyle(.white.opacity(enabled ? 0.8 : 0.25))
        }
        .buttonStyle(.plain).disabled(!enabled).accessibilityLabel(label).help(label)
    }
}

/// Native text layout keeps fractional scroll positions and remains accessible to VoiceOver.
/// The timer belongs to this visible reader, not to a permanently running application service.
struct PrompterReader: NSViewRepresentable {
    let model: PrompterModel
    let text: String
    let fontSize: Double
    let offset: Double
    let advancing: Bool
    let visible: Bool
    let onStop: @MainActor () -> Void
    let onEdit: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PrompterScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.contentView.postsBoundsChangedNotifications = true

        let textView = PrompterTextView(frame: .zero)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 2, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Teleprompter script")
        scroll.documentView = textView
        context.coordinator.attach(scroll, textView: textView)
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(text: text, fontSize: fontSize, offset: offset,
                                   advancing: advancing, visible: visible, onStop: onStop, onEdit: onEdit)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    @MainActor final class Coordinator: NSObject {
        private let model: PrompterModel
        private weak var scroll: PrompterScrollView?
        private weak var textView: PrompterTextView?
        private var timer: Timer?
        private var previousTick: TimeInterval?
        private var updatingScroll = false
        private var layingOut = false
        private var layoutQueued = false
        private var visible = false
        private var advancing = false
        private var lastText: String?
        private var lastFontSize: Double?
        private var lastWidth: CGFloat = 0
        private var lastHeight: CGFloat = 0
        private var onStop: (@MainActor () -> Void)?
        private var onEdit: (@MainActor () -> Void)?

        init(model: PrompterModel) { self.model = model }

        fileprivate func attach(_ scroll: PrompterScrollView, textView: PrompterTextView) {
            self.scroll = scroll
            self.textView = textView
            scroll.layoutChanged = { [weak self] in self?.scheduleLayout() }
            scroll.visibilityChanged = { [weak self] in self?.reconcileTimer() }
            textView.handleKey = { [weak self] in self?.handleKey($0) ?? false }
            NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        }

        func update(text: String, fontSize: Double, offset: Double, advancing: Bool, visible: Bool,
                    onStop: @escaping @MainActor () -> Void, onEdit: @escaping @MainActor () -> Void) {
            self.visible = visible
            self.advancing = advancing
            self.onStop = onStop
            self.onEdit = onEdit
            if lastText != text || lastFontSize != fontSize {
                lastText = text
                lastFontSize = fontSize
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = fontSize * 0.28
                paragraph.paragraphSpacing = fontSize * 0.4
                paragraph.lineBreakMode = .byWordWrapping
                textView?.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: paragraph
                ]))
                lastWidth = 0
                scheduleLayout()
            }
            synchronizeScroll(to: offset)
            reconcileTimer()
        }

        private func scheduleLayout() {
            guard !layoutQueued else { return }
            layoutQueued = true
            // Layout can arrive inside a SwiftUI update. Publish the measured extent afterward.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.layoutQueued = false
                self.layoutText()
            }
        }

        private func layoutText() {
            guard let scroll, let textView, let container = textView.textContainer,
                  let manager = textView.layoutManager else { return }
            let viewport = scroll.contentSize
            guard viewport.width > 1, viewport.height > 1 else { return }
            guard viewport.width != lastWidth || viewport.height != lastHeight else {
                reconcileTimer()
                return
            }
            lastWidth = viewport.width
            lastHeight = viewport.height
            layingOut = true
            defer { layingOut = false }
            textView.setFrameSize(NSSize(width: viewport.width, height: max(textView.frame.height, viewport.height)))
            container.containerSize = NSSize(width: max(1, viewport.width - 4), height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            let glyphs = manager.numberOfGlyphs
            // A viewport-sized trailing region lets the final line reach the reading position.
            let lastLineTop = glyphs > 0
                ? manager.lineFragmentRect(forGlyphAt: glyphs - 1, effectiveRange: nil).minY : 0
            let extent = max(0, Double(lastLineTop))
            textView.setFrameSize(NSSize(width: viewport.width, height: viewport.height + extent))
            if abs(model.maxOffset - extent) > 0.25 { model.updateExtent(extent) }
            synchronizeScroll(to: model.offset)
            reconcileTimer()
        }

        private func synchronizeScroll(to offset: Double) {
            guard let scroll else { return }
            let target = max(0, min(offset, max(0, (textView?.frame.height ?? 0) - scroll.contentSize.height)))
            guard abs(scroll.contentView.bounds.origin.y - target) > 0.01 else { return }
            updatingScroll = true
            scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
            updatingScroll = false
        }

        @objc private func didScroll(_ notification: Notification) {
            guard !updatingScroll, !layingOut, let scroll else { return }
            let offset = Double(scroll.contentView.bounds.origin.y)
            if abs(offset - model.offset) > 0.25 { model.seek(to: offset) }
        }

        @objc private func visibilityChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, window === scroll?.window else { return }
            reconcileTimer()
        }

        private var isVisible: Bool {
            guard visible, let scroll, let window = scroll.window else { return false }
            return window.isVisible && window.occlusionState.contains(.visible)
                && !scroll.isHiddenOrHasHiddenAncestor && !scroll.visibleRect.isEmpty
        }

        private func reconcileTimer() {
            guard advancing, isVisible else {
                timer?.invalidate()
                timer = nil
                previousTick = nil
                return
            }
            guard timer == nil else { return }
            previousTick = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.002
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func tick() {
            guard isVisible else {
                reconcileTimer()
                return
            }
            guard model.phase == .playing || model.phase == .countdown else {
                advancing = false
                reconcileTimer()
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - (previousTick ?? now)
            previousTick = now
            // Sleep, debugging, or a blocked run loop must not skip several lines on return.
            guard elapsed >= 0, elapsed < 0.5 else { return }
            model.advance(by: min(elapsed, 0.1))
            synchronizeScroll(to: model.offset)
        }

        private func handleKey(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            switch event.keyCode {
            case 49: if !event.isARepeat { model.togglePlayback() }
            case 15: if !event.isARepeat { model.restart() }
            case 53: onStop?()
            case 126: model.speed = min(120, model.speed + 5)
            case 125: model.speed = max(5, model.speed - 5)
            case 14: if !event.isARepeat { model.pause(); onEdit?() }
            default: return false
            }
            return true
        }

        func invalidate() {
            visible = false
            timer?.invalidate()
            timer = nil
            previousTick = nil
            NotificationCenter.default.removeObserver(self)
            scroll?.layoutChanged = nil
            scroll?.visibilityChanged = nil
            textView?.handleKey = nil
            onStop = nil
            onEdit = nil
        }
    }
}

@MainActor private final class PrompterScrollView: NSScrollView {
    var layoutChanged: (() -> Void)?
    var visibilityChanged: (() -> Void)?

    override func layout() { super.layout(); layoutChanged?() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); visibilityChanged?() }
    override func viewDidHide() { super.viewDidHide(); visibilityChanged?() }
    override func viewDidUnhide() { super.viewDidUnhide(); visibilityChanged?() }
}

@MainActor private final class PrompterTextView: NSTextView {
    var handleKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Taking a responder within this panel does not activate LeNotch or another app.
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if handleKey?(event) != true { super.keyDown(with: event) }
    }
}
