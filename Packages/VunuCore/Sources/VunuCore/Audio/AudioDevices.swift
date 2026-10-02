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

    /// Nominal sample rate and input channel count, to tell a real format change from a notification that changed nothing.
    static func inputFormat(_ id: AudioDeviceID) -> (rate: Double, channels: Int)? {
        guard let rate = getData(id, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) else { return nil }
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return (rate, 0) }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return (rate, 0) }
        let channels = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
        return (rate, channels)
    }

    public static func deviceExists(_ id: AudioDeviceID) -> Bool {
        (getData(id, address(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) ?? 0) != 0
    }

    // MARK: output mute / volume (used only when "Mute music while dictating" is on)

    static func uid(of id: AudioDeviceID) -> String? { getString(id, address(kAudioDevicePropertyDeviceUID)) }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafeMutablePointer(to: &cfUID) { q in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), q, &size, &id)
        }
        return st == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector, _ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }
    static func isSettable(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: UInt32) -> Bool {
        var a = outputAddress(selector, element)
        guard AudioObjectHasProperty(id, &a) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
    }
    /// Mute (0/1) or volume scalar (0…1) as a Float.
    static func outputValue(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: UInt32) -> Float? {
        if selector == kAudioDevicePropertyMute { return getData(id, outputAddress(selector, element), UInt32(0)).map { Float($0) } }
        return getData(id, outputAddress(selector, element), Float(0))
    }
    @discardableResult static func setOutputValue(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: UInt32, _ value: Float) -> Bool {
        var a = outputAddress(selector, element)
        if selector == kAudioDevicePropertyMute {
            var v: UInt32 = value != 0 ? 1 : 0
            return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
        }
        var v = value
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float>.size), &v) == noErr
    }

    /// PIDs of processes currently producing audio output, excluding `excludingPID` (Vunu's own ping must not count).
    public static func processesPlayingOutput(excludingPID: pid_t) -> [pid_t] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { obj -> pid_t? in
            guard (getData(obj, address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0) != 0,
                  let pid = getData(obj, address(kAudioProcessPropertyPID), pid_t(0)), pid != excludingPID else { return nil }
            return pid
        }
    }
}

/// "Mute music while dictating" (opt-in). Modeled on Wispr Flow's behaviour:
/// - mutes the default output only when another app is actually playing (Vunu's own start ping doesn't count), 250 ms after
///   recording starts so the ping is still heard;
/// - remembers the device by UID and the exact previous value of each control it changed (mute, else volume; main element,
///   else channels 1/2), and puts back only values that are still what it set — a change the user made wins;
/// - retries the restore at 0.5, 1.5 and 3.5 s while a Bluetooth headset settles, and gives up if the device is gone;
/// - persists the pending restore so a crash or quit can't leave music muted (applied at the next launch).
/// All Core Audio calls run on its own queue, never the main thread.
public final class OutputMuter: @unchecked Sendable {
    struct Change: Codable, Equatable { let selector: UInt32; let element: UInt32; let previous: Float; let applied: Float }
    struct Record: Codable, Equatable { let uid: String; var changes: [Change] }

    private static let defaultsKey = "pendingOutputRestore"
    private let queue = DispatchQueue(label: "dev.nunu.vunu.muter", qos: .userInitiated)
    private var record: Record?                 // queue only
    private var muteWork: DispatchWorkItem?     // queue only
    private var restoreGen = 0                  // queue only

    public init() {}

    /// Mute in 250 ms unless the dictation ends first.
    public func scheduleMute() {
        queue.async { [self] in
            muteWork?.cancel()
            restoreGen += 1   // a restore still retrying for the previous dictation stops; its record is reused
            let work = DispatchWorkItem { [weak self] in self?.muteNow() }
            muteWork = work
            queue.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    public func restore() {
        queue.async { [self] in
            muteWork?.cancel(); muteWork = nil
            guard record != nil else { return }
            restoreGen += 1
            attemptRestore(gen: restoreGen, attempt: 0)
        }
    }

    /// App quit: one bounded restore attempt (≤ 0.5 s). Anything left is applied at the next launch.
    public func restoreBeforeQuit() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            muteWork?.cancel(); muteWork = nil
            if record != nil { restoreGen += 1; attemptRestore(gen: restoreGen, attempt: 0, retry: false) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 0.5)
    }

    /// Launch: put back what a previous run muted if it never got to (crash, force quit).
    public func restorePendingFromLastRun() {
        queue.async { [self] in
            guard record == nil, let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
                  let r = try? JSONDecoder().decode(Record.self, from: data) else { return }
            Log.file("audio", "restoring output left muted by the last run")
            record = r
            restoreGen += 1
            attemptRestore(gen: restoreGen, attempt: 0)
        }
    }

    private func muteNow() {
        muteWork = nil
        guard record == nil else { return }   // still muted from the previous dictation (restore pending): keep that record
        let playing = AudioDevices.processesPlayingOutput(excludingPID: getpid())
        guard !playing.isEmpty, let out = AudioDevices.defaultOutputDeviceID(), let uid = AudioDevices.uid(of: out) else { return }
        var changes: [Change] = []
        // Prefer mute (exact on/off restore); fall back to volume. Main element first, else the stereo channels.
        for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] where changes.isEmpty {
            let target: Float = selector == kAudioDevicePropertyMute ? 1 : 0
            for element in [kAudioObjectPropertyElementMain, 1, 2] as [UInt32] {
                guard AudioDevices.isSettable(out, selector, element), let current = AudioDevices.outputValue(out, selector, element) else { continue }
                if current == target { return }   // already silent (muted or volume 0): the user did that, leave it alone
                if AudioDevices.setOutputValue(out, selector, element, target) {
                    changes.append(Change(selector: selector, element: element, previous: current, applied: target))
                }
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        guard !changes.isEmpty else { return }
        let r = Record(uid: uid, changes: changes)
        record = r
        if let data = try? JSONEncoder().encode(r) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
        Log.file("audio", "output muted for dictation (\(AudioDevices.describe(out)); \(changes.count) control\(changes.count == 1 ? "" : "s"))")
    }

    private func attemptRestore(gen: Int, attempt: Int, retry: Bool = true) {
        guard gen == restoreGen, var r = record else { return }
        guard let id = AudioDevices.deviceID(forUID: r.uid) else {
            finish("output device gone; nothing to restore")
            return
        }
        var remaining: [Change] = []
        for c in r.changes {
            guard let current = AudioDevices.outputValue(id, c.selector, c.element) else { remaining.append(c); continue }
            if current != c.applied { continue }   // changed by the user (or already restored): theirs wins
            if !AudioDevices.setOutputValue(id, c.selector, c.element, c.previous) || AudioDevices.outputValue(id, c.selector, c.element) != c.previous {
                remaining.append(c)
            }
        }
        if remaining.isEmpty { finish("output restored"); return }
        r.changes = remaining
        record = r
        if let data = try? JSONEncoder().encode(r) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
        guard retry else { Log.file("audio", "output not fully restored at quit; will retry at next launch"); return }
        let delays: [Double] = [0.5, 1.0, 2.0]   // → attempts at 0.5, 1.5 and 3.5 s
        guard attempt < delays.count else { finish("output restore gave up after retries"); return }
        queue.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in self?.attemptRestore(gen: gen, attempt: attempt + 1) }
    }

    private func finish(_ message: String) {
        record = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        Log.file("audio", message)
    }
}
