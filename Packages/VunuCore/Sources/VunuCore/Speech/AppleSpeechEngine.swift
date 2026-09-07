import Foundation
import Speech
@preconcurrency import AVFoundation

/// Apple's on-device SpeechAnalyzer / SpeechTranscriber (macOS 26). Zero download for installed locales;
/// batch transcription of a sample buffer, plus a streaming preview session for the pill.
public actor AppleSpeechEngine: TranscriptionEngine {
    public let kind: SttEngineKind = .appleSpeech
    private var locale: Locale
    private var loaded = false

    public init(locale: Locale = Locale(identifier: "en-US")) { self.locale = locale }

    public var isLoaded: Bool { loaded }

    public static func supportedLocales() async -> [Locale] { await SpeechTranscriber.supportedLocales }
    public static func installedLocales() async -> [Locale] { await SpeechTranscriber.installedLocales }

    public func setLocale(_ l: Locale) { locale = l }

    public func load(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            progress(0.1, "Downloading \(locale.identifier) speech assets…")
            try await req.downloadAndInstall()
        }
        loaded = true
        progress(1, "Ready")
    }

    public func unload() async { loaded = false }

    public func transcribe(_ samples: [Float], languageHint: String?) async throws -> TranscriptionResult {
        let sw = Stopwatch()
        let loc = languageHint.map { Locale(identifier: $0) } ?? locale
        let transcriber = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw VunuError.engineUnavailable("Apple Speech format") }
        guard let buffer = Self.makeBuffer(samples, format: fmt) else { throw VunuError.noAudio }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let collector = Task { () -> String in
            var text = ""
            for try await r in transcriber.results where r.isFinal { text += String(r.text.characters) }
            return text
        }
        try await analyzer.start(inputSequence: stream)
        cont.yield(AnalyzerInput(buffer: buffer))
        cont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await collector.value
        return TranscriptionResult(text: text.trimmed, language: loc.identifier, confidence: 1, processingMs: sw.elapsedMs)
    }

    /// Convert 16 kHz Float32 mono to the analyzer's preferred format.
    nonisolated static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: false),
              let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if format.sampleRate == src.sampleRate && format.channelCount == 1 && format.commonFormat == .pcmFormatFloat32 { return inBuf }
        guard let conv = AVAudioConverter(from: src, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * format.sampleRate / src.sampleRate) + 64) else { return nil }
        var done = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true; status.pointee = .haveData; return inBuf
        }
        return err == nil ? out : nil
    }
}

/// Live preview: streams mic buffers into SpeechTranscriber with volatile results while the key is held.
public actor LivePreviewSession {
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var task: Task<Void, Never>?
    public private(set) var text = ""
    private let onText: @Sendable (String) -> Void

    public init(onText: @escaping @Sendable (String) -> Void) { self.onText = onText }

    public func start(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        let a = SpeechAnalyzer(modules: [transcriber])
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        continuation = cont
        analyzer = a
        let cb = onText
        task = Task {
            var finalText = ""
            do {
                for try await r in transcriber.results {
                    let s = String(r.text.characters)
                    if r.isFinal { finalText += s; cb(finalText) } else { cb(finalText + s) }
                }
            } catch {}
        }
        try await a.start(inputSequence: stream)
    }

    public func feed(_ samples: [Float]) {
        guard let format, let buf = AppleSpeechEngine.makeBuffer(samples, format: format) else { return }
        continuation?.yield(AnalyzerInput(buffer: buf))
    }

    public func stop() async {
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        task?.cancel()
        analyzer = nil; continuation = nil; task = nil
    }
}
