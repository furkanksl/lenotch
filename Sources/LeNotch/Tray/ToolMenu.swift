import Foundation
import Observation

/// One entry of the notch's tools menu, in the order the menu lists them.
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
        case .chat: "Ask Claude or ChatGPT. ⌥Space still opens it."
        case .dictation: "Start or finish dictation. ⌥D still works."
        case .prompter: "Read a script from the notch."
        case .today: "Your calendar for the day."
        case .launcher: "Open your apps, folders and websites. Its shortcut still works."
        case .clipboard: "Your recent copies, ready to paste again."
        case .shelf: "Hold files for a moment. Dropping a file on the notch still opens it."
        case .shortcuts: "Run your Shortcuts from the notch."
        case .usage: "How much of your Claude and Codex limits you have used."
        case .system: "CPU, memory and storage on this Mac."
        case .todo: "Lists of things to do, kept on this Mac."
        case .notes: "Write notes and keep them on this Mac."
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

    /// Tools per row.
    static let columns = 5
    /// A button is a 40 pt tile, 5 pt, and its label; rows are 10 pt apart and the card keeps a 20 pt margin.
    static let rowHeight = 59.0
    static let rowSpacing = 10.0
    static let margin = 20.0

    private(set) var choices: [String: Bool]
    @ObservationIgnored private let defaults: UserDefaults
    /// Told which tool changed, after the choice is stored.
    @ObservationIgnored var onChange: ((TrayTool) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.choices = defaults.dictionary(forKey: Self.storageKey) as? [String: Bool] ?? [:]
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
    var visible: [TrayTool] { TrayTool.allCases.filter(isEnabled) }

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

    /// The menu's rows, five tools each, the last one holding the rest.
    var rows: [[TrayTool]] {
        let tools = visible
        return stride(from: 0, to: tools.count, by: Self.columns).map {
            Array(tools[$0..<min($0 + Self.columns, tools.count)])
        }
    }

    /// The tools card's height: the rows and their gaps inside the margins. Two rows are the card's long-standing 168 pt.
    var cardHeight: Double { Self.cardHeight(rows: rows.count) }

    static func cardHeight(rows: Int) -> Double {
        let rows = Double(max(rows, 1))
        return margin * 2 + rows * rowHeight + (rows - 1) * rowSpacing
    }
}
