import AppKit

#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
    // Offscreen render of the scripted transitions to PNG contact sheets; no windows.
    let dir = CommandLine.arguments.dropFirst(i + 1).first ?? "snapshots"
    MainActor.assumeIsolated { SnapshotRunner.run(outputDirectory: dir) }
    exit(0)
}
#endif

let app = NSApplication.shared
#if DEBUG
if CommandLine.arguments.contains("--voice-diagnostic") {
    let diagnostic = MainActor.assumeIsolated { ChatGPTVoiceDiagnostic() }
    app.delegate = diagnostic
    app.run()
    exit(0)
}
#endif
if CommandLine.arguments.contains("--desktop-transitions-helper") {
    // A helper must be spawned with a parent-owned input pipe, never as a second
    // independent instance owning the user's keyboard and trackpad indefinitely.
    guard isatty(STDIN_FILENO) == 0 else { exit(1) }
    let helper = MainActor.assumeIsolated { DesktopTransitionsHelper() }
    app.setActivationPolicy(.accessory)
    app.delegate = helper
    app.run()
    exit(0)
}
let delegate = MainActor.assumeIsolated { AppDelegate() }
// Updates (1.1): only from a built app, never a bare `swift run` binary, which has no bundle to replace.
if Bundle.main.bundleURL.pathExtension == "app" { MainActor.assumeIsolated { Updates.shared.start() } }
app.delegate = delegate
app.run()
