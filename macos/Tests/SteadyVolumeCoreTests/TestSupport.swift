import Foundation
@testable import SteadyVolumeCore

/// A settable clock.
final class TestClock {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_793_448_000)) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    var provider: () -> Date { { self.now } }
}

final class InMemoryStore: ConfigStoring {
    var saved: SteadyVolumeConfig?
    var saveCount = 0
    var failSaves = false

    func load() throws -> SteadyVolumeConfig { saved ?? SteadyVolumeConfig() }

    func save(_ config: SteadyVolumeConfig) throws {
        if failSaves { throw ConfigError("disk full") }
        try config.validate()
        saved = config
        saveCount += 1
    }
}

final class FakeProtection: TamperProtecting {
    var protectCalls = 0
    var restoreCalls = 0
    var failProtect = false
    var failRestore = false

    func protect() throws {
        protectCalls += 1
        if failProtect { throw ConfigError("protect failed") }
    }

    func restore() throws {
        restoreCalls += 1
        if failRestore { throw ConfigError("restore failed") }
    }
}

final class FakeSnapshots: VolumeSnapshotProviding {
    var levels: [DeviceLevel] = []
    var error: Error?
    var calls = 0

    func captureCurrentLevels(timeout: TimeInterval) throws -> [DeviceLevel] {
        calls += 1
        if let error { throw error }
        return levels
    }
}

final class RecordingLog: EventLogging {
    private let lock = NSLock()
    private var _entries: [(LogLevel, LogEvent, String)] = []

    var entries: [(level: LogLevel, event: LogEvent, message: String)] {
        lock.lock(); defer { lock.unlock() }
        return _entries.map { ($0.0, $0.1, $0.2) }
    }

    func log(_ level: LogLevel, _ event: LogEvent, _ message: String) {
        lock.lock(); _entries.append((level, event, message)); lock.unlock()
    }

    func messages(_ event: LogEvent) -> [String] { entries.filter { $0.event == event }.map(\.message) }
}

/// A fake output device. Mute exists only to prove the enforcer never touches it.
final class FakeDevice: OutputDevice {
    let id: String
    let name: String?
    private let lock = NSLock()
    private var _volume: Float32
    private var _writes: [Float32] = []
    private(set) var muted: Bool
    /// When set, written values are snapped to this step (like hardware with coarse volume steps).
    var step: Float32?
    var failReads = false
    var failWrites = false

    init(id: String, name: String? = nil, volume: Float32, muted: Bool = false) {
        self.id = id
        self.name = name
        _volume = volume
        self.muted = muted
    }

    var volume: Float32 {
        get { lock.lock(); defer { lock.unlock() }; return _volume }
        set { lock.lock(); _volume = newValue; lock.unlock() }
    }

    var writes: [Float32] { lock.lock(); defer { lock.unlock() }; return _writes }

    func readVolume() throws -> Float32 {
        if failReads { throw ConfigError("device gone") }
        return volume
    }

    func writeVolume(_ scalar: Float32) throws {
        if failWrites { throw ConfigError("device gone") }
        lock.lock()
        _writes.append(scalar)
        if let step { _volume = (scalar / step).rounded(.down) * step } else { _volume = scalar }
        lock.unlock()
    }
}

final class FakeBackend: AudioBackend {
    private let lock = NSLock()
    private var _devices: [FakeDevice]
    private(set) var notify: ((AudioChange) -> Void)?
    private(set) var scans = 0
    private(set) var connects = 0
    var failScan = false

    init(_ devices: [FakeDevice]) { _devices = devices }

    var devices: [FakeDevice] {
        get { lock.lock(); defer { lock.unlock() }; return _devices }
        set { lock.lock(); _devices = newValue; lock.unlock() }
    }

    func connect(notify: @escaping (AudioChange) -> Void) throws {
        connects += 1
        self.notify = notify
    }

    func scanOutputDevices() throws -> DeviceScan {
        if failScan { throw ConfigError("audio system gone") }
        scans += 1
        return DeviceScan(devices: devices, skipped: [(key: "hdmi", reason: "Output device 'HDMI' has no settable volume control.")])
    }

    func disconnect() { notify = nil }

    /// Simulates a CoreAudio notification.
    func fire(_ change: AudioChange) { notify?(change) }
}

func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
