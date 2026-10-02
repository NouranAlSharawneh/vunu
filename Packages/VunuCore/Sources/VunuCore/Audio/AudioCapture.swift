import Foundation
import os

/// Identifies one dictation's capture. Events carry it so a late event from an earlier dictation can be ignored.
public typealias CaptureToken = UInt64

public enum CaptureEvent: Sendable, Equatable {
    /// The mic is running for this dictation.
    case started(device: String, bluetooth: Bool)
    /// First real (non-silent) audio arrived. Bluetooth mics take 1–3 s to switch profiles before this.
    case micReady
    /// The device changed format mid-dictation; capture restarted on the same mic and the recording continues.
    case formatChanged
    /// The mic went away (unplugged, headset taken by another device, audio service restart). Audio so far is kept.
    case deviceLost(String)
    /// The mic couldn't be started (or the audio system stopped responding).
    case startFailed(String)
    /// The mic never delivered any audio.
    case noInput
    /// The mic delivers only digital silence (a busy multipoint headset, or the internal mic with the lid closed).
    case silentInput(device: String, lidClosed: Bool)
}

/// The capture backend contract shared by the Core Audio engine and the legacy AVAudioEngine fallback.
protocol CaptureEngine: AnyObject, Sendable {
    func setEventHandler(_ handler: @escaping @Sendable (CaptureToken, CaptureEvent) -> Void)
    var level: Float { get }
    var peak: Float { get }
    var isRecording: Bool { get }
    var isRunning: Bool { get }
    var recordedSampleCount: Int { get }
    var firstSampleLatencyMs: Double { get }
    func beginRecording(gain: Float) -> CaptureToken
    func endRecording() -> [Float]
    func snapshotSamples() -> [Float]
    func renewMonitoringLease()
    func endMonitoring()
    func releaseIfIdle()
    func selectDevice(uid: String?, modelUID: String?)
    func shutdown()
}

/// Microphone capture: 16 kHz mono Float32, accumulated only while recording; level metering for the waveform and the
/// Settings meter. The mic is opened on key-down and released shortly after each dictation, so the mic indicator is off
/// while idle and a Bluetooth headset is never held in call mode.
///
/// Backed by `HALCaptureEngine` (input-only Core Audio unit bound to the chosen device). The ≤ 0.3.x AVAudioEngine path
/// stays available for one release: `defaults write dev.nunu.vunu captureEngine legacy`.
public final class AudioCapture: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    public enum Backend: String, Sendable { case hal, legacy }
    public static var configuredBackend: Backend {
        UserDefaults.standard.string(forKey: "captureEngine").flatMap(Backend.init(rawValue:)) ?? .hal
    }
    /// Tests and offscreen renders must never open the mic (VUNU_MIC_TESTS=1 opts a hardware test in).
    static let isTesting = NSClassFromString("XCTestCase") != nil && ProcessInfo.processInfo.environment["VUNU_MIC_TESTS"] == nil

    public let backend: Backend
    private let engine: CaptureEngine

    public init(backend: Backend = AudioCapture.configuredBackend) {
        self.backend = backend
        engine = backend == .legacy ? LegacyCaptureEngine() : HALCaptureEngine()
    }

    /// Events arrive on an internal queue; hop to the main actor before touching UI state.
    public func setEventHandler(_ handler: @escaping @Sendable (CaptureToken, CaptureEvent) -> Void) { engine.setEventHandler(handler) }

    public var isEngineRunning: Bool { engine.isRunning }
    public var isRecording: Bool { engine.isRecording }
    /// 0…1 smoothed input level, for the waveform / mic test.
    public var level: Float { debugLevelOverride ?? engine.level }
    /// Test/preview hook so the waveform can be rendered offscreen with a fake level.
    public nonisolated(unsafe) var debugLevelOverride: Float? = nil
    public var peak: Float { engine.peak }
    public var recordedSampleCount: Int { engine.recordedSampleCount }
    public var recordedDuration: TimeInterval { Double(engine.recordedSampleCount) / Self.sampleRate }
    /// Latency from beginRecording() to the first captured sample, ms (for the HUD).
    public var firstSampleLatencyMs: Double { engine.firstSampleLatencyMs }

    /// Starts accumulating samples and opens the mic if needed. Returns immediately; problems arrive as events.
    @discardableResult public func beginRecording(gain: Float = 1) -> CaptureToken { engine.beginRecording(gain: gain) }
    /// Stops accumulating and returns the 16 kHz mono samples.
    public func endRecording() -> [Float] { engine.endRecording() }
    /// Samples captured so far (live preview, "Microphone disconnected — Insert").
    public func snapshotSamples() -> [Float] { engine.snapshotSamples() }

    /// Level metering without recording (Settings mic meter). A lease: call at least once a second while the meter is
    /// visible; it lapses 2 s after the last call, so a hidden window can't keep the mic on.
    public func renewMonitoringLease() { engine.renewMonitoringLease() }
    public func startMonitoring() { engine.renewMonitoringLease() }
    public func stopMonitoring() { engine.endMonitoring() }

    /// Release the mic shortly unless a recording or the meter still needs it.
    public func releaseIfIdle() { engine.releaseIfIdle() }

    /// Select the input device by UID (nil = automatic). Takes effect for the next capture; an idle meter switches now.
    public func selectDevice(uid: String?, modelUID: String? = nil) { engine.selectDevice(uid: uid, modelUID: modelUID) }

    /// App quit. Doesn't block: process exit releases the device anyway.
    public func stop() { engine.shutdown() }

    /// `--audio-probe`: repeated start/stop cycles with timings in vunu.log, to validate capture on a given Mac/headset.
    public func probe(cycles: Int = 20) async {
        Log.file("audio", "probe: \(cycles) cycles on the \(backend.rawValue) engine")
        for i in 1...cycles {
            beginRecording()
            try? await Task.sleep(for: .milliseconds(1_500))
            let latency = firstSampleLatencyMs
            let samples = endRecording()
            var peak: Float = 0
            for v in samples { peak = max(peak, abs(v)) }
            Log.file("audio", "probe \(i): \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / Self.sampleRate)) s), first sample \(Int(latency)) ms, peak \(String(format: "%.4f", peak))")
            releaseIfIdle()
            try? await Task.sleep(for: .milliseconds(900))
        }
        Log.file("audio", "probe done")
    }
}

/// Adapts the legacy AVAudioEngine capture to the event/token contract.
final class LegacyCaptureEngine: CaptureEngine, @unchecked Sendable {
    private let impl = LegacyAudioCapture()
    private let state = OSAllocatedUnfairLock<(token: CaptureToken, handler: (@Sendable (CaptureToken, CaptureEvent) -> Void)?, monitoring: Bool)>(initialState: (0, nil, false))

    init() {
        impl.onDeviceChanged = { [weak self] change in
            guard let self else { return }
            let (token, handler) = self.state.withLock { ($0.token, $0.handler) }
            handler?(token, change == .deviceLost ? .deviceLost("device lost") : .formatChanged)
        }
    }

    func setEventHandler(_ handler: @escaping @Sendable (CaptureToken, CaptureEvent) -> Void) { state.withLock { $0.handler = handler } }
    var level: Float { impl.level }
    var peak: Float { impl.peak }
    var isRecording: Bool { impl.isRecording }
    var isRunning: Bool { impl.isEngineRunning }
    var recordedSampleCount: Int { impl.recordedSampleCount }
    var firstSampleLatencyMs: Double { impl.firstSampleLatencyMs }

    func beginRecording(gain: Float) -> CaptureToken {
        let (token, handler) = state.withLock { s -> (CaptureToken, (@Sendable (CaptureToken, CaptureEvent) -> Void)?) in s.token += 1; return (s.token, s.handler) }
        if AudioCapture.isTesting { return token }
        do {
            try impl.beginRecording(gain: gain)
            handler?(token, .started(device: "", bluetooth: false))
            handler?(token, .micReady)
        } catch {
            handler?(token, .startFailed(error.localizedDescription))
        }
        return token
    }
    func endRecording() -> [Float] { impl.endRecording() }
    func snapshotSamples() -> [Float] { impl.snapshotSamples() }
    // The legacy engine counts monitor references; map the lease onto a single reference.
    func renewMonitoringLease() {
        guard !AudioCapture.isTesting, state.withLock({ s -> Bool in defer { s.monitoring = true }; return !s.monitoring }) else { return }
        impl.startMonitoring()
    }
    func endMonitoring() {
        if state.withLock({ s -> Bool in defer { s.monitoring = false }; return s.monitoring }) { impl.stopMonitoring() }
    }
    func releaseIfIdle() { impl.releaseIfIdle() }
    func selectDevice(uid: String?, modelUID: String?) { impl.selectDevice(uid: uid) }
    func shutdown() { impl.stop() }
}
