import Foundation

enum UsageProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude, codex

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
}

/// Percentages from both providers mean USED, never remaining capacity or context tokens.
struct UsageLimit: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?

    init(id: String, title: String, usedPercent: Double, windowMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent.isFinite ? min(100, max(0, usedPercent)) : 0
        self.windowMinutes = windowMinutes.flatMap { $0 > 0 ? $0 : nil }
        self.resetsAt = resetsAt
    }

    var remainingPercent: Double { 100 - usedPercent }

    /// A passed reset is not proof of a fresh allowance. Wait for a new provider snapshot.
    func resetHasPassed(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }

    func resetDescription(at now: Date) -> String {
        guard let resetsAt else { return "Reset time unavailable" }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Awaiting new window" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1_440 {
            return "Resets in \(minutes / 1_440)d \((minutes % 1_440) / 60)h"
        }
        if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
}

struct UsageSnapshot: Equatable, Sendable {
    let provider: UsageProvider
    let plan: String?
    let limits: [UsageLimit]
    /// Time of the actual measurement, not the time a cached log was read.
    let observedAt: Date
    let sourceDescription: String

    func isStale(at now: Date, maximumAge: TimeInterval = 15 * 60) -> Bool {
        now.timeIntervalSince(observedAt) > maximumAge || limits.contains { $0.resetHasPassed(at: now) }
    }
}

enum UsageFailure: Error, Equatable, Sendable {
    case noData
    case signInRequired
    case credentialExpired
    case keychainDenied
    case invalidResponse
    case network
    case rateLimited(retryAfter: TimeInterval)
    case serverUnavailable
    case sourceUnavailable

    func message(for provider: UsageProvider) -> String {
        switch self {
        case .noData:
            return provider == .codex
                ? "No recent rate-limit snapshot. Sign in to Codex, use a session, then refresh."
                : "Claude did not return subscription limits for this account."
        case .signInRequired:
            return "Sign in to \(provider.title)\(provider == .claude ? " Code" : "") with your subscription, then refresh."
        case .credentialExpired:
            return "Open Claude Code to renew your sign-in, then refresh. LeNotch never refreshes your token."
        case .keychainDenied:
            return "Claude Code’s sign-in is unavailable in Keychain. Refresh to request access, or check Keychain Access."
        case .invalidResponse:
            return "The usage format changed or is unavailable. No usage estimate is shown."
        case .network:
            return "Couldn’t reach \(provider.title). Check your connection and refresh."
        case .rateLimited:
            return "\(provider.title) asked us to wait. Automatic updates are backed off."
        case .serverUnavailable:
            return "\(provider.title)’s usage service is unavailable. Try again later."
        case .sourceUnavailable:
            return "The usage source is unavailable. Check the integration in Setup."
        }
    }
}

struct UsageProviderState: Equatable, Sendable {
    var snapshot: UsageSnapshot?
    var lastAttemptAt: Date?
    var lastRefreshedAt: Date?
    var error: UsageFailure?
    var isRefreshing = false
    var retryAfter: Date?

    func isStale(at now: Date) -> Bool {
        guard let snapshot else { return false }
        return error != nil || snapshot.isStale(at: now)
    }
}

enum UsageRefreshReason: Equatable, Sendable { case background, userInitiated }

protocol UsageSource: Sendable {
    func fetch(reason: UsageRefreshReason) async throws -> UsageSnapshot
}

/// Only provider-defined quota fields are decoded. Token counts/costs are never turned into quota estimates.
enum UsageDecoders {
    static func claude(_ data: Data, observedAt: Date, plan: String? = nil) throws -> UsageSnapshot {
        let payload: ClaudeResponse
        do { payload = try JSONDecoder().decode(ClaudeResponse.self, from: data) }
        catch { throw UsageFailure.invalidResponse }
        let limits = [
            claudeLimit(payload.fiveHour, id: "five_hour", title: "Session", minutes: 300),
            claudeLimit(payload.sevenDay, id: "seven_day", title: "Weekly", minutes: 10_080)
        ].compactMap { $0 }
        guard !limits.isEmpty else { throw UsageFailure.noData }
        return UsageSnapshot(provider: .claude, plan: displayPlan(plan), limits: limits,
                             observedAt: observedAt, sourceDescription: "Claude subscription")
    }

    /// Official app-server `account/rateLimits/read` response. Kept separate from local JSONL envelopes.
    static func codexAppServer(_ data: Data, observedAt: Date) throws -> UsageSnapshot {
        let response: CodexServerResponse
        do { response = try JSONDecoder().decode(CodexServerResponse.self, from: data) }
        catch { throw UsageFailure.invalidResponse }
        let bucket = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
        return try codexSnapshot(bucket, at: observedAt, source: "Codex account")
    }

    /// Bounded JSONL tail, containing only provider-reported `event_msg/token_count/rate_limits` snapshots.
    /// Unrelated records are skipped before JSON decoding; no prompt/message bodies are inspected or logged.
    static func codexSessionTail(_ data: Data, now: Date) -> UsageSnapshot? {
        var newest: UsageSnapshot?
        for line in data.split(separator: 0x0A) {
            guard line.count <= 64 * 1_024,
                  line.range(of: Data("\"rate_limits\"".utf8)) != nil,
                  let event = try? JSONDecoder().decode(CodexEvent.self, from: Data(line)),
                  event.type == "event_msg", event.payload.type == "token_count",
                  let limits = event.payload.rateLimits,
                  let observedAt = parseDate(event.timestamp),
                  observedAt <= now.addingTimeInterval(60),
                  let snapshot = try? codexSnapshot(limits, at: observedAt, source: "Local Codex session"),
                  newest.map({ snapshot.observedAt > $0.observedAt }) ?? true
            else { continue }
            newest = snapshot
        }
        return newest
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value, value.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func displayPlan(_ value: String?) -> String? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "pro": return "Pro"
        case "max": return "Max"
        case "plus": return "Plus"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        case "edu": return "Edu"
        default: return nil
        }
    }

    private static func claudeLimit(_ window: ClaudeWindow?, id: String, title: String, minutes: Int) -> UsageLimit? {
        guard let window, let used = window.utilization, used.isFinite else { return nil }
        return UsageLimit(id: id, title: title, usedPercent: used, windowMinutes: minutes,
                          resetsAt: parseDate(window.resetsAt))
    }

    private static func codexSnapshot(_ response: CodexLimits, at date: Date, source: String) throws -> UsageSnapshot {
        // Other rate-limit buckets (e.g. reviews or individual models) are not the account-wide Codex allowance.
        guard response.limitID == nil || response.limitID == "codex" else { throw UsageFailure.noData }
        let limits = [("primary", response.primary), ("secondary", response.secondary)].compactMap { id, window -> UsageLimit? in
            guard let window, let used = window.usedPercent, used.isFinite else { return nil }
            let minutes = window.windowMinutes
            let title: String
            switch minutes {
            case 300: title = "5-hour"
            case 10_080: title = "Weekly"
            case .some(let value) where value > 0 && value % 1_440 == 0: title = "\(value / 1_440)-day"
            case .some(let value) where value > 0 && value % 60 == 0: title = "\(value / 60)-hour"
            case .some(let value) where value > 0: title = "\(value)-minute"
            default: title = id == "primary" ? "Primary" : "Secondary"
            }
            return UsageLimit(id: id, title: title, usedPercent: used, windowMinutes: minutes,
                              resetsAt: window.resetsAt.flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0) : nil })
        }
        guard !limits.isEmpty else { throw UsageFailure.noData }
        return UsageSnapshot(provider: .codex, plan: displayPlan(response.planType), limits: limits,
                             observedAt: date, sourceDescription: source)
    }

    private struct ClaudeResponse: Decodable {
        let fiveHour: ClaudeWindow?
        let sevenDay: ClaudeWindow?
        enum CodingKeys: String, CodingKey { case fiveHour = "five_hour", sevenDay = "seven_day" }
    }
    private struct ClaudeWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey { case utilization, resetsAt = "resets_at" }
    }
    private struct CodexEvent: Decodable {
        let timestamp: String?
        let type: String
        let payload: Payload
        struct Payload: Decodable {
            let type: String
            let rateLimits: CodexLimits?
            enum CodingKeys: String, CodingKey { case type, rateLimits = "rate_limits" }
        }
    }
    private struct CodexServerResponse: Decodable {
        let rateLimits: CodexLimits
        let rateLimitsByLimitId: [String: CodexLimits]?
    }
    private struct CodexLimits: Decodable {
        let primary: CodexWindow?
        let secondary: CodexWindow?
        let planType: String?
        let limitID: String?
        enum CodingKeys: String, CodingKey {
            case primary, secondary, planType, planTypeSnake = "plan_type", limitId, limitIDSnake = "limit_id"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            primary = try c.decodeIfPresent(CodexWindow.self, forKey: .primary)
            secondary = try c.decodeIfPresent(CodexWindow.self, forKey: .secondary)
            planType = try c.decodeIfPresent(String.self, forKey: .planType) ?? c.decodeIfPresent(String.self, forKey: .planTypeSnake)
            limitID = try c.decodeIfPresent(String.self, forKey: .limitId) ?? c.decodeIfPresent(String.self, forKey: .limitIDSnake)
        }
    }
    private struct CodexWindow: Decodable {
        let usedPercent: Double?
        let windowMinutes: Int?
        let resetsAt: Double?
        enum CodingKeys: String, CodingKey {
            case usedPercent, usedSnake = "used_percent", windowDurationMins, minutesSnake = "window_minutes"
            case resetsAt, resetsSnake = "resets_at"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try c.decodeIfPresent(Double.self, forKey: .usedPercent) ?? c.decodeIfPresent(Double.self, forKey: .usedSnake)
            windowMinutes = try c.decodeIfPresent(Int.self, forKey: .windowDurationMins) ?? c.decodeIfPresent(Int.self, forKey: .minutesSnake)
            resetsAt = try c.decodeIfPresent(Double.self, forKey: .resetsAt) ?? c.decodeIfPresent(Double.self, forKey: .resetsSnake)
        }
    }
}
