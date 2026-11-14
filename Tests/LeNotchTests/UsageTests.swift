import AppKit
import IslandCore
import LocalAuthentication
import SwiftUI
import XCTest
@testable import Lenotch

@MainActor
final class UsageTests: XCTestCase {
    private let now = UsageDecoders.parseDate("2026-11-14T12:00:00Z")!

    private func defaults() throws -> UserDefaults {
        let name = "com.lenotch.tests.usage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func snapshot(_ provider: UsageProvider = .claude, used: Double = 25) -> UsageSnapshot {
        UsageSnapshot(provider: provider, plan: nil,
                      limits: [UsageLimit(id: "primary", title: "Session", usedPercent: used,
                                          resetsAt: now.addingTimeInterval(3_600))],
                      observedAt: now, sourceDescription: "Fixture")
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Usage operation did not settle")
    }

    private var claudeResponse: Data {
        Data(#"{"five_hour":{"utilization":27.5,"resets_at":"2026-11-14T15:00:00.000Z"},"seven_day":{"utilization":81,"resets_at":"2026-11-19T12:00:00Z"},"seven_day_sonnet":null,"extra_usage":{"is_enabled":false}}"#.utf8)
    }

    private func codexEvent(timestamp: String = "2026-11-14T11:58:00.123Z", used: Double = 12,
                            limitID: String = "codex", includeSecondary: Bool = true) -> String {
        let reset = now.addingTimeInterval(7_200).timeIntervalSince1970
        let secondary = includeSecondary
            ? #", "secondary":{"used_percent":35,"window_minutes":10080,"resets_at":\#(reset + 86_400)}"# : ""
        return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000,"output_tokens":500}},"rate_limits":{"limit_id":"\#(limitID)","primary":{"used_percent":\#(used),"window_minutes":300,"resets_at":\#(reset)}\#(secondary),"credits":{"has_credits":false,"unlimited":false,"balance":null},"plan_type":"plus"}}}"#
    }

    func testClaudeDecodesRealUtilizationAsUsedNotRemaining() throws {
        let result = try UsageDecoders.claude(claudeResponse, observedAt: now, plan: "max")
        XCTAssertEqual(result.provider, .claude)
        XCTAssertEqual(result.plan, "Max")
        XCTAssertEqual(result.limits.map(\.usedPercent), [27.5, 81])
        XCTAssertEqual(result.limits.map(\.remainingPercent), [72.5, 19])
        XCTAssertEqual(result.limits.map(\.title), ["Session", "Weekly"])
        XCTAssertEqual(result.limits[0].resetsAt, now.addingTimeInterval(3 * 3_600))
        XCTAssertEqual(result.observedAt, now)
    }

    func testUnknownClaudePlanIsNotInvented() throws {
        XCTAssertNil(try UsageDecoders.claude(claudeResponse, observedAt: now, plan: "unknown-tier").plan)
        XCTAssertNil(try UsageDecoders.claude(claudeResponse, observedAt: now).plan)
    }

    func testClaudeNullAndMissingWindowsAreNotZeroPercentUsage() throws {
        let one = try UsageDecoders.claude(Data(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":null}"#.utf8), observedAt: now)
        XCTAssertEqual(one.limits.count, 1)
        XCTAssertEqual(one.limits.first?.remainingPercent, 100)
        XCTAssertNil(one.limits.first?.resetsAt)
        for payload in ["{}", #"{"five_hour":null,"seven_day":null}"#, #"{"five_hour":{"resets_at":null}}"#] {
            XCTAssertThrowsError(try UsageDecoders.claude(Data(payload.utf8), observedAt: now)) {
                XCTAssertEqual($0 as? UsageFailure, .noData)
            }
        }
    }

    func testMalformedProviderFormatFailsInsteadOfShowingAnEstimate() {
        XCTAssertThrowsError(try UsageDecoders.claude(Data(#"{"five_hour":{"utilization":"unknown"}}"#.utf8), observedAt: now)) {
            XCTAssertEqual($0 as? UsageFailure, .invalidResponse)
        }
        XCTAssertThrowsError(try UsageDecoders.codexAppServer(Data("not-json".utf8), observedAt: now))
    }

    func testPercentagesAreClampedAtPresentationBoundary() throws {
        let payload = Data(#"{"five_hour":{"utilization":123.4},"seven_day":{"utilization":-12}}"#.utf8)
        let result = try UsageDecoders.claude(payload, observedAt: now)
        XCTAssertEqual(result.limits.map(\.usedPercent), [100, 0])
        XCTAssertEqual(result.limits.map(\.remainingPercent), [0, 100])
    }

    func testResetCountdownAndPassedResetNeverFabricateRenewedAllowance() {
        let limit = UsageLimit(id: "a", title: "Weekly", usedPercent: 90, resetsAt: now.addingTimeInterval(90))
        XCTAssertEqual(limit.resetDescription(at: now), "Resets in 2m")
        XCTAssertEqual(limit.resetDescription(at: now.addingTimeInterval(90)), "Awaiting new window")
        XCTAssertTrue(limit.resetHasPassed(at: now.addingTimeInterval(100)))
        XCTAssertEqual(limit.remainingPercent, 10)
        XCTAssertEqual(UsageLimit(id: "b", title: "Unknown", usedPercent: 1).resetDescription(at: now), "Reset time unavailable")
        XCTAssertEqual(UsageLimit(id: "c", title: "Long", usedPercent: 1, resetsAt: now.addingTimeInterval(90_000)).resetDescription(at: now), "Resets in 1d 1h")
    }

    func testCodexSessionDecodesRealQuotaNotContextTokens() throws {
        let result = try XCTUnwrap(UsageDecoders.codexSessionTail(Data(codexEvent().utf8), now: now))
        XCTAssertEqual(result.provider, .codex)
        XCTAssertEqual(result.plan, "Plus")
        XCTAssertEqual(result.limits.map(\.usedPercent), [12, 35])
        XCTAssertEqual(result.limits.map(\.title), ["5-hour", "Weekly"])
        XCTAssertEqual(result.limits[0].remainingPercent, 88)
        XCTAssertEqual(result.limits[0].resetsAt, now.addingTimeInterval(7_200))
        XCTAssertEqual(result.sourceDescription, "Local Codex session")
    }

    func testCodexAppServerSchemaAndDynamicDurations() throws {
        let data = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":17,"windowDurationMins":120,"resetsAt":1794668400},"secondary":{"usedPercent":31,"windowDurationMins":null,"resetsAt":null},"credits":null,"planType":"pro"},"rateLimitsByLimitId":null}"#.utf8)
        let result = try UsageDecoders.codexAppServer(data, observedAt: now)
        XCTAssertEqual(result.limits.map(\.usedPercent), [17, 31])
        XCTAssertEqual(result.limits.map(\.title), ["2-hour", "Secondary"])
        XCTAssertNil(result.limits[1].resetsAt)
        XCTAssertEqual(result.plan, "Pro")
    }

    func testCodexIgnoresOtherBucketsAndChoosesNewestValidEvent() throws {
        let lines = [
            #"{"timestamp":"2026-11-14T12:00:00Z","type":"response_item","payload":{"type":"message","content":"fixture, not actual user data"}}"#,
            "not-json",
            codexEvent(timestamp: "2026-11-14T11:59:00Z", used: 99, limitID: "codex-review"),
            codexEvent(timestamp: "2026-11-14T11:57:00Z", used: 20),
            codexEvent(timestamp: "2026-11-14T11:59:00Z", used: 26),
            codexEvent(timestamp: "2099-11-14T11:59:00Z", used: 90)
        ].joined(separator: "\n")
        let result = try XCTUnwrap(UsageDecoders.codexSessionTail(Data(lines.utf8), now: now))
        XCTAssertEqual(result.limits[0].usedPercent, 26)
        XCTAssertNil(UsageDecoders.codexSessionTail(Data(codexEvent(limitID: "codex-review").utf8), now: now))
    }

    func testCodexNoDataIsNotMisrepresentedAsAnEmptyAllowance() {
        XCTAssertNil(UsageDecoders.codexSessionTail(Data(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_tokens":9999},"rate_limits":null}}"#.utf8), now: now))
        XCTAssertNil(UsageDecoders.codexSessionTail(Data(), now: now))
    }

    func testSnapshotAgeAndResetMakeLimitsStale() {
        let snapshot = snapshot()
        XCTAssertFalse(snapshot.isStale(at: now))
        XCTAssertTrue(snapshot.isStale(at: now.addingTimeInterval(901)))
        XCTAssertTrue(snapshot.isStale(at: now.addingTimeInterval(3_600), maximumAge: 10_000))
        var state = UsageProviderState(snapshot: snapshot)
        state.error = .network
        XCTAssertTrue(state.isStale(at: now))
    }

    func testCredentialFixtureUsesMillisecondsAndNoRefreshTokenIsNeeded() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"fixture-not-a-real-token","expiresAt":1794661200000,"scopes":["user:profile"],"subscriptionType":"pro"},"mcpOAuth":{}}"#.utf8)
        let credential = try UsageClaudeKeychainReader.decode(data)
        XCTAssertEqual(credential.accessToken, "fixture-not-a-real-token")
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 1_794_661_200))
        XCTAssertEqual(credential.plan, "pro")
        XCTAssertThrowsError(try UsageClaudeKeychainReader.decode(Data(#"{"mcpOAuth":{}}"#.utf8)))
        XCTAssertThrowsError(try UsageClaudeKeychainReader.decode(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)))
    }

    func testKeychainBackgroundContextCannotPromptAndManualContextExplainsAccess() {
        // Constructing a context does not query Keychain or evaluate an authentication policy.
        let background = UsageKeychainAuthenticationContext(allowInteraction: false)
        let manual = UsageKeychainAuthenticationContext(allowInteraction: true)
        defer { background.invalidate(); manual.invalidate() }
        XCTAssertTrue(background.context.interactionNotAllowed)
        XCTAssertFalse(manual.context.interactionNotAllowed)
        XCTAssertEqual(manual.context.localizedReason,
                       "LeNotch reads Claude Code’s sign-in only to display your usage limits.")
        XCTAssertFalse(background.context === manual.context)
    }

    func testDisabledModelDoesNotReadKeychainOrSendRequests() async throws {
        let credentials = UsageCredentialSpy(credential: fixtureCredential())
        let transport = UsageHTTPSpy(response: UsageHTTPResponse(data: claudeResponse, statusCode: 200, retryAfter: nil))
        let source = ClaudeUsageSource(credentials: credentials, transport: transport)
        let model = UsageModel(defaults: try defaults(), sources: [.claude: source])
        model.start()
        model.refresh()
        for _ in 0..<30 { await Task.yield() }
        let reads = await credentials.readCount
        let requests = await transport.requestCount
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(model.enabled)
        model.stop()
    }

    func testOptInPersistsAndDisablingClearsUsageButNeverWritesCredentials() async throws {
        let defaults = try defaults()
        let source = UsageSourceSpy(snapshot: snapshot())
        let model = UsageModel(defaults: defaults, sources: [.claude: source])
        model.start()
        model.setEnabled(true, for: .claude)
        await settle { model.state(for: .claude).snapshot != nil }
        XCTAssertTrue(model.enabled)
        XCTAssertTrue(defaults.bool(forKey: "usage.claude.enabled"))
        let restored = UsageModel(defaults: defaults, sources: [:])
        XCTAssertTrue(restored.isEnabled(.claude))
        XCTAssertNil(restored.state(for: .claude).snapshot)
        model.setEnabled(false, for: .claude)
        XCTAssertNil(model.state(for: .claude).snapshot)
        XCTAssertFalse(model.isEnabled(.claude))
        XCTAssertFalse(defaults.bool(forKey: "usage.claude.enabled"))
        XCTAssertNil(defaults.data(forKey: "usage.snapshot"))
        model.stop()
    }

    func testSelectionPersistsAndProviderStatesStayIndependent() async throws {
        let defaults = try defaults()
        let claude = UsageSourceSpy(snapshot: snapshot(.claude, used: 22))
        let codex = UsageSourceSpy(snapshot: snapshot(.codex, used: 65))
        let model = UsageModel(defaults: defaults, sources: [.claude: claude, .codex: codex])
        model.start()
        model.setEnabled(true, for: .claude)
        model.setEnabled(true, for: .codex)
        await settle { model.state(for: .claude).snapshot != nil && model.state(for: .codex).snapshot != nil }
        XCTAssertEqual(model.state(for: .claude).snapshot?.limits[0].usedPercent, 22)
        XCTAssertEqual(model.state(for: .codex).snapshot?.limits[0].usedPercent, 65)
        model.selectedProvider = .codex
        XCTAssertEqual(UsageModel(defaults: defaults, sources: [:]).selectedProvider, .codex)
        model.stop()
    }

    func testRefreshIsSingleFlightAndStartIsIdempotent() async throws {
        let source = UsageSourceSpy(snapshot: snapshot(), suspended: true)
        let model = UsageModel(defaults: try defaults(), sources: [.claude: source])
        model.start()
        model.start()
        model.setEnabled(true, for: .claude)
        await settle { model.state(for: .claude).isRefreshing }
        for _ in 0..<20 { model.refresh(); await Task.yield() }
        let calls = await source.calls
        XCTAssertEqual(calls, 1)
        await source.release()
        await settle { !model.state(for: .claude).isRefreshing }
        XCTAssertNotNil(model.state(for: .claude).snapshot)
        model.stop()
    }

    func testDisabledAndStoppedRequestsCannotPublishLateResults() async throws {
        for stop in [false, true] {
            let source = UsageSourceSpy(snapshot: snapshot(), suspended: true)
            let model = UsageModel(defaults: try defaults(), sources: [.claude: source])
            model.start()
            model.setEnabled(true, for: .claude)
            for _ in 0..<100 { if await source.calls > 0 { break }; await Task.yield() }
            if stop { model.stop() } else { model.setEnabled(false, for: .claude) }
            await source.release()
            for _ in 0..<20 { await Task.yield() }
            XCTAssertNil(model.state(for: .claude).snapshot)
            XCTAssertFalse(model.state(for: .claude).isRefreshing)
            model.stop()
        }
    }

    func testFailedRefreshPreservesLastKnownSnapshotAndItsObservationTime() async throws {
        let now = now
        let source = UsageSourceSpy(snapshot: snapshot())
        let model = UsageModel(defaults: try defaults(), sources: [.claude: source], now: { now })
        model.start()
        model.setEnabled(true, for: .claude)
        await settle { model.state(for: .claude).snapshot != nil }
        await source.fail(.network)
        model.refresh()
        await settle { model.state(for: .claude).error == .network }
        XCTAssertEqual(model.state(for: .claude).snapshot?.observedAt, now)
        XCTAssertEqual(model.state(for: .claude).lastRefreshedAt, now)
        XCTAssertTrue(model.state(for: .claude).isStale(at: now))
        model.stop()
    }

    func test429BackoffPreventsRepeatedManualRequests() async throws {
        let now = now
        let source = UsageSourceSpy(snapshot: snapshot())
        await source.fail(.rateLimited(retryAfter: 900))
        let model = UsageModel(defaults: try defaults(), sources: [.claude: source], now: { now })
        model.start()
        model.setEnabled(true, for: .claude)
        await settle { model.state(for: .claude).error != nil }
        model.refresh()
        for _ in 0..<20 { await Task.yield() }
        let calls = await source.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.state(for: .claude).retryAfter, now.addingTimeInterval(900))
        model.stop()
    }

    func testProviderMismatchCannotPopulateTheWrongAccountCard() async throws {
        let source = UsageSourceSpy(snapshot: snapshot(.codex))
        let model = UsageModel(defaults: try defaults(), sources: [.claude: source])
        model.start()
        model.setEnabled(true, for: .claude)
        await settle { model.state(for: .claude).error != nil }
        XCTAssertEqual(model.state(for: .claude).error, .invalidResponse)
        XCTAssertNil(model.state(for: .claude).snapshot)
        model.stop()
    }

    func testClaudeRequestUsesOnlyFixedUsageEndpointAndManualKeychainConsent() async throws {
        let now = now
        let credentials = UsageCredentialSpy(credential: fixtureCredential())
        let transport = UsageHTTPSpy(response: UsageHTTPResponse(data: claudeResponse, statusCode: 200, retryAfter: nil))
        let source = ClaudeUsageSource(credentials: credentials, transport: transport, now: { now })
        let result = try await source.fetch(reason: .userInitiated)
        XCTAssertEqual(result.provider, .claude)
        let lastRequest = await transport.lastRequest
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.url, URL(string: "https://api.anthropic.com/api/oauth/usage"))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-not-a-real-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        let allowed = await credentials.interactions
        XCTAssertEqual(allowed, [true])
        _ = try await source.fetch(reason: .background)
        let background = await credentials.interactions
        XCTAssertEqual(background, [true, false])
    }

    func testExpiredClaudeCredentialDoesNotSendRequestOrRotateToken() async throws {
        let now = now
        let credentials = UsageCredentialSpy(credential: UsageClaudeCredential(accessToken: "fixture-expired", expiresAt: now.addingTimeInterval(-1), scopes: ["user:profile"], plan: nil))
        let transport = UsageHTTPSpy(response: UsageHTTPResponse(data: Data(), statusCode: 200, retryAfter: nil))
        let source = ClaudeUsageSource(credentials: credentials, transport: transport, now: { now })
        do { _ = try await source.fetch(reason: .userInitiated); XCTFail("Expected expired credential") }
        catch { XCTAssertEqual(error as? UsageFailure, .credentialExpired) }
        let requests = await transport.requestCount
        XCTAssertEqual(requests, 0)
    }

    func testCredentialWithoutUsageScopeDoesNotSendAnyRequest() async throws {
        let now = now
        let credentials = UsageCredentialSpy(credential: UsageClaudeCredential(accessToken: "fixture-without-scope", expiresAt: nil, scopes: ["user:inference"], plan: nil))
        let transport = UsageHTTPSpy(response: UsageHTTPResponse(data: Data(), statusCode: 200, retryAfter: nil))
        let source = ClaudeUsageSource(credentials: credentials, transport: transport, now: { now })
        do { _ = try await source.fetch(reason: .userInitiated); XCTFail("Expected missing scope") }
        catch { XCTAssertEqual(error as? UsageFailure, .signInRequired) }
        let requests = await transport.requestCount
        XCTAssertEqual(requests, 0)
    }

    func testClaudeHTTPFailuresAreSanitizedAndRetryAfterIsRespected() async throws {
        let now = now
        for (status, expected) in [(401, UsageFailure.signInRequired), (403, .signInRequired),
                                    (429, .rateLimited(retryAfter: 1_200)), (503, .serverUnavailable), (302, .invalidResponse)] {
            let credentials = UsageCredentialSpy(credential: fixtureCredential())
            let transport = UsageHTTPSpy(response: UsageHTTPResponse(data: Data("body-not-for-display".utf8), statusCode: status, retryAfter: "1200"))
            let source = ClaudeUsageSource(credentials: credentials, transport: transport, now: { now })
            do { _ = try await source.fetch(reason: .background); XCTFail("Expected HTTP failure") }
            catch { XCTAssertEqual(error as? UsageFailure, expected) }
        }
        XCTAssertEqual(ClaudeUsageSource.retryDelay(nil, now: now), 900)
        XCTAssertEqual(ClaudeUsageSource.retryDelay("-3", now: now), 60)
        XCTAssertEqual(ClaudeUsageSource.retryDelay("Sat, 14 Nov 2026 12:10:00 GMT", now: now), 600)
    }

    func testLocalCodexSourceReadsOnlyBoundedRecentRolloutTails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lenotch-usage-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/11/14", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-fixture.jsonl")
        // Oversized unrelated line ensures only a bounded tail is read; no user transcript fixtures are needed.
        var data = Data(repeating: 0x20, count: CodexUsageSource.maximumTailBytes + 400)
        data.append(Data(("\n" + codexEvent() + "\n").utf8))
        try data.write(to: file)
        let now = now
        let source = CodexUsageSource(sessionsURL: root, now: { now })
        let result = try await source.fetch(reason: .background)
        XCTAssertEqual(result.limits.first?.usedPercent, 12)
        XCTAssertEqual(result.observedAt, UsageDecoders.parseDate("2026-11-14T11:58:00.123Z"))
        try FileManager.default.removeItem(at: file)
        do { _ = try await source.fetch(reason: .background); XCTFail("Expected no data") }
        catch { XCTAssertEqual(error as? UsageFailure, .noData) }
    }

    func testUsageProvidersUseTheMatchingSharedAgentMarks() {
        XCTAssertEqual(UsageProvider.claude.agentProvider, AgentProvider.claude)
        XCTAssertEqual(UsageProvider.codex.agentProvider, AgentProvider.codex)
    }

    func testProviderMarksRemainVisibleAndDistinctAtTabSize() throws {
        for scale in [1.0, 2.0] {
            var rendered: [Data] = []
            for provider in UsageProvider.allCases {
                let renderer = ImageRenderer(content: AgentMark(provider: provider.agentProvider, size: 14))
                renderer.scale = scale
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.width, Int(14 * scale))
                XCTAssertEqual(image.height, Int(14 * scale))
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try pixels.withUnsafeMutableBytes { bytes in
                    let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                                         bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                         space: CGColorSpaceCreateDeviceRGB(),
                                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                let visible = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 32 }
                XCTAssertGreaterThan(visible.count, Int(8 * scale), "\(provider) mark must be visible at \(scale)x")
                rendered.append(Data(pixels))
            }
            XCTAssertNotEqual(rendered[0], rendered[1], "Claude and Codex must retain distinct provider marks")
        }
    }

    func testNotchUsageCardRendersAtDeclaredIntegrationSizeWithoutOptingIn() throws {
        let model = UsageModel(defaults: try defaults(), sources: [:])
        for provider in UsageProvider.allCases {
            model.selectedProvider = provider
            let renderer = ImageRenderer(content: UsageView(model: model, onClose: {}, onOpenSettings: {}))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertEqual(image.size.width, UsageView.cardWidth)
            XCTAssertEqual(image.size.height, UsageView.cardHeight)
            XCTAssertFalse(model.enabled)
        }
    }

    func testNotchUsageCardRendersMeasuredAndStaleWindowsWithoutResizing() async throws {
        let source = UsageSourceSpy(snapshot: snapshot(.codex, used: 87))
        let model = UsageModel(defaults: try defaults(), sources: [.codex: source])
        model.start()
        model.setEnabled(true, for: .codex)
        model.selectedProvider = .codex
        await settle { model.state(for: .codex).snapshot != nil }
        for scale in [1.0, 2.0] {
            let renderer = ImageRenderer(content: UsageView(model: model, onClose: {}, onOpenSettings: {}))
            renderer.scale = scale
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertEqual(image.size, NSSize(width: 480, height: 266))
        }
        model.stop()
    }

    private func fixtureCredential() -> UsageClaudeCredential {
        UsageClaudeCredential(accessToken: "fixture-not-a-real-token", expiresAt: now.addingTimeInterval(86_400),
                              scopes: ["user:profile", "user:inference"], plan: "pro")
    }
}

private actor UsageSourceSpy: UsageSource {
    var calls = 0
    private var snapshot: UsageSnapshot
    private var failure: UsageFailure?
    private var suspended: Bool
    private var pending: CheckedContinuation<Void, Never>?

    init(snapshot: UsageSnapshot, suspended: Bool = false) {
        self.snapshot = snapshot
        self.suspended = suspended
    }

    func fetch(reason: UsageRefreshReason) async throws -> UsageSnapshot {
        calls += 1
        if suspended { await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
        return snapshot
    }

    func release() { suspended = false; pending?.resume(); pending = nil }
    func fail(_ failure: UsageFailure) { self.failure = failure }
}

private actor UsageCredentialSpy: UsageClaudeCredentialReading {
    var readCount = 0
    var interactions: [Bool] = []
    let credential: UsageClaudeCredential
    init(credential: UsageClaudeCredential) { self.credential = credential }
    func read(allowInteraction: Bool) async throws -> UsageClaudeCredential {
        readCount += 1
        interactions.append(allowInteraction)
        return credential
    }
}

private actor UsageHTTPSpy: UsageHTTPTransport {
    var requestCount = 0
    var lastRequest: URLRequest?
    let fixture: UsageHTTPResponse
    init(response: UsageHTTPResponse) { fixture = response }
    func response(for request: URLRequest) async throws -> UsageHTTPResponse {
        requestCount += 1
        lastRequest = request
        return fixture
    }
}
