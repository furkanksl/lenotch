import XCTest
@testable import Lenotch

/// A proper app (11-11): it lives in Applications, and uninstalling takes only its own files.
@MainActor
final class InstallTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    private let downloaded = URL(fileURLWithPath: "/Users/someone/Downloads/LeNotch.app", isDirectory: true)

    func testAppIdentityMatchesBundleMetadata() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleName"] as? String, "LeNotch")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "LeNotch")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "LeNotch")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.lenotch.app")
        XCTAssertEqual(ApplicationInstaller.appName, "LeNotch.app")
        XCTAssertEqual(Uninstaller.bundleID, "com.lenotch.app")

        for key in ["NSCalendarsFullAccessUsageDescription", "NSBluetoothAlwaysUsageDescription",
                    "NSAudioCaptureUsageDescription", "NSAppleEventsUsageDescription"] {
            let description = try XCTUnwrap(info[key] as? String, key)
            XCTAssertTrue(description.contains("LeNotch"), "\(key) should use the app's display name")
        }
        XCTAssertNil(info["NSFocusStatusUsageDescription"], "LeNotch no longer requests Focus status")
    }

    func testAlreadyInApplicationsStays() {
        for app in ["/Applications/LeNotch.app", "/Applications/Utilities/LeNotch.app", "/Users/someone/Applications/LeNotch.app"] {
            XCTAssertEqual(ApplicationInstaller.plan(bundle: URL(fileURLWithPath: app), original: nil, home: home,
                                                     systemApplicationsWritable: true), .stay, app)
        }
    }

    func testFromDownloadsItMovesToApplications() {
        XCTAssertEqual(ApplicationInstaller.plan(bundle: downloaded, original: nil, home: home, systemApplicationsWritable: true),
                       .move(from: downloaded, to: URL(fileURLWithPath: "/Applications/LeNotch.app", isDirectory: true)))
    }

    func testWithoutWriteAccessItGoesToTheUsersOwnApplications() {
        XCTAssertEqual(ApplicationInstaller.plan(bundle: downloaded, original: nil, home: home, systemApplicationsWritable: false),
                       .move(from: downloaded, to: URL(fileURLWithPath: "/Users/someone/Applications/LeNotch.app", isDirectory: true)))
    }

    /// macOS runs a downloaded app from a random read-only copy: the real one is what moves.
    func testATranslocatedAppMovesItsRealCopy() {
        let random = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1234/d/LeNotch.app")
        XCTAssertEqual(ApplicationInstaller.plan(bundle: random, original: downloaded, home: home, systemApplicationsWritable: true),
                       .move(from: downloaded, to: URL(fileURLWithPath: "/Applications/LeNotch.app", isDirectory: true)))
        let installed = URL(fileURLWithPath: "/Applications/LeNotch.app")
        XCTAssertEqual(ApplicationInstaller.plan(bundle: random, original: installed, home: home, systemApplicationsWritable: true), .stay)
    }

    func testAFolderNamedLikeApplicationsIsntApplications() {
        let lookalike = URL(fileURLWithPath: "/Applications Old/LeNotch.app")
        XCTAssertNotEqual(ApplicationInstaller.plan(bundle: lookalike, original: nil, home: home, systemApplicationsWritable: true), .stay)
    }

    /// Uninstalling deletes only files named after the app, inside the user's Library.
    func testUninstallTouchesOnlyTheAppsOwnFiles() {
        let urls = Uninstaller.leftovers(home: home)
        XCTAssertFalse(urls.isEmpty)
        for url in urls {
            XCTAssertTrue(url.path.hasPrefix("/Users/someone/Library/"), url.path)
            XCTAssertTrue(url.lastPathComponent.hasPrefix("com.lenotch.app") || url.lastPathComponent == "lenotch", url.path)
        }
        XCTAssertEqual(urls.map(\.path), [
            "Application Support/lenotch",
            "Caches/com.lenotch.app",
            "HTTPStorages/com.lenotch.app",
            "HTTPStorages/com.lenotch.app.binarycookies",
            "Saved Application State/com.lenotch.app.savedState",
            "WebKit/com.lenotch.app",
            "Preferences/com.lenotch.app.plist",
        ].map { home.appendingPathComponent("Library/" + $0).path })
        XCTAssertFalse(urls.contains { $0.path.contains(".claude") || $0.path.contains(".codex") || $0.path.contains("com.apple") })
    }

    func testAgentHookUsesTheSupportDirectoryThatUninstallRemoves() {
        let support = home.appendingPathComponent("Library/Application Support/lenotch")
        XCTAssertTrue(Uninstaller.leftovers(home: home).contains(support))
        XCTAssertEqual(HookInstaller.scriptURL(home), support.appendingPathComponent("agent-hook.sh"))
        XCTAssertTrue(HookInstaller.script.contains(#"SOCK="$HOME/Library/Application Support/lenotch/agents.sock"#))
        let socket = URL(fileURLWithPath: AgentSocket.path)
        XCTAssertEqual(socket.lastPathComponent, "agents.sock")
        XCTAssertEqual(socket.deletingLastPathComponent(), HookInstaller.scriptURL().deletingLastPathComponent())
    }
}
