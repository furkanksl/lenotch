import AppKit
import SwiftUI

/// Settings → Tools: one list for the notch's menu. Each row is a tool with its shortcut and its visibility, and rows
/// are reordered by dragging them. The drag is tracked from the pointer itself (no pasteboard, no drop types), so the
/// row follows the cursor, the others slide out of its way, and the page scrolls when the cursor holds near an edge.
struct SetupToolsPage: View {
    let model: ToolMenuModel
    let shortcuts: ToolShortcutSettings
    @State private var recordingTarget: ToolShortcutTarget?
    @State private var session: ToolReorderSession
    @State private var scroller = ToolsScrollHandle()
    @State private var recorderMessage: (tool: TrayTool, text: String)?
    @State private var showingPreview = false
    @State private var autoScroll: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: ToolMenuModel = .shared, shortcuts: ToolShortcutSettings = .shared,
         session: ToolReorderSession = ToolReorderSession()) {
        self.model = model
        self.shortcuts = shortcuts
        _session = State(initialValue: session)
    }

    private var settle: Animation? { reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12) }
    private var order: [TrayTool] { session.isActive ? session.displayOrder(model.orderedTools) : model.orderedTools }

    private var statusMessage: String? {
        if let recorderMessage { return "\(recorderMessage.tool.title) · \(recorderMessage.text)" }
        if let failure = ToolShortcutTarget.allCases.compactMap({ target in
            shortcuts.failures[target].map { "\(target.title) · \($0)" }
        }).first { return failure }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let message = statusMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12))
                    Text(message).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(SetupTheme.accent)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SetupTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity)
                .accessibilityLabel(message)
            }
            list
            Text("Dictation’s Fn hold works independently of its shortcut.")
                .font(.system(size: 11)).foregroundStyle(SetupTheme.textTertiary)
        }
        .animation(settle, value: statusMessage)
        .background(ToolsScrollHandleReader(handle: scroller))
        .onChange(of: recordingTarget) { _, now in if now == nil { recorderMessage = nil } }
        .onChange(of: session.targetIndex) { _, _ in
            if session.isActive { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default) }
        }
        #if DEBUG
        .onAppear { ToolReorderSession.live = session }
        #endif
        .onDisappear {
            cancelRecording()
            endAutoScroll()
            session.cancel()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Your menu").font(.system(size: 14, weight: .bold)).foregroundStyle(SetupTheme.text)
            Text("\(model.visible.count) of \(model.orderedTools.count) shown")
                .font(.system(size: 12)).foregroundStyle(SetupTheme.textTertiary)
            Spacer(minLength: 8)
            if model.hasCustomOrder {
                Button("Restore order") {
                    cancelRecording()
                    withAnimation(settle) { model.restoreOrder() }
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(SetupTheme.textSecondary)
                .help("Put the tools back in their original order. Shortcuts and visibility stay as they are.")
                .transition(.opacity)
            }
            Button { cancelRecording(); showingPreview.toggle() } label: {
                Label("Preview", systemImage: "rectangle.grid.3x2").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(SetupTheme.textSecondary)
            .popover(isPresented: $showingPreview, arrowEdge: .bottom) {
                ToolsMenuPreview(model: model).padding(18).background(Color.black)
            }
        }
        .animation(settle, value: model.hasCustomOrder)
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(order) { tool in
                SetupToolRow(
                    tool: tool, model: model, shortcuts: shortcuts, session: session,
                    isLast: tool == order.last, recordingTarget: $recordingTarget,
                    report: { recorderMessage = $0.map { (tool, $0) } },
                    beginDrag: { startY in beginDrag(tool, startY: startY) },
                    moveDrag: { y in session.move(to: y) },
                    endDrag: endDrag
                )
                .zIndex(session.tool == tool ? 1 : 0)
            }
        }
        .animation(session.isActive ? settle : nil, value: order)
        .background(SetupTheme.row, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SetupTheme.ring, lineWidth: 1))
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { session.listTop = $0 }
    }

    // MARK: Dragging

    private func beginDrag(_ tool: TrayTool, startY: CGFloat) {
        guard !session.isActive, let index = model.orderedTools.firstIndex(of: tool) else { return }
        cancelRecording()
        session.begin(tool, index: index, count: model.orderedTools.count, startY: startY)
        startAutoScroll()
    }

    private func endDrag() {
        endAutoScroll()
        let result = session.result
        withAnimation(settle) {
            if let result { model.move(result.tool, by: result.delta) }
            session.cancel()
        }
    }

    private func startAutoScroll() {
        autoScroll?.cancel()
        autoScroll = Task { @MainActor in
            while !Task.isCancelled, session.isActive {
                try? await Task.sleep(for: .milliseconds(16))
                guard let viewport = scroller.viewport else { continue }
                let step = session.scrollStep(viewportTop: viewport.top, viewportBottom: viewport.bottom)
                if step != 0 { scroller.scroll(by: step) }
            }
        }
    }

    private func endAutoScroll() {
        autoScroll?.cancel()
        autoScroll = nil
    }

    private func cancelRecording() {
        guard recordingTarget != nil else { return }
        recordingTarget = nil
        shortcuts.endRecording()
    }

    /// Shared with the native switch tests.
    func isOn(_ tool: TrayTool) -> Binding<Bool> {
        Binding(get: { model.isEnabled(tool) }, set: { model.setEnabled(tool, $0) })
    }
}

// MARK: - Row

struct SetupToolRow: View {
    let tool: TrayTool
    let model: ToolMenuModel
    let shortcuts: ToolShortcutSettings
    let session: ToolReorderSession
    let isLast: Bool
    @Binding var recordingTarget: ToolShortcutTarget?
    let report: (String?) -> Void
    let beginDrag: (CGFloat) -> Void
    let moveDrag: (CGFloat) -> Void
    let endDrag: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var target: ToolShortcutTarget { ToolShortcutTarget(rawValue: tool.rawValue)! }
    private var recording: Bool { recordingTarget == target }
    private var dragging: Bool { session.tool == tool }
    private var visible: Bool { model.isEnabled(tool) }
    private var index: Int { model.orderedTools.firstIndex(of: tool) ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            identity
            ToolShortcutRecorder(target: target, settings: shortcuts, recordingTarget: $recordingTarget,
                                 compact: true, reportError: report)
                .frame(width: 112)
            Toggle("Show \(tool.menuLabel) in menu", isOn: Binding(
                get: { model.isEnabled(tool) },
                set: { stopRecording(); model.setEnabled(tool, $0) }))
                .labelsHidden().toggleStyle(ToolSwitchStyle())
                .disabled(!model.canDisable(tool))
                .frame(width: 64)
                .help(model.canDisable(tool) ? "Hiding a tool keeps its shortcut working."
                                             : "Keep at least one tool in the menu.")
            optionsMenu.frame(width: 34)
        }
        .frame(height: ToolReorderSession.rowHeight)
        .background {
            if dragging {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SetupTheme.lifted)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SetupTheme.ringStrong, lineWidth: 1))
                    .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
                    .padding(.horizontal, 4)
            } else if recording {
                SetupTheme.accent.opacity(0.06)
            } else if hovered && !session.isActive {
                SetupTheme.rowHover
            }
        }
        .overlay(alignment: .bottom) {
            if !isLast && !dragging {
                SetupTheme.ring.frame(height: 1).padding(.leading, 60).padding(.trailing, 16)
            }
        }
        .scaleEffect(dragging ? 1.012 : 1)
        .offset(y: dragging ? session.draggedOffset : 0)
        // The dragged row tracks the pointer exactly; only the rows around it animate.
        .transaction { if dragging { $0.animation = nil } }
        .onHover { hovered = $0 }
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-tool-\(tool.rawValue)")
        .accessibilityAction(named: "Move up") { model.move(tool, by: -1) }
        .accessibilityAction(named: "Move down") { model.move(tool, by: 1) }
    }

    /// The left side of the row is the handle: grip, icon and name all start a drag.
    private var identity: some View {
        HStack(spacing: 12) {
            ToolGrip(active: hovered || dragging)
            ToolIconView(icon: tool.icon).frame(width: 18, height: 18)
                .foregroundStyle(visible ? SetupTheme.ink(0.7, 0.75) : SetupTheme.textFaint)
                .frame(width: 32, height: 32)
                .background(SetupTheme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.title).font(.system(size: 14, weight: .semibold)).tracking(-0.2).lineLimit(1)
                    .foregroundStyle(visible ? SetupTheme.text : SetupTheme.textTertiary)
                if tool == .notifications {
                    Text("Shown as Inbox").font(.system(size: 11)).foregroundStyle(SetupTheme.textTertiary)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .pointerStyle(dragging ? .grabActive : .grabIdle)
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging { beginDrag(value.startLocation.y) }
                    moveDrag(value.location.y)
                }
                .onEnded { _ in endDrag() }
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow]) { press in
            guard press.modifiers.contains(.option), recordingTarget == nil else { return .ignored }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12)) { model.move(tool, by: -1) }
            return .handled
        }
        .onKeyPress(keys: [.downArrow]) { press in
            guard press.modifiers.contains(.option), recordingTarget == nil else { return .ignored }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12)) { model.move(tool, by: 1) }
            return .handled
        }
        .help("Drag to reorder")
        .accessibilityLabel("\(tool.title), position \(index + 1) of \(model.orderedTools.count)")
        .accessibilityHint("Drag to reorder, or press Option and an arrow key")
    }

    private var optionsMenu: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SetupTheme.textSecondary).frame(width: 26, height: 30).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .opacity(hovered || recording ? 1 : 0)
        .accessibilityLabel("Options for \(tool.title)")
    }

    @ViewBuilder private var actions: some View {
        Button(shortcuts.binding(for: target) == nil ? "Add shortcut" : "Change shortcut") {
            report(nil)
            shortcuts.beginRecording()
            recordingTarget = target
        }
        Button("Clear shortcut") {
            stopRecording()
            _ = shortcuts.setBinding(nil, for: target)
        }.disabled(shortcuts.binding(for: target) == nil)
        Button("Use default\(target.defaultBinding.map { " (\($0.display))" } ?? " (none)")") {
            stopRecording()
            if !shortcuts.reset(target) { report("That shortcut is assigned to another tool.") }
        }.disabled(shortcuts.binding(for: target) == target.defaultBinding)
        Divider()
        Button("Move up") { stopRecording(); model.move(tool, by: -1) }.disabled(index == 0)
        Button("Move down") { stopRecording(); model.move(tool, by: 1) }.disabled(index == model.orderedTools.count - 1)
    }

    private func stopRecording() {
        report(nil)
        guard recordingTarget != nil else { return }
        recordingTarget = nil
        shortcuts.endRecording()
    }
}

// MARK: - Pieces

/// Six dots, two by three: the usual "this moves" handle.
private struct ToolGrip: View {
    let active: Bool
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    Circle().frame(width: 2.6, height: 2.6)
                    Circle().frame(width: 2.6, height: 2.6)
                }
            }
        }
        .foregroundStyle(active ? SetupTheme.ink(0.5, 0.55) : SetupTheme.ink(0.22, 0.28))
        .frame(width: 14, height: 24)
        .accessibilityHidden(true)
    }
}

/// A compact version of Settings' orange switch, sized for a dense list.
struct ToolSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? SetupTheme.accent : SetupTheme.ink(0.1, 0.12))
                .overlay(Capsule().strokeBorder(on ? SetupTheme.accent.opacity(0.25) : SetupTheme.ring, lineWidth: 1))
            Circle().fill(.white)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .padding(2.5)
                .frame(width: 24, height: 24)
        }
        .frame(width: 42, height: 24)
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Capsule())
        .onTapGesture {
            guard enabled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { configuration.isOn.toggle() }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: on)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

private struct ToolsMenuPreview: View {
    let model: ToolMenuModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("YOUR NOTCH MENU").font(.system(size: 9, weight: .semibold)).tracking(1.3)
                .foregroundStyle(.white.opacity(0.5))
            VStack(spacing: 14) {
                ForEach(model.rows.indices, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(model.rows[row]) { tool in
                            VStack(spacing: 6) {
                                ToolIconView(icon: tool.icon).frame(width: 22, height: 22)
                                    .frame(width: 40, height: 40)
                                    .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                                Text(tool.menuLabel).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(width: 290 / CGFloat(model.columnCount))
                        }
                    }
                    .frame(width: 290)
                }
            }
            Text("The menu updates as you edit.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
        }
        .foregroundStyle(.white).frame(width: 290)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Reorder geometry

/// The state of one drag, kept free of views so its arithmetic can be tested. Positions are in the window's
/// top-left space: the pointer, and the top of the list (which moves when the page scrolls).
@MainActor @Observable
final class ToolReorderSession {
    static let rowHeight: CGFloat = 48
    /// How close to the page's edge the pointer must be before it scrolls, and the fastest it goes (points a tick).
    static let edgeZone: CGFloat = 64
    static let maximumStep: CGFloat = 16

    private(set) var tool: TrayTool?
    private(set) var startIndex = 0
    private(set) var count = 0
    private(set) var pointerY: CGFloat = 0
    private var grabOffset: CGFloat = 0
    var listTop: CGFloat = 0

    var isActive: Bool { tool != nil }

    #if DEBUG
    /// The session of the Tools page now on screen, for the development self-test.
    static weak var live: ToolReorderSession?
    #endif

    func begin(_ tool: TrayTool, index: Int, count: Int, startY: CGFloat) {
        self.tool = tool
        startIndex = index
        self.count = count
        pointerY = startY
        // Where inside its row the pointer took hold, so the row doesn't jump to centre under it.
        grabOffset = startY - listTop - CGFloat(index) * Self.rowHeight
    }

    func move(to y: CGFloat) { pointerY = y }

    func cancel() { tool = nil }

    /// The top of the dragged row in list space, held inside the list.
    var draggedTop: CGFloat {
        let raw = pointerY - listTop - grabOffset
        return min(max(raw, 0), CGFloat(max(count - 1, 0)) * Self.rowHeight)
    }

    /// The slot the row would drop into: the nearest one to where its top is.
    var targetIndex: Int {
        guard tool != nil, count > 0 else { return 0 }
        return min(max(Int((draggedTop / Self.rowHeight).rounded()), 0), count - 1)
    }

    /// How far the dragged row sits from the slot it currently occupies in the list.
    var draggedOffset: CGFloat { draggedTop - CGFloat(targetIndex) * Self.rowHeight }

    /// The tools in the order they would take if the drag ended now.
    func displayOrder(_ order: [TrayTool]) -> [TrayTool] {
        guard let tool, let from = order.firstIndex(of: tool) else { return order }
        var next = order
        next.remove(at: from)
        next.insert(tool, at: min(max(targetIndex, 0), next.count))
        return next
    }

    /// What dropping now would do, or nil when the row ends where it began.
    var result: (tool: TrayTool, delta: Int)? {
        guard let tool, targetIndex != startIndex else { return nil }
        return (tool, targetIndex - startIndex)
    }

    /// How far to scroll this tick: toward the edge the pointer is holding near, faster the closer it gets.
    func scrollStep(viewportTop: CGFloat, viewportBottom: CGFloat) -> CGFloat {
        guard isActive else { return 0 }
        let zone = Self.edgeZone
        if pointerY < viewportTop + zone {
            let depth = min((viewportTop + zone - pointerY) / zone, 1.5)
            return -Self.maximumStep * depth
        }
        if pointerY > viewportBottom - zone {
            let depth = min((pointerY - (viewportBottom - zone)) / zone, 1.5)
            return Self.maximumStep * depth
        }
        return 0
    }
}

// MARK: - Scrolling the page

/// The Settings page scrolls in an NSScrollView that SwiftUI owns. This finds it so a drag can scroll the page.
@MainActor
final class ToolsScrollHandle {
    weak var scrollView: NSScrollView?

    /// The visible part of the page, in the window's top-left space.
    var viewport: (top: CGFloat, bottom: CGFloat)? {
        guard let scrollView, let window = scrollView.window else { return nil }
        let rect = scrollView.convert(scrollView.bounds, to: nil)
        let height = window.contentView?.bounds.height ?? window.frame.height
        return (height - rect.maxY, height - rect.minY)
    }

    @discardableResult
    func scroll(by delta: CGFloat) -> CGFloat {
        guard let scrollView, let document = scrollView.documentView else { return 0 }
        let clip = scrollView.contentView
        let maximum = max(0, document.frame.height - clip.bounds.height)
        let target = min(max(clip.bounds.origin.y + delta, 0), maximum)
        let applied = target - clip.bounds.origin.y
        guard applied != 0 else { return 0 }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
        return applied
    }
}

private struct ToolsScrollHandleReader: NSViewRepresentable {
    let handle: ToolsScrollHandle
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in handle.scrollView = view?.enclosingScrollView }
    }
}

private extension SetupTheme {
    /// A row picked up off the list: lighter than the list in both appearances so it reads as raised.
    static let lifted = dynamic(.white, .setupHex(0x262624))
}
