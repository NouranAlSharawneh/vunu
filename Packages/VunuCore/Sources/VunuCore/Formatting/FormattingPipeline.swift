import Foundation

public struct FormatContext: Sendable {
    public var category: AppCategory = .other
    public var isMessaging = false
    public var style: WritingStyle? = nil
    public var language: String = "English"
    public var dictionary: [DictionaryEntry] = []
    public var snippets: [Snippet] = []
    public var userName: String = ""
    public var cleanupLevel: CleanupLevel = .medium
    public var formatterKind: FormatterKind = .appleIntelligence
    public init() {}
}

public struct FormatOutcome: Sendable, Equatable {
    public var ruleText: String        // deterministic result (always available)
    public var text: String            // final text (LLM result when accepted, else ruleText)
    public var llmUsed: Bool
    public var llmRejectReason: String?
    public var rulesMs: Double
    public var llmMs: Double
    public var pressEnter: Bool        // "press enter" spoken at the very end
}

/// Orchestrates: dictionary → snippets → rules → (LLM with deadline + guard rails) → style → messaging-period rule.
public final class FormattingPipeline: Sendable {
    public let rules = RuleFormatter()
    public let llm: (any LLMFormatter)?
    public init(llm: (any LLMFormatter)?) { self.llm = llm }

    static let pressEnterRe = TextUtil.regex(#"[,.!?\s]*\b(?:press|hit) (?:enter|return)\b[.!?]?\s*$"#)

    public func format(_ raw: String, context ctx: FormatContext) async -> FormatOutcome {
        let sw = Stopwatch()
        var text = raw.trimmed
        var pressEnter = false
        if let m = Self.pressEnterRe.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range, in: text) {
            pressEnter = true
            text.removeSubrange(r)
        }
        text = DictionaryApplier(entries: ctx.dictionary).apply(text)
        text = SnippetExpander(snippets: ctx.snippets).expand(text)
        let ruleText = rules.format(text)
        let rulesMs = sw.elapsedMs

        var final = ruleText
        var llmUsed = false
        var reject: String? = nil
        var llmMs = 0.0
        let words = TextUtil.wordCount(ruleText)
        let wantLLM = ctx.cleanupLevel != .none && ctx.formatterKind != .rulesOnly && words >= 4 && !TextUtil.isArabicScript(ruleText)
        if wantLLM, let llm {
            let sw2 = Stopwatch()
            let deadlineMs = min(900, max(300, 25 * words))
            let req = LLMRequest(text: ruleText, dictionaryWords: ctx.dictionary.map(\.word), userName: ctx.userName, style: ctx.style, language: ctx.language, level: ctx.cleanupLevel)
            do {
                let out = try await llm.cleanup(req, deadline: .milliseconds(deadlineMs))
                llmMs = sw2.elapsedMs
                let cleaned = Self.stripWrapping(out)
                if let why = GuardRails.check(input: ruleText, output: cleaned, dictionaryWords: ctx.dictionary.map(\.word)) {
                    reject = why
                    Log.formatting.info("cleanup rejected: \(why)")
                } else {
                    final = RuleFormatter.tidySpacing(cleaned)
                    llmUsed = true
                }
            } catch {
                llmMs = sw2.elapsedMs
                reject = AppleFMFormatter.reason(for: error)
                Log.formatting.info("cleanup rejected: \(reject ?? "?") after \(Int(llmMs)) ms")
            }
        } else if wantLLM { reject = "no formatter" } else if ctx.cleanupLevel == .none { reject = "level none" } else if words < 4 { reject = "short" }

        final = StylePolicy.apply(final, style: ctx.style, preserve: ctx.dictionary.map(\.word))
        final = MessagingAppPolicy.apply(final, isMessaging: ctx.isMessaging, style: ctx.style)
        return FormatOutcome(ruleText: ruleText, text: final, llmUsed: llmUsed, llmRejectReason: reject, rulesMs: rulesMs, llmMs: llmMs, pressEnter: pressEnter)
    }

    /// Remove quotes/fences/labels an LLM sometimes wraps around its answer.
    static func stripWrapping(_ s: String) -> String {
        var t = s.trimmed
        if t.hasPrefix("```") { t = t.replacingOccurrences(of: "```[a-z]*\n?", with: "", options: .regularExpression) }
        for label in ["Cleaned transcript:", "Cleaned text:", "Transcript:", "Output:"] where t.lowercased().hasPrefix(label.lowercased()) {
            t = String(t.dropFirst(label.count)).trimmed
        }
        if t.count > 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("“") && t.hasSuffix("”")) { t = String(t.dropFirst().dropLast()) }
        return t.trimmed
    }
}
