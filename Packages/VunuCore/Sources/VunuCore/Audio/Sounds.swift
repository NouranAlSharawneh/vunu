import Foundation
import AVFoundation
import AppKit

/// Start "ping" and success "tick" played via NSSound at low volume. Files are synthesized once into Application Support.
@MainActor
public final class Sounds {
    public static let shared = Sounds()
    private var ping: NSSound?
    private var tick: NSSound?
    private var shake: NSSound?

    private init() {
        let dir = Paths.appSupport.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ping = load(dir.appendingPathComponent("ping.wav")) { Self.synth(url: $0, tones: [(880, 0.0, 0.09), (1320, 0.05, 0.10)], amp: 0.35) }
        tick = load(dir.appendingPathComponent("tick.wav")) { Self.synth(url: $0, tones: [(1568, 0.0, 0.05)], amp: 0.3) }
        shake = load(dir.appendingPathComponent("shake.wav")) { Self.synth(url: $0, tones: [(330, 0.0, 0.08)], amp: 0.25) }
    }

    private func load(_ url: URL, make: (URL) -> Void) -> NSSound? {
        if !FileManager.default.fileExists(atPath: url.path) { make(url) }
        let s = NSSound(contentsOf: url, byReference: false)
        s?.volume = 0.35
        return s
    }

    public func playPing() { guard Preferences.shared.soundEffects else { return }; ping?.stop(); ping?.play() }
    public func playTick() { guard Preferences.shared.soundEffects else { return }; tick?.stop(); tick?.play() }
    public func playError() { guard Preferences.shared.soundEffects else { return }; shake?.stop(); shake?.play() }

    /// Write a tiny 44.1 kHz mono WAV made of decaying sine tones.
    private static func synth(url: URL, tones: [(freq: Double, start: Double, dur: Double)], amp: Float) {
        let sr = 44_100.0
        let total = tones.map { $0.start + $0.dur }.max() ?? 0.1
        let frames = Int(sr * (total + 0.02))
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let p = buf.floatChannelData![0]
        for i in 0..<frames { p[i] = 0 }
        for t in tones {
            let s0 = Int(t.start * sr), n = Int(t.dur * sr)
            for i in 0..<n where s0 + i < frames {
                let x = Double(i) / sr
                let env = Float(exp(-x * 30)) * Float(min(1, Double(i) / (sr * 0.004)))
                p[s0 + i] += amp * env * Float(sin(2 * .pi * t.freq * x))
            }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buf)
        } catch { Log.audio.error("sound synth failed: \(error)") }
    }
}
