import AudioToolbox
import CoreAudio
import Foundation
import SteadyVolumeCore

struct CoreAudioError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus

    var description: String { "\(what) failed (\(Self.describe(status)))" }

    /// OSStatus values from the HAL are usually four-character codes such as '!obj'.
    static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'\(String(decoding: bytes, as: UTF8.self))'"
        }
        return "\(status)"
    }
}

/// Small typed wrappers around the AudioObject property API.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let virtualMainVolume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) throws -> T {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr else { throw CoreAudioError(what: "Reading \(fourCC(address.mSelector))", status: status) }
        return value
    }

    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        var value = value
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        guard status == noErr else { throw CoreAudioError(what: "Setting \(fourCC(address.mSelector))", status: status) }
    }

    static func size(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> UInt32 {
        var address = address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(what: "Sizing \(fourCC(address.mSelector))", status: status) }
        return size
    }

    static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ zero: T) throws -> [T] {
        let byteCount = try size(object, address)
        let count = Int(byteCount) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var address = address
        var items = [T](repeating: zero, count: count)
        var size = byteCount
        let status = items.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { throw CoreAudioError(what: "Reading \(fourCC(address.mSelector))", status: status) }
        return Array(items.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Tells the HAL to deliver notifications on its own thread instead of the main run loop,
    /// which a daemon running dispatchMain() never spins. Must be called before other HAL use.
    static func useOwnNotificationThread() {
        var address = address(kAudioHardwarePropertyRunLoop)
        var runLoop: CFRunLoop? = nil
        _ = withUnsafeMutablePointer(to: &runLoop) {
            AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout<CFRunLoop?>.size), $0)
        }
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }

    // MARK: Devices

    static func allDevices() throws -> [AudioObjectID] {
        try array(system, address(kAudioHardwarePropertyDevices), AudioObjectID(0))
    }

    static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        (try? size(device, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput))) ?? 0 > 0
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        let alive = try? get(device, address(kAudioDevicePropertyDeviceIsAlive), UInt32(1))
        return (alive ?? 1) != 0
    }

    static func uid(_ device: AudioObjectID) -> String? {
        string(device, address(kAudioDevicePropertyDeviceUID))
    }

    static func name(_ device: AudioObjectID) -> String? {
        string(device, address(kAudioObjectPropertyName))
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let id = try? get(system, address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)), id != 0 else { return nil }
        return id
    }

    /// The output channels the system uses for stereo (usually 1 and 2).
    static func stereoChannels(_ device: AudioObjectID) -> [UInt32] {
        let pair = try? array(device, address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput), UInt32(0))
        let channels = (pair ?? []).filter { $0 > 0 }
        return channels.isEmpty ? [1, 2] : Array(Set(channels)).sorted()
    }

    /// Mute is only ever read (for the probe's report), never written.
    static func readMute(_ device: AudioObjectID) -> Bool? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            let a = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, element)
            if has(device, a), let value = try? get(device, a, UInt32(0)) { return value != 0 }
        }
        return nil
    }
}

/// How a device's master output volume is controlled.
enum VolumeControl: CustomStringConvertible {
    /// kAudioHardwareServiceDeviceProperty_VirtualMainVolume: what the menu bar slider and volume keys use.
    /// It keeps the left/right balance.
    case virtualMain
    /// kAudioDevicePropertyVolumeScalar on the main element.
    case mainScalar
    /// kAudioDevicePropertyVolumeScalar on each stereo channel (devices with no main control).
    case channels([UInt32])

    var description: String {
        switch self {
        case .virtualMain: return "virtual main volume"
        case .mainScalar: return "main volume scalar"
        case .channels(let list): return "per-channel volume scalar (channels \(list.map(String.init).joined(separator: ", ")))"
        }
    }

    /// Picks the best settable control, or nil if the device has none (for example most HDMI outputs).
    static func choose(for device: AudioObjectID) -> VolumeControl? {
        let output = kAudioObjectPropertyScopeOutput
        if HAL.has(device, HAL.address(HAL.virtualMainVolume, output)),
           HAL.isSettable(device, HAL.address(HAL.virtualMainVolume, output)) {
            return .virtualMain
        }
        if HAL.isSettable(device, HAL.address(kAudioDevicePropertyVolumeScalar, output)) {
            return .mainScalar
        }
        let channels = HAL.stereoChannels(device).filter {
            HAL.isSettable(device, HAL.address(kAudioDevicePropertyVolumeScalar, output, $0))
        }
        return channels.isEmpty ? nil : .channels(channels)
    }

    /// Every volume property worth listening to on the device, whichever control is used for writing.
    static func watchAddresses(for device: AudioObjectID) -> [AudioObjectPropertyAddress] {
        let output = kAudioObjectPropertyScopeOutput
        var candidates = [HAL.address(HAL.virtualMainVolume, output),
                          HAL.address(kAudioDevicePropertyVolumeScalar, output)]
        candidates += HAL.stereoChannels(device).map { HAL.address(kAudioDevicePropertyVolumeScalar, output, $0) }
        return candidates.filter { HAL.has(device, $0) }
    }
}

/// One CoreAudio output device. Only its master output volume is read or written.
final class CoreAudioDevice: OutputDevice {
    let objectID: AudioObjectID
    let id: String
    let name: String?
    let control: VolumeControl

    init(objectID: AudioObjectID, id: String, name: String?, control: VolumeControl) {
        self.objectID = objectID
        self.id = id
        self.name = name
        self.control = control
    }

    func readVolume() throws -> Float32 {
        let output = kAudioObjectPropertyScopeOutput
        switch control {
        case .virtualMain:
            return try HAL.get(objectID, HAL.address(HAL.virtualMainVolume, output), Float32(0))
        case .mainScalar:
            return try HAL.get(objectID, HAL.address(kAudioDevicePropertyVolumeScalar, output), Float32(0))
        case .channels(let channels):
            return try HAL.get(objectID, HAL.address(kAudioDevicePropertyVolumeScalar, output, channels[0]), Float32(0))
        }
    }

    func writeVolume(_ scalar: Float32) throws {
        let output = kAudioObjectPropertyScopeOutput
        let value = VolumeMath.clampScalar(scalar)
        switch control {
        case .virtualMain:
            try HAL.set(objectID, HAL.address(HAL.virtualMainVolume, output), value)
        case .mainScalar:
            try HAL.set(objectID, HAL.address(kAudioDevicePropertyVolumeScalar, output), value)
        case .channels(let channels):
            for channel in channels {
                try HAL.set(objectID, HAL.address(kAudioDevicePropertyVolumeScalar, output, channel), value)
            }
        }
    }
}
