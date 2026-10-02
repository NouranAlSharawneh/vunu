import Foundation
import CoreAudio
import os

/// Mic capture on an input-only Core Audio unit bound to the resolved device (see `HALInputUnit`).
///
/// Threads:
/// - `controlQueue`: every HAL call (create, start, stop, dispose, listeners). A watchdog abandons an operation that hangs
///   (a disappearing Bluetooth device can block a HAL call for seconds or forever): the app gets a fresh queue for the next
///   key-down, and the hung call, if it ever returns, tears down its own unit so the mic can't be left on.
/// - realtime: the unit's callback copies frames into a lock-free ring.
/// - `sampleQueue`: drains the ring every 20 ms (downmix, 16 kHz conversion, gain, level) and runs the watchdogs. It never
///   makes HAL calls, so `endRecording()` can wait on it from the main thread.
/// - `listenerQueue`: HAL property listeners.
/// Shared state lives in `state` (a lock); nothing else is touched across threads.
final class HALCaptureEngine: CaptureEngine, @unchecked Sendable {
    private struct State: Sendable {
        var token: CaptureToken = 0
        var recording = false
        var samples: [Float] = []
        var level: Float = 0
        var peak: Float = 0
        var gain: Float = 1
        var recordStartedAt: TimeInterval = 0
        var firstSampleAt: TimeInterval = 0
        var leaseUntil: TimeInterval = 0
        var micReadyFor: CaptureToken = 0
        var silentReportedFor: CaptureToken = 0
        var noInputRestartFor: CaptureToken = 0
        var noInputReportedFor: CaptureToken = 0
        var formatRestartsFor: CaptureToken = 0
        var formatRestarts = 0
        var preferredUID: String?
        var preferredModelUID: String?
        var control = DispatchQueue(label: "dev.nunu.vunu.audio.control", qos: .userInitiated)
        var stream: Stream?
        var streamGen = 0
        var starting = false
        var hungOps = 0
        var releaseGen = 0
        var releasePending = false
        var handler: (@Sendable (CaptureToken, CaptureEvent) -> Void)?
    }

    /// One running unit on one device.
    final class Stream: @unchecked Sendable {
        let unit: HALInputUnit
        let device: AudioInputDevice
        let reason: InputChoice.Reason
        let gen: Int
        let startedAt: TimeInterval
        var listeners: HALListeners?   // control queue only
        init(unit: HALInputUnit, device: AudioInputDevice, reason: InputChoice.Reason, gen: Int, startedAt: TimeInterval) {
            self.unit = unit; self.device = device; self.reason = reason; self.gen = gen; self.startedAt = startedAt
        }
    }

    /// A control-queue operation the watchdog can abandon. Fields are read and written under `state`'s lock.
    private final class Op: @unchecked Sendable {
        var finished = false
        var abandoned = false
        var slow = false       // Bluetooth/Continuity: allow 5 s instead of 3 s
        var extended = false
    }

    /// Drain-side state; `sampleQueue` only.
    private final class Drain: @unchecked Sendable {
        let stream: Stream
        var processor: CaptureProcessor
        let scratch: UnsafeMutablePointer<Float>
        let scratchCount: Int
        var lastCallbacks = 0
        var lastCallbackChange: TimeInterval
        var stallReported = false
        init(stream: Stream, processor: CaptureProcessor) {
            self.stream = stream; self.processor = processor
            scratchCount = 4_096 * stream.unit.clientChannels
            scratch = .allocate(capacity: scratchCount)
            lastCallbackChange = Self.now
        }
        deinit { scratch.deallocate() }
        static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let sampleQueue = DispatchQueue(label: "dev.nunu.vunu.audio.samples", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "dev.nunu.vunu.audio.listeners", qos: .userInitiated)
    private var drain: Drain?                      // sampleQueue
    private var timer: DispatchSourceTimer?        // sampleQueue
    private var formatWork: DispatchWorkItem?      // listenerQueue
    private let activityLock = NSLock()
    private var activity: NSObjectProtocol?

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static func ms(_ seconds: TimeInterval) -> Int { Int(seconds * 1000) }

    init() {
        guard !AudioCapture.isTesting else { return }
        state.withLock { $0.control }.async { HALInputUnit.warmUp() }
    }

    // MARK: CaptureEngine

    func setEventHandler(_ handler: @escaping @Sendable (CaptureToken, CaptureEvent) -> Void) { state.withLock { $0.handler = handler } }

    var level: Float { state.withLock { $0.level } }
    var peak: Float { state.withLock { $0.peak } }
    var isRecording: Bool { state.withLock { $0.recording } }
    var isRunning: Bool { state.withLock { $0.stream != nil } }
    var recordedSampleCount: Int { state.withLock { $0.samples.count } }
    var firstSampleLatencyMs: Double { state.withLock { $0.firstSampleAt > 0 ? ($0.firstSampleAt - $0.recordStartedAt) * 1000 : 0 } }

    func beginRecording(gain: Float) -> CaptureToken {
        let (token, hung) = state.withLock { s -> (CaptureToken, Bool) in
            s.token += 1
            s.recording = true
            s.samples.removeAll(keepingCapacity: true)
            s.samples.reserveCapacity(Int(AudioCapture.sampleRate) * 30)
            s.gain = gain
            s.level = 0; s.peak = 0
            s.recordStartedAt = Self.now
            s.firstSampleAt = 0
            s.releaseGen += 1; s.releasePending = false   // cancels a pending release (fn+⌃ → push-to-talk churn)
            return (s.token, s.hungOps > 0)
        }
        if hung {
            Log.file("audio", "start refused: an earlier audio call is still hung")
            emit(token, .startFailed("The audio system isn't responding"))
            return token
        }
        ensureRunning()
        return token
    }

    func endRecording() -> [Float] {
        sampleQueue.sync {
            guard let d = drain else { return }
            drainRing(d)
            deliver(d.processor.flush(), d)
            // A converter that saw end-of-stream produces nothing more: the next dictation on this stream needs a new one.
            if let fresh = CaptureProcessor(hwRate: d.stream.unit.hwRate, channels: d.stream.unit.clientChannels) { d.processor = fresh }
        }
        return state.withLock { s in
            s.recording = false
            let out = s.samples
            s.samples = []
            s.level = 0
            return out
        }
    }

    func snapshotSamples() -> [Float] { state.withLock { $0.samples } }

    func renewMonitoringLease() {
        let needStart = state.withLock { s -> Bool in
            let now = Self.now
            if s.stream != nil, s.leaseUntil - now > 1.5 { return false }   // renewed recently
            s.leaseUntil = now + 2
            s.releaseGen += 1; s.releasePending = false
            return s.stream == nil
        }
        if needStart { ensureRunning() }
    }

    func endMonitoring() {
        state.withLock { $0.leaseUntil = 0 }
        releaseIfIdle()
    }

    func releaseIfIdle() { scheduleRelease(after: 0.5) }

    func selectDevice(uid: String?, modelUID: String?) {
        let (changed, recording, running) = state.withLock { s -> (Bool, Bool, Bool) in
            let changed = s.preferredUID != uid || s.preferredModelUID != modelUID
            s.preferredUID = uid; s.preferredModelUID = modelUID
            return (changed, s.recording, s.stream != nil)
        }
        // Never switch mid-dictation; an idle stream (the Settings meter) moves to the new mic now.
        guard changed, running, !recording else { return }
        runControl("switch device") { [weak self] op in self?.restartOp(op, reason: "device selection changed", gen: nil) }
    }

    func shutdown() {
        runControl("shutdown") { [weak self] op in self?.releaseOp(op, reason: "quit", force: true) }
    }

    // MARK: control operations

    private func wantsRunning(_ s: State) -> Bool { s.recording || s.leaseUntil > Self.now }

    private func ensureRunning() {
        guard !AudioCapture.isTesting else { return }
        let go = state.withLock { s -> Bool in
            guard s.stream == nil, !s.starting, s.hungOps == 0 else { return false }
            s.starting = true
            return true
        }
        guard go else { return }
        runControl("start") { [weak self] op in self?.startOp(op) }
    }

    private func runControl(_ name: String, _ body: @escaping @Sendable (Op) -> Void) {
        let op = Op()
        let queue = state.withLock { $0.control }
        queue.async { [weak self] in
            body(op)
            guard let self else { return }
            let lateReturn = self.state.withLock { s -> Bool in
                op.finished = true
                if op.abandoned { s.hungOps -= 1; return true }
                return false
            }
            if lateReturn { Log.file("audio", "\(name) returned after being abandoned; its unit was released") }
        }
        watch(op, name, after: 3)
    }

    /// Abandons an operation still running after 3 s (5 s for Bluetooth/Continuity).
    private func watch(_ op: Op, _ name: String, after delay: Double) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            enum Action { case done, extend, abandoned(CaptureToken) }
            let action = self.state.withLock { s -> Action in
                if op.finished { return .done }
                if op.slow, !op.extended { op.extended = true; return .extend }
                op.abandoned = true
                s.hungOps += 1
                s.control = DispatchQueue(label: "dev.nunu.vunu.audio.control", qos: .userInitiated)
                s.starting = false
                s.stream = nil   // whatever unit the hung call holds now belongs to it
                return .abandoned(s.token)
            }
            switch action {
            case .done: return
            case .extend: self.watch(op, name, after: 2)
            case .abandoned(let token):
                self.sampleQueue.async { self.uninstallDrain(final: true) }
                self.endActivity()
                Log.file("audio", "\(name) hung for more than \(op.slow ? 5 : 3) s; abandoned it")
                if self.isRecording { self.emit(token, .startFailed("The audio system isn't responding")) }
            }
        }
    }

    private func isAbandoned(_ op: Op) -> Bool { state.withLock { _ in op.abandoned } }

    private func startOp(_ op: Op) {
        defer { state.withLock { s in if !op.abandoned { s.starting = false } } }
        let (wanted, uid, model) = state.withLock { s in (wantsRunning(s), s.preferredUID, s.preferredModelUID) }
        guard wanted else { return }
        let t0 = Self.now
        guard let choice = AudioDevices.resolveCurrentInput(preferredUID: uid, preferredModelUID: model) else {
            Log.file("audio", "mic start failed: no input device")
            emitCurrent(.startFailed("No microphone found"))
            return
        }
        if choice.device.isRemote { state.withLock { _ in op.slow = true } }
        let unit: HALInputUnit
        do { unit = try HALInputUnit(deviceID: choice.device.id) } catch {
            if isAbandoned(op) { return }
            Log.file("audio", "mic setup failed on \(choice.device.name) [\(choice.device.transport.rawValue)]: \(error.localizedDescription)")
            emitCurrent(.startFailed(error.localizedDescription))
            return
        }
        if isAbandoned(op) { unit.dispose(); return }
        let t1 = Self.now
        guard let processor = CaptureProcessor(hwRate: unit.hwRate, channels: unit.clientChannels) else {
            unit.dispose()
            emitCurrent(.startFailed("Unsupported input format (\(Int(unit.hwRate)) Hz)"))
            return
        }
        let gen = state.withLock { s -> Int in s.streamGen += 1; return s.streamGen }
        let stream = Stream(unit: unit, device: choice.device, reason: choice.reason, gen: gen, startedAt: Self.now)
        sampleQueue.sync { installDrain(Drain(stream: stream, processor: processor)) }
        do { try unit.start() } catch {
            sampleQueue.sync { uninstallDrain(final: false, only: stream) }
            unit.dispose()
            if isAbandoned(op) { return }
            Log.file("audio", "mic start failed on \(choice.device.name): \(error.localizedDescription)")
            emitCurrent(.startFailed(error.localizedDescription))
            return
        }
        let published = state.withLock { s -> Bool in
            guard !op.abandoned else { return false }
            s.stream = stream
            return true
        }
        guard published else {
            // The watchdog gave up on us while start() blocked: we own this unit now and must not leave the mic on.
            unit.stop(); unit.dispose()
            return
        }
        stream.listeners = HALListeners(deviceID: choice.device.id, queue: listenerQueue) { [weak self] selector in
            self?.halChanged(selector, gen: gen)
        }
        beginActivity()
        let t2 = Self.now
        Log.file("audio", "mic start: \(choice.device.name) [\(choice.device.transport.rawValue)] (\(choice.reason.rawValue)), \(Int(unit.hwRate)) Hz, \(unit.deviceChannels)→\(unit.clientChannels) ch, max \(unit.bufferFrames) frames; setup \(Self.ms(t1 - t0)) ms, start \(Self.ms(t2 - t1)) ms; default in \(AudioDevices.describe(AudioDevices.defaultInputDeviceID())), out \(AudioDevices.describe(AudioDevices.defaultOutputDeviceID())); lid \(Clamshell.isClosed ? "closed" : "open")")
        emitCurrent(.started(device: choice.device.name, bluetooth: choice.device.isBluetooth))
        if !state.withLock({ wantsRunning($0) }) { scheduleRelease(after: 0.5) }
    }

    /// Stops and releases the current stream unless something still needs it (or `force`).
    private func releaseOp(_ op: Op, reason: String, force: Bool = false) {
        let stream = state.withLock { s -> Stream? in
            s.releasePending = false
            guard force || !wantsRunning(s) else { return nil }
            let st = s.stream
            s.stream = nil
            return st
        }
        guard let stream else { return }
        teardown(stream, reason: reason)
    }

    /// Tears down `gen` (or the current stream) and starts again if still wanted — format change, no-input retry, device switch.
    private func restartOp(_ op: Op, reason: String, gen: Int?) {
        let (stream, canStart) = state.withLock { s -> (Stream?, Bool) in
            guard let st = s.stream, gen == nil || st.gen == gen else { return (nil, false) }
            s.stream = nil
            let canStart = s.hungOps == 0 && !s.starting
            if canStart { s.starting = true }
            return (st, canStart)
        }
        guard let stream else { return }
        teardown(stream, reason: reason)
        if canStart { startOp(op) }
    }

    private func lostOp(_ op: Op, reason: String, gen: Int) {
        let (stream, token, recording) = state.withLock { s -> (Stream?, CaptureToken, Bool) in
            guard let st = s.stream, st.gen == gen else { return (nil, s.token, s.recording) }
            s.stream = nil
            return (st, s.token, s.recording)
        }
        guard let stream else { return }
        teardown(stream, reason: reason)
        if recording { emit(token, .deviceLost(reason)) }
    }

    private func teardown(_ stream: Stream, reason: String) {
        stream.listeners?.remove()
        stream.listeners = nil
        stream.unit.stop()
        sampleQueue.sync { uninstallDrain(final: true, only: stream) }   // keeps what was captured
        stream.unit.dispose()
        endActivity()
        let ctx = stream.unit.context
        Log.file("audio", "mic released (\(reason)) after \(String(format: "%.1f", Self.now - stream.startedAt)) s; \(ctx.callbacks.load(ordering: .relaxed)) callbacks, \(ctx.renderErrors.load(ordering: .relaxed)) render errors, \(ctx.overruns.load(ordering: .relaxed)) overruns")
    }

    private func scheduleRelease(after delay: Double) {
        let gen = state.withLock { s -> Int in s.releaseGen += 1; s.releasePending = true; return s.releaseGen }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.state.withLock({ $0.releaseGen == gen && $0.stream != nil }) else { return }
            self.runControl("release") { [weak self] op in self?.releaseOp(op, reason: "idle") }
        }
    }

    // MARK: HAL changes

    private func halChanged(_ selector: AudioObjectPropertySelector, gen: Int) {
        guard let stream = state.withLock({ s in s.stream?.gen == gen ? s.stream : nil }) else { return }
        switch selector {
        case kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyStreamConfiguration:
            // Stop feeding the ring at once (frames at a new rate must not go through the old converter), restart after 300 ms quiet.
            stream.unit.context.suspect.store(true, ordering: .releasing)
            formatWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.runControl("format restart") { [weak self] op in self?.formatRestartOp(op, gen: gen) }
            }
            formatWork = work
            listenerQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
        case kAudioDevicePropertyDeviceIsAlive:
            if !AudioDevices.deviceExists(stream.device.id) { gone("device disconnected", gen) }
        case kAudioDevicePropertyIOStoppedAbnormally:
            gone("input stopped abnormally", gen)
        case kAudioHardwarePropertyDevices:
            if !AudioDevices.deviceExists(stream.device.id) { gone("device removed", gen) }
        case kAudioHardwarePropertyServiceRestarted:
            gone("audio service restarted", gen)
        default: break
        }
    }

    private func gone(_ reason: String, _ gen: Int) {
        runControl("device lost") { [weak self] op in self?.lostOp(op, reason: reason, gen: gen) }
    }

    private func formatRestartOp(_ op: Op, gen: Int) {
        let (allowed, token, recording) = state.withLock { s -> (Bool, CaptureToken, Bool) in
            if s.formatRestartsFor != s.token { s.formatRestartsFor = s.token; s.formatRestarts = 0 }
            s.formatRestarts += 1
            return (s.formatRestarts <= 3, s.token, s.recording)
        }
        guard allowed else { lostOp(op, reason: "format kept changing", gen: gen); return }
        let before = state.withLock { $0.stream?.unit.hwRate }
        restartOp(op, reason: "format changed", gen: gen)
        let after = state.withLock { $0.stream?.unit.hwRate }
        Log.file("audio", "format changed: \(before.map { "\(Int($0))" } ?? "?") → \(after.map { "\(Int($0))" } ?? "?") Hz")
        if recording, after != nil { emit(token, .formatChanged) }
    }

    // MARK: draining (sampleQueue)

    private func installDrain(_ d: Drain) {
        uninstallDrain(final: true)
        drain = d
        let t = DispatchSource.makeTimerSource(queue: sampleQueue)
        t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    /// `only`: leave the drain alone unless it belongs to that stream (a hung teardown returning late must not remove a
    /// newer stream's drain).
    private func uninstallDrain(final: Bool, only stream: Stream? = nil) {
        guard let d = drain, stream == nil || d.stream === stream else { return }
        timer?.cancel(); timer = nil
        drain = nil
        drainRing(d)
        if final { deliver(d.processor.flush(), d) }
    }

    private func tick() {
        guard let d = drain else { return }
        drainRing(d)
        watchdogs(d)
        let idle = state.withLock { s in !wantsRunning(s) && !s.releasePending && s.stream != nil }
        if idle { scheduleRelease(after: 0.5) }
    }

    private func drainRing(_ d: Drain) {
        let ctx = d.stream.unit.context
        while true {
            let n = ctx.ring.read(into: d.scratch, max: d.scratchCount)
            if n == 0 { break }
            deliver(d.processor.process(interleaved: d.scratch, frames: n / ctx.channels), d)
        }
    }

    private func deliver(_ chunk: [Float], _ d: Drain) {
        guard !chunk.isEmpty else { return }
        let now = Self.now
        let gain = state.withLock { $0.gain }
        var out = chunk
        if gain != 1 { for i in out.indices { out[i] = max(-1, min(1, out[i] * gain)) } }
        var sum: Float = 0, pk: Float = 0
        for v in out { sum += v * v; pk = max(pk, abs(v)) }
        let rms = sqrt(sum / Float(out.count))
        // map RMS (~0.005 quiet … 0.3 loud) to 0…1 with a soft log curve
        let mapped = min(1, max(0, (log10(max(rms, 1e-5)) + 4) / 3.2))
        let discard = now < d.stream.startedAt + 0.04   // the first 40 ms can carry a start-up pop
        let samples = out, chunkPeak = pk
        state.withLock { s in
            if s.recording && !discard {
                if s.firstSampleAt == 0 { s.firstSampleAt = now }
                s.samples.append(contentsOf: samples)
            }
            s.level = mapped > s.level ? mapped : s.level * 0.55 + mapped * 0.45
            s.peak = max(s.peak * 0.9, chunkPeak)
        }
    }

    private func watchdogs(_ d: Drain) {
        let now = Self.now
        let callbacks = d.stream.unit.context.callbacks.load(ordering: .relaxed)
        if callbacks != d.lastCallbacks { d.lastCallbacks = callbacks; d.lastCallbackChange = now }
        enum Action { case none, restart, noInput, ready, silent }
        let remote = d.stream.device.isRemote
        let action = state.withLock { s -> Action in
            guard s.recording else { return .none }
            if callbacks == 0 {
                // Built-in/USB deliver within ~100 ms; Bluetooth needs 1–3 s to switch profiles. One restart, then report.
                guard now - d.stream.startedAt > (remote ? 2.5 : 1.0) else { return .none }
                if s.noInputRestartFor != s.token { s.noInputRestartFor = s.token; return .restart }
                if s.noInputReportedFor != s.token { s.noInputReportedFor = s.token; return .noInput }
                return .none
            }
            if d.processor.heardSignal, s.micReadyFor != s.token { s.micReadyFor = s.token; return .ready }
            // Only a mic that has never sent anything: one with a noise gate can legitimately send zeros between words.
            if !d.processor.heardSignal, d.processor.silentSeconds >= 1.5, s.silentReportedFor != s.token { s.silentReportedFor = s.token; return .silent }
            return .none
        }
        let token = state.withLock { $0.token }
        switch action {
        case .none: break
        case .restart:
            Log.file("audio", "no audio from \(d.stream.device.name) after \(Self.ms(now - d.stream.startedAt)) ms; restarting once")
            let gen = d.stream.gen
            runControl("no-input restart") { [weak self] op in self?.restartOp(op, reason: "no input", gen: gen) }
        case .noInput:
            Log.file("audio", "no audio from \(d.stream.device.name) after a restart")
            emit(token, .noInput)
        case .ready:
            emit(token, .micReady)
        case .silent:
            let lid = d.stream.device.isInternalMic && Clamshell.isClosed
            Log.file("audio", "\(d.stream.device.name) is delivering digital silence\(lid ? " (lid closed)" : "")")
            emit(token, .silentInput(device: d.stream.device.name, lidClosed: lid))
        }
        // Callbacks stopped after flowing: the device went away without telling us (phone took the headset, driver stall).
        if callbacks > 0, !d.stallReported, now - d.lastCallbackChange > 1.0, isRecording {
            d.stallReported = true
            Log.file("audio", "input from \(d.stream.device.name) stalled")
            gone("input stalled", d.stream.gen)
        }
    }

    // MARK: events, App Nap

    private func emit(_ token: CaptureToken, _ event: CaptureEvent) {
        let handler = state.withLock { $0.handler }
        handler?(token, event)
    }

    private func emitCurrent(_ event: CaptureEvent) {
        let (token, recording) = state.withLock { ($0.token, $0.recording) }
        if recording { emit(token, event) }
    }

    /// Keeps App Nap from throttling the 20 ms drain while the mic runs (Vunu is a background accessory app).
    private func beginActivity() {
        activityLock.lock(); defer { activityLock.unlock() }
        if activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Recording dictation") }
    }

    private func endActivity() {
        activityLock.lock(); defer { activityLock.unlock() }
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }
}
