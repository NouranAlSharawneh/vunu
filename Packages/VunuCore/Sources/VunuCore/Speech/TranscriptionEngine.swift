import Foundation

public struct TranscriptionResult: Sendable, Equatable {
    public var text: String
    public var language: String?      // BCP-47-ish code if detected
    public var confidence: Float
    public var processingMs: Double
    public init(text: String, language: String? = nil, confidence: Float = 1, processingMs: Double = 0) {
        self.text = text; self.language = language; self.confidence = confidence; self.processingMs = processingMs
    }
}

/// A speech-to-text backend. Samples are 16 kHz mono Float32.
public protocol TranscriptionEngine: Sendable {
    var kind: SttEngineKind { get }
    var isLoaded: Bool { get async }
    /// Download (if needed) + load + warm up.
    func load(progress: @escaping @Sendable (Double, String) -> Void) async throws
    func unload() async
    func transcribe(_ samples: [Float], languageHint: String?) async throws -> TranscriptionResult
    /// Vocabulary bias (dictionary words). Optional.
    func setVocabulary(_ words: [String]) async
}

public extension TranscriptionEngine {
    func setVocabulary(_ words: [String]) async {}
}
