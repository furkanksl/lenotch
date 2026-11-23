import AppKit
import Foundation

/// Privacy-first feature usage analytics for LeNotch, posting directly to Umami's official `/api/send` endpoint.
///
/// - No third-party SDK dependencies, no cookies, no persistent visitor identifiers, and no user content.
/// - Inactive (no-op) until `start(...)` is called for a normal `.app` launch, so tests and snapshot runs never
///   send network traffic.
enum AnalyticsFeature: String, CaseIterable, Sendable {
    case nowPlaying = "now_playing"
    case notchVideo = "notch_video"
    case chat = "chat"
    case voiceMode = "voice_mode"
    case dictation = "dictation"
    case timer = "timer"
    case agentSessions = "agent_sessions"
    case shelf = "shelf"
    case launcher = "launcher"
    case clipboard = "clipboard"
    case prompter = "prompter"
    case today = "today"
    case todo = "todo"
    case notes = "notes"
    case shortcuts = "shortcuts"
    case system = "system"
    case usage = "usage"
    case inbox = "inbox"
    case desktopTransitions = "desktop_transitions"
    case appearance = "appearance"

    var eventName: String { "feature_\(rawValue)" }
    var path: String { "/app/features/\(rawValue)" }
}

extension TrayModel.Page {
    var analyticsFeature: AnalyticsFeature? {
        switch self {
        case .main: nil
        case .timer: .timer
        case .clipboard: .clipboard
        case .shelf: .shelf
        case .shortcuts: .shortcuts
        case .today: .today
        case .prompter: .prompter
        case .launcher: .launcher
        case .usage: .usage
        case .system: .system
        case .todo: .todo
        case .notes: .notes
        case .notifications: .inbox
        }
    }
}

/// Scalar values allowed in Umami `payload.data`.
enum AnalyticsValue: Encodable, Equatable, Sendable,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

@MainActor
final class Analytics {
    static let shared = Analytics()

    struct Configuration: Equatable, Sendable {
        let endpoint: URL
        let websiteID: String
        let hostname: String

        static let endpointKey = "LNAnalyticsEndpoint"
        static let websiteIDKey = "LNAnalyticsWebsiteID"
        static let hostnameKey = "LNAnalyticsHostname"

        nonisolated static func from(bundle: Bundle = .main) -> Configuration? {
            from(info: bundle.infoDictionary)
        }

        nonisolated static func from(info: [String: Any]?) -> Configuration? {
            guard let info,
                  let endpointRaw = info[endpointKey] as? String,
                  let websiteRaw = info[websiteIDKey] as? String,
                  let hostnameRaw = info[hostnameKey] as? String else { return nil }
            let endpointText = endpointRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let websiteID = websiteRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let hostname = hostnameRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let endpoint = URL(string: endpointText),
                  endpoint.scheme?.lowercased() == "https",
                  let host = endpoint.host, !host.isEmpty,
                  UUID(uuidString: websiteID) != nil,
                  isValidHostname(hostname) else { return nil }
            return Configuration(endpoint: endpoint, websiteID: websiteID, hostname: hostname)
        }

        nonisolated private static func isValidHostname(_ value: String) -> Bool {
            guard !value.isEmpty,
                  !value.contains("://"),
                  !value.contains("/"),
                  !value.contains(where: { $0.isWhitespace }) else { return false }
            var components = URLComponents()
            components.scheme = "https"
            components.host = value
            return components.url?.host == value
        }
    }

    struct Environment: Equatable, Sendable {
        let language: String
        let screen: String
        let userAgent: String
        let appVersion: String
        let buildNumber: String
        let macOSVersion: String
        let architecture: String

        @MainActor static func live(bundle: Bundle = .main) -> Environment {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let osShort = "\(os.majorVersion).\(os.minorVersion)"
            let osUnderscore = "\(os.majorVersion)_\(os.minorVersion)"
            let language = Locale.preferredLanguages.first ?? Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
            let screenSize = NSScreen.main?.frame.size ?? NSSize(width: 1440, height: 900)
            let screen = "\(Int(screenSize.width.rounded()))x\(Int(screenSize.height.rounded()))"
            // Browser-shaped Safari UA on macOS so Umami's bot filter accepts requests and OS/device reports Mac OS desktop.
            let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X \(osUnderscore)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            #if arch(arm64)
            let architecture = "arm64"
            #elseif arch(x86_64)
            let architecture = "x86_64"
            #else
            let architecture = "unknown"
            #endif
            return Environment(language: language, screen: screen, userAgent: userAgent,
                               appVersion: appVersion, buildNumber: buildNumber,
                               macOSVersion: osShort, architecture: architecture)
        }
    }

    /// Recorded event representation, also exposed for unit tests.
    struct RecordedEvent: Equatable, Sendable {
        let name: String?
        let url: String
        let title: String
        let data: [String: AnalyticsValue]
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private var worker: AnalyticsWorker?
    private var environment: Environment?
    private var enqueueTail: Task<Void, Never>?
    /// Test hook: receives every event emitted by this instance even when no network worker is started.
    var onRecord: ((RecordedEvent) -> Void)?

    init(configuration: Configuration? = nil, environment: Environment? = nil,
         transport: Transport? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        if let configuration {
            let env = environment ?? Self.liveOrFallbackEnvironment()
            self.environment = env
            self.worker = AnalyticsWorker(configuration: configuration, environment: env,
                                          transport: transport ?? Self.defaultTransport, now: now)
        }
    }

    func start(bundle: Bundle = .main, transport: Transport? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        guard worker == nil, let configuration = Configuration.from(bundle: bundle) else { return }
        let env = Environment.live(bundle: bundle)
        environment = env
        worker = AnalyticsWorker(configuration: configuration, environment: env,
                                 transport: transport ?? Self.defaultTransport, now: now)
    }

    func trackAppLaunch(hasNotch: Bool) {
        let env = environment ?? Self.liveOrFallbackEnvironment()
        enqueue(RecordedEvent(name: nil, url: "/app", title: "LeNotch", data: [:]), marksDay: true)
        enqueue(RecordedEvent(
            name: "app_launched",
            url: "/app",
            title: "LeNotch",
            data: [
                "version": .string(env.appVersion),
                "build": .string(env.buildNumber),
                "macos": .string(env.macOSVersion),
                "arch": .string(env.architecture),
                "notch": .string(hasNotch ? "physical" : "virtual"),
            ]
        ))
    }

    func trackFeature(_ feature: AnalyticsFeature, action: String, data: [String: AnalyticsValue] = [:]) {
        var payload = data
        payload["action"] = .string(action)
        enqueue(RecordedEvent(name: feature.eventName, url: feature.path, title: "LeNotch", data: payload))
    }

    func trackEvent(_ name: String, url: String = "/app", title: String = "LeNotch", data: [String: AnalyticsValue] = [:]) {
        guard let sanitized = Self.sanitizeEventName(name) else { return }
        enqueue(RecordedEvent(name: sanitized, url: url, title: title, data: data))
    }

    /// Waits for all currently queued HTTP requests to finish (used by unit tests).
    func flushForTesting() async {
        await enqueueTail?.value
        await worker?.flush()
    }

    private func enqueue(_ event: RecordedEvent, marksDay: Bool = false) {
        onRecord?(event)
        guard let worker else { return }
        let previous = enqueueTail
        enqueueTail = Task {
            await previous?.value
            await worker.enqueue(event, marksDay: marksDay)
        }
    }

    /// Umami rejects event names starting with spreadsheet formula characters (`= + - @ \t \r`) and truncates past 50 chars.
    nonisolated static func sanitizeEventName(_ raw: String) -> String? {
        let forbidden: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]
        guard let rawFirst = raw.first, !forbidden.contains(rawFirst) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, !forbidden.contains(first) else { return nil }
        return String(trimmed.prefix(50))
    }

    private static func liveOrFallbackEnvironment() -> Environment {
        Environment.live(bundle: .main)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static let defaultTransport: Transport = { request in
        try await session.data(for: request)
    }
}

private actor AnalyticsWorker {
    private struct RequestBody: Encodable {
        let type = "event"
        let payload: Payload
    }

    private struct Payload: Encodable {
        let website: String
        let hostname: String
        let language: String
        let screen: String
        let title: String
        let url: String
        let referrer: String
        let name: String?
        let data: [String: AnalyticsValue]?
    }

    private struct SendResponse: Decodable {
        let cache: String?
    }

    private static let maxQueueSize = 100

    private let configuration: Analytics.Configuration
    private let environment: Analytics.Environment
    private let transport: Analytics.Transport
    private let now: @Sendable () -> Date

    private var queue: [Analytics.RecordedEvent] = []
    private var draining = false
    private var cacheToken: String?
    private var lastPageviewDay: String?
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: Analytics.Configuration, environment: Analytics.Environment,
         transport: @escaping Analytics.Transport, now: @escaping @Sendable () -> Date) {
        self.configuration = configuration
        self.environment = environment
        self.transport = transport
        self.now = now
    }

    func enqueue(_ event: Analytics.RecordedEvent, marksDay: Bool) {
        let today = dayStamp(now())
        if marksDay {
            if lastPageviewDay != today { cacheToken = nil }
            lastPageviewDay = today
        } else if lastPageviewDay != today {
            // Long-running notch apps stay open across days: record a fresh daily `/app` pageview on the first activity of a new day.
            lastPageviewDay = today
            cacheToken = nil
            appendBounded(Analytics.RecordedEvent(name: nil, url: "/app", title: "LeNotch", data: [:]))
        }
        appendBounded(event)
        startDrainIfNeeded()
    }

    func flush() async {
        if !draining && queue.isEmpty { return }
        await withCheckedContinuation { continuation in
            flushWaiters.append(continuation)
        }
    }

    private func appendBounded(_ event: Analytics.RecordedEvent) {
        if queue.count >= Self.maxQueueSize {
            queue.removeFirst(queue.count - Self.maxQueueSize + 1)
        }
        queue.append(event)
    }

    private func startDrainIfNeeded() {
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let event = queue.removeFirst()
            await send(event)
        }
        draining = false
        let waiters = flushWaiters
        flushWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func send(_ event: Analytics.RecordedEvent) async {
        let payload = Payload(
            website: configuration.websiteID,
            hostname: configuration.hostname,
            language: environment.language,
            screen: environment.screen,
            title: event.title,
            url: event.url,
            referrer: "",
            name: event.name,
            data: event.name == nil || event.data.isEmpty ? nil : event.data
        )
        guard let body = try? JSONEncoder().encode(RequestBody(payload: payload)) else { return }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(environment.userAgent, forHTTPHeaderField: "User-Agent")
        if let cacheToken {
            request.setValue(cacheToken, forHTTPHeaderField: "x-umami-cache")
        }

        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { return }
            if (200..<300).contains(http.statusCode) {
                if let decoded = try? JSONDecoder().decode(SendResponse.self, from: data),
                   let token = decoded.cache, !token.isEmpty {
                    cacheToken = token
                }
            } else if (400..<500).contains(http.statusCode) {
                cacheToken = nil
            }
        } catch {
            // Analytics failures are silent and never interrupt the app.
        }
    }

    private func dayStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
