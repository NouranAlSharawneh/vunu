import Foundation

/// Context-aware leading/trailing space and first-letter casing based on text around the caret.
public enum CasingSpacing {
    public struct Decision: Sendable, Equatable {
        public var leadingSpace: Bool
        public var trailingSpace: Bool
        public var lowercaseFirst: Bool
        public var lineHasPunctuation: Bool
    }

    public static func decide(text: String, context: SurroundingText?, properNouns: [String] = []) -> Decision {
        guard let ctx = context else { return Decision(leadingSpace: false, trailingSpace: false, lowercaseFirst: false, lineHasPunctuation: false) }
        let before = ctx.before
        let after = ctx.after
        let lastChar = before.last
        let firstAfter = after.first

        var leading = false
        if let c = lastChar, !c.isWhitespace, !c.isNewline, !"([{\"'“‘/@#$«-".contains(c) { leading = true }
        if text.first?.isNewline == true || text.first.map({ ".,;:!?)".contains($0) }) == true { leading = false }

        var trailing = false
        if let f = firstAfter, f.isLetter || f.isNumber { trailing = true }

        // casing: continuing mid-sentence?
        var lowercase = false
        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        if let c = trimmedBefore.last, !before.hasSuffix("\n"), !before.hasSuffix("\n "), !".!?\n“\"(".contains(c) {
            // previous text ends with a word or comma → we are mid-sentence
            if c.isLetter || c.isNumber || ",;:-—".contains(c) { lowercase = true }
        }
        if lowercase, let first = TextUtil.words(text).first {
            let bare = first.trimmingCharacters(in: .punctuationCharacters)
            if bare == "I" || bare.hasPrefix("I'") { lowercase = false }
            else if properNouns.contains(where: { $0.caseInsensitiveCompare(bare) == .orderedSame }) { lowercase = false }
            else if bare.count > 1, bare == bare.uppercased(), bare.rangeOfCharacter(from: .letters) != nil { lowercase = false } // acronyms
        }
        let lineBefore = before.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let lineHasPunct = lineBefore.contains(where: { ".!?".contains($0) })
        return Decision(leadingSpace: leading, trailingSpace: trailing, lowercaseFirst: lowercase, lineHasPunctuation: lineHasPunct)
    }

    public static func apply(_ text: String, _ d: Decision) -> String {
        var t = text
        if d.lowercaseFirst { t = TextUtil.lowercaseFirst(t) }
        if d.leadingSpace { t = " " + t }
        if d.trailingSpace { t += " " }
        return t
    }
}
