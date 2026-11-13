import AppKit
import ApplicationServices
import OSLog

enum FocusSwitchResult: Equatable, Sendable {
    case changed
    case failed(String)
}

/// macOS has no public setter for Focus. Operate its own controls through Accessibility, without making the
/// island's main thread wait for another process. AX elements are created, inspected and discarded on one queue.
@MainActor
enum FocusSwitcher {
    private static let queue = DispatchQueue(label: "com.lenotch.app.focus", qos: .userInitiated)

    static func set(_ mode: String, enabled: Bool) async -> FocusSwitchResult {
        guard !Task.isCancelled else { return .failed("The Focus change was cancelled.") }
        let pids = ["com.apple.MenuBarAgent", "com.apple.controlcenter"].compactMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: FocusAXSwitch(pids: pids, mode: mode, enabled: enabled).run())
            }
        }
    }
}

/// All members are confined to FocusSwitcher's serial queue, including the synchronous AX IPC calls.
private final class FocusAXSwitch {
    private struct Panel {
        let app: AXUIElement
        let window: AXUIElement
    }

    private struct Control {
        let element: AXUIElement
        let panel: Panel
        let rank: Int
    }

    private let pids: [pid_t]
    private let mode: String
    private let enabled: Bool
    private let log = Logger(subsystem: "com.lenotch.app", category: "focus")
    private let deadline = ProcessInfo.processInfo.systemUptime + 4
    private var apps: [AXUIElement] = []
    private var originalPanels: [Panel] = []
    private var openedPanels: [Panel] = []
    private var openedMenu = false
    private var cleaningUp = false
    private var visited = 0
    private let nodeLimit = 1_200

    init(pids: [pid_t], mode: String, enabled: Bool) {
        self.pids = pids
        self.mode = mode
        self.enabled = enabled
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }
    // Keep a little of the request's budget for dismissing a panel we opened.
    private var remaining: Double { (cleaningUp ? deadline : deadline - 0.4) - now }
    private var canInspect: Bool { remaining > 0 && visited < nodeLimit }

    func run() -> FocusSwitchResult {
        guard AXIsProcessTrusted() else {
            return .failed("Allow LeNotch in System Settings → Privacy & Security → Accessibility, then try again.")
        }
        guard !pids.isEmpty else { return .failed("Control Center is unavailable. Try again in a moment.") }
        apps = pids.map(AXUIElementCreateApplication)
        originalPanels = panels()
        defer { closeOpenedPanels() }

        // Reuse an already-open Focus pane. A checkbox/radio is a mode; a module's disclosure button is not.
        if let row = findMode(in: originalPanels, requireSelectionControl: true) { return apply(row) }
        if let module = findModule(in: originalPanels), openModule(module) {
            guard let row = waitForMode() else { return modeNotFound() }
            return apply(row)
        }

        let extras = menuExtras()
        let focus = extras.first { identifier($0)?.lowercased().contains("focus") == true }
        guard let opener = focus ?? extras.first(where: { identifier($0)?.lowercased().contains("controlcenter") == true }) else {
            log.notice("focus: no accessible menu bar opener")
            return .failed("The Focus controls aren't available in the menu bar. Open Control Center and try again.")
        }
        guard press(opener) == .success else { return actionFailed() }
        openedMenu = true

        if focus != nil, let row = waitForMode(timeout: 0.7) { return apply(row) }
        guard let module = waitForModule(), openModule(module) else {
            log.notice("focus: module unavailable")
            return .failed(canInspect
                ? "Couldn't open the Focus controls. Open Control Center → Focus and try again."
                : "Control Center took too long to respond. Try again.")
        }
        guard let row = waitForMode() else { return modeNotFound() }
        return apply(row)
    }

    private func apply(_ row: Control) -> FocusSwitchResult {
        // Do not blindly toggle an optimistic/stale UI selection. Read the actual control first.
        guard let before = selection(row.element) ?? databaseSelection() else {
            return .failed("macOS didn't expose this Focus mode's current state. Open Control Center → Focus and try again.")
        }
        if before == enabled { return .changed }
        guard row.rank >= 100 else {
            // A same-named button can open duration/options rather than change the mode. In particular, never
            // claim an explicit off request succeeded by pressing that disclosure and losing its AX reference.
            return .failed("macOS didn't expose a switch for this Focus mode. Open Control Center → Focus to change it.")
        }
        guard press(row.element) == .success else { return actionFailed() }

        // Checkbox values normally update in place. Some system versions dismiss the pane on a successful press;
        // in that case the readable Focus database can confirm it, but its absence is not evidence of failure.
        let until = min(now + 0.8, deadline - 0.4)
        var lastObserved: Bool?
        repeat {
            if let actual = selection(row.element) ?? databaseSelection() {
                lastObserved = actual
                if actual == enabled { return .changed }
            }
            pause()
        } while canInspect && now < until
        if let lastObserved, lastObserved != enabled {
            log.notice("focus: selection did not change after press")
            return .failed("macOS didn't change the Focus mode. Try again from Control Center → Focus.")
        }
        log.notice("focus: press accepted; selection no longer readable")
        return .changed
    }

    private func databaseSelection() -> Bool? {
        guard canInspect, let state = FocusDatabase.read() else { return nil }
        guard let state else { return false }
        return state.name.compare(mode, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    // MARK: - Find controls (only these two system apps' windows and menu extras)

    private func panels() -> [Panel] {
        var result: [Panel] = []
        for app in apps where remaining > 0 {
            for window in elements(attribute(app, kAXWindowsAttribute)) {
                guard boolean(attribute(window, "AXHidden")) != true,
                      boolean(attribute(window, kAXMinimizedAttribute)) != true else { continue }
                let panel = Panel(app: app, window: window)
                result.append(panel)
                if openedMenu,
                   !originalPanels.contains(where: { CFEqual($0.window, window) }),
                   !openedPanels.contains(where: { CFEqual($0.window, window) }) {
                    openedPanels.append(panel)
                }
            }
        }
        return result
    }

    private func menuExtras() -> [AXUIElement] {
        var result: [AXUIElement] = []
        for app in apps {
            var stack = elements(attribute(app, "AXExtrasMenuBar")).map { ($0, 0) }
            while let (element, depth) = stack.popLast(), canInspect {
                visited += 1
                if string(element, kAXRoleAttribute) == kAXMenuBarItemRole as String {
                    result.append(element)
                } else if depth < 4 {
                    stack += elements(attribute(element, kAXChildrenAttribute)).reversed().map { ($0, depth + 1) }
                }
            }
        }
        return result
    }

    /// Bound both depth and node count. A timeout around a recursive walk alone cannot bound synchronous AX IPC.
    private func find(in panels: [Panel], maxDepth: Int = 12,
                      rank: (AXUIElement) -> Int?) -> Control? {
        var best: Control?
        var count = 0
        for panel in panels {
            var stack = [(panel.window, 0)]
            while let (element, depth) = stack.popLast(), canInspect, count < 180 {
                visited += 1
                count += 1
                if let score = rank(element), best == nil || score > best!.rank {
                    best = Control(element: element, panel: panel, rank: score)
                    if score >= 100 { return best }
                }
                if depth < maxDepth {
                    stack += elements(attribute(element, kAXChildrenAttribute)).reversed().map { ($0, depth + 1) }
                }
            }
        }
        return best
    }

    private func findMode(in panels: [Panel], requireSelectionControl: Bool = false) -> Control? {
        find(in: panels) { element in
            guard let role = string(element, kAXRoleAttribute) else { return nil }
            let selectionControl = [kAXCheckBoxRole as String, kAXRadioButtonRole as String, "AXSwitch"].contains(role)
            guard selectionControl || (!requireSelectionControl && role == kAXButtonRole as String) else { return nil }
            let labels = labels(element)
            guard labels.contains(where: matchesMode) else { return nil }
            let id = identifier(element)?.lowercased() ?? ""
            guard !id.contains("disclosure"), !id.contains("chevron"), !id.contains("options"),
                  actions(element).contains(kAXPressAction as String) else { return nil }
            return selectionControl ? 100 : 50
        }
    }

    private func findModule(in panels: [Panel]) -> Control? {
        find(in: panels) { element in
            let id = identifier(element)?.lowercased() ?? ""
            let title = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) ?? ""
            guard id.contains("focus") || title.caseInsensitiveCompare("Focus") == .orderedSame else { return nil }
            let role = string(element, kAXRoleAttribute) ?? ""
            // A mode itself is not the containing module.
            guard role != kAXCheckBoxRole as String, role != kAXRadioButtonRole as String else { return nil }
            return id.contains("focus") && (role == kAXGroupRole as String || role == kAXButtonRole as String) ? 80 : 40
        }
    }

    private func openModule(_ module: Control) -> Bool {
        let available = actions(module.element)
        if available.contains(kAXShowMenuAction as String) {
            return perform(module.element, kAXShowMenuAction) == .success
        }
        // Press the disclosure, not the module's icon (the icon can toggle Do Not Disturb directly).
        let subtree = Panel(app: module.panel.app, window: module.element)
        if let disclosure = find(in: [subtree], maxDepth: 5, rank: { element in
            let role = string(element, kAXRoleAttribute) ?? ""
            let id = identifier(element)?.lowercased() ?? ""
            guard role == kAXDisclosureTriangleRole as String || id.contains("disclosure") || id.contains("chevron") || id.contains("expand") else { return nil }
            return actions(element).contains(kAXPressAction as String) ? 100 : nil
        }) {
            return press(disclosure.element) == .success
        }
        // An undisclosed module's main press can toggle Do Not Disturb instead of opening its mode list.
        // Don't change an unrelated mode just to discover the requested control.
        return false
    }

    private func waitForMode(timeout: Double = 0.9) -> Control? {
        let until = min(now + timeout, deadline - 0.4)
        repeat {
            if let row = findMode(in: panels()) { return row }
            pause()
        } while canInspect && now < until
        return nil
    }

    private func waitForModule() -> Control? {
        let until = min(now + 0.8, deadline - 0.4)
        repeat {
            if let module = findModule(in: panels()) { return module }
            pause()
        } while canInspect && now < until
        return nil
    }

    // MARK: - State and labels

    private func selection(_ element: AXUIElement) -> Bool? {
        if let value = boolean(attribute(element, kAXValueAttribute)) { return value }
        if let selected = boolean(attribute(element, kAXSelectedAttribute)) { return selected }
        for label in labels(element) {
            if let status = statusSuffix(label) { return status }
        }
        return nil
    }

    private func boolean(_ value: CFTypeRef?) -> Bool? {
        if let number = value as? NSNumber, number == 0 || number == 1 { return number.boolValue }
        guard let text = value as? String else { return nil }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "on", "selected": return true
        case "0", "false", "off", "not selected": return false
        default: return nil
        }
    }

    private func matchesMode(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.caseInsensitiveCompare(mode) == .orderedSame || statusSuffix(text) != nil
    }

    private func statusSuffix(_ text: String) -> Bool? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > mode.count, text.lowercased().hasPrefix(mode.lowercased()) else { return nil }
        let suffix = text.dropFirst(mode.count)
        guard let first = suffix.first, first.isWhitespace || first.isPunctuation else { return nil }
        let status = suffix.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        if ["on", "selected", "focus on", "focus is on"].contains(status) || status.hasPrefix("on until ") { return true }
        if ["off", "not selected", "focus off", "focus is off"].contains(status) { return false }
        return nil
    }

    private func labels(_ element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { string(element, $0) }
    }

    // MARK: - Bounded AX IPC and cleanup

    private func prepare(_ element: AXUIElement) -> Bool {
        guard remaining > 0 else { return false }
        // The timeout belongs to the actual element used for each call, including children, not just its app.
        return AXUIElementSetMessagingTimeout(element, Float(min(0.2, remaining))) == .success
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard prepare(element) else { return nil }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
    private func identifier(_ element: AXUIElement) -> String? { string(element, kAXIdentifierAttribute) }

    private func elements(_ value: CFTypeRef?) -> [AXUIElement] {
        if let list = value as? [AXUIElement] { return Array(list.prefix(180)) }
        if let value, CFGetTypeID(value) == AXUIElementGetTypeID() { return [value as! AXUIElement] }
        return []
    }

    private func actions(_ element: AXUIElement) -> [String] {
        guard prepare(element) else { return [] }
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func perform(_ element: AXUIElement, _ action: String) -> AXError {
        guard prepare(element) else { return .cannotComplete }
        let result = AXUIElementPerformAction(element, action as CFString)
        if result != .success { log.notice("focus: AX action failed (\(result.rawValue))") }
        return result
    }

    private func press(_ element: AXUIElement) -> AXError { perform(element, kAXPressAction) }

    private func pause() {
        if remaining > 0 { Thread.sleep(forTimeInterval: min(0.06, remaining)) }
    }

    private func closeOpenedPanels() {
        guard openedMenu else { return }
        cleaningUp = true
        // Remember panels that appeared even if opening the module failed. Never toggle the menu bar opener:
        // the system may already have closed it, in which case pressing the opener would open it again.
        _ = panels()
        for panel in openedPanels.reversed() where remaining > 0 {
            guard elements(attribute(panel.app, kAXWindowsAttribute)).contains(where: { CFEqual($0, panel.window) }),
                  boolean(attribute(panel.window, "AXHidden")) != true else { continue }
            if actions(panel.window).contains(kAXCancelAction as String),
               perform(panel.window, kAXCancelAction) == .success { continue }
            guard prepare(panel.app) else { return }
            var pid: pid_t = 0
            guard AXUIElementGetPid(panel.app, &pid) == .success,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else { continue }
            down.flags = []
            up.flags = []
            // Target Escape at this panel's process, never at the user's frontmost app. Always send the pair.
            down.postToPid(pid)
            up.postToPid(pid)
        }
    }

    private func modeNotFound() -> FocusSwitchResult {
        log.notice("focus: mode row unavailable")
        return .failed(canInspect
            ? "This Focus mode wasn't found. Add it in System Settings → Focus, then try again."
            : "Control Center took too long to respond. Try again.")
    }

    private func actionFailed() -> FocusSwitchResult {
        .failed("macOS couldn't press the Focus control. Check LeNotch's Accessibility permission and try again.")
    }
}
