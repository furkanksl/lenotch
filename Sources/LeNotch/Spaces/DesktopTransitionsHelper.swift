import AppKit
import SpacesEngine

/// The same signed executable runs only the desktop engine here. It deliberately
/// does not construct AppDelegate, the notch, updates, media, AI, or settings UI.
/// stdin's lifetime belongs to the parent; EOF means stop, including a parent crash.
@MainActor
final class DesktopTransitionsHelper: NSObject, NSApplicationDelegate {
    private let engine = DesktopTransitionsEngine()
    private var finished = false
    private var parentSuspended = false
    private var locked = false
    private var lockObservers: [NSObjectProtocol] = []
    private var inputLease: FileHandle?
    private let reader = DispatchQueue(label: "com.lenotch.app.spaces.commands")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Lock handling must not wait for a busy (or crashing) parent UI process.
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.finished else { return }
                    self.locked = locked
                    self.engine.setSuspended(self.parentSuspended || locked)
                }
            })
        }
        #if DEBUG
        // Development builds only: `com.lenotch.app.debug.desktop-step` with object "1" or "-1" runs a
        // keyboard-equivalent transition so frame timing can be measured without synthetic HID events.
        lockObservers.append(center.addObserver(forName: Notification.Name("com.lenotch.app.debug.desktop-step"), object: nil, queue: .main) { [weak self] note in
            let direction = Int(note.object as? String ?? "") ?? 0
            MainActor.assumeIsolated { self?.engine.debugStep(direction) }
        })
        // `...debug.desktop-pause` simulates a lock/unlock.
        lockObservers.append(center.addObserver(forName: Notification.Name("com.lenotch.app.debug.desktop-pause"), object: nil, queue: .main) { [weak self] note in
            let paused = (note.object as? String) == "1"
            MainActor.assumeIsolated { self?.engine.setSuspended(paused) }
        })
        #endif
        engine.onStatus = { [weak self] status in
            self?.send(.status(status))
        }
        engine.onTransition = { [weak self] active in
            self?.send(.transition(active))
        }
        reader.async { [weak self] in
            var decoder = DesktopTransitionWireDecoder<DesktopTransitionCommand>()
            do {
                // Off/on can spawn the replacement before the previous process has
                // exited. Only one helper may install the global input taps at a time.
                let lease = try Self.acquireInputLease()
                DispatchQueue.main.async { [weak self] in self?.inputLease = lease }
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    for command in try decoder.append(Data(buffer.prefix(count))) {
                        if command == .stop { Self.armExitDeadline() }
                        DispatchQueue.main.async { [weak self] in self?.receive(command) }
                    }
                }
                try decoder.finish()
            } catch {
                // A broken or malformed parent stream is a shutdown, never permission
                // to leave global event taps running with stale options.
            }
            Self.armExitDeadline()
            DispatchQueue.main.async { [weak self] in self?.finish() }
        }
    }

    nonisolated private static func armExitDeadline() {
        // Parent death must release OS taps/windows even if private WindowServer
        // calls have wedged the helper's main loop. This runs only in the helper.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { _exit(0) }
    }

    nonisolated private static func acquireInputLease() throws -> FileHandle {
        let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appendingPathComponent("com.lenotch.app", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("desktop-transitions.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        for _ in 0..<80 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return handle }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { break }
            usleep(25_000)
        }
        try? handle.close()
        throw CocoaError(.fileLocking)
    }

    private func receive(_ command: DesktopTransitionCommand) {
        guard !finished else { return }
        switch command {
        case .start(let options): engine.start(options)
        case .update(let options): engine.update(options)
        case .suspend(let suspended):
            parentSuspended = suspended
            engine.setSuspended(suspended || locked)
        case .stop: finish()
        }
    }

    private func send(_ event: DesktopTransitionEvent) {
        guard !finished else { return }
        do { try FileHandle.standardOutput.write(contentsOf: DesktopTransitionWire.encode(event)) }
        catch { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        lockObservers.removeAll()
        engine.onStatus = nil
        engine.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) { engine.stop() }
}
