import Foundation

// Wire format (shared with the Windows version):
//   [4-byte little-endian length][UTF-8 JSON], one request and one response per connection.
//   Property names are camelCase, enum values are camelCase strings, nil values are omitted.

public enum IpcCommand: String, Codable {
    case status, setup, lock, unlock, changePassword, unprotect
}

public enum IpcErrorCode: String, Codable {
    case none, badRequest, notConfigured, alreadyConfigured, wrongPassword, lockedOut, invalidLevel, weakPassword
    case `internal`
}

public struct IpcRequest: Codable, Equatable {
    public static let currentProtocolVersion = 1

    public var protocolVersion: Int
    public var command: IpcCommand
    public var password: String?
    public var newPassword: String?
    /// For `.lock`: one level for every device, or nil to lock each device at its current level.
    public var level: Int?

    public init(command: IpcCommand, password: String? = nil, newPassword: String? = nil, level: Int? = nil,
                protocolVersion: Int = IpcRequest.currentProtocolVersion) {
        self.protocolVersion = protocolVersion
        self.command = command
        self.password = password
        self.newPassword = newPassword
        self.level = level
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, command, password, newPassword, level }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? Self.currentProtocolVersion
        command = try c.decode(IpcCommand.self, forKey: .command)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        newPassword = try c.decodeIfPresent(String.self, forKey: .newPassword)
        level = try c.decodeIfPresent(Int.self, forKey: .level)
    }
}

public struct DeviceStatus: Codable, Equatable {
    public var id: String
    public var name: String?
    public var level: Int

    public init(id: String, name: String?, level: Int) {
        self.id = id
        self.name = name
        self.level = level
    }
}

public struct StatusInfo: Codable, Equatable {
    public var locked: Bool
    public var mode: LockMode?
    /// The uniform level (meaningful in uniform mode).
    public var level: Int
    /// Per-device locked levels in current-levels mode, otherwise nil.
    public var devices: [DeviceStatus]?
    public var passwordSet: Bool
    public var `protected`: Bool
    public var serviceVersion: String?

    public init(locked: Bool, mode: LockMode?, level: Int, devices: [DeviceStatus]?, passwordSet: Bool,
                protected: Bool, serviceVersion: String?) {
        self.locked = locked
        self.mode = mode
        self.level = level
        self.devices = devices
        self.passwordSet = passwordSet
        self.protected = protected
        self.serviceVersion = serviceVersion
    }
}

public struct IpcResponse: Codable, Equatable {
    public var ok: Bool
    public var error: IpcErrorCode
    public var message: String?
    /// Set when the command succeeded but a secondary step (e.g. tamper protection) failed.
    public var warning: String?
    public var retryAfterSeconds: Int?
    public var attemptsRemaining: Int?
    public var status: StatusInfo?

    public init(ok: Bool, error: IpcErrorCode, message: String? = nil, warning: String? = nil,
                retryAfterSeconds: Int? = nil, attemptsRemaining: Int? = nil, status: StatusInfo? = nil) {
        self.ok = ok
        self.error = error
        self.message = message
        self.warning = warning
        self.retryAfterSeconds = retryAfterSeconds
        self.attemptsRemaining = attemptsRemaining
        self.status = status
    }

    public static func success(_ status: StatusInfo, message: String? = nil, warning: String? = nil) -> IpcResponse {
        IpcResponse(ok: true, error: .none, message: message, warning: warning, status: status)
    }

    public static func failure(_ error: IpcErrorCode, _ message: String) -> IpcResponse {
        IpcResponse(ok: false, error: error, message: message)
    }

    private enum CodingKeys: String, CodingKey {
        case ok, error, message, warning, retryAfterSeconds, attemptsRemaining, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        error = try c.decodeIfPresent(IpcErrorCode.self, forKey: .error) ?? .none
        message = try c.decodeIfPresent(String.self, forKey: .message)
        warning = try c.decodeIfPresent(String.self, forKey: .warning)
        retryAfterSeconds = try c.decodeIfPresent(Int.self, forKey: .retryAfterSeconds)
        attemptsRemaining = try c.decodeIfPresent(Int.self, forKey: .attemptsRemaining)
        status = try c.decodeIfPresent(StatusInfo.self, forKey: .status)
    }
}
