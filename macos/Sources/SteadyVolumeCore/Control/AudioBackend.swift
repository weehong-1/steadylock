import Foundation

/// One output device's master volume, as seen by the enforcer. Only the master output volume is
/// exposed: mute, per-app volumes and inputs are deliberately out of reach.
public protocol OutputDevice: AnyObject {
    /// Stable identifier (the CoreAudio device UID).
    var id: String { get }
    var name: String? { get }
    func readVolume() throws -> Float32
    func writeVolume(_ scalar: Float32) throws
}

public enum AudioChange {
    /// A watched device's volume changed.
    case volume
    /// The device list, the default output device, or the audio service itself changed.
    case devices
}

public struct DeviceScan {
    public var devices: [OutputDevice]
    /// Output devices that were skipped, keyed for log throttling (for example no settable volume control).
    public var skipped: [(key: String, reason: String)]

    public init(devices: [OutputDevice], skipped: [(key: String, reason: String)] = []) {
        self.devices = devices
        self.skipped = skipped
    }
}

/// The audio system. All methods are called on the enforcer's worker thread only.
public protocol AudioBackend: AnyObject {
    /// Installs system-level listeners. `notify` may be called on any thread and only signals the worker.
    func connect(notify: @escaping (AudioChange) -> Void) throws
    /// Lists output devices and (re)installs their volume listeners.
    func scanOutputDevices() throws -> DeviceScan
    /// Removes every listener.
    func disconnect()
}
