import Foundation
import Observation

/// Owns the STT engines and the LLM formatter; downloads, loads, warms up, unloads, benchmarks.
@MainActor @Observable
public final class ModelManager {
    public static let shared = ModelManager()

    public private(set) var parakeetV3 = ParakeetEngine(kind: .parakeetV3)
    public private(set) var parakeetV2 = ParakeetEngine(kind: .parakeetV2)
    public private(set) var appleSpeech = AppleSpeechEngine()
    public let vad = VADTrimmer()
    public let appleFM = AppleFMFormatter()

    public var downloadProgress: Double = 0
    public var downloadLabel: String = ""
    public var isDownloading = false
    public var loadedEngines: Set<SttEngineKind> = []
    public var lastError: String?
    public var fmAvailability: String = "Checking…"
    public var residentMemoryMB: Double = 0

    private init() {}

    public func engine(for kind: SttEngineKind) -> any TranscriptionEngine {
        switch kind {
        case .parakeetV3: parakeetV3
        case .parakeetV2: parakeetV2
        case .appleSpeech: appleSpeech
        case .whisperKit: WhisperKitEngine.shared
        }
    }

    public var activeEngine: any TranscriptionEngine { engine(for: Preferences.shared.sttEngine) }

    public func isDownloaded(_ kind: SttEngineKind) async -> Bool {
        switch kind {
        case .parakeetV3: await parakeetV3.isDownloaded
        case .parakeetV2: await parakeetV2.isDownloaded
        case .appleSpeech: true
        case .whisperKit: await WhisperKitEngine.shared.isDownloaded
        }
    }

    /// Download + load + warm the selected engine (and VAD + LLM prewarm).
    public func loadSelected() async {
        let kind = Preferences.shared.sttEngine
        await load(kind)
        await vad.load()
        fmAvailability = await appleFM.availabilityDescription
        await appleFM.prewarm()
        updateMemory()
    }

    public func load(_ kind: SttEngineKind) async {
        guard !loadedEngines.contains(kind) else { return }
        isDownloading = true; downloadProgress = 0; downloadLabel = "Preparing…"; lastError = nil
        do {
            let e = engine(for: kind)
            try await e.load { [weak self] p, label in
                Task { @MainActor in self?.downloadProgress = p; self?.downloadLabel = label }
            }
            if await e.isLoaded { loadedEngines.insert(kind); Log.file("models", "loaded \(kind.rawValue)") }
            else { Log.file("models", "load \(kind.rawValue) returned without a loaded model") }
        } catch {
            lastError = error.localizedDescription
            Log.models.error("load \(kind.rawValue) failed: \(error)")
            Log.file("models", "load \(kind.rawValue) failed: \(error)")
        }
        isDownloading = false
        updateMemory()
    }

    public func unload(_ kind: SttEngineKind) async {
        await engine(for: kind).unload()
        loadedEngines.remove(kind)
        updateMemory()
    }

    public func deleteModelFiles(_ kind: SttEngineKind) async {
        await unload(kind)
        let dir: URL?
        switch kind {
        case .parakeetV3: dir = await parakeetV3.modelDirectory
        case .parakeetV2: dir = await parakeetV2.modelDirectory
        case .whisperKit: dir = WhisperKitEngine.modelDirectory
        case .appleSpeech: dir = nil
        }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    public func updateMemory() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        if kr == KERN_SUCCESS { residentMemoryMB = Double(info.resident_size) / 1_048_576 }
    }

    public struct Benchmark: Sendable { public var asrMs: Double; public var rulesMs: Double; public var llmMs: Double; public var llmRejected: String?; public var text: String; public var audioSeconds: Double }

    /// Run the pipeline on a bundled fixture (or synthesized silence) and report timings.
    public func benchmark(samples: [Float], seconds: Double) async -> Benchmark {
        let engine = activeEngine
        let sw = Stopwatch()
        let asr = (try? await engine.transcribe(samples, languageHint: nil))?.text ?? ""
        let asrMs = sw.elapsedMs
        let pipeline = FormattingPipeline(llm: Preferences.shared.formatter == .appleIntelligence ? appleFM : nil)
        var ctx = FormatContext()
        ctx.cleanupLevel = Preferences.shared.cleanupLevel
        let out = await pipeline.format(asr.isEmpty ? "um so this is a test of the benchmark uh please make sure the the timing is right" : asr, context: ctx)
        return Benchmark(asrMs: asrMs, rulesMs: out.rulesMs, llmMs: out.llmMs, llmRejected: out.llmRejectReason, text: out.text, audioSeconds: seconds)
    }
}
