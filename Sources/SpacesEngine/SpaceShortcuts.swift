import CDockSwipe
import Foundation

/// The macOS shortcuts for "Move left a space" and "Move right a space".
/// All lifecycle calls and `onStep` access belong on the main thread.
enum SpaceShortcuts {
    /// Called on the main thread: -1 for the space to the left, +1 for the space to the right.
    static var onStep: ((Int) -> Void)?

    private static let moveLeftID = "79"
    private static let moveRightID = "81"
    private static let leftArrow = 123
    private static let rightArrow = 124
    private static let control: UInt64 = 0x40000

    // No settings reads, input hooks, or system changes happen during static initialization.
    private static var installed = false
    private static let callbacks = CallbackGate()

    /// Needs Accessibility permission. The caller must only install after the feature is enabled.
    static func install() -> Bool {
        precondition(Thread.isMainThread)
        if installed { return true }
        installed = ds_keys_install { direction in
            // The tap thread never waits for the main thread. Queued work is tied to this activation.
            guard let ticket = SpaceShortcuts.callbacks.ticket() else { return }
            let step = direction == DSDirectionRight ? 1 : -1
            DispatchQueue.main.async {
                guard SpaceShortcuts.callbacks.accepts(ticket) else { return }
                SpaceShortcuts.onStep?(step)
            }
        }
        return installed
    }

    /// Reads the user's bindings without changing their native enabled state. The HID tap consumes
    /// matching keypresses before macOS handles them, so disabling macOS's hotkeys is unnecessary.
    static func update(enabled: Bool) {
        precondition(Thread.isMainThread)
        let configuration: Configuration?
        if enabled && installed {
            let entries = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
                .dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
            configuration = Configuration(entries: entries)
        } else {
            configuration = nil
        }
        // In particular, polling unchanged bindings must not reset held keys or invalidate the
        // main-thread action for a keypress the HID tap has already consumed.
        guard callbacks.update(configuration) else { return }
        let bindings = configuration ?? Configuration(left: nil, right: nil)
        ds_keys_configure(bindings.isEnabled,
                          Int32(bindings.left?.key ?? -1), bindings.left?.flags ?? 0,
                          Int32(bindings.right?.key ?? -1), bindings.right?.flags ?? 0)
    }

    /// Rejects queued actions before removing and joining the keyboard worker.
    static func uninstall() {
        precondition(Thread.isMainThread)
        update(enabled: false)
        ds_keys_uninstall()
        installed = false
        onStep = nil
    }

    struct Shortcut: Equatable {
        let key: Int
        let flags: UInt64
    }

    /// Pure parsing seam: tests never have to read or mutate the user's shortcut preferences.
    struct Configuration: Equatable {
        let left: Shortcut?
        let right: Shortcut?

        var isEnabled: Bool { left != nil || right != nil }

        init(left: Shortcut?, right: Shortcut?) {
            self.left = left
            self.right = right
        }

        init(entries: [String: Any]) {
            left = shortcut(entries[moveLeftID], defaultKey: leftArrow)
            right = shortcut(entries[moveRightID], defaultKey: rightArrow)
        }
    }

    /// Pure lifecycle seam. Only a real inactive/active boundary changes callback identity;
    /// an action captured under previous bindings still belongs to the same active session.
    struct ActivationState {
        private(set) var current: Configuration?
        private var generation: UInt64 = 0

        @discardableResult
        mutating func update(_ configuration: Configuration?) -> Bool {
            let next = configuration.flatMap { $0.isEnabled ? $0 : nil }
            guard current != next else { return false }
            if (current == nil) != (next == nil) { generation &+= 1 }
            current = next
            return true
        }

        func ticket() -> UInt64? { current == nil ? nil : generation }

        func accepts(_ ticket: UInt64) -> Bool {
            current != nil && generation == ticket
        }
    }

    /// Nil when the user disabled the shortcut or its virtual key code is invalid.
    private static func shortcut(_ entry: Any?, defaultKey: Int) -> Shortcut? {
        // No entry: the user never changed it, and it is Control with an arrow key.
        guard let entry = entry as? [String: Any] else { return Shortcut(key: defaultKey, flags: control) }
        guard (entry["enabled"] as? NSNumber)?.boolValue ?? true else { return nil }
        // The parameters are a character, a key code and the modifier flags.
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3
        else { return Shortcut(key: defaultKey, flags: control) }
        let key = parameters[1].intValue
        guard (0...Int(UInt16.max)).contains(key) else { return nil }
        return Shortcut(key: key, flags: parameters[2].uint64Value)
    }

    /// Only the activation ticket crosses threads. No system API or app callback runs under this lock.
    private final class CallbackGate {
        private let lock = NSLock()
        private var state = ActivationState()

        func update(_ configuration: Configuration?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return state.update(configuration)
        }

        func ticket() -> UInt64? {
            lock.lock()
            defer { lock.unlock() }
            return state.ticket()
        }

        func accepts(_ ticket: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return state.accepts(ticket)
        }
    }
}
