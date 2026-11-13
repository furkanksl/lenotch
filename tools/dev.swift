#!/usr/bin/swift
// Run with `swift tools/dev.swift`. No package or third-party watcher is needed.
import AppKit
import Darwin
import Foundation

struct DevError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ message: String) {
    FileHandle.standardOutput.write(Data("[dev] \(message)\n".utf8))
}

struct Fingerprint: Equatable {
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init?(_ url: URL) {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

@MainActor
final class DevRunner {
    enum Step { case adapter, bundle, verify }
    enum Phase { case idle, building, quitting, launching }

    private let files = FileManager.default
    private let root: URL
    private let app: URL
    private let stagingDirectory: URL
    private let stagedApp: URL
    private let backup: URL
    private let debugPanel: Bool
    private let once: Bool
    private var lockFD: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var snapshot: [String: Fingerprint] = [:]
    private var phase: Phase = .idle
    private var needsBuild = true
    private var lastEdit = Date.distantPast
    private var childPID: pid_t?
    private var childStep: Step?
    private var quittingApps: [NSRunningApplication] = []
    private var quitDeadline = Date.distantFuture
    private var stopSignal: Int32?
    private var stopGroup: pid_t?
    private var killDeadline = Date.distantFuture
    private var sentKill = false

    init(root: URL, debugPanel: Bool, once: Bool) throws {
        self.root = root
        self.debugPanel = debugPanel
        self.once = once
        app = root.appendingPathComponent("dist/LeNotch.app")
        stagingDirectory = root.appendingPathComponent("dist/.dev-\(UUID().uuidString)")
        stagedApp = stagingDirectory.appendingPathComponent("LeNotch.app")
        backup = stagingDirectory.appendingPathComponent("previous.app")

        // Refuse an older build script: it would overwrite the running app instead of staging it.
        let script = try String(contentsOf: root.appendingPathComponent("build_app.sh"), encoding: .utf8)
        guard script.contains("APP_OUTPUT_DIR") else {
            throw DevError("build_app.sh needs the APP_OUTPUT_DIR output-directory override.")
        }
        try files.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard outputIsLocal() else {
            throw DevError("dist/ and dist/LeNotch.app must not be symlinks outside this checkout.")
        }
        lockFD = root.appendingPathComponent("dist/.dev.lock").path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        }
        guard lockFD >= 0 else { throw DevError("Could not create the development watcher lock.") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD)
            lockFD = -1
            throw DevError("A development watcher is already running for this checkout.")
        }
        try files.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    }

    private func outputIsLocal() -> Bool {
        app.resolvingSymlinksInPath().path == app.path &&
            stagingDirectory.resolvingSymlinksInPath().path == stagingDirectory.path
    }

    func start() {
        snapshot = inputSnapshot()
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stop(number) }
            source.resume()
            signals.append(source)
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        log("Watching Sources, Resources, Package.swift, Package.resolved and build scripts.")
        log("Native Swift uses incremental rebuilds and relaunches, not in-process hot reload.")
        log("Press Ctrl-C to stop watching. The last launched app stays open.")
    }

    private func inputSnapshot() -> [String: Fingerprint] {
        var result: [String: Fingerprint] = [:]
        for directory in ["Sources", "Resources"] {
            guard let entries = files.enumerator(at: root.appendingPathComponent(directory),
                                                includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in entries {
                let relative = String(url.path.dropFirst(root.path.count + 1))
                if relative.split(separator: "/").contains(where: { [".build", "dist", "Vendor"].contains(String($0)) }) {
                    entries.skipDescendants()
                    continue
                }
                result[relative] = Fingerprint(url)
            }
        }
        for path in ["Package.swift", "Package.resolved", "build_app.sh", "tools/build_adapter.sh"] {
            result[path] = Fingerprint(root.appendingPathComponent(path))
        }
        return result
    }

    private func tick() {
        if stopSignal != nil { finishStopping(); return }
        if !once {
            let current = inputSnapshot()
            if current != snapshot {
                snapshot = current
                needsBuild = true
                lastEdit = Date()
            }
        }
        if let pid = childPID {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                let succeeded = status & 0x7f == 0 && (status >> 8) & 0xff == 0
                let step = childStep
                childPID = nil
                childStep = nil
                if succeeded, let step { finished(step) }
                else { failed("Build or validation failed. Keeping the current app; save again to retry.") }
            } else if result == -1 && errno != EINTR {
                childPID = nil
                childStep = nil
                failed("Could not read the build process status. Save again to retry.")
            }
            return
        }
        switch phase {
        case .idle:
            if needsBuild && Date().timeIntervalSince(lastEdit) >= 0.6 { beginBuild() }
        case .quitting:
            let alive = quittingApps.filter { !$0.isTerminated }
            if alive.isEmpty { installAndLaunch() }
            else if Date() >= quitDeadline {
                failed("This checkout's app did not quit within 5 seconds. Its bundle was not replaced; quit it manually and save to retry.")
            }
        case .building, .launching: break
        }
    }

    private func beginBuild() {
        needsBuild = false
        phase = .building
        log("Building debug app…")
        run(.adapter)
    }

    private func run(_ step: Step) {
        let executable: String
        let arguments: [String]
        switch step {
        case .adapter:
            executable = "/bin/zsh"
            arguments = [root.appendingPathComponent("tools/build_adapter.sh").path]
        case .bundle:
            executable = "/bin/zsh"
            arguments = [root.appendingPathComponent("build_app.sh").path]
        case .verify:
            executable = "/usr/bin/codesign"
            arguments = ["--verify", "--deep", "--strict", stagedApp.path]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CONFIG"] = "debug"
        environment["APP_OUTPUT_DIR"] = stagingDirectory.path
        // Development copies must never move themselves into /Applications on launch.
        environment.removeValue(forKey: "LN_ADHOC")
        do {
            childPID = try spawn(executable, arguments: arguments, environment: environment)
            childStep = step
        } catch { failed("Could not start the build: \(error)") }
    }

    private func finished(_ step: Step) {
        switch step {
        case .adapter: run(.bundle)
        case .bundle:
            guard let bundle = Bundle(url: stagedApp),
                  bundle.bundleIdentifier == "com.lenotch.app",
                  bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "LeNotch",
                  files.isExecutableFile(atPath: stagedApp.appendingPathComponent("Contents/MacOS/LeNotch").path) else {
                failed("The staged LeNotch.app is missing or has the wrong identity. The current app is unchanged.")
                return
            }
            run(.verify)
        case .verify:
            if needsBuild {
                log("More edits arrived during the build; rebuilding before relaunch.")
                phase = .idle
                return
            }
            guard outputIsLocal() else {
                failed("The output path changed to a symlink. Refusing to quit or replace an external app.")
                return
            }
            // Match the canonical bundle path, never just the name or bundle identifier.
            // A separately installed LeNotch must not be quit by this checkout's watcher.
            quittingApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.lenotch.app")
                .filter { $0.bundleURL?.resolvingSymlinksInPath() == app.resolvingSymlinksInPath() }
            phase = .quitting
            quitDeadline = Date().addingTimeInterval(5)
            for running in quittingApps { running.terminate() }
        }
    }

    private func installAndLaunch() {
        guard outputIsLocal() else {
            failed("The output path changed to a symlink. Refusing to replace an external app.")
            return
        }
        do {
            if files.fileExists(atPath: backup.path) { try files.removeItem(at: backup) }
            if files.fileExists(atPath: app.path) { try files.moveItem(at: app, to: backup) }
            do { try files.moveItem(at: stagedApp, to: app) }
            catch {
                if files.fileExists(atPath: backup.path) { try files.moveItem(at: backup, to: app) }
                throw error
            }
            launch(recovering: false)
        } catch {
            log("Could not install the staged build: \(error)")
            if files.fileExists(atPath: app.path) { launch(recovering: true) }
            else { failed("The previous bundle could not be restored. Check \(stagingDirectory.path).") }
        }
    }

    private func launch(recovering: Bool) {
        phase = .launching
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = debugPanel ? ["--debug"] : []
        configuration.createsNewApplicationInstance = true
        configuration.activates = debugPanel
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { [weak self] running, error in
            DispatchQueue.main.async {
                guard let self, self.stopSignal == nil else { return }
                if let error {
                    if !recovering && self.files.fileExists(atPath: self.backup.path) {
                        log("New app could not launch; restoring the previous bundle: \(error)")
                        do {
                            try self.files.removeItem(at: self.app)
                            try self.files.moveItem(at: self.backup, to: self.app)
                            self.launch(recovering: true)
                        } catch { self.failed("Could not restore the previous bundle: \(error)") }
                    } else { self.failed("Could not launch LeNotch: \(error)") }
                    return
                }
                guard let running,
                      running.bundleURL?.resolvingSymlinksInPath() == self.app.resolvingSymlinksInPath() else {
                    self.failed("Launch Services did not return this checkout's app.")
                    return
                }
                try? self.files.removeItem(at: self.backup)
                log("\(recovering ? "Restored" : "Launched") \(self.app.path) (PID \(running.processIdentifier)).\(self.debugPanel ? " Debug panel enabled." : "")")
                self.phase = .idle
                if self.once { self.cleanupAndExit(recovering ? 1 : 0) }
            }
        }
    }

    private func failed(_ message: String) {
        log(message)
        phase = .idle
        if once { cleanupAndExit(1) }
    }

    private func stop(_ number: Int32) {
        guard stopSignal == nil else { return }
        stopSignal = number
        stopGroup = childPID
        killDeadline = Date().addingTimeInterval(2)
        if let pid = stopGroup { kill(-pid, SIGTERM) }
        log("Stopping watcher\(stopGroup == nil ? "." : " and its build process group…")")
        finishStopping()
    }

    private func finishStopping() {
        if let pid = childPID {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) { childPID = nil }
        }
        if let group = stopGroup, kill(-group, 0) == 0 {
            guard Date() >= killDeadline else { return }
            if !sentKill {
                kill(-group, SIGKILL)
                sentKill = true
                killDeadline = Date().addingTimeInterval(1)
                return
            }
        }
        guard childPID == nil else { return }
        cleanupAndExit(128 + (stopSignal ?? SIGINT))
    }

    private func cleanupAndExit(_ status: Int32) -> Never {
        timer?.cancel()
        for source in signals { source.cancel() }
        // Do not discard the last working bundle if a filesystem error prevented rollback.
        if !outputIsLocal() {
            log("Output path changed; skipping staging cleanup.")
        } else if files.fileExists(atPath: app.path) || !files.fileExists(atPath: backup.path) {
            try? files.removeItem(at: stagingDirectory)
        } else {
            log("Preserved the previous bundle at \(backup.path).")
        }
        if lockFD >= 0 { Darwin.close(lockFD) }
        Darwin.exit(status)
    }
}

// Give each command its own process group so Ctrl-C can stop its compiler descendants
// without touching another build or another installed LeNotch. Inherit terminal output.
func spawn(_ executable: String, arguments: [String], environment: [String: String]) throws -> pid_t {
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { throw DevError("posix_spawnattr_init failed") }
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGINT)
    sigaddset(&defaults, SIGTERM)
    var mask = sigset_t()
    sigemptyset(&mask)
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0,
          posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
          posix_spawnattr_setsigmask(&attributes, &mask) == 0 else {
        throw DevError("Could not configure the build process group")
    }
    var argv = ([executable] + arguments).map { strdup($0) } + [nil]
    var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        for pointer in argv { free(pointer) }
        for pointer in envp { free(pointer) }
    }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, executable, nil, &attributes, &argv, &envp)
    guard result == 0 else { throw DevError(String(cString: strerror(result))) }
    return pid
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    Usage: swift tools/dev.swift [--debug] [--once]

    Builds a debug LeNotch.app, then watches and rebuilds after saves.
    --debug  Open the existing debug panel on each launch.
    --once   Build and relaunch once without watching.

    No true SwiftUI hot reload: successful saves incrementally rebuild and restart
    this checkout's dist/LeNotch.app. Failed builds leave the running app alone.
    Ctrl-C stops this foreground watcher and its build, leaving the app open.
    """)
    exit(0)
}
if let invalid = arguments.first(where: { !["--debug", "--once"].contains($0) }) {
    log("Unknown option: \(invalid). Use --help for usage.")
    exit(2)
}

MainActor.assumeIsolated {
    do {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
        let runner = try DevRunner(root: root, debugPanel: arguments.contains("--debug"), once: arguments.contains("--once"))
        runner.start()
        withExtendedLifetime(runner) { RunLoop.main.run() }
    } catch {
        log("\(error)")
        exit(1)
    }
}
