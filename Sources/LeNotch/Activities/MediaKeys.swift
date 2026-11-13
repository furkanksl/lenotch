import AppKit
import AudioToolbox
import CoreAudio
import IslandCore
import OSLog
import Synchronization

/// The default output's volume and mute (CoreAudio).
enum SystemVolume {
    private static var device: AudioObjectID? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return nil }
        return dev
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// The volume (0…1), or nil when the output has none we can set (HDMI, some interfaces).
    static var level: Double? {
        guard let dev = device else { return nil }
        var addr = volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return Double(v)
    }

    static var muted: Bool {
        guard let dev = device else { return false }
        var addr = muteAddress
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr && m != 0
    }

    @discardableResult
    static func set(_ level: Double) -> Bool {
        guard let dev = device else { return false }
        var addr = volumeAddress
        var v = Float32(min(max(level, 0), 1))
        guard AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr else { return false }
        if level > 0 && muted { setMuted(false) }
        return true
    }

    @discardableResult
    static func setMuted(_ on: Bool) -> Bool {
        guard let dev = device else { return false }
        var addr = muteAddress
        var m = UInt32(on ? 1 : 0)
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr
    }
}

/// The built-in display's brightness, through DisplayServices (private; `DisplayServicesGetBrightness`
/// read 0.635 on this Mac).
enum SystemBrightness {
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32
    /// Immutable C functions, shared by the input thread and the HUD slider. The library stays loaded for their lifetime.
    private final class Functions: @unchecked Sendable {
        let handle: UnsafeMutableRawPointer?
        let get: Get?
        let set: Set?

        init() {
            let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
            self.handle = handle
            get = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
            set = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }
        }
    }
    private static let functions = Functions()
    private static let displayID = Mutex<CGDirectDisplayID>(CGMainDisplayID())

    /// The display the keys act on: the built-in (notched) one.
    static var display: CGDirectDisplayID {
        get { displayID.withLock { $0 } }
        set { displayID.withLock { $0 = newValue } }
    }

    static var level: Double? {
        guard let getter = functions.get else { return nil }
        var b: Float = 0
        return getter(display, &b) == 0 ? Double(b) : nil
    }

    @discardableResult
    static func set(_ level: Double) -> Bool {
        guard let setter = functions.set else { return false }
        return setter(display, Float(min(max(level, 0), 1))) == 0
    }
}

/// The volume and brightness keys, caught before the system sees them, so the island's HUD replaces
/// the system's instead of showing beside it. Needs Accessibility. A key is only swallowed when the
/// change was applied here; anything else goes on to the system untouched.
@MainActor
final class MediaKeyTap {
    enum Key: Int, Sendable { case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7 }

    /// A key press was handled: show the HUD at this level.
    var onLevel: ((HUDLevel) -> Void)?
    /// ⌥Space: quick ask (owner, 11-07: "give a better shortcut for asking, or override claude current shortcut"). The
    /// tap sees it before the apps do and swallows it, so Claude's own quick entry doesn't open as well.
    var onAskKey: (() -> Void)?
    private(set) var running = false
    private var input: HardwareKeyEventTap?
    private var generation = UUID()
    private static let log = Logger(subsystem: "com.lenotch.app", category: "keys")

    deinit { input?.stop() }

    struct HUDLevel: Equatable, Sendable {
        var brightness: Bool
        var level: Double
    }

    /// Option alone (no ⌘, ⌃ or ⇧) with Space.
    nonisolated static func isAskChord(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate) && flags.isDisjoint(with: [.maskCommand, .maskControl, .maskShift])
    }

    /// Decodes an NX_SYSDEFINED media-key event's data1: the key, and whether it's going down.
    nonisolated static func decode(subtype: Int16, data1: Int) -> (key: Key, down: Bool)? {
        guard subtype == 8, let key = Key(rawValue: (data1 & 0xFFFF0000) >> 16) else { return nil }
        let flags = data1 & 0xFFFF
        return (key, (flags & 0xFF00) >> 8 == 0x0A)
    }

    /// The next level after a key: sixteen steps, or sixty-four with ⌥⇧ (as macOS does).
    nonisolated static func step(_ level: Double, up: Bool, fine: Bool) -> Double {
        let n = fine ? 64.0 : 16.0
        let next = up ? (level * n + 0.5).rounded(.down) / n + 1 / n : (level * n - 0.5).rounded(.up) / n - 1 / n
        return min(max(next, 0), 1)
    }

    func start() {
        guard !running, AXIsProcessTrusted() else { return }
        let session = UUID()
        generation = session
        let level: @Sendable (HUDLevel) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == session else { return }
                self.onLevel?(value)
            }
        }
        let ask: (@Sendable () -> Void)?
        if onAskKey == nil {
            ask = nil
        } else {
            ask = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.running, self.generation == session else { return }
                    self.onAskKey?()
                }
            }
        }
        let input = HardwareKeyEventTap(onLevel: level, onAsk: ask)
        guard input.start() else {
            Self.log.notice("key tap unavailable")
            return
        }
        self.input = input
        running = true
        Self.log.notice("key tap running on dedicated input thread; playback keys pass through")
    }

    func stop() {
        running = false
        generation = UUID()
        input?.stop()
        input = nil
    }
}

/// The system waits for an active event tap before delivering a key to other apps. Keep this run loop independent
/// of SwiftUI, permission dialogs and layout work, even for keys LeNotch doesn't handle. Only HUD updates and the
/// explicit Ask shortcut are dispatched to the main actor; playback events are returned unchanged here.
///
/// Event routing and its key-up state are confined to the input thread. Lifecycle state is protected by `lifecycle`.
final class HardwareKeyEventTap: @unchecked Sendable {
    private let onLevel: @Sendable (MediaKeyTap.HUDLevel) -> Void
    private let onAsk: (@Sendable () -> Void)?
    private var swallowSpaceUp = false
    private let lifecycle = NSCondition()
    private var thread: Thread?
    private var loop: CFRunLoop?
    private var port: CFMachPort?
    private var starting = false
    private var finished = true

    init(onLevel: @escaping @Sendable (MediaKeyTap.HUDLevel) -> Void,
         onAsk: (@Sendable () -> Void)? = nil) {
        self.onLevel = onLevel
        self.onAsk = onAsk
    }

    func start() -> Bool {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard thread == nil else { return port != nil }
        starting = true
        finished = false
        let thread = Thread { [self] in run() }
        thread.name = "com.lenotch.app.hardware-keys"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        while starting { lifecycle.wait() }
        return port != nil
    }

    func stop() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard let loop else { return }
        CFRunLoopStop(loop)
        CFRunLoopWakeUp(loop)
        while !finished { lifecycle.wait() }
    }

    private func run() {
        // NX_SYSDEFINED for volume/brightness; normal key events only for the explicit ⌥Space shortcut.
        let mask = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<HardwareKeyEventTap>.fromOpaque(info).takeUnretainedValue().route(type, event: event)
        }, userInfo: me), let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            lifecycle.lock()
            starting = false
            finished = true
            thread = nil
            lifecycle.broadcast()
            lifecycle.unlock()
            return
        }
        let runLoop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(runLoop, source, .commonModes)
        // Publish readiness only after the run loop has entered. A stop immediately after start cannot be lost.
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            lifecycle.lock()
            self.port = port
            loop = CFRunLoopGetCurrent()
            starting = false
            lifecycle.broadcast()
            lifecycle.unlock()
        }
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRun()
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        lifecycle.lock()
        self.port = nil
        loop = nil
        thread = nil
        swallowSpaceUp = false
        finished = true
        lifecycle.broadcast()
        lifecycle.unlock()
    }

    /// The real CGEvent callback's routing path, also exercised by tests without posting system input.
    func route(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        autoreleasepool {
            handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
    }

    /// True when the key was handled here (and must not reach the system).
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        if type == .keyDown || type == .keyUp {
            guard event.getIntegerValueField(.keyboardEventKeycode) == 49 else { return false }   // Space
            if type == .keyUp { defer { swallowSpaceUp = false }; return swallowSpaceUp }
            guard MediaKeyTap.isAskChord(event.flags), let onAsk else { return false }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onAsk() }
            swallowSpaceUp = true
            return true
        }
        // An allowlist: play/pause (16), next/previous and every other system key belong to macOS. No media command
        // is forwarded or synthesized here, so a passed-through key cannot also cause a duplicate playback toggle.
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event),
              let (key, down) = MediaKeyTap.decode(subtype: ns.subtype.rawValue, data1: ns.data1)
        else { return false }
        let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
        switch key {
        case .soundUp, .soundDown, .mute:
            guard let current = SystemVolume.level else { return false }
            guard down else { return true }        // the key's release is ours too
            var level = SystemVolume.muted ? 0 : current
            if key == .mute {
                let mute = !SystemVolume.muted
                guard SystemVolume.setMuted(mute) else { return false }
                level = mute ? 0 : current
            } else {
                level = MediaKeyTap.step(level, up: key == .soundUp, fine: fine)
                guard SystemVolume.set(level) else { return false }
                if level == 0 { SystemVolume.setMuted(true) }
            }
            onLevel(MediaKeyTap.HUDLevel(brightness: false, level: level))
            return true
        case .brightnessUp, .brightnessDown:
            guard let current = SystemBrightness.level else { return false }
            guard down else { return true }
            let level = MediaKeyTap.step(current, up: key == .brightnessUp, fine: fine)
            guard SystemBrightness.set(level) else { return false }
            onLevel(MediaKeyTap.HUDLevel(brightness: true, level: level))
            return true
        }
    }
}
