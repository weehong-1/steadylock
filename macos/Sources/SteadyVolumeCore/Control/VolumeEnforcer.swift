import Foundation

/// Owns every audio object on one dedicated worker thread. Audio callbacks (volume changes, device
/// list and default-device changes) never touch the audio API; they only set a flag and signal this
/// thread. The thread also wakes every 250 ms as a backup in case a notification is missed. Requests to
/// read the current levels (for "lock at current levels") are also served on this thread.
/// Only the master volume scalar of output devices is read or written. Mute is never touched.
public final class VolumeEnforcer: VolumeSnapshotProviding {
    public static let pollInterval: TimeInterval = 0.25
    static let retryDelay: TimeInterval = 1
    static let revertLogWindow: TimeInterval = 10

    private let backend: AudioBackend
    private let log: EventLogging
    private let dryRun: Bool
    private let revertLog: RevertLogThrottle
    private let errorLog: RevertLogThrottle
    private let signal = DispatchSemaphore(value: 0)

    // Shared state, guarded by `state`.
    private let state = NSLock()
    private var sharedTarget: EnforcementTarget?
    private var sharedDevicesDirty = true
    private var stopRequested = false
    private var captureRequests: [CaptureRequest] = []
    private var thread: Thread?

    // Worker-thread state.
    private var devices: [DeviceState] = []
    private var deviceNames: [String: String] = [:]
    /// Devices first seen while locked at current levels, held at the level they reported then.
    /// Cleared whenever a new target arrives (it already includes persisted ones).
    private var adopted: [String: Float32] = [:]
    private var appliedTarget: EnforcementTarget?
    private var lastDeviceIDs: Set<String> = []

    /// Called on a background queue (never the worker thread) when a device not covered by a
    /// current-levels lock was seen and is now held at the level it reported.
    public var deviceDiscovered: ((DeviceLevel) -> Void)?

    public init(backend: AudioBackend, log: EventLogging, dryRun: Bool = false, now: @escaping () -> Date = Date.init) {
        self.backend = backend
        self.log = log
        self.dryRun = dryRun
        revertLog = RevertLogThrottle(window: Self.revertLogWindow, now: now)
        errorLog = RevertLogThrottle(window: 60, now: now)
    }

    /// Thread-safe. Nil stops enforcement without touching the volume.
    public func setTarget(_ target: EnforcementTarget?) {
        state.lock(); sharedTarget = target; state.unlock()
        signal.signal()
    }

    /// Thread-safe; read-only. Served by the worker thread, which owns the audio objects.
    public func captureCurrentLevels(timeout: TimeInterval) throws -> [DeviceLevel] {
        state.lock()
        let isWorker = thread != nil && Thread.current == thread
        state.unlock()
        if isWorker { throw ConfigError("Cannot capture levels from the enforcement thread.") }

        let request = CaptureRequest()
        state.lock(); captureRequests.append(request); state.unlock()
        signal.signal()
        guard request.done.wait(timeout: .now() + timeout) == .success else {
            state.lock(); captureRequests.removeAll { $0 === request }; state.unlock()
            throw ConfigError("The audio system did not answer in time.")
        }
        return try request.result!.get()
    }

    public func start() {
        state.lock(); defer { state.unlock() }
        precondition(thread == nil, "Already started.")
        let worker = Thread { [weak self] in self?.run() }
        worker.name = "SteadyVolume enforcer"
        worker.qualityOfService = .userInteractive
        thread = worker
        worker.start()
    }

    public func stop() {
        state.lock()
        stopRequested = true
        let pending = captureRequests
        captureRequests.removeAll()
        state.unlock()
        signal.signal()
        for request in pending { request.finish(.failure(ConfigError("The daemon is stopping."))) }
    }

    // MARK: - Callbacks: signal only

    private func notify(_ change: AudioChange) {
        if change == .devices {
            state.lock(); sharedDevicesDirty = true; state.unlock()
        }
        signal.signal()
    }

    // MARK: - Worker thread

    private var shouldStop: Bool {
        state.lock(); defer { state.unlock() }
        return stopRequested
    }

    private func run() {
        while !shouldStop {
            do {
                try connect()
                while !shouldStop {
                    try pass()
                    _ = signal.wait(timeout: .now() + Self.pollInterval)
                }
            } catch {
                if errorLog.register("session") != nil {
                    log.log(.error, .audioError,
                            "Audio enforcement error: \(error). Reconnecting to the audio system in \(Int(Self.retryDelay)) s.")
                }
            }
            disconnect()
            if shouldStop { break }
            _ = signal.wait(timeout: .now() + Self.retryDelay)
        }
        disconnect()
    }

    /// Connects to the audio system. Internal so tests can drive the worker logic step by step.
    func connect() throws {
        try backend.connect { [weak self] change in self?.notify(change) }
        state.lock(); sharedDevicesDirty = true; state.unlock()
    }

    func disconnect() {
        devices.removeAll()
        backend.disconnect()
        lastDeviceIDs = []
    }

    /// One enforcement pass: rebuild the device list if needed, serve capture requests, enforce, report.
    func pass() throws {
        state.lock()
        let dirty = sharedDevicesDirty
        sharedDevicesDirty = false // cleared first so a change during the scan marks it dirty again
        state.unlock()
        if dirty { try rebuildDevices() }
        serveCaptureRequests()
        enforceAll()
        reportSuppressedReverts()
    }

    private func markDirty() {
        state.lock(); sharedDevicesDirty = true; state.unlock()
    }

    private func rebuildDevices() throws {
        let scan = try backend.scanOutputDevices()
        devices = scan.devices.map(DeviceState.init)
        for device in devices { deviceNames[device.device.id] = device.displayName }
        for skipped in scan.skipped where errorLog.register("skip:" + skipped.key) != nil {
            log.log(.notice, .devicesChanged, skipped.reason)
        }

        let ids = Set(devices.map { $0.device.id })
        if ids != lastDeviceIDs {
            lastDeviceIDs = ids
            log.log(.info, .devicesChanged,
                    "Watching \(devices.count) output device(s): \(devices.map(\.displayName).joined(separator: ", ")).")
        }
    }

    private func serveCaptureRequests() {
        state.lock()
        let requests = captureRequests
        captureRequests.removeAll()
        state.unlock()
        guard !requests.isEmpty else { return }

        let result: Result<[DeviceLevel], Error>
        do {
            result = .success(try devices.map {
                DeviceLevel(id: $0.device.id, name: $0.device.name, scalar: VolumeMath.clampScalar(try $0.device.readVolume()))
            })
        } catch {
            markDirty()
            result = .failure(error)
        }
        for request in requests { request.finish(result) }
    }

    private func enforceAll() {
        state.lock()
        let target = sharedTarget
        state.unlock()
        if target !== appliedTarget {
            adopted.removeAll()
            appliedTarget = target
        }
        guard let target else { return }

        for device in devices {
            do {
                try enforce(device, target)
            } catch {
                // Usually the device went away. Rebuild on the next pass; if the whole audio system is
                // gone the rebuild throws and the session restarts.
                markDirty()
                if errorLog.register("enforce:" + device.device.id) != nil {
                    log.log(.warning, .audioError, "Could not enforce volume on \(device.displayName): \(error)")
                }
            }
        }
    }

    private func enforce(_ entry: DeviceState, _ target: EnforcementTarget) throws {
        let device = entry.device
        let currentScalar = try device.readVolume()
        var expectedScalar = target.scalar(for: device.id)
        if expectedScalar == nil {
            guard target.captureNewDevices else { return }
            if let held = adopted[device.id] {
                expectedScalar = held
            } else {
                // First time this device is seen under a current-levels lock: hold it where it is. No write.
                let level = VolumeMath.clampScalar(currentScalar)
                adopted[device.id] = level
                raiseDeviceDiscovered(DeviceLevel(id: device.id, name: device.name, scalar: level))
                return
            }
        }
        guard let expectedScalar else { return }

        let current = VolumeMath.toPercent(currentScalar)
        let expected = VolumeMath.toPercent(expectedScalar)
        if current == expected || entry.isAcceptedSubstitute(target: expected, current: current) { return }

        if dryRun {
            logRevert(entry, from: current, to: expected, dryRun: true)
            return
        }

        // Write back the exact stored scalar (for example 0.4998), not a rounded percent.
        try device.writeVolume(expectedScalar)

        // Some hardware volume controls only support coarse steps. If the device cannot land on the
        // exact percent, accept the closest value it reports, otherwise we would rewrite it forever.
        let after = VolumeMath.toPercent(try device.readVolume())
        if after != expected { entry.acceptSubstitute(target: expected, actual: after) }
        logRevert(entry, from: current, to: expected, dryRun: false)
    }

    private func raiseDeviceDiscovered(_ device: DeviceLevel) {
        guard let handler = deviceDiscovered else { return }
        // Never call out from the worker thread: the handler takes the control lock and saves the config.
        DispatchQueue.global(qos: .utility).async { handler(device) }
    }

    private func logRevert(_ entry: DeviceState, from: Int, to: Int, dryRun: Bool) {
        guard let count = revertLog.register(entry.device.id) else { return }
        let verb = dryRun ? "Would revert (dry run)" : "Reverted"
        let suffix = count == 1 ? "." : " (\(count) changes since the last report)."
        log.log(.info, .volumeReverted, "\(verb) master volume on \(entry.displayName) from \(from)% to \(to)%\(suffix)")
    }

    private func reportSuppressedReverts() {
        for (id, count) in revertLog.drainExpired() {
            log.log(.info, .volumeReverted,
                    "Reverted master volume on \(deviceNames[id] ?? id) \(count) more time(s) in the last \(Int(Self.revertLogWindow)) s.")
        }
    }

    // MARK: - Types

    private final class DeviceState {
        let device: OutputDevice
        let displayName: String
        private var substituteFor = -1
        private var substitute = -1

        init(_ device: OutputDevice) {
            self.device = device
            displayName = device.name.map { "'\($0)'" } ?? device.id
        }

        func isAcceptedSubstitute(target: Int, current: Int) -> Bool { substituteFor == target && substitute == current }

        func acceptSubstitute(target: Int, actual: Int) {
            substituteFor = target
            substitute = actual
        }
    }

    private final class CaptureRequest {
        let done = DispatchSemaphore(value: 0)
        private(set) var result: Result<[DeviceLevel], Error>?

        func finish(_ result: Result<[DeviceLevel], Error>) {
            self.result = result
            done.signal()
        }
    }
}
