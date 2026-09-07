import Foundation

/// Expands snippet trigger phrases (case-insensitive, whole-word). Punctuation around the trigger is tolerated
/// only when the whole dictation is the trigger.
public struct SnippetExpander: Sendable {
    public var snippets: [Snippet]
    public init(snippets: [Snippet]) { self.snippets = snippets }

    public func expand(_ text: String) -> String {
        var out = text
        let whole = text.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:")).lowercased()
        for s in snippets.sorted(by: { $0.phrase.count > $1.phrase.count }) {
            let phrase = s.phrase.trimmed
            guard !phrase.isEmpty, !s.replacement.isEmpty else { continue }
            if whole == phrase.lowercased() { return s.replacement }
            let pattern = "(?<![\\w])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\w])"
            let re = TextUtil.regex(pattern)
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: NSRegularExpression.escapedTemplate(for: s.replacement))
        }
        return out
    }

    public static let defaults: [Snippet] = [
        Snippet(phrase: "my email address", replacement: ""),
        Snippet(phrase: "organize thoughts prompt", replacement: "Please organize the following thoughts into a clear, structured summary with headings and bullet points. Keep my wording where possible and flag anything that seems unfinished."),
    ]
}
