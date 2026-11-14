import Foundation
import LocalAuthentication
import Security

// Provider/security notes (reviewed 2026-11-14):
// - Codex account/rateLimits/read: official schema, percentages USED, Unix-second resets.
//   https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md
//   https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/typescript/v2/RateLimitSnapshot.ts
//   Local token_count/rate_limits events are the offline source used here. They are snapshots, not live queries;
//   old windows and account changes cannot be inferred. Source/observation age are always visible in the card.
// - Claude Code documents macOS Keychain storage, but NOT a public subscription-usage API:
//   https://code.claude.com/docs/en/authentication
//   The OAuth endpoint/header and credential shape are corroborated by maintained public client source:
//   https://github.com/steipete/CodexBar/tree/main/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth
//   GET /api/oauth/usage is a private interface and can change or stop accepting third-party clients.
//   This integration is independently optional, never refreshes tokens or changes CLI configuration, and
//   never reads browser cookies, plaintext credential files, prompts, or sends conversation content.
// - Consent belongs to UsageModel; source initialization has no Keychain, filesystem, or network side effects.
//   Keychain interaction is allowed only for a user-initiated enable/refresh, never for background polling.
//   Secrets stay in memory, are never logged/cached/persisted, and go only to the fixed HTTPS usage endpoint.

struct UsageHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let retryAfter: String?
}

protocol UsageHTTPTransport: Sendable {
    func response(for request: URLRequest) async throws -> UsageHTTPResponse
}

/// Ephemeral, cancellable, bounded requests. Refuse redirects so bearer credentials cannot change origin.
final class UsageURLSessionTransport: NSObject, UsageHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let redirectDelegate: UsageNoRedirectDelegate

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = UsageNoRedirectDelegate()
        redirectDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        super.init()
    }

    deinit { session.invalidateAndCancel() }

    func response(for request: URLRequest) async throws -> UsageHTTPResponse {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        // AsyncBytes does not guarantee task cancellation when iteration exits early (e.g. size limit).
        let streamTask = bytes.task
        defer { streamTask.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw UsageFailure.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 256 * 1_024 else { throw UsageFailure.invalidResponse }
                data.append(byte)
            }
            return UsageHTTPResponse(data: data, statusCode: response.statusCode,
                                     retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        } onCancel: {
            streamTask.cancel()
        }
    }
}

private final class UsageNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Deliberately no refresh token, Codable conformance, description, or persistent token cache.
struct UsageClaudeCredential: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let scopes: [String]?
    let plan: String?
}

protocol UsageClaudeCredentialReading: Sendable {
    func read(allowInteraction: Bool) async throws -> UsageClaudeCredential
}

/// Configured before sharing; cancellation only invalidates the in-flight authentication.
/// A separate context per read prevents one cancelled request from authenticating a later refresh.
final class UsageKeychainAuthenticationContext: @unchecked Sendable {
    let context: LAContext

    init(allowInteraction: Bool) {
        context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        context.localizedReason = "LeNotch reads Claude Code’s sign-in only to display your usage limits."
    }

    func invalidate() { context.invalidate() }
}

actor UsageClaudeKeychainReader: UsageClaudeCredentialReading {
    func read(allowInteraction: Bool) async throws -> UsageClaudeCredential {
        try Task.checkCancellation()
        let authentication = UsageKeychainAuthenticationContext(allowInteraction: allowInteraction)
        defer { authentication.invalidate() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            // Exact Claude Code generic-password service only. No enumeration or auth mutation.
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: "Claude Code-credentials",
                kSecMatchLimit: kSecMatchLimitOne,
                kSecReturnData: true,
                kSecUseAuthenticationContext: authentication.context
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            try Task.checkCancellation()
            if status == errSecItemNotFound { throw UsageFailure.signInRequired }
            guard status == errSecSuccess, let data = result as? Data else { throw UsageFailure.keychainDenied }
            return try Self.decode(data)
        } onCancel: {
            // Opting out/stopping while a prompt is pending must cancel that authentication too.
            authentication.invalidate()
        }
    }

    /// Pure decoder so realistic credential fixtures can be tested without accessing a real Keychain.
    nonisolated static func decode(_ data: Data) throws -> UsageClaudeCredential {
        struct Root: Decodable {
            let claudeAiOauth: OAuth?
            struct OAuth: Decodable {
                let accessToken: String?
                let expiresAt: Double?
                let scopes: [String]?
                let subscriptionType: String?
            }
        }
        guard data.count <= 128 * 1_024,
              let root = try? JSONDecoder().decode(Root.self, from: data),
              let oauth = root.claudeAiOauth,
              let token = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              !token.contains(where: { $0.isNewline || $0 == "\r" }) else { throw UsageFailure.signInRequired }
        return UsageClaudeCredential(accessToken: token,
                                     expiresAt: oauth.expiresAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1_000) : nil },
                                     scopes: oauth.scopes, plan: oauth.subscriptionType)
    }
}

struct ClaudeUsageSource: UsageSource {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let credentials: any UsageClaudeCredentialReading
    private let transport: any UsageHTTPTransport
    private let now: @Sendable () -> Date

    init(credentials: any UsageClaudeCredentialReading = UsageClaudeKeychainReader(),
         transport: any UsageHTTPTransport = UsageURLSessionTransport(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    func fetch(reason: UsageRefreshReason) async throws -> UsageSnapshot {
        try Task.checkCancellation()
        let credential = try await credentials.read(allowInteraction: reason == .userInitiated)
        try Task.checkCancellation()
        if let expiresAt = credential.expiresAt, expiresAt <= now() { throw UsageFailure.credentialExpired }
        if let scopes = credential.scopes, !scopes.contains("user:profile") { throw UsageFailure.signInRequired }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LeNotch/1.0 (subscription usage)", forHTTPHeaderField: "User-Agent")
        let response: UsageHTTPResponse
        do { response = try await transport.response(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as UsageFailure { throw error }
        catch { throw UsageFailure.network }
        try Task.checkCancellation()
        switch response.statusCode {
        case 200: return try UsageDecoders.claude(response.data, observedAt: now(), plan: credential.plan)
        case 401, 403: throw UsageFailure.signInRequired
        case 429: throw UsageFailure.rateLimited(retryAfter: Self.retryDelay(response.retryAfter, now: now()))
        case 500...599: throw UsageFailure.serverUnavailable
        default: throw UsageFailure.invalidResponse
        }
    }

    static func retryDelay(_ header: String?, now: Date) -> TimeInterval {
        guard let header else { return 15 * 60 }
        if let seconds = Double(header), seconds.isFinite { return min(86_400, max(60, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let date = formatter.date(from: header) { return min(86_400, max(60, date.timeIntervalSince(now))) }
        return 15 * 60
    }
}

/// Offline fallback supported by Codex's own rollout event format. Does not start a CLI, touch auth.json,
/// traverse arbitrary transcript trees, or send any request. At most 8 × 128 KiB tails per refresh.
actor CodexUsageSource: UsageSource {
    static let maximumFiles = 8
    static let maximumTailBytes = 128 * 1_024
    static let maximumDirectoryEntries = 256
    static let lookbackDays = 14

    private let sessionsURL: URL
    private let now: @Sendable () -> Date

    init(sessionsURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        if let sessionsURL {
            self.sessionsURL = sessionsURL
        } else {
            let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
                .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
            self.sessionsURL = home.appendingPathComponent("sessions", isDirectory: true)
        }
        self.now = now
    }

    func fetch(reason: UsageRefreshReason) async throws -> UsageSnapshot {
        try Task.checkCancellation()
        let date = now()
        let files = try recentFiles(at: date)
        var newest: UsageSnapshot?
        for file in files {
            try Task.checkCancellation()
            guard let data = try? readTail(file),
                  let snapshot = UsageDecoders.codexSessionTail(data, now: date),
                  newest.map({ snapshot.observedAt > $0.observedAt }) ?? true else { continue }
            newest = snapshot
        }
        guard let newest else { throw UsageFailure.noData }
        return newest
    }

    private func recentFiles(at date: Date) throws -> [URL] {
        let manager = FileManager.default
        // Codex builds rollout paths using local dates. Include the UTC date around timezone boundaries too.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var candidates: [(URL, Date)] = []
        var visited = Set<URL>()
        var scanned = 0
        for offset in 0..<Self.lookbackDays {
            try Task.checkCancellation()
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { continue }
            for zone in [TimeZone.current, TimeZone(secondsFromGMT: 0)!] {
                calendar.timeZone = zone
                let components = calendar.dateComponents([.year, .month, .day], from: day)
                guard let year = components.year, let month = components.month, let number = components.day else { continue }
                let directory = sessionsURL.appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, number), isDirectory: true)
                guard visited.insert(directory).inserted else { continue }
                // Shallow enumeration and global entry budget avoid an unbounded recursive log scan.
                guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                          options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { continue }
                while scanned < Self.maximumDirectoryEntries, let file = enumerator.nextObject() as? URL {
                    scanned += 1
                    try Task.checkCancellation()
                    guard file.pathExtension == "jsonl", file.lastPathComponent.hasPrefix("rollout-"),
                          let values = try? file.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    candidates.append((file, values.contentModificationDate ?? .distantPast))
                }
                if scanned >= Self.maximumDirectoryEntries { break }
            }
            if scanned >= Self.maximumDirectoryEntries { break }
        }
        return candidates.sorted { $0.1 > $1.1 }.prefix(Self.maximumFiles).map(\.0)
    }

    private func readTail(_ url: URL) throws -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > UInt64(Self.maximumTailBytes) ? size - UInt64(Self.maximumTailBytes) : 0
        try handle.seek(toOffset: offset)
        guard var data = try handle.read(upToCount: Self.maximumTailBytes) else { return nil }
        if offset > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return nil }
            data.removeSubrange(...newline)
        }
        return data
    }
}
