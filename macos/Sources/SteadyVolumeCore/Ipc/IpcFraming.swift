import Foundation

public struct IpcProtocolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Length-prefixed JSON messages: [4-byte little-endian length][UTF-8 JSON].
public enum IpcFraming {
    public static let maxMessageBytes = 64 * 1024

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// The JSON payload alone (no length prefix).
    public static func payload<T: Encodable>(_ message: T) throws -> Data {
        try encoder.encode(message)
    }

    /// Length prefix plus payload, ready to write.
    public static func frame<T: Encodable>(_ message: T) throws -> Data {
        let body = try payload(message)
        guard body.count <= maxMessageBytes else { throw IpcProtocolError("Message too large.") }
        var length = UInt32(body.count).littleEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    /// Validates a 4-byte header and returns the payload length.
    public static func payloadLength(header: Data) throws -> Int {
        guard header.count == 4 else { throw IpcProtocolError("Connection closed before the message was complete.") }
        let raw = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let length = Int(Int32(bitPattern: UInt32(littleEndian: raw)))
        guard length > 0, length <= maxMessageBytes else { throw IpcProtocolError("Invalid message length \(length).") }
        return length
    }

    public static func decode<T: Decodable>(_ type: T.Type, payload: Data) throws -> T {
        do {
            return try decoder.decode(type, from: payload)
        } catch {
            throw IpcProtocolError("Malformed message.")
        }
    }

    /// Writes one framed message to a connected socket.
    public static func write<T: Encodable>(_ message: T, to socket: UnixSocket) throws {
        try socket.writeAll(frame(message))
    }

    /// Reads one framed message from a connected socket.
    public static func read<T: Decodable>(_ type: T.Type, from socket: UnixSocket) throws -> T {
        guard let message = try readIfAny(type, from: socket) else {
            throw IpcProtocolError("Connection closed before the message was complete.")
        }
        return message
    }

    /// Like `read`, but returns nil when the peer closed the connection before sending a single byte.
    /// `steadyvol status` does that on purpose: it connects only to learn the daemon's process ID.
    /// A message cut off part way is still an error.
    public static func readIfAny<T: Decodable>(_ type: T.Type, from socket: UnixSocket) throws -> T? {
        let header = try socket.readExactly(4)
        if header.isEmpty { return nil }
        let length = try payloadLength(header: header)
        let body = try socket.readExactly(length)
        guard body.count == length else { throw IpcProtocolError("Connection closed before the message was complete.") }
        return try decode(type, payload: body)
    }
}
