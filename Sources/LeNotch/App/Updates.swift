import Foundation
import Sparkle

/// Updates for copies already installed (1.1), through Sparkle. It reads the appcast attached to the
/// configured feed (`SUFeedURL`) and installs only update files signed with the key in `SUPublicEDKey`
/// (tools/updates.sh). It checks by itself once a day (`SUEnableAutomaticChecks`, so it never asks first); the island's
/// right-click menu has Check for Updates… too. Started only on a normal launch: never for snapshots or tests.
/// A background app (no Dock icon), so it takes Sparkle's gentle reminders: an update found by the daily check waits
/// behind your windows instead of taking focus from what you're doing (Sparkle warns a background app without them).
@MainActor
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil,
              Self.isConfigured(feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                                publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// A renamed app must use its own feed and signing key, never the original project's updates.
    nonisolated static func isConfigured(feedURL: String?, publicKey: String?) -> Bool {
        guard let feedURL, let url = URL(string: feedURL), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              let publicKey, !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkNow() { controller?.checkForUpdates(nil) }
}
