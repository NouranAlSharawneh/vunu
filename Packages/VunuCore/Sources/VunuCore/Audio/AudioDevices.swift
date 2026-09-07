import Foundation
import CoreAudio
import AudioToolbox

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public enum Transport: String, Sendable { case builtIn, usb, bluetooth, virtual, other }
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transport: Transport
    public var isBluetooth: Bool { transport == .bluetooth }
    public var isVirtual: Bool { transport == .virtual }
    public var rank: Int { switch transport { case .builtIn: 0; case .usb: 1; case .other: 2; case .bluetooth: 3; case .virtual: 4 } }
    public var displayName: String { transport == .builtIn ? "\(name) (recommended)" : name }
}

/// Core Audio device enumeration + default-output mute/volume control (for "Mute music while dictating").
public enum AudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func getData<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = addr
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let st = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value)
        return st == noErr ? value : nil
    }
    private static func getString(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        var a = addr
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let st = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value)
        guard st == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    public static func inputDevices(includeVirtual: Bool = false) -> [AudioInputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var result: [AudioInputDevice] = []
        for id in ids {
            // has input channels?
            var cfgAddr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
            var cfgSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &cfgAddr, 0, nil, &cfgSize) == noErr, cfgSize > 0 else { continue }
            let bufList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(cfgSize))
            defer { bufList.deallocate() }
            guard AudioObjectGetPropertyData(id, &cfgAddr, 0, nil, &cfgSize, bufList) == noErr else { continue }
            let channels = UnsafeMutableAudioBufferListPointer(bufList).reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { continue }
            let name = getString(id, address(kAudioObjectPropertyName)) ?? "Unknown"
            let uid = getString(id, address(kAudioDevicePropertyDeviceUID)) ?? "\(id)"
            let transportRaw = getData(id, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
            let transport: AudioInputDevice.Transport
            switch transportRaw {
            case kAudioDeviceTransportTypeBuiltIn: transport = .builtIn
            case kAudioDeviceTransportTypeUSB: transport = .usb
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = .bluetooth
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: transport = .virtual
            default: transport = .other
            }
            if transport == .virtual && !includeVirtual { continue }
            result.append(AudioInputDevice(id: id, uid: uid, name: name, transport: transport))
        }
        return result.sorted { ($0.rank, $0.name) < ($1.rank, $1.name) }
    }

    public static func defaultInputDeviceID() -> AudioDeviceID? {
        getData(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultInputDevice), AudioDeviceID(0))
    }
    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        getData(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0))
    }

    public static func device(withUID uid: String) -> AudioInputDevice? {
        inputDevices(includeVirtual: true).first { $0.uid == uid }
    }

    // MARK: output mute / volume (used only when "Mute music while dictating" is on)
    public static func isOutputRunningSomewhere(_ id: AudioDeviceID) -> Bool {
        (getData(id, address(kAudioDevicePropertyDeviceIsRunningSomewhere), UInt32(0)) ?? 0) != 0
    }
    public static func outputMute(_ id: AudioDeviceID) -> Bool? {
        getData(id, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(0)).map { $0 != 0 }
    }
    @discardableResult public static func setOutputMute(_ id: AudioDeviceID, _ mute: Bool) -> Bool {
        var a = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var v: UInt32 = mute ? 1 : 0
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }
    public static func outputVolume(_ id: AudioDeviceID) -> Float? {
        getData(id, address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput), Float(0))
    }
    @discardableResult public static func setOutputVolume(_ id: AudioDeviceID, _ volume: Float) -> Bool {
        var a = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
        var v = volume
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float>.size), &v) == noErr
    }
}

/// Mutes the default output device during a dictation and restores the exact previous state.
/// Only acts when audio is actually playing and never overrides a user-set mute.
public final class OutputMuter: @unchecked Sendable {
    private var restore: (() -> Void)?
    private let lock = NSLock()
    public init() {}

    public func muteIfPlaying() {
        lock.lock(); defer { lock.unlock() }
        guard restore == nil, let out = AudioDevices.defaultOutputDeviceID(), AudioDevices.isOutputRunningSomewhere(out) else { return }
        if let muted = AudioDevices.outputMute(out) {
            guard !muted else { return } // user-set mute → leave alone
            if AudioDevices.setOutputMute(out, true) { restore = { AudioDevices.setOutputMute(out, false) }; Log.audio.info("output muted"); return }
        }
        if let vol = AudioDevices.outputVolume(out), vol > 0, AudioDevices.setOutputVolume(out, 0) {
            restore = { AudioDevices.setOutputVolume(out, vol) }
            Log.audio.info("output volume set to 0 (was \(vol))")
        }
    }

    public func restoreIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        restore?(); restore = nil
    }
}
