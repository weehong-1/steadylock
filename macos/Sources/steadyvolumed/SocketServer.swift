import Darwin
import Foundation
import SteadyVolumeCore

/// Serves the control socket: one request and one response per connection.
/// Any local user may connect; every command that changes something needs the password.
final class SocketServer {
    private static let clientTimeout: TimeInterval = 30
    private static let maxConcurrentClients = 8

    private let path: String
    private let mode: mode_t
    private let processor: CommandProcessor
    private let log: EventLogging
    private let errorLog = RevertLogThrottle(window: 60)
    private let errorLogLock = NSLock()
    private let slots = DispatchSemaphore(value: maxConcurrentClients)
    private let clients = DispatchQueue(label: "com.steadyvolume.ipc-clients", attributes: .concurrent)
    private var listener: UnixSocket?

    init(path: String, mode: mode_t, processor: CommandProcessor, log: EventLogging) {
        self.path = path
        self.mode = mode
        self.processor = processor
        self.log = log
    }

    func start() throws {
        let listener = try UnixSocket.listen(path: path, mode: mode)
        self.listener = listener
        let thread = Thread { [weak self] in self?.acceptLoop(listener) }
        thread.name = "SteadyVolume IPC"
        thread.start()
    }

    func stop() {
        listener?.close()
        unlink(path)
    }

    private func acceptLoop(_ listener: UnixSocket) {
        while true {
            slots.wait()
            let client: UnixSocket?
            do {
                client = try listener.accept()
            } catch {
                slots.signal()
                logError("accept", "Could not accept a control connection: \(error)")
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            guard let client else { return } // listener closed
            clients.async { [self] in
                defer { slots.signal() }
                serve(client)
            }
        }
    }

    private func serve(_ client: UnixSocket) {
        defer { client.close() }
        do {
            do {
                try client.setTimeout(Self.clientTimeout)
            } catch let error as SocketError where error.code == EINVAL {
                // macOS refuses setsockopt once the peer has closed. That is a client that only
                // looked up the daemon's PID (steadyvol status), not a failure.
                return
            }
            let response: IpcResponse
            do {
                // nil: the client closed without sending anything (see above). Nothing to answer.
                guard let request = try IpcFraming.readIfAny(IpcRequest.self, from: client) else { return }
                response = processor.handle(request)
            } catch let error as IpcProtocolError {
                response = .failure(.badRequest, error.description)
            }
            try IpcFraming.write(response, to: client)
            client.shutdownWrite()
        } catch {
            logError("client", "Control connection failed: \(error)")
        }
    }

    private func logError(_ key: String, _ message: String) {
        errorLogLock.lock()
        let report = errorLog.register(key) != nil
        errorLogLock.unlock()
        if report { log.log(.warning, .ipcError, message) }
    }
}
