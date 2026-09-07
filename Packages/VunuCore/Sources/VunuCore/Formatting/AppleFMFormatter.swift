import Foundation
import FoundationModels

/// Tier-1 LLM cleanup with Apple's on-device Foundation Models. One prewarmed session per instruction set.
public actor AppleFMFormatter: LLMFormatter {
    public let kind: FormatterKind = .appleIntelligence
    private var sessions: [String: LanguageModelSession] = [:]
    private var turns: [String: Int] = [:]
    private var rewriteSession: LanguageModelSession?
    private var lastInstructions: String?

    public init() {}

    public var isAvailable: Bool {
        get async { SystemLanguageModel.default.isAvailable }
    }
    public var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "Available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "Device not eligible"
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is off in System Settings"
            case .modelNotReady: return "Model downloading / not ready"
            @unknown default: return "Unavailable"
            }
        }
    }

    public func prewarm() async {
        guard SystemLanguageModel.default.isAvailable else { return }
        let r = LLMRequest(text: "")
        session(for: LLMPrompt.instructions(for: r)).prewarm()
    }

    public func prewarm(for request: LLMRequest) {
        guard SystemLanguageModel.default.isAvailable else { return }
        session(for: LLMPrompt.instructions(for: request)).prewarm()
    }

    private func session(for instructions: String) -> LanguageModelSession {
        if let s = sessions[instructions], (turns[instructions] ?? 0) < 20, !s.isResponding { return s }
        let s = LanguageModelSession(instructions: instructions)
        sessions[instructions] = s
        turns[instructions] = 0
        if sessions.count > 6, let oldest = sessions.keys.first(where: { $0 != instructions }) { sessions[oldest] = nil; turns[oldest] = nil }
        return s
    }

    public func cleanup(_ request: LLMRequest, deadline: Duration) async throws -> String {
        guard SystemLanguageModel.default.isAvailable else { throw VunuError.engineUnavailable("Apple Intelligence") }
        let instructions = LLMPrompt.instructions(for: request)
        let s = session(for: instructions)
        turns[instructions, default: 0] += 1
        let options = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: max(64, TextUtil.wordCount(request.text) * 3 + 32))
        return try await Self.race(deadline: deadline) {
            try await s.respond(to: request.text, options: options).content
        }
    }

    public func rewrite(selection: String, instruction: String, deadline: Duration) async throws -> String {
        guard SystemLanguageModel.default.isAvailable else { throw VunuError.engineUnavailable("Apple Intelligence") }
        let s = LanguageModelSession(instructions: LLMPrompt.rewriteInstructions)
        let prompt = "Instruction: \(instruction)\n\nText:\n\(selection)"
        let options = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: max(128, selection.count / 2 + 128))
        return try await Self.race(deadline: deadline) { try await s.respond(to: prompt, options: options).content }
    }

    /// Run `work` against a deadline; cancels the generation on timeout.
    static func race(deadline: Duration, _ work: @escaping @Sendable () async throws -> String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(for: deadline); throw LLMTimeout() }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LLMTimeout() }
            return first
        }
    }

    /// Map FoundationModels errors to a short reason (never surfaced to the user).
    public static func reason(for error: Error) -> String {
        if error is LLMTimeout { return "timeout" }
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .guardrailViolation: return "guardrail"
            case .exceededContextWindowSize: return "context window"
            case .refusal: return "refusal"
            case .rateLimited: return "rate limited"
            case .concurrentRequests: return "busy"
            case .unsupportedLanguageOrLocale: return "language"
            case .assetsUnavailable: return "assets"
            default: return "generation error"
            }
        }
        return "error: \(error.localizedDescription)"
    }
}

public struct LLMTimeout: Error, Sendable {}
