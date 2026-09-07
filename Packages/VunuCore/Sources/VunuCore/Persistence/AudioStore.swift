import Foundation
@preconcurrency import AVFoundation

/// Saves session audio as 16 kHz mono FLAC and garbage-collects by retention policy.
public enum AudioStore {
    public static func save(_ samples: [Float], id: String = UUID().uuidString) -> URL? {
        guard !samples.isEmpty else { return nil }
        let url = Paths.audio.appendingPathComponent("\(id).flac")
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: AudioCapture.sampleRate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buf)
            return url
        } catch {
            Log.persistence.error("audio save failed: \(error)")
            return nil
        }
    }

    /// Load a FLAC/WAV file back as 16 kHz mono Float32 samples.
    public static func load(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let src = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: false),
              let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try? file.read(into: inBuf)
        if src.sampleRate == target.sampleRate && src.channelCount == 1, let ch = inBuf.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(inBuf.frameLength)))
        }
        guard let conv = AVAudioConverter(from: src, to: target) else { return nil }
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * target.sampleRate / src.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var done = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true; status.pointee = .haveData; return inBuf
        }
        guard let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    public static func delete(_ path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Delete audio older than the retention window.
    public static func collectGarbage(retention: AudioRetention) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.audio, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let maxAge: TimeInterval
        switch retention { case .fourteenDays: maxAge = 14 * 86_400; case .oneDay: maxAge = 86_400; case .never: maxAge = 0 }
        let cutoff = Date().addingTimeInterval(-maxAge)
        var removed = 0
        for f in files {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mod < cutoff { try? fm.removeItem(at: f); removed += 1 }
        }
        if removed > 0 { Log.persistence.info("audio GC removed \(removed) files") }
    }
}
