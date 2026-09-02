import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    /// The CoreAudio device UID — stable across reboots and reconnects, unlike the
    /// numeric AudioDeviceID, so this is what gets stored in preferences.
    let id: String
    let name: String
}

/// Enumerating input devices via CoreAudio, so a specific microphone can be picked
/// instead of whatever macOS currently calls the default.
enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs()
            .filter(hasInputChannels)
            .compactMap { id in
                guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                      let name = string(id, kAudioObjectPropertyName)
                else { return nil }
                return AudioInputDevice(id: uid, name: name)
            }
    }

    /// The device with this UID, or nil if it isn't connected.
    ///
    /// This asks coreaudiod to translate the UID directly rather than walking the device
    /// list and reading `kAudioDevicePropertyDeviceUID` off every device in it. The walk
    /// is what made choosing the built-in microphone slow whenever Bluetooth headphones
    /// were connected: it queries devices we have no interest in, and a headset that is
    /// busy negotiating takes its time answering. Naming a device should never mean
    /// touching the others. The walk stays as a fallback.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = propertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier,
                &size, &deviceID
            )
        }
        // Translation answers with kAudioObjectUnknown rather than an error for a UID it
        // doesn't recognise, so a zero here means "not connected", not "ask again".
        if status == noErr { return deviceID == 0 ? nil : deviceID }

        return allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func name(forUID uid: String) -> String? {
        inputDevices().first { $0.id == uid }?.name
    }

    static var defaultInputDeviceID: AudioDeviceID? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    static var defaultInputName: String? {
        defaultInputDeviceID.flatMap { name(forDeviceID: $0) }
    }

    static func name(forDeviceID id: AudioDeviceID) -> String? {
        string(id, kAudioObjectPropertyName)
    }

    static func uid(forDeviceID id: AudioDeviceID) -> String? {
        string(id, kAudioDevicePropertyDeviceUID)
    }

    /// Whether a device is a Bluetooth headset.
    ///
    /// Worth knowing before recording from one: a Bluetooth headset cannot carry
    /// high-quality playback and a microphone at the same time. Opening its mic switches
    /// the whole device from A2DP to HFP, and whatever you were listening to collapses
    /// from stereo at 44.1 kHz to mono at 16 kHz until the recording stops.
    static func isBluetooth(deviceID id: AudioDeviceID) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func isBluetooth(uid: String) -> Bool {
        guard let id = deviceID(forUID: uid) else { return false }
        return isBluetooth(deviceID: id)
    }

    /// True when "System Default" would open a Bluetooth microphone.
    static var defaultInputIsBluetooth: Bool {
        guard let id = defaultInputDeviceID else { return false }
        return isBluetooth(deviceID: id)
    }

    // MARK: - CoreAudio plumbing

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    /// Output-only devices show up in the same list, so they're filtered by asking
    /// whether the device has any input channels at all.
    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
