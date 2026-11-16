import Darwin
import Foundation
import SpacesEngine
import Synchronization

/// Only the transition engine runs in the child. Its stdin is also the parent-lifetime lease:
/// closing the pipe (including when this app exits) makes the helper stop its input hooks.
@MainActor
final class DesktopTransitionsProcess: DesktopTransitionsDriving {
    var onStatus: ((DesktopTransitionStatus) -> Void)?
    var onTransition: ((Bool) -> Void)?
    private var transitioning = false

    private let makeTransport: () throws -> any DesktopTransitionsProcessTransport
    private var transport: (any DesktopTransitionsProcessTransport)?
    private var generation = UUID()
    private var enabled = false
    private var suspended = false
    private var options = DesktopTransitionOptions()
    private var status = DesktopTransitionStatus.off
    private var output = DesktopTransitionEventLines()

    init(makeTransport: @escaping () throws -> any DesktopTransitionsProcessTransport = {
        guard let executable = Bundle.main.executableURL else { throw DesktopTransitionsProcessError.noExecutable }
        return DesktopTransitionsChildProcess(executable: executable)
    }) {
        self.makeTransport = makeTransport
    }

    isolated deinit {
        transport?.shutdown(finalCommand: nil)
    }

    func start(_ options: DesktopTransitionOptions) {
        guard !enabled else { update(options); return }
        enabled = true
        self.options = options
        output = DesktopTransitionEventLines()
        let token = UUID()
        generation = token
        do {
            let child = try makeTransport()
            transport = child
            child.onOutput = { [weak self] bytes in self?.receive(bytes, generation: token) }
            child.onExit = { [weak self] in self?.failed(generation: token) }
            child.onFailure = { [weak self] in self?.failed(generation: token) }
            try child.launch()
            // Suspend BEFORE starting: a locked/presenting parent must never briefly install hooks.
            send(.suspend(suspended))
            send(.start(options))
        } catch {
            failed(generation: token)
        }
    }

    func update(_ options: DesktopTransitionOptions) {
        guard options != self.options else { return }
        self.options = options
        if enabled { send(.update(options)) }
    }

    func setSuspended(_ suspended: Bool) {
        guard suspended != self.suspended else { return }
        self.suspended = suspended
        if enabled { send(.suspend(suspended)) }
    }

    func stop() {
        enabled = false
        detach()
        publish(.off)
    }

    private func send(_ command: DesktopTransitionCommand) {
        guard let transport else { return }
        do { transport.send(try Self.line(command)) }
        catch { failed(generation: generation) }
    }

    private static func line(_ command: DesktopTransitionCommand) throws -> Data {
        try DesktopTransitionWire.encode(command)
    }

    private func receive(_ bytes: Data, generation: UUID) {
        guard enabled, transport != nil, self.generation == generation else { return }
        do {
            for event in try output.append(bytes) {
                guard enabled, self.generation == generation else { return }
                switch event {
                case .status(let status): publish(status)
                case .transition(let active): setTransitioning(active)
                }
            }
        } catch {
            // An unbounded/malformed producer must not retain desktop input hooks invisibly.
            failed(generation: generation)
        }
    }

    private func failed(generation: UUID) {
        guard enabled, self.generation == generation else { return }
        detach()
        // Keep enabled latched. Retrying requires an explicit stop/start, not a crash/relaunch loop.
        publish(.unsupported)
    }

    private func setTransitioning(_ active: Bool) {
        guard active != transitioning else { return }
        transitioning = active
        onTransition?(active)
    }

    private func detach() {
        setTransitioning(false)
        generation = UUID()
        output = DesktopTransitionEventLines()
        let child = transport
        transport = nil
        child?.onOutput = nil
        child?.onExit = nil
        child?.onFailure = nil
        child?.shutdown(finalCommand: try? Self.line(.stop))
    }

    private func publish(_ status: DesktopTransitionStatus) {
        guard status != self.status else { return }
        self.status = status
        onStatus?(status)
    }
}

@MainActor
protocol DesktopTransitionsProcessTransport: AnyObject {
    var onOutput: ((Data) -> Void)? { get set }
    var onExit: (() -> Void)? { get set }
    var onFailure: (() -> Void)? { get set }
    func launch() throws
    func send(_ data: Data)
    /// Nonblocking: enqueue the final command, close stdin, then reap/terminate only this child.
    func shutdown(finalCommand: Data?)
}

enum DesktopTransitionsProcessError: Error {
    case noExecutable, oversizedOutput, pipeSetup
}

/// NDJSON framing is independent of read boundaries. Unknown/invalid complete lines are ignored;
/// an unterminated or complete oversized line is fatal, with bounded retained memory.
struct DesktopTransitionEventLines {
    static let maximumLineBytes = DesktopTransitionWireDecoder<DesktopTransitionEvent>.maximumRecordBytes
    private var pending = Data()

    mutating func append(_ bytes: Data) throws -> [DesktopTransitionEvent] {
        var events: [DesktopTransitionEvent] = []
        for byte in bytes {
            if byte == 0x0a {
                if let event = try? JSONDecoder().decode(DesktopTransitionEvent.self, from: pending) {
                    events.append(event)
                }
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < Self.maximumLineBytes else { throw DesktopTransitionsProcessError.oversizedOutput }
                pending.append(byte)
            }
        }
        return events
    }
}

@MainActor
private final class DesktopTransitionsChildProcess: DesktopTransitionsProcessTransport {
    var onOutput: ((Data) -> Void)?
    var onExit: (() -> Void)?
    var onFailure: (() -> Void)?
    private let io: DesktopTransitionsChildIO

    init(executable: URL) { io = DesktopTransitionsChildIO(executable: executable) }

    func launch() throws {
        try io.launch(output: { [weak self] bytes in
            Task { @MainActor [weak self] in self?.onOutput?(bytes) }
        }, exit: { [weak self] in
            Task { @MainActor [weak self] in self?.onExit?() }
        }, failure: { [weak self] in
            Task { @MainActor [weak self] in self?.onFailure?() }
        })
    }

    func send(_ data: Data) { io.send(data) }
    func shutdown(finalCommand: Data?) { io.shutdown(finalCommand: finalCommand) }
    isolated deinit { io.shutdown(finalCommand: nil) }
}

/// All potentially blocking pipe work and process waiting live off the UI/animation thread.
/// Lifecycle flags are locked; writes/close are serialized; Process itself owns the child's PID.
private final class DesktopTransitionsChildIO: @unchecked Sendable {
    private struct State {
        var launched = false
        var stopping = false
        var failure: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writer = DispatchQueue(label: "com.lenotch.app.spaces-helper-input", qos: .userInitiated)

    init(executable: URL) {
        process.executableURL = executable
        process.arguments = ["--desktop-transitions-helper"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
    }

    func launch(output receive: @escaping @Sendable (Data) -> Void,
                exit: @escaping @Sendable () -> Void,
                failure: @escaping @Sendable () -> Void) throws {
        let fd = input.fileHandleForWriting.fileDescriptor
        // A crashed child must not deliver SIGPIPE to the GUI. A wedged reader must not fill a
        // blocking write queue and prevent EOF/shutdown; backpressure fails closed instead.
        guard fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else { throw DesktopTransitionsProcessError.pipeSetup }
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw DesktopTransitionsProcessError.pipeSetup
        }
        state.withLock { $0.failure = failure }
        output.fileHandleForReading.readabilityHandler = { handle in
            // NSFileHandle.read(upToCount:) may wait to fill the requested count on
            // a pipe. One POSIX read delivers a short status immediately instead.
            var buffer = [UInt8](repeating: 0, count: DesktopTransitionEventLines.maximumLineBytes)
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { return }
            guard count > 0 else {
                handle.readabilityHandler = nil
                failure()
                return
            }
            receive(Data(buffer.prefix(count)))
        }
        do {
            try process.run()
            state.withLock { $0.launched = true }
            // Do not retain the child's ends in the parent, otherwise EOF is never observable.
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            DispatchQueue.global(qos: .utility).async { [self] in
                process.waitUntilExit()
                output.fileHandleForReading.readabilityHandler = nil
                try? output.fileHandleForReading.close()
                exit()
            }
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    func send(_ data: Data) {
        writer.async { [self] in
            guard state.withLock({ $0.launched && !$0.stopping }) else { return }
            if !write(data) { state.withLock { $0.failure }?() }
        }
    }

    func shutdown(finalCommand: Data?) {
        let launched = state.withLock { state -> Bool? in
            guard !state.stopping else { return nil }
            state.stopping = true
            state.failure = nil
            return state.launched
        }
        guard let launched else { return }
        writer.async { [self] in
            if launched, let finalCommand { _ = write(finalCommand) }
            try? input.fileHandleForWriting.close()
            if !launched {
                output.fileHandleForReading.readabilityHandler = nil
                try? input.fileHandleForReading.close()
                try? output.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
            }
        }
        guard launched else { return }
        // Never wait on main, signal a process group, or find/kill a process by its executable name.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            if process.isRunning { process.terminate() }
        }
    }

    private func write(_ data: Data) -> Bool {
        let fd = input.fileHandleForWriting.fileDescriptor
        return data.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, start.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written }
                else if written == -1 && errno == EINTR { continue }
                else { return false }
            }
            return true
        }
    }
}
