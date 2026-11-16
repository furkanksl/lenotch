import Foundation

@MainActor
protocol ChatGPTVoiceCalling: AnyObject {
    var onEvent: ((ChatGPTVoiceTransportEvent) -> Void)? { get set }
    func prepare() async throws
    func connect(offer: String) async throws -> String
    func startEvents() async throws
    func sendDelegationResult(id: String, text: String) async throws
    func stop()
}

/// The ChatGPT-authenticated WebRTC path used by Codex. Unlike the public Audio API,
/// this backend accepts JSON and returns an SDP answer. It is an experimental service.
@MainActor
final class ChatGPTVoiceClient: ChatGPTVoiceCalling {
    var onEvent: ((ChatGPTVoiceTransportEvent) -> Void)?
    private var connection: ChatGPTDictation.Connection?
    private var callID: String?
    private let sideband = ChatGPTVoiceSideband()
    private var voice = ChatGPTVoice.cove
    private let session: URLSession
    var onDiagnostic: ((String) -> Void)?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: ChatGPTNoRedirectDelegate(), delegateQueue: nil)
    }

    func prepare() async throws {
        voice = ChatGPTVoice.selected()
        connection = try await ChatGPTDictation.connection()
    }

    func connect(offer: String) async throws -> String {
        guard let connection else { throw ChatGPTAccountError.unavailable }
        for attempt in 0..<2 {
            try validate(connection)
            let credentials = try await ChatGPTAccount.shared.validCredentials(forceRefresh: attempt > 0)
            try Task.checkCancellation()
            try validate(connection)
            guard credentials.accountID == connection.accountID else { throw VoiceError.accountChanged }
            let request = try Self.request(offer: offer, token: credentials.accessToken, accountID: credentials.accountID, voice: voice)
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw VoiceError.invalidAnswer }
            if response.statusCode == 401, attempt == 0 { continue }
            guard (200..<300).contains(response.statusCode) else {
                var errorData = Data()
                for try await byte in bytes {
                    if errorData.count >= 16 * 1024 { break }
                    errorData.append(byte)
                }
                onDiagnostic?(Self.errorSummary(status: response.statusCode, data: errorData))
                throw VoiceError.http(response.statusCode)
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumSDPBytes else { throw VoiceError.invalidAnswer }
                data.append(byte)
            }
            try Task.checkCancellation()
            try validate(connection)
            callID = try Self.callID(response.value(forHTTPHeaderField: "Location"))
            return try Self.answer(data)
        }
        throw VoiceError.http(401)
    }

    func startEvents() async throws {
        guard let callID, let connection else { throw VoiceError.invalidAnswer }
        sideband.onEvent = { [weak self] in self?.onEvent?($0) }
        try await sideband.connect(callID: callID, connection: connection)
    }

    func sendDelegationResult(id: String, text: String) async throws {
        guard let connection else { throw VoiceError.accountChanged }
        try validate(connection)
        for message in try ChatGPTVoiceDelegation.messages(id: id, text: text) { try await sideband.send(message) }
    }

    func sendText(_ text: String) async throws {
        guard !text.isEmpty, text.utf8.count <= 500 else { throw VoiceError.invalidOffer }
        try await sideband.send(["type": "session.context.append", "content": [["type": "input_text", "text": text]]])
    }

    func stop() {
        sideband.onEvent = nil
        sideband.stop()
        callID = nil
        connection = nil
    }

    private func validate(_ connection: ChatGPTDictation.Connection) throws {
        guard ChatGPTAccount.shared.isConnected,
              connection.generation == ChatGPTAccount.shared.connectionGeneration else { throw VoiceError.accountChanged }
    }

    nonisolated static let maximumSDPBytes = 256 * 1024

    nonisolated static func callID(_ location: String?) throws -> String {
        guard let location, let components = URLComponents(string: location),
              let id = components.percentEncodedPath.split(separator: "/").last.map(String.init),
              id.utf8.count <= 256, id != ".", id != "..", id != "calls",
              id.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil else { throw VoiceError.invalidAnswer }
        return id
    }

    /// Deliberately omits raw backend text, which may echo request/session information.
    nonisolated static func errorSummary(status: Int, data: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = (json?["error"] as? [String: Any]) ?? json ?? [:]
        var fields = ["HTTP \(status)"]
        for name in ["type", "code", "param"] {
            if let value = error[name] as? String, !value.isEmpty, value.count < 100,
               value.range(of: #"^[a-zA-Z0-9_.\[\]-]+$"#, options: .regularExpression) != nil {
                fields.append("\(name)=\(value)")
            }
        }
        let message = ((error["message"] as? String) ?? (json?["detail"] as? String) ?? "").lowercased()
        let terms = ["model", "voice", "session", "audio", "architecture", "instructions", "sdp", "attestation", "unsupported", "unknown", "required", "invalid", "access", "not found", "missing"]
        let matches = terms.filter { message.contains($0) }
        if !matches.isEmpty { fields.append("mentions=" + matches.joined(separator: ",")) }
        return fields.joined(separator: "; ")
    }

    nonisolated static func request(offer: String, token: String, accountID: String, voice: ChatGPTVoice = .cove) throws -> URLRequest {
        guard offer.utf8.count <= maximumSDPBytes, offer.hasPrefix("v=0"), offer.contains("m=audio ") else {
            throw VoiceError.invalidOffer
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("quicksilver=v2", forHTTPHeaderField: "OpenAI-Alpha")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/sdp", forHTTPHeaderField: "Accept")
        request.setValue("lenotch/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "sdp": offer,
            "session": [
                "instructions": "You are the voice assistant in Lenotch, a macOS utility. Have a natural, concise spoken conversation in the user's language. For requests needing current information, internet research, fact checking, or multi-step work, delegate the task to the client. The client worker can search and open web pages using ChatGPT web search. Wait for its returned result before claiming findings or completion. An acknowledgement is not a completed task; never pretend work is running if it was not delegated. You cannot access this Mac, run commands, or change files; say so for requests requiring those capabilities.",
                "audio": [
                    "output": ["voice": voice.rawValue],
                ],
                "delegation": ["type": "client"],
            ],
        ])
        return request
    }

    nonisolated static func answer(_ data: Data) throws -> String {
        guard data.count <= maximumSDPBytes, let answer = String(data: data, encoding: .utf8),
              answer.hasPrefix("v=0"), answer.contains("m=audio ") else { throw VoiceError.invalidAnswer }
        return answer
    }

    enum VoiceError: LocalizedError {
        case invalidOffer, invalidAnswer, accountChanged, microphoneDenied, connectionTimedOut
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidOffer: "Couldn't prepare voice audio. Close voice mode and try again."
            case .invalidAnswer: "ChatGPT couldn't start a voice call. The experimental service may have changed."
            case .accountChanged: "Your ChatGPT connection changed. Reconnect your account and try again."
            case .microphoneDenied: "Allow Lenotch to use your microphone in System Settings → Privacy & Security → Microphone."
            case .connectionTimedOut: "Voice couldn't connect. Check your internet connection and try again."
            case .http(401): "Reconnect ChatGPT in Setup → AI providers, then try again."
            case .http(403): "Voice isn't available for this ChatGPT account right now."
            case .http(404): "ChatGPT's experimental voice service is unavailable. Try again later."
            case .http(429): "You've reached ChatGPT's voice limit. Try again later."
            case .http(500...599): "ChatGPT voice is temporarily unavailable. Try again shortly."
            case .http: "ChatGPT couldn't start voice mode. Try again later."
            }
        }
    }
}
