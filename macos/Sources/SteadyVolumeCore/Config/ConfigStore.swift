import Darwin
import Foundation

public protocol ConfigStoring: AnyObject {
    func load() throws -> SteadyVolumeConfig
    func save(_ config: SteadyVolumeConfig) throws
}

/// JSON file store. Writes go to a temp file (mode 0600, flushed to disk) that is then renamed over
/// config.json atomically; the previous version is kept as config.json.bak. If the main file is
/// unreadable, the backup is used.
public final class ConfigStore: ConfigStoring {
    public let filePath: String
    public var backupPath: String { filePath + ".bak" }
    private var tempPath: String { filePath + ".tmp" }

    /// Optional hook run on the directory and each file written (the daemon uses it to force root:wheel and modes).
    private let afterWrite: ((String) throws -> Void)?

    public init(path: String, afterWrite: ((String) throws -> Void)? = nil) {
        precondition(!path.isEmpty)
        filePath = URL(fileURLWithPath: path).standardizedFileURL.path
        self.afterWrite = afterWrite
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFormatter.string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = isoFormatter.date(from: text) ?? plainIsoFormatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date '\(text)'."))
        }
        return decoder
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainIsoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Returns defaults when no file exists. Throws `ConfigError` when the file and/or its backup
    /// exist but none can be read.
    public func load() throws -> SteadyVolumeConfig {
        let fm = FileManager.default
        let mainExists = fm.fileExists(atPath: filePath)
        let backupExists = fm.fileExists(atPath: backupPath)
        if !mainExists && !backupExists { return SteadyVolumeConfig() }

        var mainError: Error?
        if mainExists {
            do { return try Self.readFile(filePath) } catch { mainError = error }
        }
        if backupExists {
            do { return try Self.readFile(backupPath) } catch {
                throw ConfigError("Both config.json and its backup are unreadable: \(mainError.map { "\($0)" } ?? "\(error)")")
            }
        }
        throw ConfigError("config.json is unreadable and there is no backup: \(mainError.map { "\($0)" } ?? "unknown error")")
    }

    public func save(_ config: SteadyVolumeConfig) throws {
        try config.validate()
        let data = try Self.encoder.encode(config)

        let directory = (filePath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }

        try Self.writeDurably(data, to: tempPath)

        if FileManager.default.fileExists(atPath: filePath) {
            // Keep the previous version: replace the backup with a hard link to the current file,
            // then atomically rename the new file over it.
            unlink(backupPath)
            if link(filePath, backupPath) != 0 {
                _ = try? FileManager.default.copyItem(atPath: filePath, toPath: backupPath)
            }
        }
        guard rename(tempPath, filePath) == 0 else {
            let code = errno
            unlink(tempPath)
            throw ConfigError("Could not replace \(filePath): \(String(cString: strerror(code)))")
        }
        Self.syncDirectory(directory)

        if let afterWrite {
            try afterWrite(directory)
            try afterWrite(filePath)
            if FileManager.default.fileExists(atPath: backupPath) { try afterWrite(backupPath) }
        }
    }

    private static func readFile(_ path: String) throws -> SteadyVolumeConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !data.isEmpty else { throw ConfigError("\((path as NSString).lastPathComponent) is empty.") }
        let config = try decoder.decode(SteadyVolumeConfig.self, from: data)
        try config.validate()
        return config
    }

    private static func writeDurably(_ data: Data, to path: String) throws {
        unlink(path)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ConfigError("Could not create \(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ConfigError("Could not write \(path): \(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
        // F_FULLFSYNC asks the drive itself to flush, not just the OS.
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
    }

    private static func syncDirectory(_ directory: String) {
        let fd = open(directory, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        fsync(fd)
        close(fd)
    }
}
