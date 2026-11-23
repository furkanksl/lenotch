import Foundation
import IslandCore
import NowPlaying
import XCTest
@testable import Lenotch

private struct CapturedRequest {
    let request: URLRequest
    let body: [String: Any]

    var payload: [String: Any] { body["payload"] as? [String: Any] ?? [:] }
}

private actor RequestRecorder {
    private(set) var items: [(request: URLRequest, bodyData: Data)] = []
    private var responses: [(status: Int, body: Data, fail: Bool)]

    init(responses: [(status: Int, body: Data, fail: Bool)] = []) {
        self.responses = responses
    }

    func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        let data = request.httpBody ?? Data()
        items.append((request, data))
        let next = responses.isEmpty ? (status: 200, body: Data("{}".utf8), fail: false) : responses.removeFirst()
        if next.fail { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)!
        return (next.body, response)
    }

    func snapshot() -> [(request: URLRequest, bodyData: Data)] { items }
}

private func decodeCaptured(_ items: [(request: URLRequest, bodyData: Data)]) throws -> [CapturedRequest] {
    try items.map { item in
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: item.bodyData) as? [String: Any])
        return CapturedRequest(request: item.request, body: json)
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { self.current = date }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

@MainActor
final class AnalyticsTests: XCTestCase {
    private let validConfig = Analytics.Configuration(
        endpoint: URL(string: "https://umami.zely.ai/api/send")!,
        websiteID: "3e476eb3-0aaa-4124-ae5c-5f5ed4e7da61",
        hostname: "desktop.lenotch.app"
    )

    private let testEnvironment = Analytics.Environment(
        language: "en-US",
        screen: "1512x982",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
        appVersion: "1.1.3",
        buildNumber: "10",
        macOSVersion: "15.4",
        architecture: "arm64"
    )

    func testBundledInfoPlistHasValidUmamiConfiguration() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let config = try XCTUnwrap(Analytics.Configuration.from(info: info))
        XCTAssertEqual(config.endpoint.absoluteString, "https://umami.zely.ai/api/send")
        XCTAssertEqual(config.websiteID, "3e476eb3-0aaa-4124-ae5c-5f5ed4e7da61")
        XCTAssertEqual(config.hostname, "desktop.lenotch.app")
    }

    func testConfigurationRejectsInvalidEndpointsWebsiteIDsAndHostnames() {
        let base: [String: Any] = [
            Analytics.Configuration.endpointKey: "https://umami.zely.ai/api/send",
            Analytics.Configuration.websiteIDKey: "3e476eb3-0aaa-4124-ae5c-5f5ed4e7da61",
            Analytics.Configuration.hostnameKey: "desktop.lenotch.app",
        ]
        XCTAssertNotNil(Analytics.Configuration.from(info: base))

        for badEndpoint in ["http://umami.zely.ai/api/send", "file:///tmp/send", "https:///api/send", "not a url"] {
            var info = base
            info[Analytics.Configuration.endpointKey] = badEndpoint
            XCTAssertNil(Analytics.Configuration.from(info: info), badEndpoint)
        }
        for badWebsite in ["", "not-a-uuid", "12345"] {
            var info = base
            info[Analytics.Configuration.websiteIDKey] = badWebsite
            XCTAssertNil(Analytics.Configuration.from(info: info), badWebsite)
        }
        for badHost in ["", "https://desktop.lenotch.app", "desktop.lenotch.app/path", "has space"] {
            var info = base
            info[Analytics.Configuration.hostnameKey] = badHost
            XCTAssertNil(Analytics.Configuration.from(info: info), badHost)
        }
    }

    func testEventNameSanitizationAndFeatureNamesMatchUmamiLimits() {
        for feature in AnalyticsFeature.allCases {
            XCTAssertLessThanOrEqual(feature.eventName.count, 50)
            XCTAssertEqual(Analytics.sanitizeEventName(feature.eventName), feature.eventName)
        }
        for forbidden in ["", "   ", "=sum", "+cmd", "-flag", "@user", "\ttab", "\rcr"] {
            XCTAssertNil(Analytics.sanitizeEventName(forbidden), forbidden)
        }
        let long = String(repeating: "a", count: 80)
        XCTAssertEqual(Analytics.sanitizeEventName(long)?.count, 50)
    }

    func testInactiveAnalyticsSendsNoRequests() async {
        let analytics = Analytics()
        var recorded: [Analytics.RecordedEvent] = []
        analytics.onRecord = { recorded.append($0) }
        analytics.trackFeature(.chat, action: "open")
        await analytics.flushForTesting()
        XCTAssertEqual(recorded.count, 1)
    }

    func testLaunchAndFeaturePayloadsCacheTokenAndDailyRollover() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_780_000_000))
        let recorder = RequestRecorder(responses: [
            (200, Data(#"{"cache":"tok-1","sessionId":"s1","visitId":"v1"}"#.utf8), false),
            (200, Data(#"{"cache":"tok-2"}"#.utf8), false),
            (400, Data(#"{"error":"bad-request"}"#.utf8), false),
            (200, Data(#"{"cache":"tok-3"}"#.utf8), false),
            (200, Data(#"{"cache":"tok-4"}"#.utf8), false),
            (200, Data(#"{"cache":"tok-5"}"#.utf8), false),
        ])
        let analytics = Analytics(
            configuration: validConfig,
            environment: testEnvironment,
            transport: { request in try await recorder.handle(request) },
            now: { clock.now() }
        )

        analytics.trackAppLaunch(hasNotch: true)
        analytics.trackFeature(.chat, action: "submit", data: ["provider": "chatgpt", "follow_up": false])
        analytics.trackFeature(.timer, action: "start", data: ["minutes": 5])
        await analytics.flushForTesting()

        // Advance one full calendar day: next event should drop stale cache and emit a fresh daily /app pageview first.
        clock.advance(by: 86_400)
        analytics.trackFeature(.notes, action: "add_note")
        await analytics.flushForTesting()

        let captured = try decodeCaptured(await recorder.snapshot())
        XCTAssertEqual(captured.count, 6)

        // 1: Launch pageview (no name, no data, browser-shaped macOS UA, no cache header yet)
        let first = captured[0]
        XCTAssertEqual(first.request.url?.absoluteString, "https://umami.zely.ai/api/send")
        XCTAssertEqual(first.request.httpMethod, "POST")
        XCTAssertEqual(first.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(first.request.value(forHTTPHeaderField: "User-Agent")?.contains("Macintosh; Intel Mac OS X") == true)
        XCTAssertNil(first.request.value(forHTTPHeaderField: "x-umami-cache"))
        XCTAssertEqual(first.body["type"] as? String, "event")
        XCTAssertEqual(first.payload["website"] as? String, validConfig.websiteID)
        XCTAssertEqual(first.payload["hostname"] as? String, "desktop.lenotch.app")
        XCTAssertEqual(first.payload["url"] as? String, "/app")
        XCTAssertNil(first.payload["name"])
        XCTAssertNil(first.payload["data"])

        // 2: app_launched event reuses tok-1
        let second = captured[1]
        XCTAssertEqual(second.request.value(forHTTPHeaderField: "x-umami-cache"), "tok-1")
        XCTAssertEqual(second.payload["name"] as? String, "app_launched")
        let launchData = try XCTUnwrap(second.payload["data"] as? [String: Any])
        XCTAssertEqual(launchData["version"] as? String, "1.1.3")
        XCTAssertEqual(launchData["arch"] as? String, "arm64")
        XCTAssertEqual(launchData["notch"] as? String, "physical")

        // 3: feature_chat reuses tok-2 and fails with 400 -> clears cache token
        let third = captured[2]
        XCTAssertEqual(third.request.value(forHTTPHeaderField: "x-umami-cache"), "tok-2")
        XCTAssertEqual(third.payload["name"] as? String, "feature_chat")
        XCTAssertEqual(third.payload["url"] as? String, "/app/features/chat")
        let chatData = try XCTUnwrap(third.payload["data"] as? [String: Any])
        XCTAssertEqual(chatData["action"] as? String, "submit")
        XCTAssertEqual(chatData["provider"] as? String, "chatgpt")
        XCTAssertEqual(chatData["follow_up"] as? Bool, false)

        // 4: feature_timer sends without stale cache after the 400
        let fourth = captured[3]
        XCTAssertNil(fourth.request.value(forHTTPHeaderField: "x-umami-cache"))
        XCTAssertEqual(fourth.payload["name"] as? String, "feature_timer")
        let timerData = try XCTUnwrap(fourth.payload["data"] as? [String: Any])
        XCTAssertEqual(timerData["minutes"] as? Int, 5)

        // 5 & 6: Day rollover clears tok-3, sends fresh /app pageview, then feature_notes with tok-4
        let rolloverPageview = captured[4]
        XCTAssertNil(rolloverPageview.request.value(forHTTPHeaderField: "x-umami-cache"))
        XCTAssertEqual(rolloverPageview.payload["url"] as? String, "/app")
        XCTAssertNil(rolloverPageview.payload["name"])

        let notesEvent = captured[5]
        XCTAssertEqual(notesEvent.request.value(forHTTPHeaderField: "x-umami-cache"), "tok-4")
        XCTAssertEqual(notesEvent.payload["name"] as? String, "feature_notes")
        XCTAssertEqual((notesEvent.payload["data"] as? [String: Any])?["action"] as? String, "add_note")
    }

    func testNetworkFailureIsSilentAndDoesNotBlockLaterEvents() async throws {
        let recorder = RequestRecorder(responses: [
            (0, Data(), true),
            (200, Data(#"{"cache":"ok"}"#.utf8), false),
        ])
        let analytics = Analytics(
            configuration: validConfig,
            environment: testEnvironment,
            transport: { request in try await recorder.handle(request) }
        )
        analytics.trackFeature(.system, action: "open")
        await analytics.flushForTesting()
        let captured = try decodeCaptured(await recorder.snapshot())
        // Auto daily pageview failed silently, then feature_system still went through.
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[1].payload["name"] as? String, "feature_system")
    }

    func testIslandDirectorTracksFeaturesWithoutDoubleCountingOrLeakingContent() {
        let suite = "lenotch.analytics.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let analytics = Analytics()
        var events: [Analytics.RecordedEvent] = []
        analytics.onRecord = { events.append($0) }

        let director = IslandDirector(chatDefaults: defaults, analytics: analytics)
        director.askSend = { _, _, _ in }
        director.sendCommand = { _ in }
        director.sendShuffle = { _ in }

        // Tray open + page open from tray grid
        director.openTray()
        director.tray.go(.notes)
        XCTAssertEqual(events.map(\.name), ["tray_opened", "feature_notes"])
        XCTAssertEqual(events[1].data["source"], "tray")

        // Shortcut switch while tray is open emits once with source=shortcut; repeating closes without tracking.
        events.removeAll()
        director.toggleToolShortcut(.todo)
        director.toggleToolShortcut(.todo)
        XCTAssertEqual(events.map(\.name), ["feature_todo"])
        XCTAssertEqual(events[0].data["source"], "shortcut")

        // Launcher toggle: opening tracks, closing already-visible launcher does not.
        events.removeAll()
        director.toggleToolShortcut(.launcher)
        director.launcherVisibilityChanged(true)
        director.toggleToolShortcut(.launcher)
        XCTAssertEqual(events.map(\.name), ["feature_launcher"])
        XCTAssertEqual(events[0].data, ["action": "open", "source": "shortcut"])

        // Chat open + submit never includes prompt text
        events.removeAll()
        director.openAsk(.codex, source: "shortcut")
        director.submitAsk("super secret prompt text")
        XCTAssertEqual(events.map(\.name), ["feature_chat", "feature_chat"])
        XCTAssertEqual(events[0].data, ["action": "open", "provider": "chatgpt", "source": "shortcut"])
        XCTAssertEqual(events[1].data, ["action": "submit", "provider": "chatgpt", "follow_up": false])
        for event in events {
            XCTAssertFalse("\(event.data)".contains("super secret"))
        }

        // Sample music does not track; real music tracks without song metadata
        events.removeAll()
        director.startMusic()
        director.togglePlaying()
        director.nextTrack()
        XCTAssertTrue(events.isEmpty, "debug sample music must not emit analytics")

        director.stopMusic()
        director.nowPlayingChanged(NowPlaying(
            title: "Private Track Title",
            artist: "Private Artist",
            album: "Private Album",
            bundleID: BundleID.music,
            playing: true,
            duration: 180,
            elapsed: 12,
            timestamp: Date(),
            kind: .audio
        ))
        director.togglePlaying()
        director.nextTrack()
        director.toggleShuffle()
        director.openFocus()
        XCTAssertEqual(events.map(\.name), [
            "feature_now_playing",
            "feature_now_playing",
            "feature_now_playing",
            "feature_now_playing",
        ])
        XCTAssertEqual(events.map { $0.data["action"] }, ["play_pause", "next", "shuffle", "lyrics"])
        for event in events {
            XCTAssertFalse("\(event.data)".contains("Private Track"))
        }

        // Shelf drop logs count only, never file names or paths
        events.removeAll()
        director.filesDropped([URL(fileURLWithPath: "/Users/alice/secret-tax-return.pdf"),
                               URL(fileURLWithPath: "/Users/alice/passwords.txt")])
        XCTAssertEqual(events.map(\.name), ["feature_shelf"])
        XCTAssertEqual(events[0].data, ["action": "drop", "count": 2])

        // Timer start logs minutes and source
        events.removeAll()
        director.startTimer(minutes: 10, source: "menu")
        XCTAssertEqual(events.map(\.name), ["feature_timer"])
        XCTAssertEqual(events[0].data, ["action": "start", "minutes": 10, "source": "menu"])

        // Agent permission and question log actions without user choice or tool arguments
        events.removeAll()
        director.frontmostApp = { BundleID.finder }
        let permLine = AgentSocket.Line(
            provider: "claude",
            event: "PermissionRequest",
            host: "",
            raw: Data(#"{"session_id":"s-perm","cwd":"/tmp/secret-project","tool_name":"Bash"}"#.utf8)
        )
        director.agentHook(permLine, reply: { _ in })
        director.answerAgent("s-perm", allow: true)
        XCTAssertEqual(events.map(\.name), ["feature_agent_sessions"])
        XCTAssertEqual(events[0].data, ["action": "permission", "decision": "allow"])
        XCTAssertFalse("\(events[0].data)".contains("secret-project"))
    }
}
