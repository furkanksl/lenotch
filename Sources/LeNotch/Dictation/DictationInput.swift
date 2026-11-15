import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Shortcut preferences are independent. New Fn push-to-talk is opt-in; keep the existing ⌥D shortcut working
/// unless the user explicitly disables it.
struct DictationInputSettings: Equatable {
    static let pushToTalkKey = "lenotch.dictation.fnPushToTalk"
    static let toggleShortcutKey = "lenotch.dictation.toggleShortcut"

    let pushToTalk: Bool
    let toggleShortcut: Bool

    init(defaults: UserDefaults = .standard) {
        pushToTalk = defaults.bool(forKey: Self.pushToTalkKey)
        toggleShortcut = defaults.object(forKey: Self.toggleShortcutKey) as? Bool ?? true
    }
}

extension Notification.Name {
    static let dictationShortcutsChanged = Notification.Name("lenotch.dictation.shortcuts.changed")
}

/// Plain Fn ownership on the input thread. Modifier flags alone aren't a physical Fn press (arrow/F-keys can carry
/// them too). Only keycode 63 may start a hold. Ordinary keys, modifiers and system keys always pass through.
struct FnPushToTalk: Sendable {
    enum Action: Equatable, Sendable {
        case pressed(UUID), released(UUID), cancelled(UUID)
    }

    struct Result: Equatable {
        var consume = false
        var action: Action?
    }

    private(set) var enabled = false
    private(set) var hold: UUID?
    private var fnDown = false
    private var claimedFn = false
    private var heldKeys: Set<Int64> = []

    mutating func setEnabled(_ enabled: Bool) -> Action? {
        guard enabled != self.enabled else { return nil }
        self.enabled = enabled
        let action = hold.map(Action.cancelled)
        hold = nil
        claimedFn = false
        return action
    }

    /// A lost tap, lock or sleep invalidates the hold. Fn must come up before another one can begin.
    mutating func interrupt() -> Action? {
        let action = hold.map(Action.cancelled)
        hold = nil
        heldKeys.removeAll()
        return action
    }

    mutating func route(_ type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Result {
        if type == .keyDown { heldKeys.insert(keyCode) }
        if type == .keyUp { heldKeys.remove(keyCode) }

        if type == .flagsChanged, keyCode == kVK_Function {
            let down = flags.contains(.maskSecondaryFn)
            defer { fnDown = down }
            guard enabled else { return Result() }
            if !down {
                let result = Result(consume: claimedFn, action: hold.map(Action.released))
                hold = nil
                claimedFn = false
                return result
            }
            guard !fnDown else { return Result(consume: claimedFn) }
            guard heldKeys.isEmpty, flags.isDisjoint(with: Self.otherModifiers) else { return Result() }
            let id = UUID()
            hold = id
            claimedFn = true
            return Result(consume: true, action: .pressed(id))
        }

        guard enabled, let id = hold else { return Result() }
        // Fn joins another shortcut: stop dictating, but leave the shortcut's key and flags untouched. It won't
        // become a new dictation hold when the other key comes up; only a fresh physical Fn press can do that.
        if type == .keyDown || type.rawValue == 14 ||
            (type == .flagsChanged && !flags.isDisjoint(with: Self.otherModifiers)) {
            hold = nil
            return Result(action: .cancelled(id))
        }
        return Result()
    }

    private static let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
}

/// A hold may finish only the run it started, not a menu/⌥D run or a later hold.
struct DictationHold: Equatable {
    private(set) var id: UUID?

    mutating func begin(_ id: UUID) { self.id = id }

    mutating func end(_ id: UUID) -> Bool {
        guard self.id == id else { return false }
        self.id = nil
        return true
    }

    mutating func clear() { id = nil }
}
