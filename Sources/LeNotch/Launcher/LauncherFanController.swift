import AppKit
import SwiftUI
import IslandCore

/// Independent transparent surface: opening Launcher never allocates a rectangular island card.
@MainActor final class LauncherFanController {
    let state: LauncherFanState
    let panel: NSPanel
    private(set) var isOpen = false
    var onVisibilityChanged: ((Bool) -> Void)?
    private var geometry: NotchGeometry?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var generation = 0
    private var transition: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(model: LauncherModel = .shared) {
        state = LauncherFanState(model: model)
        panel = NotchPanel()
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        panel.setAccessibilityElement(false)
        panel.setAccessibilityLabel("Launcher")
    }

    func updateGeometry(_ geometry: NotchGeometry?) {
        if self.geometry != geometry { hide(animated: false) }
        self.geometry = geometry
    }

    func toggle(showsControls: Bool = true) { isOpen ? hide() : show(showsControls: showsControls) }

    func show(showsControls: Bool = true) {
        guard let geometry else { return }
        if isOpen { return }
        generation += 1
        let current = generation
        transition?.cancel()
        let width = min(680, geometry.screenFrame.width - 24)
        state.layout = LauncherFanLayout(width: width, notchWidth: geometry.notchWidth, notchHeight: geometry.notchHeight)
        state.reset()
        state.showsControls = showsControls
        state.model.clearError()
        state.setPresented(true)
        panel.setFrame(geometry.panelFrame(size: NSSize(width: state.layout.width, height: LauncherFanLayout.height)), display: false)
        panel.contentView = NSHostingView(rootView: LauncherView(state: state, reduceMotion: reduceMotion,
            onClose: { [weak self] in self?.hide() },
            onConfigure: { [weak self] in
                guard let self else { return }
                hide(animated: false)
                LauncherEditor.shared.show(model: state.model)
            }, onLaunch: { [weak self] in self?.launch($0) }))
        panel.contentView?.layoutSubtreeIfNeeded()
        isOpen = true
        onVisibilityChanged?(true)
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
        updatePointer()
        transition = Task { [weak self] in
            try? await Task.sleep(for: .seconds(LauncherDropMotion.openingDuration))
            guard let self, !Task.isCancelled, generation == current else { return }
            state.finishTransition()
        }
    }

    func hide(animated: Bool = true) {
        guard isOpen || panel.isVisible else { return }
        isOpen = false
        generation += 1
        let current = generation
        transition?.cancel()
        state.setPresented(false)
        panel.ignoresMouseEvents = true
        panel.resignKey()
        removeMonitors()
        onVisibilityChanged?(false)
        if !animated { state.finishTransition(); panel.orderOut(nil); return }
        let duration = reduceMotion ? 0.13 : LauncherDropMotion.closingDuration
        transition = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled, generation == current else { return }
            state.finishTransition()
            panel.orderOut(nil)
        }
    }

    func stop() {
        hide(animated: false)
        transition?.cancel()
        launchTask?.cancel()
        removeMonitors()
    }

    func contains(screenPoint: NSPoint) -> Bool {
        guard isOpen else { return false }
        let point = CGPoint(x: screenPoint.x - panel.frame.minX, y: panel.frame.maxY - screenPoint.y)
        if state.items.isEmpty && state.layout.empty.contains(point) { return true }
        if state.showsControls && state.layout.controls.contains(point) { return true }
        return state.items.indices.contains { index in
            let pose = state.pose(index: index, at: Date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
            return pose.reveal > 0.95 && CGRect(x: pose.center.x - 50, y: pose.center.y - 36, width: 100, height: 108).contains(point)
        }
    }

    func launch(_ item: LauncherItem) {
        guard isOpen, launchTask == nil, !state.model.isLaunching else { return }
        let current = generation
        launchTask = Task { [weak self] in
            guard let self else { return }
            defer { launchTask = nil }
            if await state.model.launch(item), generation == current { hide() }
        }
    }

    private func updatePointer() {
        panel.ignoresMouseEvents = !contains(screenPoint: NSEvent.mouseLocation)
    }

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handle(event) }
            return handled ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handle(event) }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    /// True only when a keyboard event was handled; outside clicks must continue to their original destination.
    @discardableResult private func handle(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        if event.type == .mouseMoved { updatePointer(); return false }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            dismissIfOutside(NSEvent.mouseLocation)
            return false
        }
        guard event.type == .keyDown, panel.isKeyWindow else { return false }
        return handleKey(event.keyCode, modifiers: event.modifierFlags)
    }

    func dismissIfOutside(_ screenPoint: NSPoint) {
        if isOpen && !contains(screenPoint: screenPoint) { hide() }
    }

    @discardableResult func handleKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard isOpen else { return false }
        // Launcher temporarily owns keyboard focus. Do not reinterpret modified AppKit shortcuts.
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        switch keyCode {
        case 53: hide(); return true
        case 123, 126: state.moveSelection(-1); return true
        case 124, 125: state.moveSelection(1); return true
        case 116, 121:
            if !state.animating { state.changePage(keyCode == 116 ? -1 : 1) }
            return true
        case 36, 76:
            if let item = state.selection { launch(item) }
            return true
        default: return false
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        localMonitor = nil
        globalMonitor = nil
        activationObserver = nil
    }
}
