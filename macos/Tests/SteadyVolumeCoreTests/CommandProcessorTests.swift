import XCTest
@testable import SteadyVolumeCore

final class CommandProcessorTests: XCTestCase {
    private let password = "correct horse"
    private let clock = TestClock()
    private let store = InMemoryStore()
    private let protection = FakeProtection()
    private let snapshots = FakeSnapshots()
    private let log = RecordingLog()
    private var targets: [EnforcementTarget?] = []

    /// Uniform level of each target the enforcer was given (nil = unlocked).
    private var uniformTargets: [Int?] { targets.map { $0?.uniformLevel } }

    private func create(_ config: SteadyVolumeConfig? = nil, withSnapshots: Bool = true) -> CommandProcessor {
        let processor = CommandProcessor(store: store, initialConfig: config ?? (try! store.load()), protection: protection,
                                         log: log, now: clock.provider, hashIterations: PasswordHasher.minimumIterations,
                                         version: "test", snapshots: withSnapshots ? snapshots : nil)
        processor.targetChanged = { [unowned self] in self.targets.append($0) }
        return processor
    }

    private func createConfigured() -> CommandProcessor {
        let processor = create()
        XCTAssertTrue(processor.handle(IpcRequest(command: .setup, newPassword: password)).ok)
        return processor
    }

    private func req(_ command: IpcCommand, password: String? = "correct horse", level: Int? = nil,
                     newPassword: String? = nil) -> IpcRequest {
        IpcRequest(command: command, password: password, newPassword: newPassword, level: level)
    }

    func testStatusNeedsNoPassword() {
        let response = create().handle(IpcRequest(command: .status))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.status?.passwordSet, false)
        XCTAssertEqual(response.status?.locked, false)
        XCTAssertEqual(response.status?.serviceVersion, "test")
    }

    func testPasswordCommandsBeforeSetupReportNotConfigured() {
        XCTAssertEqual(create().handle(req(.lock, level: 30)).error, .notConfigured)
    }

    func testSetupCreatesPasswordTurnsOnProtectionAndPersists() throws {
        let processor = create()
        let response = processor.handle(IpcRequest(command: .setup, newPassword: password))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.message, "Password created.")
        let saved = try XCTUnwrap(store.saved)
        XCTAssertTrue(saved.protected)
        XCTAssertFalse(saved.locked)
        XCTAssertTrue(try PasswordHasher.verify(password, against: XCTUnwrap(saved.password)))
        XCTAssertEqual(protection.protectCalls, 1)
        XCTAssertEqual(log.messages(.passwordCreated).count, 1)
    }

    func testSetupTwiceIsRefused() {
        let processor = createConfigured()
        XCTAssertEqual(processor.handle(IpcRequest(command: .setup, newPassword: "another one")).error, .alreadyConfigured)
    }

    func testSetupWithWeakPasswordIsRefused() {
        let response = create().handle(IpcRequest(command: .setup, newPassword: "short"))
        XCTAssertEqual(response.error, .weakPassword)
        XCTAssertNil(store.saved)
    }

    func testLockWithCorrectPasswordLocksAndNotifiesEnforcer() throws {
        let processor = createConfigured()
        let response = processor.handle(req(.lock, level: 30))
        XCTAssertTrue(response.ok, response.message ?? "")
        XCTAssertEqual(response.message, "Locked at 30% on every output device.")
        XCTAssertEqual(uniformTargets, [30])
        XCTAssertEqual(processor.target?.uniformLevel, 30)
        XCTAssertEqual(store.saved?.locked, true)
        XCTAssertEqual(store.saved?.level, 30)
        XCTAssertEqual(log.messages(.locked), ["Master volume locked at 30% on every output device."])
    }

    func testUnlockStopsEnforcement() {
        let processor = createConfigured()
        _ = processor.handle(req(.lock, level: 30))
        let response = processor.handle(req(.unlock))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(uniformTargets, [30, nil])
        XCTAssertNil(processor.target)
        XCTAssertEqual(store.saved?.locked, false)
        XCTAssertEqual(log.messages(.unlocked).count, 1)
    }

    func testInvalidLevelIsRefusedWithoutCostingAnAttempt() {
        let processor = createConfigured()
        for level in [-1, 101] {
            XCTAssertEqual(processor.handle(req(.lock, password: "wrong password", level: level)).error, .invalidLevel)
        }
        XCTAssertEqual(store.saved?.failedAttempts, 0)
        XCTAssertEqual(processor.handle(req(.lock, password: "wrong password", level: 20)).attemptsRemaining, 4)
    }

    func testLockWithoutLevelHoldsEveryDeviceAtItsExactCurrentLevel() throws {
        snapshots.levels = [
            DeviceLevel(id: "speakers", name: "Speakers", scalar: 1.0),
            DeviceLevel(id: "usb-dac", name: "USB DAC", scalar: 0.499846),
        ]
        let processor = createConfigured()
        let response = processor.handle(req(.lock))

        XCTAssertTrue(response.ok, response.message ?? "")
        XCTAssertEqual(response.message, "Locked 2 output device(s) at their current levels. Nothing was changed.")
        XCTAssertEqual(snapshots.calls, 1)
        let saved = try XCTUnwrap(store.saved)
        XCTAssertTrue(saved.locked)
        XCTAssertEqual(saved.mode, .currentLevels)
        XCTAssertEqual(saved.deviceLevels.first { $0.id == "usb-dac" }?.scalar, 0.499846) // exact, not rounded
        XCTAssertTrue(saved.protected)

        let target = try XCTUnwrap(XCTUnwrap(targets.first))
        XCTAssertEqual(targets.count, 1)
        XCTAssertNil(target.uniformLevel)
        XCTAssertTrue(target.captureNewDevices)
        XCTAssertEqual(target.scalar(for: "speakers"), 1.0)
        XCTAssertEqual(target.scalar(for: "usb-dac"), 0.499846)
        XCTAssertNil(target.scalar(for: "headphones-plugged-in-later"))

        let status = try XCTUnwrap(response.status)
        XCTAssertEqual(status.mode, .currentLevels)
        XCTAssertEqual(status.devices?.map(\.level).sorted(), [50, 100])
    }

    func testLockWithoutLevelAndNoDevicesExplainsWhatHappens() {
        let processor = createConfigured()
        let response = processor.handle(req(.lock))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.message,
                       "Locked. No output device is active right now; each device is held at its level when it first appears.")
    }

    func testLockWithoutLevelChecksThePasswordBeforeReadingLevels() {
        let processor = createConfigured()
        XCTAssertEqual(processor.handle(req(.lock, password: "wrong password")).error, .wrongPassword)
        XCTAssertEqual(snapshots.calls, 0)
        XCTAssertEqual(store.saved?.locked, false)
    }

    func testLockWithoutLevelFailsCleanlyWhenLevelsCannotBeRead() {
        snapshots.error = ConfigError("The audio system did not answer in time.")
        let processor = createConfigured()
        let response = processor.handle(req(.lock))
        XCTAssertEqual(response.error, .internal)
        XCTAssertEqual(store.saved?.locked, false)
        XCTAssertTrue(targets.isEmpty)
    }

    func testLockWithoutLevelIsRefusedWhenTheServiceCannotReadLevels() {
        let processor = create(withSnapshots: false)
        XCTAssertTrue(processor.handle(IpcRequest(command: .setup, newPassword: password)).ok)
        let response = processor.handle(req(.lock))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(store.saved?.failedAttempts, 0)
        XCTAssertEqual(store.saved?.locked, false)
    }

    func testDeviceSeenLaterIsRecordedAtItsLevelAndSurvivesARestart() throws {
        snapshots.levels = [DeviceLevel(id: "speakers", name: "Speakers", scalar: 0.8)]
        let processor = createConfigured()
        _ = processor.handle(req(.lock))

        processor.recordDiscoveredDevice(DeviceLevel(id: "headphones", name: "Headphones", scalar: 0.25))
        processor.recordDiscoveredDevice(DeviceLevel(id: "headphones", name: "Headphones", scalar: 0.9)) // ignored

        XCTAssertEqual(store.saved?.deviceLevels.filter { $0.id == "headphones" }.map(\.scalar), [0.25])
        let restarted = create(try store.load())
        XCTAssertEqual(restarted.target?.scalar(for: "headphones"), 0.25)
        XCTAssertEqual(restarted.target?.scalar(for: "speakers"), 0.8)
        XCTAssertEqual(log.messages(.deviceAdded), ["New output device Headphones locked at its current level, 25%."])
    }

    func testDiscoveredDevicesAreIgnoredOutsideACurrentLevelsLock() {
        for uniformLock in [true, false] {
            let processor = createConfigured()
            if uniformLock { _ = processor.handle(req(.lock, level: 40)) }
            let saves = store.saveCount
            processor.recordDiscoveredDevice(DeviceLevel(id: "headphones", name: nil, scalar: 0.25))
            XCTAssertEqual(store.saveCount, saves)
            XCTAssertEqual(store.saved?.deviceLevels, [])
            store.saved = nil
        }
    }

    func testLockWithALevelReplacesACurrentLevelsLock() throws {
        snapshots.levels = [DeviceLevel(id: "speakers", name: "Speakers", scalar: 0.8)]
        let processor = createConfigured()
        _ = processor.handle(req(.lock))
        _ = processor.handle(req(.lock, level: 15))
        let saved = try XCTUnwrap(store.saved)
        XCTAssertEqual(saved.mode, .uniform)
        XCTAssertEqual(saved.level, 15)
        XCTAssertEqual(saved.deviceLevels, [])
        XCTAssertEqual(processor.target?.scalar(for: "speakers"), 0.15)
        XCTAssertNil(processor.status().devices)
    }

    func testUnlockAfterCurrentLevelsLockStopsEnforcement() {
        snapshots.levels = [DeviceLevel(id: "speakers", name: "Speakers", scalar: 0.8)]
        let processor = createConfigured()
        _ = processor.handle(req(.lock))
        XCTAssertTrue(processor.handle(req(.unlock)).ok)
        XCTAssertNil(processor.target)
        XCTAssertNil(targets.last!)
    }

    func testWrongPasswordIsRefusedAndCounted() {
        let processor = createConfigured()
        let response = processor.handle(req(.lock, password: "nope nope", level: 30))
        XCTAssertEqual(response.error, .wrongPassword)
        XCTAssertEqual(response.attemptsRemaining, 4)
        XCTAssertEqual(store.saved?.failedAttempts, 1)
        XCTAssertEqual(store.saved?.locked, false)
        XCTAssertEqual(log.messages(.failedPassword), ["Wrong password for lock."])
    }

    func testFiveWrongPasswordsRefuseAllPasswordCommandsFor30Seconds() {
        let processor = createConfigured()
        _ = processor.handle(req(.lock, level: 40))

        for _ in 0..<4 {
            XCTAssertEqual(processor.handle(req(.unlock, password: "nope nope")).error, .wrongPassword)
        }
        let fifth = processor.handle(req(.unlock, password: "nope nope"))
        XCTAssertEqual(fifth.error, .lockedOut)
        XCTAssertEqual(fifth.retryAfterSeconds, 30)
        XCTAssertEqual(log.messages(.lockoutStarted).count, 1)

        // Even the right password is refused during the lockout, for every password command.
        for command in [IpcCommand.unlock, .changePassword, .unprotect] {
            XCTAssertEqual(processor.handle(req(command, newPassword: "new password 1")).error, .lockedOut)
        }
        XCTAssertEqual(processor.handle(req(.lock, level: 10)).error, .lockedOut)
        XCTAssertTrue(processor.status().locked)
        XCTAssertEqual(processor.status().level, 40)
        XCTAssertFalse(log.messages(.refusedLockedOut).isEmpty)

        // Status is still allowed.
        XCTAssertTrue(processor.handle(IpcRequest(command: .status)).ok)

        clock.advance(30)
        XCTAssertTrue(processor.handle(req(.unlock)).ok)
    }

    func testLockoutSurvivesADaemonRestart() throws {
        let processor = createConfigured()
        for _ in 0..<5 { _ = processor.handle(req(.unlock, password: "nope nope")) }
        clock.advance(5)
        let restarted = create(try store.load())
        let response = restarted.handle(req(.unlock))
        XCTAssertEqual(response.error, .lockedOut)
        XCTAssertEqual(response.retryAfterSeconds, 25)
    }

    func testCorrectPasswordResetsTheFailureCount() {
        let processor = createConfigured()
        for _ in 0..<4 { _ = processor.handle(req(.unlock, password: "nope nope")) }
        XCTAssertTrue(processor.handle(req(.unlock)).ok)
        XCTAssertEqual(store.saved?.failedAttempts, 0)
        XCTAssertEqual(processor.handle(req(.unlock, password: "nope nope")).attemptsRemaining, 4)
    }

    func testChangePasswordRequiresOldPasswordAndSwitchesToNewOne() {
        let processor = createConfigured()
        XCTAssertEqual(processor.handle(req(.changePassword, password: "nope nope", newPassword: "new password 1")).error,
                       .wrongPassword)
        XCTAssertTrue(processor.handle(req(.changePassword, newPassword: "new password 1")).ok)
        XCTAssertEqual(processor.handle(req(.unlock)).error, .wrongPassword)
        XCTAssertTrue(processor.handle(req(.unlock, password: "new password 1")).ok)
        XCTAssertEqual(log.messages(.passwordChanged).count, 1)
    }

    func testChangePasswordRejectsWeakNewPasswordBeforeCheckingOld() {
        let processor = createConfigured()
        let response = processor.handle(req(.changePassword, password: "nope nope", newPassword: "short"))
        XCTAssertEqual(response.error, .weakPassword)
        XCTAssertEqual(store.saved?.failedAttempts, 0)
    }

    func testUnprotectRestoresAndLockRearmsProtection() {
        let processor = createConfigured()
        let response = processor.handle(req(.unprotect))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(protection.restoreCalls, 1)
        XCTAssertEqual(store.saved?.protected, false)
        XCTAssertEqual(response.status?.protected, false)

        _ = processor.handle(req(.lock, level: 20))
        XCTAssertEqual(store.saved?.protected, true)
        XCTAssertEqual(protection.protectCalls, 2)
    }

    func testUnprotectFailureKeepsProtectedFlag() {
        let processor = createConfigured()
        protection.failRestore = true
        let response = processor.handle(req(.unprotect))
        XCTAssertEqual(response.error, .internal)
        XCTAssertEqual(store.saved?.protected, true)
    }

    func testProtectionFailureOnLockIsReportedAsWarningButLockStillApplies() {
        let processor = createConfigured()
        protection.failProtect = true
        let response = processor.handle(req(.lock, level: 25))
        XCTAssertTrue(response.ok)
        XCTAssertNotNil(response.warning)
        XCTAssertEqual(store.saved?.locked, true)
        XCTAssertEqual(uniformTargets, [25])
    }

    func testFailedSaveLeavesPreviousStateInEffect() {
        let processor = createConfigured()
        store.failSaves = true
        let response = processor.handle(req(.lock, level: 25))
        XCTAssertEqual(response.error, .internal)
        XCTAssertFalse(processor.status().locked)
        XCTAssertTrue(targets.isEmpty)
    }

    func testStartupReappliesProtectionWhenConfigured() {
        var config = SteadyVolumeConfig()
        config.protected = true
        create(config).applyStartupState()
        XCTAssertEqual(protection.protectCalls, 1)

        create(SteadyVolumeConfig()).applyStartupState()
        XCTAssertEqual(protection.protectCalls, 1)
    }

    func testMismatchedProtocolVersionIsRefused() {
        let response = create().handle(IpcRequest(command: .status, protocolVersion: 2))
        XCTAssertEqual(response.error, .badRequest)
    }
}
