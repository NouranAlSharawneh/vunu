import Foundation
@preconcurrency import AVFoundation

/// Turns interleaved hardware-rate frames (1 or 2 channels) into 16 kHz mono, off the realtime thread.
///
/// - Downmix: averages the stereo pair, unless one side stays silent for the first 0.5 s (a mic wired to one channel), then
///   that side alone is used so the level isn't halved.
/// - Resample: one `AVAudioConverter` per processor. A converter that has seen `.endOfStream` produces nothing until reset,
///   so `flush()` ends this processor; make a new one for the next recording or format.
/// - Silence: counts consecutive raw (pre-gain) samples at or below one 16-bit step. A Bluetooth mic whose headset is busy
///   with another device, or the internal mic with the lid closed, delivers exactly that.
/// Confined to the capture drain queue; `@unchecked` because AVAudioConverter's input block is typed `@Sendable` even
/// though it runs synchronously inside `convert`.
final class CaptureProcessor: @unchecked Sendable {
    static let silenceThreshold: Float = 1.0 / 32768

    let hwRate: Double
    let channels: Int
    private let converter: AVAudioConverter
    private let inBuffer: AVAudioPCMBuffer
    private let outBuffer: AVAudioPCMBuffer
    private let maxChunk: Int

    enum ChannelMode: Equatable { case undecided, average, only(Int) }
    private(set) var channelMode: ChannelMode
    private var channelEnergy: [Double]
    private var framesSeen = 0
    private(set) var silentFrames = 0
    private(set) var heardSignal = false
    private var flushed = false

    /// Seconds of consecutive digital silence at the input.
    var silentSeconds: Double { Double(silentFrames) / hwRate }

    init?(hwRate: Double, channels: Int, maxChunkFrames: Int = 8192) {
        guard hwRate > 0, (1...2).contains(channels),
              let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hwRate, channels: 1, interleaved: false),
              let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: src, to: dst),
              let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(maxChunkFrames)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: AVAudioFrameCount(Double(maxChunkFrames) * AudioCapture.sampleRate / hwRate) + 256)
        else { return nil }
        conv.sampleRateConverterQuality = .max
        self.hwRate = hwRate; self.channels = channels; maxChunk = maxChunkFrames
        converter = conv; inBuffer = inBuf; outBuffer = outBuf
        channelMode = channels == 1 ? .only(0) : .undecided
        channelEnergy = Array(repeating: 0, count: channels)
    }

    /// Converts `frames` interleaved frames; returns 16 kHz mono (pre-gain).
    func process(interleaved src: UnsafePointer<Float>, frames: Int) -> [Float] {
        guard !flushed, frames > 0 else { return [] }
        var out: [Float] = []
        var offset = 0
        while offset < frames {
            let n = min(maxChunk, frames - offset)
            downmix(src + offset * channels, frames: n)
            out += convert(final: false)
            offset += n
        }
        return out
    }

    /// Drains what the converter still holds. Ends this processor.
    func flush() -> [Float] {
        guard !flushed else { return [] }
        flushed = true
        inBuffer.frameLength = 0
        return convert(final: true)
    }

    private func downmix(_ src: UnsafePointer<Float>, frames: Int) {
        let dst = inBuffer.floatChannelData![0]
        if case .undecided = channelMode {
            for c in 0..<channels { var e = 0.0; for i in 0..<frames { let v = Double(src[i * channels + c]); e += v * v }; channelEnergy[c] += e }
            framesSeen += frames
            if Double(framesSeen) >= hwRate * 0.5 { decideChannels() }
        }
        switch channelMode {
        case .only(let c): for i in 0..<frames { dst[i] = src[i * channels + c] }
        default:
            if channels == 1 { for i in 0..<frames { dst[i] = src[i] } }
            else { for i in 0..<frames { dst[i] = (src[i * 2] + src[i * 2 + 1]) * 0.5 } }
        }
        inBuffer.frameLength = AVAudioFrameCount(frames)
        // Silence streak on the raw signal.
        var loudest: Float = 0
        for i in 0..<frames { loudest = max(loudest, abs(dst[i])) }
        if loudest <= Self.silenceThreshold { silentFrames += frames } else { silentFrames = 0; heardSignal = true }
    }

    private func decideChannels() {
        guard channels == 2 else { channelMode = .only(0); return }
        let (l, r) = (channelEnergy[0], channelEnergy[1])
        // One side ≥ 20 dB quieter than the other (and the other has signal): use the live side alone.
        if l > 1e-9 || r > 1e-9 {
            if l < r * 0.01 { channelMode = .only(1); return }
            if r < l * 0.01 { channelMode = .only(0); return }
        }
        channelMode = .average
    }

    private func convert(final: Bool) -> [Float] {
        var result: [Float] = []
        nonisolated(unsafe) var supplied = false
        while true {
            outBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, inStatus in
                if final { inStatus.pointee = .endOfStream; return nil }
                if supplied || self.inBuffer.frameLength == 0 { inStatus.pointee = .noDataNow; return nil }
                supplied = true
                inStatus.pointee = .haveData
                return self.inBuffer
            }
            let n = Int(outBuffer.frameLength)
            if n > 0, let ch = outBuffer.floatChannelData { result.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n)) }
            // Keep pulling while the converter fills whole output buffers; stop on no data / end / error.
            if status != .haveData || n == 0 { break }
            if !final && supplied && n < Int(outBuffer.frameCapacity) { break }
        }
        return result
    }
}
