// The Mac's audio inputs (CoreAudio) and the choice of one for dictation. A saved choice is a device UID, stable across
// plugging and unplugging; nil follows the system default. No capture happens here.
import CoreAudio
import Foundation

public struct InputDevice: Equatable, Identifiable, Sendable {
    public let uid: String
    public let name: String
    public let isDefault: Bool
    public var id: String { uid }
    public init(uid: String, name: String, isDefault: Bool) { self.uid = uid; self.name = name; self.isDefault = isDefault }
}

public enum Microphone {
    /// The input to select explicitly (nil = leave it on the system default), and a notice when the saved UID is not
    /// connected. The saved choice itself is never touched, so it works again when the device returns.
    public static func resolve(_ uid: String?, in devices: [InputDevice]) -> (device: InputDevice?, notice: String?) {
        guard let uid else { return (nil, nil) }
        if let device = devices.first(where: { $0.uid == uid }) { return (device, nil) }
        return (nil, "Mic not found, using \(devices.first(where: \.isDefault)?.name ?? "the system default")")
    }

    /// "System default (MacBook Pro Microphone)", for the pickers.
    public static func defaultLabel(_ devices: [InputDevice]) -> String {
        devices.first(where: \.isDefault).map { "System default (\($0.name))" } ?? "System default"
    }

    /// Every visible device with an input stream, in CoreAudio's order.
    public static func inputs() -> [InputDevice] { devices().map(\.device) }

    public static func deviceID(uid: String) -> AudioDeviceID? { devices().first { $0.device.uid == uid }?.id }

    /// Calls `onChange` (on the main queue) when a device is plugged in or removed, or the default input changes.
    /// ponytail: listeners live for the process; add removal if anything but the app-wide list ever observes.
    public static func observe(_ onChange: @escaping @Sendable () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var a = address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { _, _ in onChange() }
        }
    }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func devices() -> [(id: AudioDeviceID, device: InputDevice)] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        var current: AudioDeviceID = 0
        var d = address(kAudioHardwarePropertyDefaultInputDevice)
        var currentSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(system, &d, 0, nil, &currentSize, &current)
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { return nil }
            var hidden: UInt32 = 0
            var h = address(kAudioDevicePropertyIsHidden)
            var hiddenSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &h, 0, nil, &hiddenSize, &hidden) == noErr, hidden != 0 { return nil }
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return (id, InputDevice(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, isDefault: id == current))
        }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
