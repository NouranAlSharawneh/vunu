import Foundation
import CoreAudio
import IOKit
import os

/// Whether a MacBook's lid is closed. Apple silicon disconnects the built-in mic in hardware then; the device stays listed
/// but only delivers zeros. Desktops have no clamshell state.
public enum Clamshell {
    public static var isClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }
}

/// The input device list, refreshed off the main thread whenever devices or the default input change.
/// Menus, Settings and the Flow Bar read this instead of querying the HAL, which can block for seconds while a
/// Bluetooth headset renegotiates (and would freeze the UI).
public final class AudioDeviceCache: @unchecked Sendable {
    public static let shared = AudioDeviceCache()

    private struct Snapshot { var devices: [AudioInputDevice] = []; var defaultInputID: AudioDeviceID?; var loaded = false }
    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    private let queue = DispatchQueue(label: "dev.nunu.vunu.audio.devices", qos: .utility)
    private var listener: AudioObjectPropertyListenerBlock?
    private var started = false

    private init() {}

    /// Registers HAL listeners and loads the list in the background. Idempotent.
    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            listener = block
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
                var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            }
            refreshLocked()
        }
    }

    /// Re-reads the HAL on the cache queue, then tells the UI.
    public func refresh() { queue.async { [self] in refreshLocked() } }

    private func refreshLocked() {
        let devices = AudioDevices.inputDevices(includeVirtual: true)
        let def = AudioDevices.defaultInputDeviceID()
        state.withLock { $0 = Snapshot(devices: devices, defaultInputID: def, loaded: true) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .vunuAudioDevicesChanged, object: nil) }
    }

    /// Cached inputs (physical only unless `includeVirtual`), best first.
    public func inputDevices(includeVirtual: Bool = false) -> [AudioInputDevice] {
        let all = state.withLock { $0.devices }
        return includeVirtual ? all : all.filter { !$0.isVirtual }
    }

    public func device(withUID uid: String) -> AudioInputDevice? { state.withLock { $0.devices.first { $0.uid == uid } } }

    /// What Vunu would record from right now, from the cache (for "Now using" and the Flow Bar tooltip).
    @MainActor public func currentChoice() -> InputChoice? {
        let snap = state.withLock { $0 }
        let prefs = Preferences.shared
        return AudioDevices.resolveInput(preferredUID: prefs.preferredMicrophoneUID, preferredModelUID: prefs.preferredMicrophoneModelUID,
                                         devices: snap.devices, defaultID: snap.defaultInputID, clamshellClosed: Clamshell.isClosed)
    }
}

extension Notification.Name { public static let vunuAudioDevicesChanged = Notification.Name("vunuAudioDevicesChanged") }
