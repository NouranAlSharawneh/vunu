import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import os

/// Always-warm microphone capture. Keeps an AVAudioEngine running (no voice processing → no ducking),
/// converts the hardware stream to 16 kHz mono Float32 once, and accumulates samples only while recording.
/// Level (RMS) is updated on every buffer for the waveform; no timers.
public final class AudioCapture: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat!
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var configObserver: NSObjectProtocol?
    private var idleTimer: DispatchWorkItem?
    private let queue = DispatchQueue(label: "dev.nunu.vunu.audio", qos: .userInitiated)
    public var onDeviceChanged: (@Sendable () -> Void)?

    private struct State {
        var recording = false
        var samples: [Float] = []
        var level: Float = 0          // smoothed RMS 0…1
        var peak: Float = 0
        var startedAt: TimeInterval = 0
        var discardUntil: TimeInterval = 0
        var firstSampleAt: TimeInterval = 0
        var engineRunning = false
        var gain: Float = 1
        var monitoring = 0
    }

    public init() {
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)
    }

    public var isEngineRunning: Bool { state.withLock { $0.engineRunning } }
    public var isRecording: Bool { state.withLock { $0.recording } }
    /// 0…1 smoothed input level, for the waveform / mic test.
    public var level: Float { state.withLock { $0.level } }
    public var peak: Float { state.withLock { $0.peak } }
    public var recordedDuration: TimeInterval { state.withLock { Double($0.samples.count) / Self.sampleRate } }
    public var recordedSampleCount: Int { state.withLock { $0.samples.count } }

    // MARK: engine lifecycle

    /// Select the input device by UID (nil = system default). Restarts the engine if running.
    public func selectDevice(uid: String?) {
        queue.sync {
            let wasRunning = engine.isRunning
            if wasRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            applyDevice(uid: uid)
            converter = nil
            if wasRunning { try? startLocked() }
        }
    }

    private func applyDevice(uid: String?) {
        guard let unit = engine.inputNode.audioUnit else { return }
        var deviceID: AudioDeviceID
        if let uid, let dev = AudioDevices.device(withUID: uid) { deviceID = dev.id }
        else if let def = AudioDevices.defaultInputDeviceID() { deviceID = def }
        else { return }
        let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { Log.audio.error("failed to set input device \(deviceID): \(st)") }
    }

    /// Start (or ensure) the engine. ~30 ms cold; instant when already running.
    public func start() throws {
        try queue.sync { try startLocked() }
    }

    private func startLocked() throws {
        if engine.isRunning { return }
        let input = engine.inputNode
        // NEVER: input.setVoiceProcessingEnabled(true) — it ducks other apps' audio on macOS.
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else { throw VunuError.engineUnavailable("no input format") }
        if converter == nil || converter?.inputFormat != hw {
            converter = AVAudioConverter(from: hw, to: targetFormat)
            converter?.sampleRateConverterQuality = .max
        }
        input.removeTap(onBus: 0)
        let ratio = Self.sampleRate / hw.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: hw) { [weak self] buffer, _ in
            self?.process(buffer, ratio: ratio)
        }
        engine.prepare()
        try engine.start()
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { $0.engineRunning = true; $0.discardUntil = now + 0.04 }
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.handleConfigChange()
            }
        }
        Log.audio.info("audio engine started (\(hw.sampleRate) Hz, \(hw.channelCount) ch)")
        scheduleIdleStop()
    }

    public func stop() {
        if Thread.isMainThread { queue.async { [self] in stopLocked() } } else { queue.sync { stopLocked() } }
    }
    private func stopLocked() {
        do {
            idleTimer?.cancel(); idleTimer = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            state.withLock { $0.engineRunning = false; $0.level = 0 }
            Log.audio.info("audio engine stopped")
        }
    }

    private func handleConfigChange() {
        Log.audio.warning("audio configuration changed (device removed/added)")
        queue.async { [self] in
            let wasRecording = state.withLock { $0.recording }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            converter = nil
            do { try startLocked() } catch { Log.audio.error("restart after config change failed: \(error)") }
            if wasRecording { onDeviceChanged?() }
        }
    }

    /// Stop the engine after 10 min of no recording to save power; restarted on the next key-down.
    private func scheduleIdleStop() {
        idleTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isRecording else { return }
            self.stop()
        }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + 600, execute: item)
    }

    // MARK: recording

    /// Begin accumulating samples. Starts the engine if it was idle-stopped.
    public func beginRecording(gain: Float = 1) throws {
        if !isEngineRunning { try start() }
        idleTimer?.cancel()
        state.withLock {
            $0.samples.removeAll(keepingCapacity: true)
            $0.samples.reserveCapacity(Int(Self.sampleRate) * 30)
            $0.recording = true
            $0.startedAt = ProcessInfo.processInfo.systemUptime
            $0.firstSampleAt = 0
            $0.gain = gain
            $0.level = 0; $0.peak = 0
        }
    }

    /// Stop accumulating and return the 16 kHz mono samples.
    public func endRecording() -> [Float] {
        let samples = state.withLock { s -> [Float] in
            s.recording = false
            let out = s.samples
            s.samples = []
            s.level = 0
            return out
        }
        scheduleIdleStop()
        return samples
    }

    /// Level metering without recording (mic test UI). Reference-counted.
    public func startMonitoring() { if !isEngineRunning { try? start() }; state.withLock { $0.monitoring += 1 } }
    public func stopMonitoring() {
        let stopEngine = state.withLock { s -> Bool in
            s.monitoring = max(0, s.monitoring - 1)
            if s.monitoring == 0 && !s.recording { s.level = 0; return true }
            return false
        }
        if stopEngine { stop() }
    }

    /// Stop the engine unless something (recording / level monitoring) still needs it. Keeps the mic-in-use indicator off while idle.
    public func releaseIfIdle() {
        let busy = state.withLock { $0.recording || $0.monitoring > 0 }
        if !busy && isEngineRunning { stop() }
    }

    /// Samples captured so far (used for "Microphone disconnected — Insert").
    public func snapshotSamples() -> [Float] { state.withLock { $0.samples } }

    /// Latency from beginRecording() to the first captured sample, ms (for the HUD).
    public var firstSampleLatencyMs: Double {
        state.withLock { $0.firstSampleAt > 0 ? ($0.firstSampleAt - $0.startedAt) * 1000 : 0 }
    }

    private func process(_ buffer: AVAudioPCMBuffer, ratio: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let (recording, discard, gain, monitoring) = state.withLock { ($0.recording, now < $0.discardUntil, $0.gain, $0.monitoring > 0) }
        guard recording || monitoring, !discard, let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true; outStatus.pointee = .haveData; return buffer
        }
        guard status != .error, let ch = out.floatChannelData else { return }
        let n = Int(out.frameLength)
        guard n > 0 else { return }
        let ptr = ch[0]
        var sum: Float = 0, pk: Float = 0
        if gain != 1 { for i in 0..<n { ptr[i] = max(-1, min(1, ptr[i] * gain)) } }
        for i in 0..<n { let v = ptr[i]; sum += v * v; pk = max(pk, abs(v)) }
        let rms = sqrt(sum / Float(n))
        // map RMS (~0.005 quiet … 0.3 loud) to 0…1 with a soft log curve
        let mapped = min(1, max(0, (log10(max(rms, 1e-5)) + 4) / 3.2))
        let chunk = Array(UnsafeBufferPointer(start: ptr, count: n))
        let peakValue = pk
        state.withLock { s in
            if s.recording {
                if s.firstSampleAt == 0 { s.firstSampleAt = now }
                s.samples.append(contentsOf: chunk)
            }
            // attack 30 ms / release 120 ms at ~43 ms buffers → fast attack, slower release
            s.level = mapped > s.level ? mapped : s.level * 0.55 + mapped * 0.45
            s.peak = max(s.peak * 0.9, peakValue)
        }
    }
}
