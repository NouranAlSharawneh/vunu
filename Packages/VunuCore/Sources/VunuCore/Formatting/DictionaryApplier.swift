import Foundation

/// Applies "Correct a misspelling" rules and enforces dictionary casing (case-insensitive, whole word).
public struct DictionaryApplier: Sendable {
    public var entries: [DictionaryEntry]
    public init(entries: [DictionaryEntry]) { self.entries = entries }

    public func apply(_ text: String) -> String {
        var out = text
        for e in entries {
            if let wrong = e.misspelling?.trimmed, !wrong.isEmpty {
                out = replaceWord(in: out, wrong, with: e.word)
            }
            // casing enforcement: "github" → "GitHub"
            if e.word.rangeOfCharacter(from: .uppercaseLetters) != nil || e.word.contains(" ") {
                out = replaceWord(in: out, e.word, with: e.word)
            }
        }
        return out
    }

    private func replaceWord(in text: String, _ target: String, with replacement: String) -> String {
        let pattern = "(?<![\\w])" + NSRegularExpression.escapedPattern(for: target) + "(?![\\w])"
        let re = TextUtil.regex(pattern)
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// Words to bias ASR and to tell the LLM to preserve.
    public var vocabulary: [String] { entries.map(\.word) }
}
