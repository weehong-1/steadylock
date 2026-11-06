import Darwin
import Foundation
import SteadyVolumeCore

struct DaemonUnavailableError: Error, CustomStringConvertible {
    let description: String
}

/// Talks to the daemon over its Unix socket: one request, one response per connection.
struct DaemonClient {
    static let connectTimeout: TimeInterval = 5
    static let responseTimeout: TimeInterval = 60

    let socketPath: String
    /// Production only: refuse to send anything unless root is at the other end. /var/run is writable
    /// only by root, so a non-root program cannot put a fake socket there to collect the password.
    let verifyServer: Bool

    func send(_ request: IpcRequest) throws -> IpcResponse {
        let socket: UnixSocket
        do {
            socket = try UnixSocket.connect(path: socketPath, timeout: Self.connectTimeout)
        } catch {
            throw DaemonUnavailableError(description: "Could not connect to the SteadyVolume daemon at \(socketPath): \(error).")
        }
        defer { socket.close() }

        if verifyServer {
            let uid = try? socket.peerUID()
            guard uid == 0 else {
                throw DaemonUnavailableError(description:
                    "The process behind \(socketPath) is not running as root (uid \(uid.map(String.init) ?? "unknown")). Refusing to talk to it.")
            }
        }

        do {
            try socket.setTimeout(Self.responseTimeout)
            try IpcFraming.write(request, to: socket)
            return try IpcFraming.read(IpcResponse.self, from: socket)
        } catch {
            throw DaemonUnavailableError(description: "The SteadyVolume daemon did not answer: \(error).")
        }
    }

    /// The daemon's process ID, if something is listening on the socket.
    func peerPID() -> pid_t? {
        guard let socket = try? UnixSocket.connect(path: socketPath, timeout: Self.connectTimeout) else { return nil }
        defer { socket.close() }
        return try? socket.peerPID()
    }
}
