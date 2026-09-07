import Foundation

/// Monotonic millisecond stopwatch used for per-stage timings.
public struct Stopwatch: Sendable {
    private let start: UInt64
    public init() { start = DispatchTime.now().uptimeNanoseconds }
    public var elapsedMs: Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
}

/// Per-stage timings for one dictation session (shown in the debug HUD and benchmark).
public struct StageTimings: Sendable, Codable, Equatable {
    public var captureMs: Double = 0        // total recording duration
    public var vadMs: Double = 0
    public var asrMs: Double = 0
    public var rulesMs: Double = 0
    public var llmMs: Double = 0
    public var llmUsed: Bool = false
    public var llmRejected: String? = nil
    public var contextMs: Double = 0
    public var insertMs: Double = 0
    public var insertPath: String = ""
    public var totalMs: Double = 0          // key-up → text inserted
    public init() {}

    public var summary: String {
        var parts = ["asr \(Int(asrMs))ms", "rules \(Int(rulesMs))ms"]
        if llmUsed { parts.append("llm \(Int(llmMs))ms") } else if let r = llmRejected { parts.append("llm skipped(\(r))") }
        parts.append("ctx \(Int(contextMs))ms")
        parts.append("insert \(Int(insertMs))ms/\(insertPath)")
        parts.append("total \(Int(totalMs))ms")
        return parts.joined(separator: " · ")
    }
}
