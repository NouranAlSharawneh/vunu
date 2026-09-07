import Foundation

/// Style rule text for the LLM prompt + deterministic post-processing.
public enum StylePolicy {
    public static func rule(for style: WritingStyle?) -> String {
        switch style {
        case .formal: "Formal: full punctuation and capitalization."
        case .casual: "Casual: capitalization, lighter punctuation, no trailing period on short messages."
        case .veryCasual: "Very casual: all lowercase, minimal punctuation."
        case .excited: "Excited: allow exclamation marks where the tone is enthusiastic."
        case nil: "Neutral: standard punctuation and capitalization."
        }
    }

    /// Deterministic style application (used when the LLM is skipped or rejected).
    public static func apply(_ text: String, style: WritingStyle?, preserve: [String]) -> String {
        switch style {
        case .veryCasual:
            var out = text.lowercased()
            // keep URLs/emails and dictionary words as-is
            for w in preserve where !w.isEmpty {
                let re = TextUtil.regex("(?<![\\w])" + NSRegularExpression.escapedPattern(for: w) + "(?![\\w])")
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: NSRegularExpression.escapedTemplate(for: w))
            }
            for (a, b) in [(", ", ", "), ("!", "!")] { out = out.replacingOccurrences(of: a, with: b) }
            return out
        case .excited:
            var out = text
            if out.hasSuffix(".") { out.removeLast(); out += "!" }
            return out
        default: return text
        }
    }
}
