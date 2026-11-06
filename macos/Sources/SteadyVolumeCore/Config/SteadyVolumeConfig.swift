import Foundation

public enum LockMode: String, Codable, Equatable {
    /// Every output device is held at `level`.
    case uniform
    /// Every output device is held at the level it had when it was locked (`deviceLevels`).
    /// Devices that appear later are held at the level they report when first seen. `steadyvol lock` with no level.
    case currentLevels
}

/// One output device's locked level. `scalar` is the exact 0.0-1.0 value read from the device and is
/// written back exactly on revert.
public struct DeviceLevel: Codable, Equatable {
    public var id: String
    public var name: String?
    public var scalar: Float32

    public init(id: String, name: String?, scalar: Float32) {
        self.id = id
        self.name = name
        self.scalar = scalar
    }

    public var percent: Int { VolumeMath.toPercent(scalar) }
    public var displayName: String { name ?? id }
}

/// Everything the daemon persists. Only the daemon writes this file. Field names match the Windows config.
public struct SteadyVolumeConfig: Codable, Equatable {
    public static let currentSchemaVersion = 1
    public static let defaultLevel = 50

    public var schemaVersion = currentSchemaVersion
    /// True while the master volume is being enforced.
    public var locked = false
    /// How the lock is defined. Missing in older files, which were always uniform.
    public var mode: LockMode = .uniform
    /// The level to enforce in uniform mode, 0-100.
    public var level = defaultLevel
    /// Per-device levels in current-levels mode.
    public var deviceLevels: [DeviceLevel] = []
    /// Nil until first-run setup has created a password.
    public var password: PasswordHash?
    /// True while tamper protection should be applied.
    public var protected = false
    public var failedAttempts = 0
    public var lockoutUntil: Date?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, locked, mode, level, deviceLevels, password, protected, failedAttempts, lockoutUntil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        mode = try c.decodeIfPresent(LockMode.self, forKey: .mode) ?? .uniform
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? Self.defaultLevel
        deviceLevels = try c.decodeIfPresent([DeviceLevel].self, forKey: .deviceLevels) ?? []
        password = try c.decodeIfPresent(PasswordHash.self, forKey: .password)
        protected = try c.decodeIfPresent(Bool.self, forKey: .protected) ?? false
        failedAttempts = try c.decodeIfPresent(Int.self, forKey: .failedAttempts) ?? 0
        lockoutUntil = try c.decodeIfPresent(Date.self, forKey: .lockoutUntil)
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ConfigError("Unsupported config schema version \(schemaVersion).")
        }
        guard VolumeMath.isValidLevel(level) else { throw ConfigError("Level \(level) is outside 0-100.") }
        guard failedAttempts >= 0 else { throw ConfigError("failedAttempts cannot be negative.") }

        var ids = Set<String>()
        for device in deviceLevels {
            guard !device.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError("A device level has no device ID.")
            }
            guard ids.insert(device.id).inserted else { throw ConfigError("Device \(device.id) is listed twice.") }
            guard device.scalar.isFinite, device.scalar >= 0, device.scalar <= 1 else {
                throw ConfigError("Device \(device.id) has level \(device.scalar), outside 0.0-1.0.")
            }
        }

        do {
            try password?.validate()
        } catch let error as InvalidPasswordHashError {
            throw ConfigError("The stored password hash is invalid: \(error.description)")
        }
    }
}

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
