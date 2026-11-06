import XCTest
@testable import SteadyVolumeCore

/// Enforcement logic against a fake audio system. No real audio device is read or written.
final class VolumeEnforcerTests: XCTestCase {
    private let clock = TestClock()
    private let log = RecordingLog()

    private func make(_ devices: [FakeDevice], dryRun: Bool = false) throws -> (VolumeEnforcer, FakeBackend) {
        let backend = FakeBackend(devices)
        let enforcer = VolumeEnforcer(backend: backend, log: log, dryRun: dryRun, now: clock.provider)
        try enforcer.connect()
        return (enforcer, backend)
    }

    private func currentLevels(_ levels: [String: Float32]) -> EnforcementTarget {
        .currentLevels(levels.map { DeviceLevel(id: $0.key, name: nil, scalar: $0.value) })
    }

    func testUniformLockRevertsAChangedDeviceAndNeverTouchesMute() throws {
        let speakers = FakeDevice(id: "spk", name: "Speakers", volume: 0.9, muted: true)
        let (enforcer, _) = try make([speakers])
        enforcer.setTarget(.uniform(30))
        try enforcer.pass()
        XCTAssertEqual(speakers.writes, [0.30])
        XCTAssertEqual(speakers.volume, 0.30)
        XCTAssertTrue(speakers.muted)
        XCTAssertEqual(log.messages(.volumeReverted), ["Reverted master volume on 'Speakers' from 90% to 30%."])
    }

    func testNothingIsWrittenWhenTheRoundedPercentAlreadyMatches() throws {
        let speakers = FakeDevice(id: "spk", volume: 0.3021)
        let (enforcer, _) = try make([speakers])
        enforcer.setTarget(.uniform(30))
        for _ in 0..<5 { try enforcer.pass() }
        XCTAssertEqual(speakers.writes, [])
    }

    func testCurrentLevelsLockWritesBackTheExactStoredValue() throws {
        let dac = FakeDevice(id: "dac", volume: 0.4998)
        let (enforcer, _) = try make([dac])
        enforcer.setTarget(currentLevels(["dac": 0.4998]))
        try enforcer.pass()
        XCTAssertEqual(dac.writes, []) // locking at the current level changes nothing

        dac.volume = 0.75
        try enforcer.pass()
        XCTAssertEqual(dac.writes, [0.4998]) // exact, not 0.50
    }

    func testANewDeviceIsAdoptedAtItsOwnLevelWithoutAWrite() throws {
        let speakers = FakeDevice(id: "spk", volume: 0.8)
        let (enforcer, backend) = try make([speakers])
        var discovered: [DeviceLevel] = []
        let reported = expectation(description: "discovered")
        enforcer.deviceDiscovered = { discovered.append($0); reported.fulfill() }
        enforcer.setTarget(currentLevels(["spk": 0.8]))
        try enforcer.pass()

        let headphones = FakeDevice(id: "hp", name: "Headphones", volume: 0.25)
        backend.devices.append(headphones)
        backend.fire(.devices)
        try enforcer.pass()
        wait(for: [reported], timeout: 2)
        XCTAssertEqual(discovered, [DeviceLevel(id: "hp", name: "Headphones", scalar: 0.25)])
        XCTAssertEqual(headphones.writes, [])

        headphones.volume = 0.6
        try enforcer.pass()
        XCTAssertEqual(headphones.writes, [0.25])
        XCTAssertEqual(speakers.writes, [])
    }

    func testUniformLockIgnoresNothingNewDevicesGetTheLevelToo() throws {
        let (enforcer, backend) = try make([])
        enforcer.setTarget(.uniform(20))
        try enforcer.pass()
        let usb = FakeDevice(id: "usb", volume: 0.7)
        backend.devices = [usb]
        backend.fire(.devices)
        try enforcer.pass()
        XCTAssertEqual(usb.writes, [0.20])
    }

    func testANewTargetForgetsAdoptedLevels() throws {
        let hp = FakeDevice(id: "hp", volume: 0.25)
        let (enforcer, _) = try make([hp])
        enforcer.setTarget(currentLevels([:]))
        try enforcer.pass()           // adopts 0.25
        hp.volume = 0.6
        enforcer.setTarget(currentLevels([:]))
        try enforcer.pass()           // new target: adopts 0.6 instead of reverting
        XCTAssertEqual(hp.writes, [])
    }

    func testUnlockedWritesNothing() throws {
        let speakers = FakeDevice(id: "spk", volume: 0.9)
        let (enforcer, _) = try make([speakers])
        enforcer.setTarget(.uniform(30))
        enforcer.setTarget(nil)
        try enforcer.pass()
        XCTAssertEqual(speakers.writes, [])
    }

    func testDryRunLogsButWritesNothing() throws {
        let speakers = FakeDevice(id: "spk", name: "Speakers", volume: 0.9)
        let (enforcer, _) = try make([speakers], dryRun: true)
        enforcer.setTarget(.uniform(30))
        try enforcer.pass()
        XCTAssertEqual(speakers.writes, [])
        XCTAssertEqual(log.messages(.volumeReverted), ["Would revert (dry run) master volume on 'Speakers' from 90% to 30%."])
    }

    func testCoarseHardwareStepsAreAcceptedInsteadOfRewritingForever() throws {
        let coarse = FakeDevice(id: "coarse", volume: 0.9)
        coarse.step = 0.0625 // 16 steps, like many hardware volume controls
        let (enforcer, _) = try make([coarse])
        enforcer.setTarget(.uniform(30))
        for _ in 0..<10 { try enforcer.pass() }
        XCTAssertEqual(coarse.writes, [0.30])
        XCTAssertEqual(VolumeMath.toPercent(coarse.volume), 25)

        coarse.volume = 0.9 // a real change is still reverted
        try enforcer.pass()
        XCTAssertEqual(coarse.writes.count, 2)
    }

    func testRevertLoggingIsThrottled() throws {
        let speakers = FakeDevice(id: "spk", name: "Speakers", volume: 0.9)
        let (enforcer, _) = try make([speakers])
        enforcer.setTarget(.uniform(30))
        for _ in 0..<20 {
            speakers.volume = 0.9
            try enforcer.pass()
        }
        XCTAssertEqual(speakers.writes.count, 20)
        XCTAssertEqual(log.messages(.volumeReverted).count, 1)
        clock.advance(10)
        try enforcer.pass()
        XCTAssertEqual(log.messages(.volumeReverted).last, "Reverted master volume on 'Speakers' 19 more time(s) in the last 10 s.")
    }

    func testAFailingDeviceIsLoggedAndTheOthersAreStillEnforced() throws {
        let broken = FakeDevice(id: "broken", volume: 0.9)
        broken.failReads = true
        let good = FakeDevice(id: "good", volume: 0.9)
        let (enforcer, backend) = try make([broken, good])
        enforcer.setTarget(.uniform(30))
        try enforcer.pass()
        XCTAssertEqual(good.writes, [0.30])
        XCTAssertEqual(log.messages(.audioError).count, 1)
        let scans = backend.scans
        try enforcer.pass() // marked dirty, so the device list is rebuilt
        XCTAssertEqual(backend.scans, scans + 1)
    }

    func testSkippedDevicesAndDeviceListChangesAreLogged() throws {
        let (enforcer, _) = try make([FakeDevice(id: "spk", name: "Speakers", volume: 0.5)])
        try enforcer.pass()
        XCTAssertEqual(log.messages(.devicesChanged),
                       ["Output device 'HDMI' has no settable volume control.", "Watching 1 output device(s): 'Speakers'."])
    }

    // MARK: - On the real worker thread

    func testCaptureReadsEveryDeviceExactlyAndWritesNothing() throws {
        let a = FakeDevice(id: "a", name: "A", volume: 0.4998)
        let b = FakeDevice(id: "b", volume: 1)
        let backend = FakeBackend([a, b])
        let enforcer = VolumeEnforcer(backend: backend, log: log)
        enforcer.start()
        defer { enforcer.stop() }

        let levels = try enforcer.captureCurrentLevels(timeout: 3)
        XCTAssertEqual(levels, [DeviceLevel(id: "a", name: "A", scalar: 0.4998), DeviceLevel(id: "b", name: nil, scalar: 1)])
        XCTAssertEqual(a.writes + b.writes, [])
    }

    func testANotificationTriggersARevertOnTheWorkerThread() throws {
        let speakers = FakeDevice(id: "spk", volume: 0.5)
        let backend = FakeBackend([speakers])
        let enforcer = VolumeEnforcer(backend: backend, log: log)
        enforcer.setTarget(.uniform(50))
        enforcer.start()
        defer { enforcer.stop() }
        XCTAssertTrue(waitUntil { backend.notify != nil && backend.scans > 0 })

        speakers.volume = 0.95
        backend.fire(.volume)
        XCTAssertTrue(waitUntil { speakers.volume == 0.5 })
        XCTAssertEqual(speakers.writes, [0.5])
    }

    func testPollingRevertsEvenWithoutANotification() throws {
        let speakers = FakeDevice(id: "spk", volume: 0.5)
        let backend = FakeBackend([speakers])
        let enforcer = VolumeEnforcer(backend: backend, log: log)
        enforcer.setTarget(.uniform(50))
        enforcer.start()
        defer { enforcer.stop() }
        XCTAssertTrue(waitUntil { backend.scans > 0 })

        speakers.volume = 0.1 // no fire(): the 250 ms poll must catch it
        XCTAssertTrue(waitUntil(timeout: 1) { speakers.volume == 0.5 })
    }

    func testTheSessionReconnectsAfterTheAudioSystemFails() throws {
        let speakers = FakeDevice(id: "spk", volume: 0.5)
        let backend = FakeBackend([speakers])
        backend.failScan = true
        let enforcer = VolumeEnforcer(backend: backend, log: log)
        enforcer.setTarget(.uniform(50))
        enforcer.start()
        defer { enforcer.stop() }
        XCTAssertTrue(waitUntil { !self.log.messages(.audioError).isEmpty })
        backend.failScan = false
        XCTAssertTrue(waitUntil(timeout: 4) { backend.connects >= 2 && backend.scans > 0 })
        speakers.volume = 0.2
        XCTAssertTrue(waitUntil { speakers.volume == 0.5 })
    }

    func testCaptureTimesOutWhenTheWorkerIsNotRunning() {
        let enforcer = VolumeEnforcer(backend: FakeBackend([]), log: log)
        XCTAssertThrowsError(try enforcer.captureCurrentLevels(timeout: 0.2))
    }
}
