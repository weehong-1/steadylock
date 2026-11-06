import CoreAudio
import Foundation
import SteadyVolumeCore

/// The real audio system. Every method runs on the enforcer's worker thread. Property listener
/// blocks run on `listenerQueue` and only call `notify`, which signals the worker; they never call
/// the audio API themselves.
final class CoreAudioBackend: AudioBackend {
    private struct Registration {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private static let configureHAL: Void = HAL.useOwnNotificationThread()

    private let listenerQueue = DispatchQueue(label: "com.steadyvolume.audio-listeners")
    private var notify: ((AudioChange) -> Void)?
    private var systemListeners: [Registration] = []
    private var deviceListeners: [Registration] = []

    init() {
        _ = Self.configureHAL
    }

    func connect(notify: @escaping (AudioChange) -> Void) throws {
        disconnect()
        self.notify = notify
        let selectors = [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultSystemOutputDevice,
                         kAudioHardwarePropertyServiceRestarted]
        for selector in selectors {
            try addListener(HAL.system, HAL.address(selector), change: .devices, into: &systemListeners)
        }
    }

    func scanOutputDevices() throws -> DeviceScan {
        removeAll(&deviceListeners)

        var devices: [OutputDevice] = []
        var skipped: [(key: String, reason: String)] = []
        for objectID in try HAL.allDevices() where HAL.hasOutputStreams(objectID) && HAL.isAlive(objectID) {
            guard let uid = HAL.uid(objectID) else { continue }
            let name = HAL.name(objectID)
            let label = name.map { "'\($0)'" } ?? uid

            // Device-level changes (unplugged, streams reconfigured) rebuild the list.
            for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyStreams] {
                try? addListener(objectID, HAL.address(selector), change: .devices, into: &deviceListeners)
            }

            guard let control = VolumeControl.choose(for: objectID) else {
                skipped.append((key: "novolume:" + uid,
                                reason: "Output device \(label) has no settable volume control, so it cannot be locked."))
                continue
            }

            var watching = 0
            for address in VolumeControl.watchAddresses(for: objectID) {
                do {
                    try addListener(objectID, address, change: .volume, into: &deviceListeners)
                    watching += 1
                } catch {
                    skipped.append((key: "listen:" + uid,
                                    reason: "Could not watch volume changes on \(label): \(error). The 250 ms poll still covers it."))
                }
            }
            if watching == 0 {
                skipped.append((key: "nolisten:" + uid,
                                reason: "Output device \(label) reports no volume notifications; only the 250 ms poll covers it."))
            }
            devices.append(CoreAudioDevice(objectID: objectID, id: uid, name: name, control: control))
        }
        return DeviceScan(devices: devices, skipped: skipped)
    }

    func disconnect() {
        removeAll(&deviceListeners)
        removeAll(&systemListeners)
        notify = nil
    }

    // MARK: - Listeners

    private func addListener(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, change: AudioChange,
                             into list: inout [Registration]) throws {
        // Capture the closure, not self: the block must stay valid and cheap, and only signal.
        let signal = notify
        let block: AudioObjectPropertyListenerBlock = { _, _ in signal?(change) }
        var address = address
        let status = AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block)
        guard status == noErr else {
            throw CoreAudioError(what: "Listening to \(HAL.fourCC(address.mSelector))", status: status)
        }
        // The same block object must be passed to the remove call, so keep it.
        list.append(Registration(object: object, address: address, block: block))
    }

    private func removeAll(_ list: inout [Registration]) {
        for registration in list {
            var address = registration.address
            // Fails harmlessly for devices that are already gone.
            _ = AudioObjectRemovePropertyListenerBlock(registration.object, &address, listenerQueue, registration.block)
        }
        list.removeAll()
    }
}
