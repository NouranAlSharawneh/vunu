import Foundation
import AudioToolbox
import CoreAudio
import Synchronization

/// Everything the realtime callback touches. Immutable after setup except the atomics, and freed only after the unit
/// is disposed (an abandoned unit keeps it alive forever on purpose).
final class RenderContext: @unchecked Sendable {
    let channels: Int
    let maxFrames: Int
    let ring: SampleRing
    fileprivate(set) var unit: AudioUnit?
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private let storage: [UnsafeMutablePointer<Float>]
    private let interleaved: UnsafeMutablePointer<Float>

    /// Callbacks drop their data while false (set just before stop) or while `suspect` (the device format is changing).
    let active = Atomic<Bool>(true)
    let suspect = Atomic<Bool>(false)
    let inFlight = Atomic<Int>(0)
    let callbacks = Atomic<Int>(0)
    let renderErrors = Atomic<Int>(0)
    let overruns = Atomic<Int>(0)

    init(channels: Int, maxFrames: Int, ringSeconds: Double, hwRate: Double) {
        self.channels = channels
        self.maxFrames = maxFrames
        ring = SampleRing(capacity: Int(hwRate * ringSeconds) * channels)
        bufferList = AudioBufferList.allocate(maximumBuffers: channels)
        var ptrs: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<channels { let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames); p.initialize(repeating: 0, count: maxFrames); ptrs.append(p) }
        storage = ptrs
        interleaved = .allocate(capacity: maxFrames * channels)
        interleaved.initialize(repeating: 0, count: maxFrames * channels)
    }

    deinit {
        storage.forEach { $0.deallocate() }
        interleaved.deallocate()
        free(bufferList.unsafeMutablePointer)
    }

    /// Realtime thread. No allocation, no locks.
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>, _ frameCount: UInt32) -> OSStatus {
        guard let unit else { return noErr }
        let frames = Int(frameCount)
        guard frames <= maxFrames else { overruns.wrappingAdd(1, ordering: .relaxed); return noErr }
        // mDataByteSize must be reset on every call: AudioUnitRender shrinks it to what it wrote.
        for c in 0..<channels {
            bufferList[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * MemoryLayout<Float>.size), mData: storage[c])
        }
        let status = AudioUnitRender(unit, flags, ts, 1, frameCount, bufferList.unsafeMutablePointer)
        guard status == noErr else { renderErrors.wrappingAdd(1, ordering: .relaxed); return status }
        callbacks.wrappingAdd(1, ordering: .relaxed)
        guard active.load(ordering: .relaxed), !suspect.load(ordering: .relaxed) else { return noErr }
        if channels == 1 {
            if !ring.write(storage[0], count: frames) { overruns.wrappingAdd(1, ordering: .relaxed) }
        } else {
            let a = storage[0], b = storage[1]
            for i in 0..<frames { interleaved[i * 2] = a[i]; interleaved[i * 2 + 1] = b[i] }
            if !ring.write(interleaved, count: frames * 2) { overruns.wrappingAdd(1, ordering: .relaxed) }
        }
        return noErr
    }
}

/// C entry point for the AUHAL input callback.
private let halInputCallback: AURenderCallback = { refCon, flags, timeStamp, _, frameCount, _ in
    let ctx = Unmanaged<RenderContext>.fromOpaque(refCon).takeUnretainedValue()
    ctx.inFlight.wrappingAdd(1, ordering: .acquiringAndReleasing)
    defer { ctx.inFlight.wrappingSubtract(1, ordering: .acquiringAndReleasing) }
    return ctx.render(flags, timeStamp, frameCount)
}

enum HALError: Error, LocalizedError {
    case status(String, OSStatus)
    case notReady(String)
    var errorDescription: String? {
        switch self {
        case .status(let what, let st): "\(what) failed (\(st))"
        case .notReady(let why): why
        }
    }
}

/// One input-only AUHAL bound to one device, for one start…stop span. Never touches the output side, so the default
/// output device (e.g. a multipoint headset switching between Mac and phone) can't disturb it, and binding it to the
/// built-in mic never opens a Bluetooth mic.
///
/// Setup order follows TN2091: enable input / disable output → set the device → max frames → read the device format →
/// client format at the device rate (the input side does no sample-rate conversion) → channel map → callback → initialize.
final class HALInputUnit: @unchecked Sendable {
    let deviceID: AudioDeviceID
    let hwRate: Double
    let deviceChannels: Int
    let clientChannels: Int
    let bufferFrames: Int
    let context: RenderContext
    private let unit: AudioUnit
    private var disposed = false

    init(deviceID: AudioDeviceID, ringSeconds: Double = 10) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw HALError.notReady("HAL output unit not found") }
        var u: AudioUnit?
        try Self.check("AudioComponentInstanceNew", AudioComponentInstanceNew(comp, &u))
        guard let u else { throw HALError.notReady("no audio unit") }
        // Everything stays in locals until the last call that can fail: a throw after full initialization would run
        // deinit and dispose the unit a second time.
        let ctx: RenderContext, rate: Double, devCh: Int, clientCh: Int, frames: Int
        do {
            var on: UInt32 = 1, off: UInt32 = 0
            try Self.check("EnableIO input", AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4))
            try Self.check("EnableIO output", AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4))
            var dev = deviceID
            try Self.check("CurrentDevice", AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)))

            // Size for the largest buffer the device may use, not the current one.
            var range = AudioValueRange()
            var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
            var rangeAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            let rangeOK = AudioObjectGetPropertyData(deviceID, &rangeAddr, 0, nil, &rangeSize, &range) == noErr
            var maxFrames = UInt32(min(16_384, max(4_096, rangeOK ? Int(range.mMaximum) : 4_096)))
            _ = AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)
            frames = Int(maxFrames)

            // Device-side format, read fresh every time (a cached one records zeros after a rate change).
            var hw = AudioStreamBasicDescription()
            var hwSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check("device format", AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &hwSize))
            guard hw.mSampleRate > 0, hw.mChannelsPerFrame > 0 else {
                throw HALError.notReady("input not ready (\(hw.mSampleRate) Hz, \(hw.mChannelsPerFrame) ch)")
            }
            rate = hw.mSampleRate
            devCh = Int(hw.mChannelsPerFrame)

            // The device's preferred stereo pair (1-based), so a mic wired to channel 2 or a loopback on channel 1 is handled.
            var pair: [UInt32] = [1, 2]
            var pairSize = UInt32(MemoryLayout<UInt32>.size * 2)
            var pairAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelsForStereo, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(deviceID, &pairAddr, 0, nil, &pairSize, &pair)
            var mapped = devCh >= 2 ? 2 : 1
            if devCh > 1 {
                let a = Int32(max(1, min(Int(pair[0]), devCh)) - 1)
                let b = Int32(max(1, min(Int(pair[1]), devCh)) - 1)
                var map: [Int32] = [a, b]
                if AudioUnitSetProperty(u, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &map, UInt32(MemoryLayout<Int32>.size * 2)) != noErr {
                    mapped = min(2, devCh)   // no map: the first channels
                }
            }
            clientCh = mapped
            var client = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(mapped), mBitsPerChannel: 32, mReserved: 0)
            try Self.check("client format", AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

            ctx = RenderContext(channels: mapped, maxFrames: Int(maxFrames), ringSeconds: ringSeconds, hwRate: rate)
            ctx.unit = u
            var cb = AURenderCallbackStruct(inputProc: halInputCallback, inputProcRefCon: Unmanaged.passUnretained(ctx).toOpaque())
            try Self.check("input callback", AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try Self.check("AudioUnitInitialize", AudioUnitInitialize(u))
        } catch {
            AudioComponentInstanceDispose(u)
            throw error
        }
        self.deviceID = deviceID
        unit = u
        context = ctx
        hwRate = rate
        deviceChannels = devCh
        clientChannels = clientCh
        bufferFrames = frames
    }

    deinit { if !disposed { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) } }

    /// Loads the HAL output component once (no device is opened), so the first dictation after launch doesn't pay for it.
    static func warmUp() {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return }
        var u: AudioUnit?
        if AudioComponentInstanceNew(comp, &u) == noErr, let u { AudioComponentInstanceDispose(u) }
    }

    private static func check(_ what: String, _ status: OSStatus) throws {
        if status != noErr { throw HALError.status(what, status) }
    }

    /// Starts I/O. This is the call that turns the mic on (and, for a Bluetooth mic, switches the headset to HFP).
    func start() throws { try Self.check("AudioOutputUnitStart", AudioOutputUnitStart(unit)) }

    /// Stops I/O and waits for any callback still running. Apple documents the stop as synchronous off the I/O thread; the
    /// in-flight counter covers the cases where it reportedly isn't.
    func stop() {
        context.active.store(false, ordering: .releasing)
        AudioOutputUnitStop(unit)
        let deadline = Date().addingTimeInterval(0.2)
        while context.inFlight.load(ordering: .acquiring) > 0, Date() < deadline { usleep(1_000) }
    }

    /// Releases the device. After this the mic indicator is off and a Bluetooth headset can return to A2DP.
    func dispose() {
        guard !disposed else { return }
        disposed = true
        context.unit = nil
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }
}

/// HAL property listeners for the device being recorded plus system-wide changes. The exact block object is kept so it
/// can be removed; callbacks already queued after removal are dropped by the generation check in the engine.
final class HALListeners: @unchecked Sendable {
    private struct Registration { let object: AudioObjectID; var address: AudioObjectPropertyAddress }
    private var registrations: [Registration] = []
    private let block: AudioObjectPropertyListenerBlock
    private let queue: DispatchQueue

    init(deviceID: AudioDeviceID, queue: DispatchQueue, handler: @escaping @Sendable (AudioObjectPropertySelector) -> Void) {
        self.queue = queue
        block = { count, addresses in
            for i in 0..<Int(count) { handler(addresses[i].mSelector) }
        }
        let deviceProps: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            (kAudioDevicePropertyIOStoppedAbnormally, kAudioObjectPropertyScopeGlobal),
        ]
        for (sel, scope) in deviceProps { add(deviceID, sel, scope) }
        add(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        add(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyServiceRestarted, kAudioObjectPropertyScopeGlobal)
    }

    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(object, &addr, queue, block) == noErr { registrations.append(Registration(object: object, address: addr)) }
    }

    /// Must not be called on `queue`.
    func remove() {
        for var r in registrations { AudioObjectRemovePropertyListenerBlock(r.object, &r.address, queue, block) }
        registrations.removeAll()
        queue.sync {}   // let a callback that was already running finish
    }
}
