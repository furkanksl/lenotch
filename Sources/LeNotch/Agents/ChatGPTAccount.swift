import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

public struct ChatGPTCredentials: Sendable {
    public let accessToken: String
    public let accountID: String
}

public enum ChatGPTAccountStatus: Equatable {
    case disconnected
    case connecting
    case connected(email: String?, plan: String?)
    case error(String)
}

enum ChatGPTAccountError: LocalizedError {
    case alreadyConnecting, unavailable, cancelled, timedOut, invalidCallback
    case rejected(Int), invalidToken, missingAccount, missingRefreshToken
    case sessionExpired, keychain(OSStatus), network, browser

    var errorDescription: String? {
        switch self {
        case .alreadyConnecting: "ChatGPT sign-in is already in progress."
        case .unavailable: "Sign in with ChatGPT to use this feature."
        case .cancelled: "ChatGPT sign-in was cancelled."
        case .timedOut: "ChatGPT sign-in timed out. Please try again."
        case .invalidCallback: "ChatGPT sign-in did not match this request. Please try again."
        case .rejected(let status): "ChatGPT rejected the request (HTTP \(status))."
        case .invalidToken: "ChatGPT returned an unreadable sign-in response."
        case .missingAccount: "ChatGPT did not provide an account identifier. Please sign in again."
        case .missingRefreshToken: "ChatGPT did not provide a renewable session. Please sign in again."
        case .sessionExpired: "Your ChatGPT session expired. Please sign in again."
        case .keychain: "LeNotch could not access its ChatGPT sign-in in Keychain."
        case .network: "Could not reach ChatGPT. Please try again."
        case .browser: "Could not open your browser for ChatGPT sign-in."
        }
    }
}

/// This is an independent LeNotch account. It never imports Codex CLI's credentials.
@MainActor
public final class ChatGPTAccount: ObservableObject {
    public static let shared = ChatGPTAccount()
    @Published public private(set) var status: ChatGPTAccountStatus = .disconnected

    // Transient refresh failures retain the linked account so dictation can retry later.
    @Published private(set) var isConnected = false
    var connectionGeneration: Int { generation }

    private let keychain = ChatGPTAccountKeychain()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        // Authorization codes and refresh tokens must never be forwarded to a redirect target.
        return URLSession(configuration: configuration, delegate: ChatGPTNoRedirectDelegate(), delegateQueue: nil)
    }()
    private var callbackServer: ChatGPTCallbackServer?
    private var refreshTask: Task<ChatGPTStoredCredentials, Error>?
    private var generation = 0

    private init() {
        // Reading our own item does not request access to another application's Keychain entries.
        if let saved = try? keychain.load() {
            isConnected = true
            status = .connected(email: saved.email, plan: saved.plan)
        }
    }

    public func connect() async throws {
        guard callbackServer == nil else { throw ChatGPTAccountError.alreadyConnecting }
        let state = try ChatGPTOAuth.randomValue()
        let verifier = try ChatGPTOAuth.randomValue()
        // Bind before opening the browser: a different process must never receive our callback.
        let server = try ChatGPTCallbackServer()
        generation += 1
        let currentGeneration = generation
        callbackServer = server
        status = .connecting
        defer {
            server.close()
            if callbackServer === server { callbackServer = nil }
        }
        do {
            guard NSWorkspace.shared.open(ChatGPTOAuth.authorizeURL(state: state, verifier: verifier)) else {
                throw ChatGPTAccountError.browser
            }
            let code = try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    try server.waitForCode(expectedState: state, timeout: 180)
                }.value
            } onCancel: {
                server.close()
            }
            guard currentGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            let response = try await requestToken([
                "grant_type": "authorization_code", "code": code,
                "redirect_uri": ChatGPTOAuth.redirectURI,
                "client_id": ChatGPTOAuth.clientID, "code_verifier": verifier
            ])
            let saved = try ChatGPTStoredCredentials(tokenData: response, previous: nil)
            guard currentGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            try keychain.save(saved)
            generation += 1
            isConnected = true
            status = .connected(email: saved.email, plan: saved.plan)
        } catch {
            if currentGeneration == generation {
                status = error is CancellationError ? .disconnected : .error(error.localizedDescription)
            }
            throw error
        }
    }

    public func disconnect() {
        generation += 1
        isConnected = false
        callbackServer?.close()
        callbackServer = nil
        refreshTask?.cancel()
        refreshTask = nil
        do {
            try keychain.delete()
            status = .disconnected
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Refreshes at most once for concurrent callers. A forced refresh is for a request that got a 401.
    public func validCredentials(forceRefresh: Bool = false) async throws -> ChatGPTCredentials {
        if let refreshTask { return try await refreshTask.value.publicCredentials }
        guard let saved = try keychain.load() else { throw ChatGPTAccountError.unavailable }
        if !forceRefresh && !saved.needsRefresh(at: Date()) { return saved.publicCredentials }

        let currentGeneration = generation
        let task = Task { [self] in
            let data = try await requestToken([
                "grant_type": "refresh_token", "refresh_token": saved.refreshToken,
                "client_id": ChatGPTOAuth.clientID
            ])
            let updated = try ChatGPTStoredCredentials(tokenData: data, previous: saved)
            guard currentGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            try keychain.save(updated)
            isConnected = true
            status = .connected(email: updated.email, plan: updated.plan)
            return updated
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value.publicCredentials
        } catch {
            if currentGeneration == generation {
                if case ChatGPTAccountError.sessionExpired = error {
                    try? keychain.delete()
                    isConnected = false
                    status = .error(ChatGPTAccountError.sessionExpired.localizedDescription)
                } else if !(error is CancellationError) {
                    status = .error(error.localizedDescription)
                }
            }
            throw error
        }
    }

    private func requestToken(_ form: [String: String]) async throws -> Data {
        var request = URLRequest(url: ChatGPTOAuth.tokenURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map(URLQueryItem.init(name:value:))
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw ChatGPTAccountError.network }
        guard let response = response as? HTTPURLResponse, data.count <= 64 * 1024 else {
            throw ChatGPTAccountError.invalidToken
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 400 || response.statusCode == 401,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = (json["error"] as? String) ?? ((json["error"] as? [String: Any])?["code"] as? String),
               code == "invalid_grant" || code == "refresh_token_expired" {
                throw ChatGPTAccountError.sessionExpired
            }
            // Error bodies may contain codes/tokens. Never surface or log them.
            throw ChatGPTAccountError.rejected(response.statusCode)
        }
        return data
    }
}

final class ChatGPTNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ChatGPTOAuth {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann" // Public OAuth client, not a secret.
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTAccountError.unavailable
        }
        return verifier(bytes: bytes)
    }

    static func verifier(bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func challenge(verifier: String) -> String {
        self.verifier(bytes: Array(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func matches(state: String, expected: String) -> Bool {
        let left = Array(state.utf8), right = Array(expected.utf8)
        guard left.count == right.count, !left.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    static func authorizeURL(state: String, verifier: String) -> URL {
        var components = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: challenge(verifier: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "lenotch")
        ]
        return components.url!
    }

    /// Never accepts duplicated state/code, a different host, or a different callback path.
    static func callback(_ requestLine: String, host: String, expectedState: String) -> Result<String, ChatGPTAccountError>? {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."),
              parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"),
              ["localhost:1455", "127.0.0.1:1455"].contains(host.lowercased()),
              let url = URLComponents(string: "http://localhost:1455\(parts[1])"),
              url.path == "/auth/callback", let items = url.queryItems else { return nil }
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, let state = states.first?.value,
              matches(state: state, expected: expectedState) else { return nil }
        if items.contains(where: { $0.name == "error" }) { return .failure(.cancelled) }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty,
              code.count <= 4096 else { return .failure(.invalidCallback) }
        return .success(code)
    }
}

struct ChatGPTStoredCredentials: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let accountID: String
    let expiresAt: Date?
    let email: String?
    let plan: String?

    var publicCredentials: ChatGPTCredentials {
        ChatGPTCredentials(accessToken: accessToken, accountID: accountID)
    }

    func needsRefresh(at now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) <= 5 * 60
    }

    init(tokenData: Data, previous: Self?, now: Date = Date()) throws {
        let token = try JSONDecoder().decode(ChatGPTTokenResponse.self, from: tokenData)
        guard !token.accessToken.isEmpty else { throw ChatGPTAccountError.invalidToken }
        guard let refresh = token.refreshToken?.nonblank ?? previous?.refreshToken else {
            throw ChatGPTAccountError.missingRefreshToken
        }
        let claims = Self.claims(token.idToken) ?? [:]
        let account = (claims["chatgpt_account_id"] as? String)?.nonblank
            ?? ((claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String)?.nonblank
            ?? ((claims["organizations"] as? [[String: Any]])?.first?["id"] as? String)?.nonblank
            ?? previous?.accountID
        guard let account else { throw ChatGPTAccountError.missingAccount }
        guard previous == nil || previous?.accountID == account else { throw ChatGPTAccountError.invalidToken }
        accessToken = token.accessToken
        refreshToken = refresh
        accountID = account
        email = (claims["email"] as? String)?.nonblank ?? previous?.email
        plan = ((claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String)?.nonblank
            ?? previous?.plan
        let expiration = token.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
            ?? Self.claims(token.accessToken).flatMap { ($0["exp"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)) }
        expiresAt = expiration
    }

    private static func claims(_ token: String?) -> [String: Any]? {
        guard let token, token.count <= 32 * 1024, token.split(separator: ".").count == 3,
              let payload = token.split(separator: ".").dropFirst().first else { return nil }
        let base64 = String(payload).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)) else { return nil }
        // TLS token responses are trusted for display/account routing; this is not JWT signature verification.
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private struct ChatGPTTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token"
        case idToken = "id_token", expiresIn = "expires_in"
    }
}

private extension String {
    var nonblank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

private struct ChatGPTAccountKeychain {
    // ThisDeviceOnly: never sync account tokens; distinct from Codex/Claude CLI Keychain items.
    private let service = "com.lenotch.app.chatgpt.oauth"
    private let account = "account-v1"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> ChatGPTStoredCredentials? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ChatGPTAccountError.keychain(status) }
        guard let data = result as? Data,
              let credentials = try? JSONDecoder().decode(ChatGPTStoredCredentials.self, from: data) else {
            throw ChatGPTAccountError.invalidToken
        }
        return credentials
    }

    func save(_ credentials: ChatGPTStoredCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw ChatGPTAccountError.keychain(added) }
        } else if status != errSecSuccess { throw ChatGPTAccountError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ChatGPTAccountError.keychain(status)
        }
    }
}

/// A small, self-contained completion page. It contains no OAuth values, scripts,
/// remote assets, or link that could disclose the localhost callback URL.
enum ChatGPTCallbackPage {
    static func response(success: Bool) -> [UInt8] {
        let status = success ? "200 OK" : "400 Bad Request"
        let heading = success ? "Continue in LeNotch" : "Sign-in couldn't finish"
        let description = success
            ? "The browser step is complete. Return to LeNotch to finish connecting your ChatGPT account."
            : "This sign-in request wasn't accepted. Return to LeNotch and try connecting again."
        let symbol = success ? "&#10003;" : "!"
        let page = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light dark">
          <title>\(heading) · LeNotch</title>
          <style>
            :root { color-scheme: light dark; --bg: #f5f5f7; --ink: #1d1d1f; --muted: #66666d;
              --rule: #dcdce0; --accent: #21853c; --accent-bg: #e9f6ec; }
            @media (prefers-color-scheme: dark) {
              :root { --bg: #171719; --ink: #f4f4f6; --muted: #a1a1a8;
                --rule: #343438; --accent: #30d158; --accent-bg: #193524; }
            }
            * { box-sizing: border-box; }
            body { min-height: 100vh; min-height: 100svh; margin: 0; padding: 32px;
              display: grid; place-items: center; background: var(--bg); color: var(--ink);
              font: 14px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
              -webkit-font-smoothing: antialiased; }
            main { width: min(100%, 440px); padding: 32px 0; }
            .brand { display: flex; align-items: center; gap: 11px; font-size: 15px;
              font-weight: 650; letter-spacing: -.02em; }
            .status { display: grid; place-items: center; width: 54px; height: 54px;
              margin: 64px 0 26px; border-radius: 16px; background: var(--accent-bg);
              color: var(--accent); font-size: 25px; font-weight: 600; }
            .eyebrow { margin: 0 0 11px; color: var(--muted); font-size: 11px;
              font-weight: 650; letter-spacing: .1em; text-transform: uppercase; }
            h1 { margin: 0; font-size: clamp(27px, 5vw, 34px); line-height: 1.15;
              font-weight: 650; letter-spacing: -.035em; }
            .description { margin: 16px 0 0; max-width: 410px; color: var(--muted);
              font-size: 15px; line-height: 1.6; }
            footer { margin-top: 43px; padding-top: 19px; border-top: 1px solid var(--rule);
              color: var(--muted); font-size: 12px; }
            .failure .status { --accent: #a7682c; --accent-bg: #f9eadb; }
            @media (prefers-color-scheme: dark) {
              .failure .status { --accent: #e7a55d; --accent-bg: #382a20; }
            }
            @media (max-width: 480px) { body { padding: 24px; } .status { margin-top: 52px; } }
          </style>
        </head>
        <body class="\(success ? "success" : "failure")">
          <main>
            <header class="brand"><span>LeNotch</span></header>
            <div class="status" aria-hidden="true">\(symbol)</div>
            <p class="eyebrow">ChatGPT account</p>
            <h1>\(heading)</h1>
            <p class="description">\(description)</p>
            <footer>You can close this tab.</footer>
          </main>
        </body>
        </html>
        """
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\nConnection: close\r\nContent-Length: \(page.utf8.count)\r\n\r\n"
        return Array((header + page).utf8)
    }
}

/// A one-shot IPv4 loopback listener. It never serves external interfaces or echoes OAuth codes.
private final class ChatGPTCallbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChatGPTAccountError.unavailable }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(1455).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw ChatGPTAccountError.unavailable // Includes port already held by another sign-in.
        }
        descriptor = fd
    }

    func close() {
        lock.lock()
        let old = descriptor
        descriptor = -1
        lock.unlock()
        if old >= 0 { Darwin.close(old) }
    }

    deinit { close() }

    func waitForCode(expectedState: String, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let fd = descriptor
            lock.unlock()
            guard fd >= 0, !Task<Never, Never>.isCancelled else { throw CancellationError() }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 100) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            defer { Darwin.close(client) }
            var noPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            var bytes = [UInt8](repeating: 0, count: 8192)
            var received = 0
            let capacity = bytes.count
            let requestDeadline = Date().addingTimeInterval(3)
            while received < bytes.count, Date() < requestDeadline {
                var incoming = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                if poll(&incoming, 1, 100) <= 0 { continue }
                let count = bytes.withUnsafeMutableBytes { raw in
                    recv(client, raw.baseAddress!.advanced(by: received), capacity - received, 0)
                }
                if count <= 0 { break }
                received += count
                if Data(bytes.prefix(received)).range(of: Data("\r\n\r\n".utf8)) != nil { break }
            }
            let request = String(decoding: bytes.prefix(received), as: UTF8.self)
            let lines = request.components(separatedBy: "\r\n")
            let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }?
                .dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let line = lines.first,
                  let result = ChatGPTOAuth.callback(line, host: host, expectedState: expectedState) else {
                respond(client, success: false)
                continue
            }
            switch result {
            case .success(let code):
                respond(client, success: true)
                return code
            case .failure(let error):
                respond(client, success: false)
                throw error
            }
        }
        throw ChatGPTAccountError.timedOut
    }

    private func respond(_ client: Int32, success: Bool) {
        let response = ChatGPTCallbackPage.response(success: success)
        response.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = send(client, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if sent <= 0 { break }
                offset += sent
            }
        }
    }
}
