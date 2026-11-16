import Foundation

/// Codex's existing-call frameless sideband. WebRTC remains responsible for audio.
/// This intentionally uses the captured ChatGPT account, not a separate API key.
@MainActor
final class ChatGPTVoiceSideband {
    var onEvent: ((ChatGPTVoiceTransportEvent) -> Void)?
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var opening: Task<Void, Error>?
    private var openingWaiter: Opening?
    private var socketDelegate: SocketDelegate?
    private var receiving: Task<Void, Never>?
    private var connection: ChatGPTDictation.Connection?
    private var generation = UUID()
    private var decoder = ChatGPTVoiceEventDecoder()
    nonisolated static let maximumMessageBytes = 128 * 1024

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: configuration, delegate: ChatGPTNoRedirectDelegate(), delegateQueue: nil)
        }
    }

    isolated deinit { stop() }

    func connect(callID: String, connection: ChatGPTDictation.Connection) async throws {
        stop()
        let current = generation
        let work = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try validate(connection)
            let credentials = try await ChatGPTAccount.shared.validCredentials()
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            try validate(connection)
            guard credentials.accountID == connection.accountID else { throw Failure.accountChanged }
            let request = try Self.request(callID: callID, token: credentials.accessToken, accountID: credentials.accountID)
            let task = session.webSocketTask(with: request)
            let waiter = Opening()
            openingWaiter = waiter
            let delegate = SocketDelegate(opening: waiter)
            socketDelegate = delegate
            // A per-task delegate also protects an injected session from credential redirects.
            task.delegate = delegate
            task.maximumMessageSize = Self.maximumMessageBytes
            socket = task
            self.connection = connection
            // Upgrade completion is didOpen, not a pong: some servers never answer pings.
            try await waiter.wait(start: { task.resume() }, cancel: { task.cancel(with: .goingAway, reason: nil) })
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            openingWaiter = nil
            try validate(connection)
            receiving = Task { @MainActor [weak self] in
                await self?.receive(task, connection: connection, generation: current)
            }
        }
        opening = work
        do {
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
                Task { @MainActor [weak self] in
                    guard let self, generation == current else { return }
                    stop()
                }
            }
            guard generation == current else { throw CancellationError() }
            opening = nil
        } catch {
            if generation == current { stop() }
            throw error
        }
    }

    func send(_ message: [String: Any]) async throws {
        guard let socket, let connection else { throw Failure.notConnected }
        let current = generation
        try Task.checkCancellation()
        try validate(connection)
        let data = try JSONSerialization.data(withJSONObject: message)
        guard data.count <= Self.maximumMessageBytes, let text = String(data: data, encoding: .utf8) else {
            throw Failure.invalidMessage
        }
        try await socket.send(.string(text))
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        try validate(connection)
    }

    func stop() {
        generation = UUID()
        opening?.cancel(); opening = nil
        openingWaiter?.cancel(); openingWaiter = nil
        receiving?.cancel(); receiving = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        socketDelegate = nil
        connection = nil
        decoder = ChatGPTVoiceEventDecoder()
    }

    private func receive(_ task: URLSessionWebSocketTask, connection: ChatGPTDictation.Connection, generation current: UUID) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                try Task.checkCancellation()
                guard generation == current else { return }
                try validate(connection)
                let data: Data
                switch message {
                case .data(let bytes): data = bytes
                case .string(let text): data = Data(text.utf8)
                @unknown default: throw Failure.invalidMessage
                }
                guard data.count <= Self.maximumMessageBytes,
                      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw Failure.invalidMessage
                }
                for event in decoder.decode(payload) {
                    guard generation == current else { return }
                    onEvent?(event)
                }
            }
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            stop()
            onEvent?(.failed("The voice work connection closed. End voice and try again."))
        }
    }

    private func validate(_ connection: ChatGPTDictation.Connection) throws {
        let account = ChatGPTAccount.shared
        guard account.isConnected, account.connectionGeneration == connection.generation else { throw Failure.accountChanged }
    }

    /// Pinned Codex methods.rs:67,900,1293–1338 and methods_common.rs:168–173:
    /// the default API base becomes /v1/live/{id}; frameless supplies no intent query.
    nonisolated static func request(callID: String, token: String, accountID: String) throws -> URLRequest {
        guard !callID.isEmpty, callID.utf8.count <= 256, callID != ".", callID != "..",
              callID.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { throw Failure.invalidCallID }
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/live/\(callID)")!)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("quicksilver=v2", forHTTPHeaderField: "OpenAI-Alpha")
        request.setValue("lenotch/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    enum Failure: LocalizedError, Equatable {
        case accountChanged, invalidCallID, invalidMessage, notConnected, openingTimedOut
        case openingFailed(status: Int?)
        var errorDescription: String? {
            switch self {
            case .accountChanged: "Your ChatGPT connection changed. Reconnect and start voice again."
            case .invalidCallID: "ChatGPT returned an invalid voice call identifier."
            case .invalidMessage: "ChatGPT returned an invalid voice work message."
            case .notConnected: "The voice work connection is not connected."
            case .openingTimedOut: "The voice work connection did not open within 15 seconds. End voice and try again."
            case .openingFailed(let status):
                if let status, (100..<600).contains(status) {
                    "The voice work connection could not open (HTTP \(status)). End voice and try again."
                } else {
                    "The voice work connection could not open. End voice and try again."
                }
            }
        }
    }

    /// Kept separate from auth so deadline/callback races can be tested without an account.
    @MainActor
    final class Opening {
        private var continuation: CheckedContinuation<Void, Error>?
        private var deadline: Task<Void, Never>?
        private var cancelSocket: (() -> Void)?
        private var result: Result<Void, Error>?

        func wait(timeout: Duration = .seconds(15), start: () -> Void, cancel: @escaping () -> Void) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if let result { continuation.resume(with: result); return }
                    self.continuation = continuation
                    cancelSocket = cancel
                    deadline = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: timeout, clock: .continuous) }
                        catch { return }
                        self?.finish(.failure(Failure.openingTimedOut), cancelSocket: true)
                    }
                    if Task.isCancelled { finish(.failure(CancellationError()), cancelSocket: true) }
                    else { start() }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel() }
            }
        }

        func didOpen() { finish(.success(()), cancelSocket: false) }
        func didFail(status: Int?) { finish(.failure(Failure.openingFailed(status: status)), cancelSocket: true) }
        func cancel() { finish(.failure(CancellationError()), cancelSocket: true) }

        private func finish(_ result: Result<Void, Error>, cancelSocket: Bool) {
            guard self.result == nil else { return }
            self.result = result
            deadline?.cancel(); deadline = nil
            let cancel = self.cancelSocket
            self.cancelSocket = nil
            let continuation = self.continuation
            self.continuation = nil
            if cancelSocket { cancel?() }
            continuation?.resume(with: result)
        }
    }

    private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let opening: Opening
        init(opening: Opening) { self.opening = opening }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            Task { @MainActor [opening] in opening.didOpen() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            Task { @MainActor [opening] in opening.didFail(status: status) }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            let status = (webSocketTask.response as? HTTPURLResponse)?.statusCode
            Task { @MainActor [opening] in opening.didFail(status: status) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            // Never forward captured credentials to a redirected endpoint.
            completionHandler(nil)
            let status = response.statusCode
            Task { @MainActor [opening] in opening.didFail(status: status) }
        }
    }
}
