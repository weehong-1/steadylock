import Foundation

/// What the enforcer should hold each output device at. Immutable, so it can be handed from the
/// control side to the enforcement thread by a single reference assignment.
public final class EnforcementTarget {
    /// Set in uniform mode: every device is held at this percent.
    public let uniformLevel: Int?
    /// Exact scalars per device ID (CoreAudio device UID), in current-levels mode.
    public let deviceLevels: [String: Float32]
    /// True in current-levels mode: a device not in `deviceLevels` is held at the level it has when first seen.
    public let captureNewDevices: Bool

    private init(uniformLevel: Int?, deviceLevels: [String: Float32], captureNewDevices: Bool) {
        self.uniformLevel = uniformLevel
        self.deviceLevels = deviceLevels
        self.captureNewDevices = captureNewDevices
    }

    public static func uniform(_ level: Int) -> EnforcementTarget {
        precondition(VolumeMath.isValidLevel(level))
        return EnforcementTarget(uniformLevel: level, deviceLevels: [:], captureNewDevices: false)
    }

    public static func currentLevels(_ levels: [DeviceLevel]) -> EnforcementTarget {
        var map: [String: Float32] = [:]
        for level in levels { map[level.id] = level.scalar }
        return EnforcementTarget(uniformLevel: nil, deviceLevels: map, captureNewDevices: true)
    }

    /// Nil when the config is unlocked.
    public static func from(_ config: SteadyVolumeConfig) -> EnforcementTarget? {
        guard config.locked else { return nil }
        return config.mode == .currentLevels ? currentLevels(config.deviceLevels) : uniform(config.level)
    }

    /// The exact scalar to hold `deviceID` at, or nil when this target has no level for it
    /// (current-levels mode and the device has not been seen yet).
    public func scalar(for deviceID: String) -> Float32? {
        if let scalar = deviceLevels[deviceID] { return scalar }
        return uniformLevel.map(VolumeMath.toScalar)
    }
}

/// Reads the current level of every output device. Implemented by the enforcer.
public protocol VolumeSnapshotProviding: AnyObject {
    /// Throws if the audio system does not answer within `timeout`.
    func captureCurrentLevels(timeout: TimeInterval) throws -> [DeviceLevel]
}
