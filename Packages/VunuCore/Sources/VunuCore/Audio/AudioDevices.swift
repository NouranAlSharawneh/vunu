import Foundation
import CoreAudio
import AudioToolbox

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public enum Transport: String, Sendable { case builtIn, usb, bluetooth, continuity, virtual, aggregate, other }
    public let id: AudioDeviceID
    public let uid: String
    public var modelUID: String? = nil
    public let name: String
    public let transport: Transport
    /// The Mac's own microphone, as opposed to a headset plugged into the jack (which also reports built-in transport).
    public var isInternalMic: Bool = false
    public var isBluetooth: Bool { transport == .bluetooth }
    /// Not a physical mic of its own: virtual (Krisp, Teams, BlackHole…) or an aggregate.
    public var isVirtual: Bool { transport == .virtual || transport == .aggregate }
    /// Opening it changes something else: Bluetooth flips the headset to call quality, Continuity wakes the iPhone.
    public var isRemote: Bool { transport == .bluetooth || transport == .continuity }
    public var rank: Int {
        switch transport {
        case .builtIn: isInternalMic ? 0 : 1
        case .usb: 2
        case .other: 3
        case .continuity: 4
        case .bluetooth: 5
        case .virtual: 6
        case .aggregate: 7
        }
    }
    public var displayName: String { isInternalMic ? "\(name) (recommended)" : name }
}

/// Which input to record from, and why (for the log and the "Now using" line).
public struct InputChoice: Sendable, Equatable {
    public enum Reason: String, Sendable { case preferred, preferredModel, systemDefault, avoidedRemoteDefault, onlyOption }
    public let device: AudioInputDevice
    public let reason: Reason
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

    static func transport(_ id: AudioDeviceID) -> AudioInputDevice.Transport {
        switch getData(id, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0 {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: .continuity
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .aggregate
        default: .other
        }
    }

    /// Reads every input device from the HAL. Can be slow while Bluetooth renegotiates — call off the main thread
    /// (UI reads `AudioDeviceCache.shared`).
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
            let bufList = UnsafeMutableRawPointer.allocate(byteCount: Int(cfgSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { bufList.deallocate() }
            guard AudioObjectGetPropertyData(id, &cfgAddr, 0, nil, &cfgSize, bufList) == noErr else { continue }
            let channels = UnsafeMutableAudioBufferListPointer(bufList.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { continue }
            let name = getString(id, address(kAudioObjectPropertyName)) ?? "Unknown"
            let uid = getString(id, address(kAudioDevicePropertyDeviceUID)) ?? "\(id)"
            let t = transport(id)
            if t == .virtual || t == .aggregate, !includeVirtual { continue }
            // 'imic' is the Mac's own mic; 'emic' is a headset on the jack. Built-in devices without a data source are the own mic.
            let source = getData(id, address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeInput), UInt32(0))
            let internalMic = t == .builtIn && (source == nil || source == 0x696D6963 /* imic */)
            result.append(AudioInputDevice(id: id, uid: uid, modelUID: getString(id, address(kAudioDevicePropertyModelUID)),
                                           name: name, transport: t, isInternalMic: internalMic))
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

    /// Picks the input to record from. Pure, so the policy is unit-tested.
    ///
    /// - The user's explicit choice wins (by UID; by model UID when the same model reappears under a new UID, e.g. another USB port).
    /// - Otherwise the system default — unless it is a Bluetooth or Continuity mic and a local one exists. Opening a Bluetooth
    ///   mic switches the headset from A2DP to HFP (music drops to call quality) and is what multipoint headsets choke on.
    /// - The Mac's own mic is skipped while the lid is closed (Apple silicon disconnects it in hardware; it only delivers zeros).
    /// - Aggregates are never chosen automatically; a virtual default (Krisp…) is respected.
    public static func resolveInput(preferredUID: String?, preferredModelUID: String?, devices: [AudioInputDevice],
                                    defaultID: AudioDeviceID?, clamshellClosed: Bool) -> InputChoice? {
        if let preferredUID, let d = devices.first(where: { $0.uid == preferredUID }) { return InputChoice(device: d, reason: .preferred) }
        if let preferredModelUID, let d = devices.first(where: { $0.modelUID == preferredModelUID }) { return InputChoice(device: d, reason: .preferredModel) }
        let usable = devices.filter { $0.transport != .aggregate && !(clamshellClosed && $0.isInternalMic) }
        let def = usable.first { $0.id == defaultID }
        if let def, !def.isRemote { return InputChoice(device: def, reason: .systemDefault) }
        let local = usable.filter { !$0.isRemote && !$0.isVirtual }.sorted { ($0.rank, $0.name) < ($1.rank, $1.name) }
        if let best = local.first { return InputChoice(device: best, reason: def == nil ? .onlyOption : .avoidedRemoteDefault) }
        if let def { return InputChoice(device: def, reason: .systemDefault) }
        if let any = usable.sorted(by: { $0.rank < $1.rank }).first ?? devices.first { return InputChoice(device: any, reason: .onlyOption) }
        return nil
    }

    /// Live resolution against the HAL (call off the main thread).
    public static func resolveCurrentInput(preferredUID: String?, preferredModelUID: String?) -> InputChoice? {
        resolveInput(preferredUID: preferredUID, preferredModelUID: preferredModelUID, devices: inputDevices(includeVirtual: true),
                     defaultID: defaultInputDeviceID(), clamshellClosed: Clamshell.isClosed)
    }

    /// "Automatic" input ID, kept for callers that only need the ID.
    public static func automaticInputDeviceID() -> AudioDeviceID? {
        resolveCurrentInput(preferredUID: nil, preferredModelUID: nil)?.device.id
    }

    /// "Name [transport]" for logs.
    public static func describe(_ id: AudioDeviceID?) -> String {
        guard let id else { return "none" }
        let name = getString(id, address(kAudioObjectPropertyName)) ?? "#\(id)"
        return "\(name) [\(transport(id).rawValue)]"
    }

    public static func deviceExists(_ id: AudioDeviceID) -> Bool {
        (getData(id, address(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) ?? 0) != 0
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
