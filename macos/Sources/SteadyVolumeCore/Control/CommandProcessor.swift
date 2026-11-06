import Foundation

/// The daemon's control logic: validates requests, checks passwords and lockout, updates and
/// persists the config, toggles tamper protection and tells the enforcer about the new target.
/// All requests are serialised by one lock, so lockout counting is exact. A port of the Windows
/// CommandProcessor with the same messages.
public final class CommandProcessor {
    private static let captureTimeout: TimeInterval = 5

    private let gate = NSLock()
    private let store: ConfigStoring
    private let protection: TamperProtecting
    private let log: EventLogging
    private let lockout: LockoutTracker
    private let hashIterations: Int
    private let version: String
    private let snapshots: VolumeSnapshotProviding?
    private let hasSnapshots: Bool
    private var config: SteadyVolumeConfig

    /// Called (under the lock) whenever what is enforced changes. Nil means unlocked.
    public var targetChanged: ((EnforcementTarget?) -> Void)?

    public init(store: ConfigStoring,
                initialConfig: SteadyVolumeConfig,
                protection: TamperProtecting,
                log: EventLogging,
                now: @escaping () -> Date = Date.init,
                hashIterations: Int = PasswordHasher.defaultIterations,
                version: String = SteadyVolumePaths.version,
                snapshots: VolumeSnapshotProviding? = nil) {
        precondition(hashIterations >= PasswordHasher.minimumIterations)
        self.store = store
        self.config = initialConfig
        self.protection = protection
        self.log = log
        self.hashIterations = hashIterations
        self.version = version
        self.snapshots = snapshots
        self.hasSnapshots = snapshots != nil
        self.lockout = LockoutTracker(now: now, failedAttempts: initialConfig.failedAttempts,
                                      lockoutUntil: initialConfig.lockoutUntil)
    }

    public var target: EnforcementTarget? {
        gate.lock(); defer { gate.unlock() }
        return EnforcementTarget.from(config)
    }

    public var isProtected: Bool {
        gate.lock(); defer { gate.unlock() }
        return config.protected
    }

    /// Called (off the enforcement thread) when a device not in the current-levels lock was seen and
    /// held at the level it reported. Persists it so the level survives a restart. Ignored in other modes.
    public func recordDiscoveredDevice(_ device: DeviceLevel) {
        gate.lock(); defer { gate.unlock() }
        guard config.locked, config.mode == .currentLevels,
              !config.deviceLevels.contains(where: { $0.id == device.id }) else { return }
        do {
            var next = config
            next.deviceLevels.append(device)
            try persist(next)
            log.log(.info, .deviceAdded,
                    "New output device \(device.displayName) locked at its current level, \(device.percent)%.")
        } catch {
            // Still enforced in memory; only persistence across restarts is lost.
            log.log(.error, .configError, "Could not save the level of new device \(device.displayName): \(error)")
        }
    }

    public func status() -> StatusInfo {
        gate.lock(); defer { gate.unlock() }
        return buildStatus()
    }

    /// Re-applies tamper protection at daemon start if the config says it should be on.
    public func applyStartupState() {
        gate.lock(); defer { gate.unlock() }
        guard config.protected else { return }
        do {
            try protection.protect()
        } catch {
            log.log(.error, .protectionError, "Could not apply tamper protection at startup: \(error)")
        }
    }

    public func handle(_ request: IpcRequest) -> IpcResponse {
        guard request.protocolVersion == IpcRequest.currentProtocolVersion else {
            return .failure(.badRequest,
                            "Unsupported protocol version \(request.protocolVersion); the CLI and service versions do not match.")
        }

        gate.lock(); defer { gate.unlock() }
        do {
            switch request.command {
            case .status: return .success(buildStatus())
            case .setup: return try handleSetup(request)
            case .lock, .unlock, .changePassword, .unprotect: return try handlePasswordCommand(request)
            }
        } catch {
            log.log(.error, .configError, "Command \(request.command.rawValue) failed: \(error)")
            return .failure(.internal, "The service could not complete the command: \(error)")
        }
    }

    // MARK: - Commands (called with the lock held)

    private func handleSetup(_ request: IpcRequest) throws -> IpcResponse {
        if config.password != nil {
            return .failure(.alreadyConfigured, "A password already exists. Use 'passwd' to change it.")
        }
        if let problem = PasswordPolicy.check(request.newPassword) {
            return .failure(.weakPassword, problem)
        }

        var next = config
        next.password = PasswordHasher.hash(request.newPassword!, iterations: hashIterations)
        next.protected = true
        try persist(next)
        let warning = applyProtection()

        log.log(.info, .passwordCreated, "Password created during first-run setup.")
        return .success(buildStatus(), message: "Password created.", warning: warning)
    }

    private func handlePasswordCommand(_ request: IpcRequest) throws -> IpcResponse {
        guard let stored = config.password else {
            return .failure(.notConfigured, "No password has been set yet. Run setup first.")
        }

        // Validate arguments before the password so a typo in the level never costs an attempt.
        // A missing level is valid: it means "lock every device at its current level".
        if request.command == .lock, let level = request.level, !VolumeMath.isValidLevel(level) {
            return .failure(.invalidLevel, "The level must be a whole number from 0 to 100.")
        }
        if request.command == .lock, request.level == nil, !hasSnapshots {
            return .failure(.internal, "This service cannot read the current levels; give a level instead.")
        }
        if request.command == .changePassword, let problem = PasswordPolicy.check(request.newPassword) {
            return .failure(.weakPassword, problem)
        }

        let before = (lockout.failedAttempts, lockout.lockoutUntil)
        if let remaining = lockout.remainingLockout() {
            persistLockoutIfChanged(before)
            let seconds = Self.secondsUp(remaining)
            log.log(.warning, .refusedLockedOut,
                    "Refused \(request.command.rawValue): password commands are locked out for another \(seconds) s.")
            return IpcResponse(ok: false, error: .lockedOut, message: "Too many wrong passwords. Try again later.",
                               retryAfterSeconds: seconds)
        }

        let verified: Bool
        do {
            verified = try PasswordHasher.verify(request.password, against: stored)
        } catch let error as InvalidPasswordHashError {
            log.log(.error, .configError, "The stored password hash is unusable: \(error)")
            return .failure(.internal, "The stored password hash is unusable: \(error)")
        }

        if !verified {
            let startedLockout = lockout.recordFailure()
            persistLockoutIfChanged(before)
            log.log(.warning, .failedPassword, "Wrong password for \(request.command.rawValue).")
            if startedLockout {
                let seconds = Int(LockoutTracker.lockoutDuration)
                log.log(.warning, .lockoutStarted,
                        "\(LockoutTracker.maxAttempts) wrong passwords in a row. Password commands are refused for \(seconds) s.")
                return IpcResponse(ok: false, error: .lockedOut,
                                   message: "Wrong password. Too many wrong passwords; try again later.",
                                   retryAfterSeconds: seconds)
            }
            return IpcResponse(ok: false, error: .wrongPassword, message: "Wrong password.",
                               attemptsRemaining: lockout.attemptsRemaining)
        }

        lockout.recordSuccess()

        switch request.command {
        case .lock:
            if let level = request.level { return try doLock(level) }
            return try doLockAtCurrentLevels()
        case .unlock: return try doUnlock()
        case .changePassword: return try doChangePassword(request.newPassword!)
        case .unprotect: return try doUnprotect()
        case .status, .setup: preconditionFailure()
        }
    }

    private func doLock(_ level: Int) throws -> IpcResponse {
        var next = config
        next.locked = true
        next.mode = .uniform
        next.level = level
        next.deviceLevels = []
        next.protected = true // locking always re-arms protection, e.g. after an unprotect
        try persist(next)
        let warning = applyProtection()

        log.log(.info, .locked, "Master volume locked at \(level)% on every output device.")
        targetChanged?(EnforcementTarget.from(config))
        return .success(buildStatus(), message: "Locked at \(level)% on every output device.", warning: warning)
    }

    private func doLockAtCurrentLevels() throws -> IpcResponse {
        let levels: [DeviceLevel]
        do {
            guard let snapshots else { throw ConfigError("The audio enforcer is not available.") }
            levels = try snapshots.captureCurrentLevels(timeout: Self.captureTimeout)
        } catch {
            try persist(config) // still save the reset failure counter
            log.log(.error, .audioError, "Could not read the current volume levels: \(error)")
            return .failure(.internal, "Could not read the current volume levels: \(error)")
        }

        var next = config
        next.locked = true
        next.mode = .currentLevels
        next.deviceLevels = levels
        next.protected = true
        try persist(next)
        let warning = applyProtection()

        let summary = levels.map { "\($0.displayName) \($0.percent)%" }.joined(separator: ", ")
        log.log(.info, .locked, "Master volume locked at current levels on \(levels.count) output device(s): \(summary).")
        targetChanged?(EnforcementTarget.from(config))
        let message = levels.isEmpty
            ? "Locked. No output device is active right now; each device is held at its level when it first appears."
            : "Locked \(levels.count) output device(s) at their current levels. Nothing was changed."
        return .success(buildStatus(), message: message, warning: warning)
    }

    private func doUnlock() throws -> IpcResponse {
        var next = config
        next.locked = false
        try persist(next)

        log.log(.info, .unlocked, "Master volume unlocked.")
        targetChanged?(nil)
        return .success(buildStatus(), message: "Unlocked. The volume is no longer enforced.")
    }

    private func doChangePassword(_ newPassword: String) throws -> IpcResponse {
        var next = config
        next.password = PasswordHasher.hash(newPassword, iterations: hashIterations)
        try persist(next)

        log.log(.info, .passwordChanged, "Password changed.")
        return .success(buildStatus(), message: "Password changed.")
    }

    private func doUnprotect() throws -> IpcResponse {
        do {
            try protection.restore()
        } catch {
            try persist(config) // still save the reset failure counter
            log.log(.error, .protectionError, "Could not remove tamper protection: \(error)")
            return .failure(.internal, "Could not remove tamper protection: \(error)")
        }

        var next = config
        next.protected = false
        try persist(next)

        log.log(.info, .unprotected, "Tamper protection removed. The daemon can now be stopped and uninstalled.")
        return .success(buildStatus(),
                        message: "Tamper protection removed. The daemon can now be stopped and uninstalled. 'lock' turns protection back on.")
    }

    // MARK: - Helpers

    private func applyProtection() -> String? {
        do {
            try protection.protect()
            log.log(.info, .protected, "Tamper protection is on.")
            return nil
        } catch {
            log.log(.error, .protectionError, "Could not apply tamper protection: \(error)")
            return "Saved, but tamper protection could not be applied: \(error)"
        }
    }

    /// Writes `next` (plus the live lockout state) and only then makes it current.
    private func persist(_ next: SteadyVolumeConfig) throws {
        var next = next
        next.failedAttempts = lockout.failedAttempts
        next.lockoutUntil = lockout.lockoutUntil
        try store.save(next)
        config = next
    }

    private func persistLockoutIfChanged(_ before: (Int, Date?)) {
        guard before.0 != lockout.failedAttempts || before.1 != lockout.lockoutUntil else { return }
        do {
            try persist(config)
        } catch {
            // The in-memory counter still applies; only persistence across restarts is lost.
            log.log(.error, .configError, "Could not save the failed-attempt counter: \(error)")
        }
    }

    private func buildStatus() -> StatusInfo {
        StatusInfo(locked: config.locked,
                   mode: config.mode,
                   level: config.level,
                   devices: config.mode == .currentLevels
                       ? config.deviceLevels.map { DeviceStatus(id: $0.id, name: $0.name, level: $0.percent) }
                       : nil,
                   passwordSet: config.password != nil,
                   protected: config.protected,
                   serviceVersion: version)
    }

    private static func secondsUp(_ interval: TimeInterval) -> Int { max(1, Int(interval.rounded(.up))) }
}
