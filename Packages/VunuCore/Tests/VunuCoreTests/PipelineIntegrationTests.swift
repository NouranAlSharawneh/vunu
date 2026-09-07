import XCTest
@testable import VunuCore

/// Runs the real Parakeet model + formatter on spoken fixtures. Skips when the model isn't downloaded.
final class PipelineIntegrationTests: XCTestCase {
    struct Fixture: Decodable { let name: String; let spoken: String; let expected: String }

    func testFixturesThroughRealPipeline() async throws {
        let engine = ParakeetEngine(kind: .parakeetV3)
        guard await engine.isDownloaded else { throw XCTSkip("Parakeet v3 not downloaded at \(await engine.modelDirectory.path)") }
        try await engine.load { _, _ in }
        let url = Bundle.module.url(forResource: "fixtures", withExtension: "json", subdirectory: "Fixtures")!
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        let pipeline = FormattingPipeline(llm: nil)
        var ctx = FormatContext(); ctx.cleanupLevel = .none
        var report: [String] = []
        var worstWER = 0.0
        var maxAsr = 0.0
        for f in fixtures {
            let wav = Bundle.module.url(forResource: f.name, withExtension: "wav", subdirectory: "Fixtures")!
            let samples = AudioStore.load(wav)!
            let seconds = Double(samples.count) / AudioCapture.sampleRate
            let sw = Stopwatch()
            let asr = try await engine.transcribe(samples, languageHint: "en")
            let asrMs = sw.elapsedMs
            let out = await pipeline.format(asr.text, context: ctx)
            let wer = Self.wer(reference: f.expected, hypothesis: out.text)
            worstWER = max(worstWER, wer); maxAsr = max(maxAsr, asrMs)
            report.append(String(format: "%-14@ %4.1fs audio · asr %4.0f ms · rules %.1f ms · WER %3.0f%%\n    raw: %@\n    out: %@", f.name, seconds, asrMs, out.rulesMs, wer * 100, asr.text, out.text.replacingOccurrences(of: "\n", with: "⏎")))
        }
        print("\n=== Pipeline fixtures ===\n" + report.joined(separator: "\n"))
        XCTAssertLessThan(worstWER, 0.15, "WER too high on some fixture")
        XCTAssertLessThan(maxAsr, 600, "ASR slower than 600 ms on a ≤ 12 s clip")
    }

    static func wer(reference: String, hypothesis: String) -> Double {
        let r = TextUtil.tokens(reference), h = TextUtil.tokens(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        return Double(TextUtil.editDistance(r, h)) / Double(r.count)
    }
}
