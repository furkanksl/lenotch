import Foundation

/// Local pipes only. No listener, sockets, screen contents or application metadata.
public enum DesktopTransitionCommand: Codable, Equatable, Sendable {
    case start(DesktopTransitionOptions)
    case update(DesktopTransitionOptions)
    case suspend(Bool)
    case stop
}

public enum DesktopTransitionEvent: Codable, Equatable, Sendable {
    case status(DesktopTransitionStatus)
    /// A drawn transition started (true) or ended (false). Nothing about the desktops' content.
    case transition(Bool)
}

/// Newline-delimited messages can be split across reads. Limit each record, not a
/// read containing several records. A malformed/truncated stream must stop the helper.
public struct DesktopTransitionWireDecoder<Message: Decodable>: Sendable {
    public enum Failure: Error { case oversized, truncated }
    private var pending = Data()
    public static var maximumRecordBytes: Int { 4096 }
    public init() {}

    public mutating func append(_ data: Data) throws -> [Message] {
        var messages: [Message] = []
        for byte in data {
            if byte == 10 {
                messages.append(try JSONDecoder().decode(Message.self, from: pending))
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < Self.maximumRecordBytes else { throw Failure.oversized }
                pending.append(byte)
            }
        }
        return messages
    }

    public func finish() throws {
        guard pending.isEmpty else { throw Failure.truncated }
    }
}

public enum DesktopTransitionWire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        return data
    }
}
