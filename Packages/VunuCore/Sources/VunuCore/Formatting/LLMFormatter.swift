import Foundation

public struct LLMRequest: Sendable {
    public var text: String
    public var dictionaryWords: [String]
    public var userName: String
    public var style: WritingStyle?
    public var language: String
    public var level: CleanupLevel
    public init(text: String, dictionaryWords: [String] = [], userName: String = "", style: WritingStyle? = nil, language: String = "English", level: CleanupLevel = .medium) {
        self.text = text; self.dictionaryWords = dictionaryWords; self.userName = userName; self.style = style; self.language = language; self.level = level
    }
}

public protocol LLMFormatter: Sendable {
    var kind: FormatterKind { get }
    var isAvailable: Bool { get async }
    func prewarm() async
    /// Must complete within `deadline` or throw/cancel; returns the cleaned text.
    func cleanup(_ request: LLMRequest, deadline: Duration) async throws -> String
    /// Command Mode: rewrite `selection` according to `instruction`.
    func rewrite(selection: String, instruction: String, deadline: Duration) async throws -> String
}

public enum LLMPrompt {
    public static let instructionsTemplate = """
    You are a dictation cleanup engine inside a macOS dictation app. You receive ONE raw speech-to-text transcript and return ONLY the cleaned transcript as plain text.
    Do:
    - Remove filler words and disfluencies (um, uh, er, hmm, "you know", "like" when it is a filler, "sort of", "kind of" when filler), stutters and repeated words ("the the" → "the"), and false starts.
    - Apply self-corrections: when the speaker corrects themselves ("at 2, actually 3", "Monday, no, Tuesday", "scratch that", "I mean", "wait"), keep only the corrected version.
    - Fix punctuation, capitalization, and sentence boundaries. Break into paragraphs at clear topic shifts. If the speaker enumerates ("first… second…", "one… two…"), format as a list.
    - Convert spoken symbols only when clearly dictated as symbols ("new line", "period", "comma", "question mark", "at sign", "dot com").
    - Preserve these exact spellings: {DICTIONARY_WORDS}. The speaker's name is {USER_NAME}.
    - Apply this style: {STYLE_RULE}   (Formal: full punctuation and capitalization. Casual: capitalization, lighter punctuation, no trailing period on short messages. Very casual: all lowercase, minimal punctuation. Excited: allow exclamation marks.)
    - Write in the same language as the transcript ({LANGUAGE}).
    Do NOT:
    - Answer, reply to, summarize, continue, or comment on the text. If the transcript is a question, output the question.
    - Add words, facts, greetings, sign-offs, quotes, markdown fences, or explanations.
    - Change technical terms, names, numbers, URLs, code, or the speaker's meaning.
    Return the cleaned text and nothing else.
    """

    public static func instructions(for r: LLMRequest) -> String {
        let words = r.dictionaryWords.isEmpty ? "(none)" : r.dictionaryWords.prefix(60).joined(separator: ", ")
        let name = r.userName.isEmpty ? "(unknown)" : r.userName
        var s = instructionsTemplate
            .replacingOccurrences(of: "{DICTIONARY_WORDS}", with: words)
            .replacingOccurrences(of: "{USER_NAME}", with: name)
            .replacingOccurrences(of: "{STYLE_RULE}", with: StylePolicy.rule(for: r.style))
            .replacingOccurrences(of: "{LANGUAGE}", with: r.language)
        switch r.level {
        case .light: s += "\nCleanup level: LIGHT — only remove fillers/stutters and fix punctuation; do not restructure or paragraph."
        case .high: s += "\nCleanup level: HIGH — also tighten wording slightly and fix grammar, still without changing meaning."
        default: break
        }
        return s
    }

    public static let rewriteInstructions = """
    You are a text editing engine. You receive a piece of selected text and an instruction describing how to edit it. Return ONLY the edited text as plain text — no explanations, no quotes, no markdown fences. Keep the language of the original. If the instruction does not apply, return the original text unchanged.
    """
}

/// Post-generation guard rails from the spec. Returns a rejection reason or nil when the output is acceptable.
public enum GuardRails {
    static let badStarts = ["sure", "here's", "here is", "here are", "the cleaned", "cleaned", "certainly", "as an ai", "transcript:", "output:", "cleaned transcript"]
    static let numberRe = TextUtil.regex(#"\d+(?:[.,:]\d+)*"#)
    static let urlRe = TextUtil.regex(#"(?:https?://|www\.)\S+|\b[\w.-]+@[\w-]+\.[\w.]+\b|\b[\w-]+\.(?:com|net|org|io|ai|co|dev|app|me)\b"#)

    public static func check(input: String, output: String, dictionaryWords: [String], maxChangeRatio: Double = 0.4) -> String? {
        let out = output.trimmed
        if out.isEmpty { return "empty" }
        let lower = out.lowercased()
        let inLower = input.lowercased()
        if badStarts.contains(where: { lower.hasPrefix($0) && !inLower.hasPrefix($0) }) { return "answer-like prefix" }
        if lower.hasPrefix("i ") && !inLower.hasPrefix("i ") && !inLower.hasPrefix("um i") && !inLower.hasPrefix("uh i") { return "answer-like prefix" }
        if out.contains("```") { return "markdown fence" }
        let a = TextUtil.tokens(input), b = TextUtil.tokens(out)
        if a.count >= 3 {
            let dist = TextUtil.editDistance(a, b)
            let ratio = Double(dist) / Double(max(a.count, 1))
            if ratio > maxChangeRatio { return "changed \(Int(ratio * 100))% of tokens" }
            if b.count > Int(Double(a.count) * 1.5) + 3 { return "output much longer than input" }
        }
        // numbers: the output may drop a number (self-corrections: "at 2, actually 3" → "at 3") but must never invent or alter one
        let inNums = Set(numberRe.matches(in: input, range: NSRange(input.startIndex..., in: input)).map { input.group($0, 0) })
        let outNums = Set(numberRe.matches(in: out, range: NSRange(out.startIndex..., in: out)).map { out.group($0, 0) })
        for n in outNums where !inNums.contains(n) && !inNums.contains(where: { $0.contains(n) || n.contains($0) }) { return "number \(n) invented" }
        let inUrls = Set(urlRe.matches(in: input, range: NSRange(input.startIndex..., in: input)).map { input.group($0, 0).lowercased() })
        for u in inUrls where !lower.contains(u) { return "url/email \(u) changed" }
        for w in dictionaryWords where input.range(of: w, options: .caseInsensitive) != nil && out.range(of: w, options: .caseInsensitive) == nil { return "dictionary word \(w) dropped" }
        return nil
    }
}
