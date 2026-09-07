import Foundation
import FluidAudio

/// NVIDIA Parakeet TDT 0.6B (v3 multilingual / v2 English) via FluidAudio CoreML. Kept resident after load.
public actor ParakeetEngine: TranscriptionEngine {
    public let kind: SttEngineKind
    private let version: AsrModelVersion
    private var manager: AsrManager?
    private var decoderState: TdtDecoderState?
    private var loadTask: Task<Void, Error>?

    public init(kind: SttEngineKind) {
        self.kind = kind
        self.version = kind == .parakeetV2 ? .v2 : .v3
    }

    public var isLoaded: Bool { manager != nil }

    /// FluidAudio resolves `<parent>/<repo folder>`; keep the folder name equal to the repo folder.
    public var modelDirectory: URL { Paths.models.appendingPathComponent(kind == .parakeetV2 ? "parakeet-tdt-0.6b-v2" : "parakeet-tdt-0.6b-v3", isDirectory: true) }

    public var isDownloaded: Bool { AsrModels.modelsExist(at: modelDirectory, version: version) }

    public func load(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        if manager != nil { return }
        if let t = loadTask { try await t.value; return }   // join an in-flight load instead of racing it
        let t = Task { try await self.performLoad(progress: progress) }
        loadTask = t
        defer { loadTask = nil }
        try await t.value
    }

    private func performLoad(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let sw = Stopwatch()
        progress(0, "Preparing…")
        let dir = modelDirectory
        let models = try await AsrModels.downloadAndLoad(to: dir, version: version) { p in
            let label: String
            switch p.phase {
            case .listing: label = "Contacting Hugging Face…"
            case .downloading(let done, let total): label = "Downloading model \(done)/\(total)…"
            case .compiling(let name): label = "Compiling \(name)…"
            }
            progress(p.fractionCompleted * 0.9, label)
        }
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
        decoderState = TdtDecoderState.make()
        progress(0.95, "Warming up…")
        // 1 s silent warmup so CoreML compiles/allocates before the first real dictation
        var st = TdtDecoderState.make()
        _ = try? await m.transcribe([Float](repeating: 0, count: 16_000), decoderState: &st)
        progress(1, "Ready")
        Log.models.info("parakeet \(self.kind.rawValue) loaded in \(Int(sw.elapsedMs)) ms")
    }

    public func unload() async {
        await manager?.cleanup()
        manager = nil
        decoderState = nil
    }

    public func transcribe(_ samples: [Float], languageHint: String?) async throws -> TranscriptionResult {
        guard let manager else { throw VunuError.modelNotLoaded(kind.title) }
        let sw = Stopwatch()
        // pad very short clips so the encoder gets ≥ 0.5 s
        var input = samples
        if input.count < 8_000 { input.append(contentsOf: [Float](repeating: 0, count: 8_000 - input.count)) }
        var state = TdtDecoderState.make()
        let lang = languageHint.flatMap { Language(rawValue: String($0.prefix(2)).lowercased()) }
        let result = try await manager.transcribe(input, decoderState: &state, language: version == .v3 ? lang : nil)
        return TranscriptionResult(text: result.text.trimmed, language: languageHint, confidence: result.confidence, processingMs: sw.elapsedMs)
    }
}

/// Silero VAD via FluidAudio: trims leading/trailing silence and reports whether speech was present.
public actor VADTrimmer {
    private var vad: VadManager?
    public init() {}

    public func load() async {
        guard vad == nil else { return }
        do { vad = try await VadManager(config: VadConfig(defaultThreshold: 0.5)) } catch { Log.speech.error("VAD load failed: \(error)") }
    }

    public struct Result: Sendable { public var samples: [Float]; public var hadSpeech: Bool; public var speechRatio: Double }

    /// Returns trimmed samples (keeps 200 ms padding around speech). Falls back to energy-based trimming without the model.
    public func trim(_ samples: [Float]) async -> Result {
        let frame = 4096 // 256 ms @ 16 kHz — Silero window used by FluidAudio
        guard samples.count > frame else { return Result(samples: samples, hadSpeech: energy(samples) > 0.004, speechRatio: 1) }
        if let vad {
            if let results = try? await vad.process(samples) {
                let active = results.map(\.isVoiceActive)
                guard active.contains(true) else { return Result(samples: samples, hadSpeech: false, speechRatio: 0) }
                let first = active.firstIndex(of: true)!, last = active.lastIndex(of: true)!
                let pad = 3200 // 200 ms
                let start = max(0, first * frame - pad)
                let end = min(samples.count, (last + 1) * frame + pad)
                let ratio = Double(active.filter { $0 }.count) / Double(active.count)
                return Result(samples: Array(samples[start..<end]), hadSpeech: true, speechRatio: ratio)
            }
        }
        return energyTrim(samples)
    }

    private func energy(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for v in s { sum += v * v }
        return sqrt(sum / Float(s.count))
    }

    private func energyTrim(_ samples: [Float]) -> Result {
        let win = 320 // 20 ms
        var flags: [Bool] = []
        var i = 0
        while i + win <= samples.count { flags.append(energy(Array(samples[i..<i + win])) > 0.006); i += win }
        guard let first = flags.firstIndex(of: true), let last = flags.lastIndex(of: true) else { return Result(samples: samples, hadSpeech: false, speechRatio: 0) }
        let start = max(0, first * win - 3200), end = min(samples.count, (last + 1) * win + 3200)
        return Result(samples: Array(samples[start..<end]), hadSpeech: true, speechRatio: Double(flags.filter { $0 }.count) / Double(flags.count))
    }
}
