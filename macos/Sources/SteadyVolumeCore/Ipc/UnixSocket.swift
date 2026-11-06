import Darwin
import Foundation

public struct SocketError: Error, CustomStringConvertible {
    public let description: String
    public let code: Int32

    public init(_ what: String, code: Int32 = errno) {
        self.code = code
        description = "\(what): \(String(cString: strerror(code)))"
    }
}

/// A thin, blocking wrapper around a Unix domain stream socket. Owns its file descriptor.
public final class UnixSocket {
    public private(set) var fd: Int32

    public init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    /// A connected pair, for tests.
    public static func pair() throws -> (UnixSocket, UnixSocket) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw SocketError("socketpair") }
        return (UnixSocket(fd: fds[0]), UnixSocket(fd: fds[1]))
    }

    public static func connect(path: String, timeout: TimeInterval) throws -> UnixSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        let sock = UnixSocket(fd: fd)
        try sock.setTimeout(timeout)
        var address = try makeAddress(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw SocketError("connect \(path)") }
        return sock
    }

    /// Binds and listens at `path`. A stale socket file left at `path` is removed first; any other
    /// kind of file there is an error.
    public static func listen(path: String, mode: mode_t, backlog: Int32 = 16) throws -> UnixSocket {
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK else {
                throw SocketError("\(path) exists and is not a socket", code: EEXIST)
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        let sock = UnixSocket(fd: fd)
        var address = try makeAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw SocketError("bind \(path)") }
        guard chmod(path, mode) == 0 else { throw SocketError("chmod \(path)") }
        guard Darwin.listen(fd, backlog) == 0 else { throw SocketError("listen \(path)") }
        return sock
    }

    /// Blocks until a client connects. Returns nil if the listening socket was closed.
    public func accept() throws -> UnixSocket? {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client >= 0 { return UnixSocket(fd: client) }
            switch errno {
            case EINTR, ECONNABORTED: continue
            case EBADF, EINVAL: return nil
            default: throw SocketError("accept")
            }
        }
    }

    public func setTimeout(_ seconds: TimeInterval) throws {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size) == 0
        else { throw SocketError("setsockopt timeout") }
    }

    public func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { throw SocketError("write timed out", code: ETIMEDOUT) }
                    throw SocketError("write")
                }
                offset += n
            }
        }
    }

    /// Reads exactly `count` bytes, or fewer if the peer closed the connection first.
    public func readExactly(_ count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { throw SocketError("read timed out", code: ETIMEDOUT) }
                throw SocketError("read")
            }
            offset += n
        }
        return Data(buffer[0..<offset])
    }

    public func shutdownWrite() {
        Darwin.shutdown(fd, SHUT_WR)
    }

    /// The effective user ID of the process at the other end.
    public func peerUID() throws -> uid_t {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { throw SocketError("getpeereid") }
        return uid
    }

    /// The process ID at the other end.
    public func peerPID() throws -> pid_t {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { throw SocketError("LOCAL_PEERPID") }
        return pid
    }

    private static func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SocketError("Socket path too long: \(path)", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
}
