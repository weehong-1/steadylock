import XCTest
@testable import SteadyVolumeCore

final class ConfigStoreTests: XCTestCase {
    private var directory: String!
    private var path: String { directory + "/config.json" }

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "sv-config-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func sample() -> SteadyVolumeConfig {
        var config = SteadyVolumeConfig()
        config.locked = true
        config.level = 30
        config.password = PasswordHasher.hash("correct horse", iterations: PasswordHasher.minimumIterations)
        config.protected = true
        config.failedAttempts = 3
        config.lockoutUntil = Date(timeIntervalSince1970: 1_793_448_000.25)
        return config
    }

    private func write(_ text: String, to file: String) throws {
        try text.write(toFile: file, atomically: false, encoding: .utf8)
    }

    func testMissingFileLoadsDefaultsUnlockedWithoutPassword() throws {
        let config = try ConfigStore(path: path).load()
        XCTAssertFalse(config.locked)
        XCTAssertNil(config.password)
        XCTAssertEqual(config.level, 50)
        XCTAssertEqual(config.mode, .uniform)
    }

    func testSaveThenLoadRoundTripsEveryField() throws {
        let store = ConfigStore(path: path)
        let config = sample()
        try store.save(config)
        XCTAssertEqual(try store.load(), config)
    }

    func testFileUsesCamelCaseJsonAndRestrictiveMode() throws {
        try ConfigStore(path: path).save(sample())
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for key in ["\"schemaVersion\"", "\"locked\"", "\"mode\" : \"uniform\"", "\"failedAttempts\"", "\"lockoutUntil\""] {
            XCTAssertTrue(text.contains(key), key)
        }
        XCTAssertFalse(text.contains("correct horse"))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testSecondSaveKeepsPreviousVersionAsBackupAndLeavesNoTempFile() throws {
        let store = ConfigStore(path: path)
        var config = sample()
        try store.save(config)
        config.level = 70
        try store.save(config)

        let backup = try JSONDecoder.forTests.decode(SteadyVolumeConfig.self, from: Data(contentsOf: URL(fileURLWithPath: store.backupPath)))
        XCTAssertEqual(backup.level, 30)
        XCTAssertEqual(try store.load().level, 70)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".tmp"))
    }

    func testCorruptMainFileFallsBackToBackup() throws {
        let store = ConfigStore(path: path)
        var config = sample()
        try store.save(config)
        config.level = 70
        try store.save(config)
        try write("{ not json", to: path)
        XCTAssertEqual(try store.load().level, 30)
    }

    func testBothFilesCorruptThrowsConfigError() throws {
        try write("{ not json", to: path)
        try write("also not json", to: path + ".bak")
        XCTAssertThrowsError(try ConfigStore(path: path).load()) { XCTAssertTrue($0 is ConfigError) }
    }

    func testCorruptMainFileWithoutBackupThrowsConfigError() throws {
        try write("", to: path)
        XCTAssertThrowsError(try ConfigStore(path: path).load()) { XCTAssertTrue($0 is ConfigError) }
    }

    func testSavingAnOutOfRangeLevelIsRefused() {
        for level in [-1, 101] {
            var config = SteadyVolumeConfig()
            config.level = level
            XCTAssertThrowsError(try ConfigStore(path: path).save(config))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testOutOfRangeLevelInFileIsTreatedAsCorrupt() throws {
        try write(#"{"schemaVersion":1,"locked":true,"level":150}"#, to: path)
        XCTAssertThrowsError(try ConfigStore(path: path).load())
    }

    func testUnknownSchemaVersionIsRejected() throws {
        try write(#"{"schemaVersion":2}"#, to: path)
        XCTAssertThrowsError(try ConfigStore(path: path).load())
    }

    func testPasswordHashWithTooFewIterationsInFileIsRejected() throws {
        var config = sample()
        config.password?.iterations = 1000
        let data = try ConfigStore.encoder.encode(config)
        try data.write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try ConfigStore(path: path).load())
    }

    func testAfterWriteHookRunsForDirectoryConfigAndBackup() throws {
        var touched: [String] = []
        let store = ConfigStore(path: path) { touched.append($0) }
        try store.save(sample())
        try store.save(sample())
        XCTAssertEqual(touched.filter { $0 == self.path }.count, 2)
        XCTAssertEqual(touched.filter { $0 == self.path + ".bak" }.count, 1)
        XCTAssertTrue(touched.contains(directory))
    }

    func testCreatesAMissingDirectoryAsOwnerOnly() throws {
        let nested = directory + "/nested/config.json"
        try ConfigStore(path: nested).save(SteadyVolumeConfig())
        let mode = try FileManager.default.attributesOfItem(atPath: directory + "/nested")[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testPerDeviceLevelsRoundTripExactly() throws {
        var config = sample()
        config.mode = .currentLevels
        config.deviceLevels = [
            DeviceLevel(id: "BuiltInSpeakerDevice", name: "MacBook Air Speakers", scalar: 0.5625),
            DeviceLevel(id: "usb-dac", name: nil, scalar: 0.499846),
            DeviceLevel(id: "quiet", name: "Quiet", scalar: 0.0001),
        ]
        let store = ConfigStore(path: path)
        try store.save(config)
        let loaded = try store.load()
        XCTAssertEqual(loaded.deviceLevels, config.deviceLevels)
        XCTAssertEqual(loaded.deviceLevels[1].scalar, 0.499846) // exact, not rounded
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("\"currentLevels\""))
    }

    func testOlderConfigWithoutModeLoadsAsUniform() throws {
        try write(#"{"schemaVersion":1,"locked":true,"level":20}"#, to: path)
        let config = try ConfigStore(path: path).load()
        XCTAssertEqual(config.mode, .uniform)
        XCTAssertEqual(config.level, 20)
        XCTAssertEqual(config.deviceLevels, [])
    }

    func testWindowsStyleConfigLoads() throws {
        // The Windows file has an extra field and a .NET DateTimeOffset; both must be accepted.
        try write(#"""
        {"schemaVersion":1,"locked":true,"mode":"currentLevels","level":50,
         "deviceLevels":[{"id":"{0.0.0.00000000}.{abc}","name":"Speakers","scalar":0.4998}],
         "protected":true,"originalServiceSecurity":"D:(A;;CCLC;;;SY)","failedAttempts":1,
         "lockoutUntil":"2026-11-06T12:00:30+00:00"}
        """#, to: path)
        let config = try ConfigStore(path: path).load()
        XCTAssertEqual(config.deviceLevels.first?.scalar, 0.4998)
        XCTAssertEqual(config.lockoutUntil, ISO8601DateFormatter().date(from: "2026-11-06T12:00:30Z"))
    }

    func testDeviceLevelOutsideZeroToOneIsRefused() {
        for scalar: Float32 in [-0.1, 1.5, .nan, .infinity] {
            var config = SteadyVolumeConfig()
            config.deviceLevels = [DeviceLevel(id: "x", name: nil, scalar: scalar)]
            XCTAssertThrowsError(try config.validate(), "\(scalar)")
        }
    }

    func testDuplicateOrEmptyDeviceIDsAreRefused() {
        var config = SteadyVolumeConfig()
        config.deviceLevels = [DeviceLevel(id: "a", name: nil, scalar: 0.5), DeviceLevel(id: "a", name: nil, scalar: 0.6)]
        XCTAssertThrowsError(try config.validate())
        config.deviceLevels = [DeviceLevel(id: " ", name: nil, scalar: 0.5)]
        XCTAssertThrowsError(try config.validate())
    }

    func testNegativeFailedAttemptsAreRefused() {
        var config = SteadyVolumeConfig()
        config.failedAttempts = -1
        XCTAssertThrowsError(try config.validate())
    }
}

extension JSONDecoder {
    static var forTests: JSONDecoder { ConfigStore.decoder }
}
