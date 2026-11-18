import AppKit
import Carbon
import Observation
import OSLog

enum ToolShortcutTarget: String, CaseIterable, Identifiable, Sendable {
    case chat, dictation, prompter, today, launcher, clipboard, shelf, shortcuts, usage, system, todo, notes, notifications

    var id: Self { self }

    var tool: TrayTool {
        switch self {
        case .chat: .chat
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
        case .notifications: .notifications
        }
    }

    var title: String { tool.title }

    var icon: ToolIcon { tool.icon }

    /// Chat, Dictation and Launcher use their own routing rather than a tray page.
    var page: TrayModel.Page? { tool.page }

    var defaultBinding: ToolKeyBinding? {
        let key: Int
        switch self {
        case .chat: key = kVK_Space
        case .dictation: key = kVK_ANSI_D
        case .launcher: key = kVK_ANSI_A
        case .clipboard: key = kVK_ANSI_C
        case .todo: key = kVK_ANSI_T
        case .notes: key = kVK_ANSI_N
        case .prompter, .today, .shelf, .shortcuts, .usage, .system, .notifications: return nil
        }
        return ToolKeyBinding(keyCode: key, modifiers: optionKey)
    }
}

/// Physical macOS key codes and Carbon modifier bits, the same format used by HotKey.
struct ToolKeyBinding: Codable, Hashable, Sendable {
    let keyCode: Int
    let modifiers: Int

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var display: String {
        let glyphs = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
        return glyphs + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    var validationError: String? {
        guard Self.keyNames[keyCode] != nil else { return "This key can't be used as a shortcut." }
        let supported = cmdKey | optionKey | controlKey | shiftKey
        guard modifiers & ~supported == 0 else { return "Fn and other special modifiers aren't supported." }
        guard modifiers & (cmdKey | optionKey | controlKey) != 0 else {
            return "Include Command, Option, or Control in the shortcut."
        }
        if let owner = Self.appShortcuts[self] { return "\(display) is reserved for \(owner)." }
        if modifiers & cmdKey != 0, Self.commandKeys.contains(keyCode) {
            return "\(display) is reserved for a standard macOS command."
        }
        if modifiers & cmdKey != 0, modifiers & shiftKey != 0,
           [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].contains(keyCode) {
            return "\(display) is reserved for macOS screenshots."
        }
        if modifiers & controlKey != 0, Self.arrowKeys.contains(keyCode) {
            return "Control-arrow shortcuts are reserved for macOS desktop navigation."
        }
        if (modifiers & (cmdKey | optionKey)) == (cmdKey | optionKey), keyCode == kVK_Escape {
            return "\(display) is reserved for Force Quit."
        }
        return nil
    }

    /// Caps Lock and keypad flags describe how a key was typed, not the global shortcut. AppKit also sets Fn on
    /// arrow and function keys, so those keys may carry it without recording Fn as an unsupported modifier.
    static func from(event: NSEvent) -> ToolKeyBinding? {
        guard event.type == .keyDown else { return nil }
        let keyCode = Int(event.keyCode)
        guard keyNames[keyCode] != nil else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.help),
              !flags.contains(.function) || functionFlagKeys.contains(keyCode) else { return nil }
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        return ToolKeyBinding(keyCode: keyCode, modifiers: modifiers)
    }

    private static let appShortcuts: [ToolKeyBinding: String] = [
        .init(keyCode: kVK_ANSI_A, modifiers: controlKey | optionKey | cmdKey): "Chat",
    ]
    private static let commandKeys: Set<Int> = [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M, kVK_Tab, kVK_Space]
    private static let arrowKeys: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
    private static let functionFlagKeys: Set<Int> = arrowKeys.union([
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete,
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ])

    // Fixed ANSI labels keep saved physical shortcuts readable even when Option produces a symbol in NSEvent.
    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Quote: "'", kVK_ANSI_Semicolon: ";", kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",",
        kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".", kVK_ANSI_Grave: "`", kVK_ISO_Section: "§",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ForwardDelete: "⌦",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
        kVK_ANSI_Keypad0: "Keypad 0", kVK_ANSI_Keypad1: "Keypad 1", kVK_ANSI_Keypad2: "Keypad 2",
        kVK_ANSI_Keypad3: "Keypad 3", kVK_ANSI_Keypad4: "Keypad 4", kVK_ANSI_Keypad5: "Keypad 5",
        kVK_ANSI_Keypad6: "Keypad 6", kVK_ANSI_Keypad7: "Keypad 7", kVK_ANSI_Keypad8: "Keypad 8",
        kVK_ANSI_Keypad9: "Keypad 9", kVK_ANSI_KeypadDecimal: "Keypad .", kVK_ANSI_KeypadMultiply: "Keypad *",
        kVK_ANSI_KeypadPlus: "Keypad +", kVK_ANSI_KeypadClear: "Clear", kVK_ANSI_KeypadDivide: "Keypad /",
        kVK_ANSI_KeypadEnter: "⌤", kVK_ANSI_KeypadMinus: "Keypad -", kVK_ANSI_KeypadEquals: "Keypad =",
    ]
}

extension Notification.Name {
    static let toolShortcutsChanged = Notification.Name("lenotch.tools.shortcuts.changed")
    static let toolShortcutRecordingChanged = Notification.Name("lenotch.tools.shortcuts.recording.changed")
}

@MainActor @Observable
final class ToolShortcutSettings {
    static let shared = ToolShortcutSettings()
    static let storageKey = "lenotch.tools.shortcuts"
    static let legacyMigrationKey = "lenotch.tools.shortcuts.migratedLegacy"

    /// Wrapping the optional distinguishes an explicit disabled shortcut from an untouched default.
    private struct Choice: Codable, Equatable {
        let binding: ToolKeyBinding?
    }

    private var choices: [String: Choice]
    private(set) var failures: [ToolShortcutTarget: String] = [:]
    private(set) var isRecording = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var stored = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Choice].self, from: $0) } ?? [:]
        stored = stored.filter { key, choice in
            ToolShortcutTarget(rawValue: key) != nil && (choice.binding == nil || choice.binding?.validationError == nil)
        }
        let needsLegacyMigration = !defaults.bool(forKey: Self.legacyMigrationKey)
        var migratedChoice = false
        if needsLegacyMigration {
            let legacyKeys: [(ToolShortcutTarget, String)] = [
                (.launcher, "lenotch.launcher.shortcut"),
                (.dictation, DictationInputSettings.toggleShortcutKey),
            ]
            for (target, key) in legacyKeys where stored[target.rawValue] == nil {
                let enabled = defaults.object(forKey: key) as? Bool
                if enabled == false {
                    stored[target.rawValue] = Choice(binding: nil)
                    migratedChoice = true
                }
            }
        }
        // Preserve valid explicit choices, even if imported data contains a collision. The registration owner
        // reports conflicts instead of silently throwing away a shortcut or exposing a previously disabled default.
        choices = stored
        if migratedChoice { persistChoices() }
        if needsLegacyMigration { defaults.set(true, forKey: Self.legacyMigrationKey) }
    }

    func binding(for target: ToolShortcutTarget) -> ToolKeyBinding? {
        (choices[target.rawValue] ?? Choice(binding: target.defaultBinding)).binding
    }

    func validationError(for binding: ToolKeyBinding, target: ToolShortcutTarget) -> String? {
        if let error = binding.validationError { return error }
        if let other = ToolShortcutTarget.allCases.first(where: { $0 != target && self.binding(for: $0) == binding }) {
            return "\(binding.display) is already assigned to \(other.title)."
        }
        return nil
    }

    @discardableResult
    func setBinding(_ binding: ToolKeyBinding?, for target: ToolShortcutTarget) -> Bool {
        if let binding, validationError(for: binding, target: target) != nil { return false }
        guard self.binding(for: target) != binding else { return true }
        if binding == target.defaultBinding { choices.removeValue(forKey: target.rawValue) }
        else { choices[target.rawValue] = Choice(binding: binding) }
        persistChoices()
        failures.removeValue(forKey: target)
        NotificationCenter.default.post(name: .toolShortcutsChanged, object: self)
        return true
    }

    @discardableResult
    func reset(_ target: ToolShortcutTarget) -> Bool { setBinding(target.defaultBinding, for: target) }

    private func persistChoices() {
        if choices.isEmpty { defaults.removeObject(forKey: Self.storageKey) }
        else if let data = try? JSONEncoder().encode(choices) { defaults.set(data, forKey: Self.storageKey) }
    }

    func setRegistrationFailures(_ failures: [ToolShortcutTarget: String]) {
        self.failures = failures
    }

    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        ToolShortcutRecordingGate.setRecording(true)
        NotificationCenter.default.post(name: .toolShortcutRecordingChanged, object: self)
    }

    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        ToolShortcutRecordingGate.setRecording(false)
        NotificationCenter.default.post(name: .toolShortcutRecordingChanged, object: self)
    }
}

@MainActor
protocol ToolShortcutRegistration: AnyObject {
    func unregister()
}

extension HotKey: ToolShortcutRegistration {}

/// AppDelegate owns observation and calls refresh after a saved change or recording-state change.
@MainActor
final class ToolShortcutController {
    typealias Register = (ToolKeyBinding, @escaping () -> Void) -> (any ToolShortcutRegistration)?

    private let settings: ToolShortcutSettings
    private let register: Register
    private var registrations: [ToolShortcutTarget: any ToolShortcutRegistration] = [:]
    private var generation = 0
    private var isRunning = false
    private var action: ((ToolShortcutTarget) -> Void)?

    init(settings: ToolShortcutSettings, register: @escaping Register = { binding, action in
        HotKey(keyCode: binding.keyCode, modifiers: binding.modifiers, action: action)
    }) {
        self.settings = settings
        self.register = register
    }

    func start(action: @escaping (ToolShortcutTarget) -> Void) {
        self.action = action
        isRunning = true
        refresh()
    }

    func refresh() {
        generation += 1
        let currentGeneration = generation
        unregisterAll()
        guard isRunning, !settings.isRecording else {
            settings.setRegistrationFailures([:])
            return
        }
        var failures: [ToolShortcutTarget: String] = [:]
        for target in ToolShortcutTarget.allCases {
            guard let binding = settings.binding(for: target) else { continue }
            if let error = settings.validationError(for: binding, target: target) {
                failures[target] = error
                continue
            }
            let registration = register(binding) { [weak self] in
                guard let self, self.isRunning, self.generation == currentGeneration,
                      !self.settings.isRecording, self.settings.binding(for: target) == binding,
                      self.registrations[target] != nil else { return }
                self.action?(target)
            }
            // A registration adapter may call back synchronously. Don't retain a handle from an obsolete refresh.
            guard isRunning, generation == currentGeneration, !settings.isRecording,
                  settings.binding(for: target) == binding else {
                registration?.unregister()
                if generation != currentGeneration || !isRunning || settings.isRecording { return }
                continue
            }
            if let registration { registrations[target] = registration }
            else { failures[target] = "macOS couldn't register \(binding.display). It may already be in use." }
        }
        settings.setRegistrationFailures(failures)
        #if DEBUG
        let labels = ToolShortcutTarget.allCases.map { target in
            "\(target.title)=\(settings.binding(for: target)?.display ?? "off")"
        }.joined(separator: " ")
        Logger(subsystem: "com.lenotch", category: "ToolShortcuts")
            .notice("Global shortcuts registered=\(self.registrations.count, privacy: .public) failures=\(failures.count, privacy: .public) \(labels, privacy: .public)")
        #endif
    }

    func stop() {
        generation += 1
        isRunning = false
        action = nil
        unregisterAll()
        settings.setRegistrationFailures([:])
    }

    private func unregisterAll() {
        let previous = registrations
        registrations.removeAll()
        for registration in previous.values { registration.unregister() }
    }
}
