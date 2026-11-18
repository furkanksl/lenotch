import Foundation
import Observation

/// One entry of the notch's tools menu, in its default order.
enum TrayTool: String, CaseIterable, Identifiable {
    case chat, dictation, prompter, today, launcher, clipboard, shelf, shortcuts, usage, system, todo, notes, notifications

    var id: Self { self }

    /// The name in Setup.
    var title: String {
        switch self {
        case .chat: "Chat"
        case .dictation: "Dictation"
        case .prompter: "Prompter"
        case .today: "Today"
        case .launcher: "Launcher"
        case .clipboard: "Clipboard"
        case .shelf: "Shelf"
        case .shortcuts: "Shortcuts"
        case .usage: "Usage"
        case .system: "System"
        case .todo: "To-do"
        case .notes: "Notes"
        case .notifications: "Notifications"
        }
    }

    /// The label under its button. Short enough for a fifth of the card; the notifications' is "Inbox".
    var menuLabel: String { self == .notifications ? "Inbox" : title }

    var detail: String {
        switch self {
        case .chat: "Chat with Claude or ChatGPT."
        case .dictation: "Turn speech into text."
        case .prompter: "Read a script from the notch."
        case .today: "Your calendar for the day."
        case .launcher: "Open your apps, folders and websites."
        case .clipboard: "Your recent copies."
        case .shelf: "Hold files for a moment. Dropping a file on the notch still opens it."
        case .shortcuts: "Run your Shortcuts from the notch."
        case .usage: "How much of your Claude and Codex limits you have used."
        case .system: "CPU, memory and storage on this Mac."
        case .todo: "Lists of things to do, kept on this Mac."
        case .notes: "Write notes on this Mac."
        case .notifications: "Your recent notifications, shown as Inbox. New ones still appear as banners."
        }
    }

    var icon: ToolIcon {
        switch self {
        case .chat: .ask
        case .dictation: .dictation
        case .prompter: .prompter
        case .today: .today
        case .launcher: .launcher
        case .clipboard: .clipboard
        case .shelf: .shelf
        case .shortcuts: .shortcuts
        case .usage: .usage
        case .system: .system
        case .todo: .todo
        case .notes: .notes
        case .notifications: .inbox
        }
    }

    /// The tray page the button opens, when it opens one inside the card.
    var page: TrayModel.Page? {
        switch self {
        case .chat, .dictation, .launcher: nil
        case .prompter: .prompter
        case .today: .today
        case .clipboard: .clipboard
        case .shelf: .shelf
        case .shortcuts: .shortcuts
        case .usage: .usage
        case .system: .system
        case .todo: .todo
        case .notes: .notes
        case .notifications: .notifications
        }
    }

    /// Usage and Notifications are opt-in; existing explicit choices remain available.
    var enabledByDefault: Bool { self != .notifications && self != .usage }
}

/// Which tools the menu shows. Only the choices the person made are stored, so a tool added later still takes its
/// default. Hiding a tool removes its button and nothing else: its shortcut, dropping files on the notch, and a
/// notification opening the inbox all keep working.
@MainActor @Observable
final class ToolMenuModel {
    static let shared = ToolMenuModel()
    static let storageKey = "lenotch.tools.choices"
    static let orderStorageKey = "lenotch.tools.order"

    /// Maximum tools per row.
    static let columns = 5
    /// A button is a 40 pt tile, 5 pt, and its label; rows are 10 pt apart and the card keeps a 20 pt margin.
    static let rowHeight = 59.0
    static let rowSpacing = 10.0
    static let margin = 20.0

    private(set) var choices: [String: Bool]
    private(set) var orderedTools: [TrayTool]
    @ObservationIgnored private let defaults: UserDefaults
    /// Told which tool changed, after its visibility or menu order is stored.
    @ObservationIgnored var onChange: ((TrayTool) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.choices = defaults.dictionary(forKey: Self.storageKey) as? [String: Bool] ?? [:]
        let stored = defaults.stringArray(forKey: Self.orderStorageKey) ?? []
        var seen: Set<TrayTool> = []
        self.orderedTools = (stored.compactMap(TrayTool.init(rawValue:)) + TrayTool.allCases)
            .filter { seen.insert($0).inserted }
    }

    func isEnabled(_ tool: TrayTool) -> Bool {
        let on = choices[tool.rawValue] ?? tool.enabledByDefault
        // A menu with nothing in it is a dead end, so a stored set that hides everything shows the defaults.
        return on || visibleCountWithoutFallback == 0 && tool.enabledByDefault
    }

    private var visibleCountWithoutFallback: Int {
        TrayTool.allCases.filter { choices[$0.rawValue] ?? $0.enabledByDefault }.count
    }

    /// The tools the menu shows, in menu order.
    var visible: [TrayTool] { orderedTools.filter(isEnabled) }

    var hasCustomOrder: Bool { orderedTools != TrayTool.allCases }

    func move(_ tool: TrayTool, before target: TrayTool) {
        move(tool, relativeTo: target, after: false)
    }

    func move(_ tool: TrayTool, after target: TrayTool) {
        move(tool, relativeTo: target, after: true)
    }

    /// Used by the accessible Move up/Move down actions. Moving beyond an edge does nothing.
    func move(_ tool: TrayTool, by offset: Int) {
        guard let index = orderedTools.firstIndex(of: tool) else { return }
        let (destination, overflow) = index.addingReportingOverflow(offset)
        guard !overflow, orderedTools.indices.contains(destination) else { return }
        var next = orderedTools
        next.remove(at: index)
        next.insert(tool, at: destination)
        storeOrder(next, changed: tool)
    }

    /// Restores menu order without changing visibility choices or keyboard shortcuts.
    func restoreOrder() {
        guard let changed = zip(orderedTools, TrayTool.allCases).first(where: { $0 != $1 })?.0 else { return }
        storeOrder(TrayTool.allCases, changed: changed)
    }

    private func move(_ tool: TrayTool, relativeTo target: TrayTool, after: Bool) {
        guard tool != target, let index = orderedTools.firstIndex(of: tool) else { return }
        var next = orderedTools
        next.remove(at: index)
        guard let destination = next.firstIndex(of: target) else { return }
        next.insert(tool, at: destination + (after ? 1 : 0))
        storeOrder(next, changed: tool)
    }

    private func storeOrder(_ tools: [TrayTool], changed tool: TrayTool) {
        guard orderedTools != tools else { return }
        orderedTools = tools
        defaults.set(tools.map(\.rawValue), forKey: Self.orderStorageKey)
        onChange?(tool)
    }

    /// The last tool can't be turned off: the menu would have nothing to open.
    func canDisable(_ tool: TrayTool) -> Bool { !isEnabled(tool) || visible.count > 1 }

    /// Turns a tool on or off. False when it was the last one on and stays on.
    @discardableResult
    func setEnabled(_ tool: TrayTool, _ on: Bool) -> Bool {
        guard on || canDisable(tool) else { return false }
        guard isEnabled(tool) != on else { return true }
        choices[tool.rawValue] = on
        defaults.set(choices, forKey: Self.storageKey)
        onChange?(tool)
        return true
    }

    /// Six and eight tools form two balanced rows; other counts keep the five-column layout.
    var columnCount: Int {
        switch visible.count {
        case 6: 3
        case 8: 4
        default: Self.columns
        }
    }

    /// The menu's rows, in the saved tool order.
    var rows: [[TrayTool]] {
        let tools = visible
        let columns = columnCount
        return stride(from: 0, to: tools.count, by: columns).map {
            Array(tools[$0..<min($0 + columns, tools.count)])
        }
    }

    /// The tools card's height: the rows and their gaps inside the margins. Two rows are the card's long-standing 168 pt.
    var cardHeight: Double { Self.cardHeight(rows: rows.count) }

    static func cardHeight(rows: Int) -> Double {
        let rows = Double(max(rows, 1))
        return margin * 2 + rows * rowHeight + (rows - 1) * rowSpacing
    }
}
