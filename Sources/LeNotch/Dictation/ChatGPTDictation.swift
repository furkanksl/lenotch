import Foundation

enum DictationProvider: String, CaseIterable, Identifiable {
    case local
    case chatGPT

    static let preferenceKey = "lenotch.dictation.provider"
    var id: String { rawValue }
    var name: String { self == .local ? "On this Mac" : "ChatGPT" }

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .local
    }

    func isAvailable(chatGPTConnected: Bool) -> Bool {
        self == .local || chatGPTConnected
    }
}

/// Matches Capted's connected-account transcription flow. This is a ChatGPT backend endpoint,
/// not the separately billed OpenAI Audio API; availability can change independently of this app.
@MainActor
enum ChatGPTDictation {
    struct Connection: Sendable {
        let accountID: String
        let generation: Int
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config, delegate: ChatGPTNoRedirectDelegate(), delegateQueue: nil)
    }()

    static func connection() async throws -> Connection {
        let account = ChatGPTAccount.shared
        guard account.isConnected else { throw ChatGPTAccountError.unavailable }
        let generation = account.connectionGeneration
        let credentials = try await account.validCredentials()
        try Task.checkCancellation()
        guard generation == account.connectionGeneration, account.isConnected else { throw Failure.accountChanged }
        return Connection(accountID: credentials.accountID, generation: generation)
    }

    static func transcribe(_ samples: [Float], connection: Connection) async throws -> String {
        let encoding = Task.detached(priority: .userInitiated) { try wav(samples) }
        let audio = try await withTaskCancellationHandler {
            try await encoding.value
        } onCancel: {
            encoding.cancel()
        }
        try Task.checkCancellation()
        for attempt in 0..<2 {
            try validate(connection)
            let auth = try await ChatGPTAccount.shared.validCredentials(forceRefresh: attempt > 0)
            try Task.checkCancellation()
            try validate(connection)
            guard auth.accountID == connection.accountID else { throw Failure.accountChanged }
            let request = request(audio: audio, token: auth.accessToken, accountID: auth.accountID)
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
                if response.statusCode == 401, attempt == 0 { continue }
                guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < maxResponseBytes else { throw Failure.oversizedResponse }
                    data.append(byte)
                }
                try Task.checkCancellation()
                try validate(connection)
                return try transcript(data)
            } catch let error as URLError where error.code == .timedOut {
                throw Failure.timedOut
            }
        }
        throw Failure.http(401)
    }

    private static func validate(_ connection: Connection) throws {
        let account = ChatGPTAccount.shared
        guard account.isConnected, account.connectionGeneration == connection.generation else {
            throw Failure.accountChanged
        }
    }

    nonisolated static let maxResponseBytes = 64 * 1024

    nonisolated static func request(audio: Data, token: String, accountID: String) -> URLRequest {
        let boundary = "lenotch-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/transcribe")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("lenotch/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// The shared recorder produces 16 kHz mono floats. Capted uploads 24 kHz, 16-bit PCM WAV.
    nonisolated static func wav(_ samples: [Float]) throws -> Data {
        // The recording timer can fire just after 90 seconds; allow its final audio buffer.
        guard !samples.isEmpty, samples.count <= 91 * 16_000 else { throw Failure.invalidAudio }
        let samples = samples.prefix(90 * 16_000)
        let count = samples.count * 3 / 2
        let byteCount = UInt32(count * 2)
        var data = Data(capacity: 44 + Int(byteCount))
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8))
        append(UInt32(36) + byteCount)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // Mono
        append(UInt32(24_000))
        append(UInt32(48_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(byteCount)
        for index in 0..<count {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            let position = Double(index) * 2 / 3
            let lower = Int(position)
            let first = samples[lower]
            let next = samples[min(lower + 1, samples.count - 1)]
            guard first.isFinite, next.isFinite else { throw Failure.invalidAudio }
            let fraction = Float(position - Double(lower))
            let sample = min(1, max(-1, first)) * (1 - fraction) + min(1, max(-1, next)) * fraction
            append(Int16((sample * 32_767).rounded()))
        }
        return data
    }

    nonisolated static func transcript(_ data: Data) throws -> String {
        guard data.count <= maxResponseBytes else { throw Failure.oversizedResponse }
        struct Response: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw Failure.invalidResponse }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyTranscript }
        return text
    }

    enum Failure: LocalizedError {
        case invalidAudio, invalidResponse, oversizedResponse, emptyTranscript, accountChanged, timedOut
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidAudio: "Record between a moment and 90 seconds of audio, then try again."
            case .invalidResponse: "ChatGPT returned an invalid transcription response. Try again."
            case .oversizedResponse: "ChatGPT returned an oversized transcription. Try a shorter recording."
            case .emptyTranscript: "Didn't catch anything. Try again."
            case .accountChanged: "The connected ChatGPT account changed. Please record again."
            case .timedOut: "ChatGPT dictation timed out. Try a shorter recording."
            case .http(401): "Your ChatGPT session expired. Reconnect in Setup → AI providers."
            case .http(403): "ChatGPT did not allow dictation for this account. Check your account access or reconnect."
            case .http(404): "ChatGPT dictation is unavailable. Its transcription endpoint may have changed."
            case .http(413): "The recording is too large for ChatGPT dictation. Try a shorter recording."
            case .http(429): "ChatGPT dictation is rate-limited. Wait a moment and try again."
            case .http(500...599): "ChatGPT dictation is temporarily unavailable. Try again shortly."
            case let .http(status): "ChatGPT could not transcribe this recording (HTTP \(status)). Try again."
            }
        }
    }
}
