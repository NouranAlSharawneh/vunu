import Foundation

/// Deterministic cleanup that always runs (< 5 ms): spoken punctuation, numbers, emails/URLs,
/// fillers, stutters, "scratch that", capitalization, terminal punctuation.
public struct RuleFormatter: Sendable {
    public struct Options: Sendable {
        public var removeFillers = true
        public var spokenPunctuation = true
        public var numbers = true
        public var emailsAndURLs = true
        public var capitalize = true
        public var terminalPunctuation = true
        public var backtrack = true
        public init() {}
    }
    public var options = Options()
    public init(options: Options = Options()) { self.options = options }

    public func format(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n").trimmed
        guard !s.isEmpty else { return s }
        if TextUtil.isArabicScript(s) { return Self.tidySpacing(s) }
        s = Self.normalizeContractions(s)
        if options.backtrack { s = Self.applyScratchThat(s) }
        if options.removeFillers { s = Self.removeFillers(s) }
        s = Self.removeStutters(s)
        if options.spokenPunctuation { s = Self.spokenPunctuation(s) }
        if options.emailsAndURLs { s = Self.emailsAndURLs(s) }
        if options.numbers { s = NumberRules.apply(s) }
        s = Self.protectLinks(s)
        s = Self.tidySpacing(s)
        if options.capitalize { s = Self.capitalize(s) }
        s = ListRules.apply(s)
        s = Self.unprotectLinks(s)
        if options.terminalPunctuation { s = Self.terminalPunctuation(s) }
        return s
    }

    static let linkRe = TextUtil.regex(#"(?:https?://\S+|www\.\S+|[\w.+-]+@[\w-]+(?:\.[\w-]+)+|\b[\w-]+(?:\.[\w-]+)*\.(?:\#(tlds))\b(?:/\S*)?)"#)
    static let dotMark = "\u{E000}"
    static func protectLinks(_ s: String) -> String {
        s.replacingMatches(linkRe) { m, src in src.group(m, 0).replacingOccurrences(of: ".", with: dotMark) }
    }
    static func unprotectLinks(_ s: String) -> String { s.replacingOccurrences(of: dotMark, with: ".") }

    // MARK: pieces (internal for tests)

    static let contractionRe = TextUtil.regex(#"\b(\w+)\s+'\s*(s|t|re|ve|ll|d|m)\b"#)
    static func normalizeContractions(_ s: String) -> String {
        s.replacing(contractionRe, with: "$1'$2")
    }

    static let scratchRe = TextUtil.regex(#"(?:^|[,.;:!?]\s*|\s)(?:scratch that|strike that|never mind that|nevermind that|delete that)[,.!]?\s*"#)
    /// "call me at 5, scratch that, at 6" → "call me at 6". Removes the clause before the trigger (back to the last boundary).
    static func applyScratchThat(_ s: String) -> String {
        var out = s
        while let m = scratchRe.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)), let r = Range(m.range, in: out) {
            let before = String(out[..<r.lowerBound])
            let after = String(out[r.upperBound...])
            // find start of previous clause
            var clauseStart = before.startIndex
            if let idx = before.lastIndex(where: { ",.;:!?\n".contains($0) }) { clauseStart = before.index(after: idx) }
            var kept = String(before[..<clauseStart])
            let tail = after.trimmed
            // Align: if the replacement starts with a word that appears in the removed clause, keep everything before that word.
            if let firstWord = tail.split(separator: " ").first?.lowercased(), firstWord.count > 1 {
                let clause = String(before[clauseStart...])
                if let r = clause.range(of: "\\b" + NSRegularExpression.escapedPattern(for: firstWord) + "\\b", options: [.regularExpression, .caseInsensitive, .backwards]) {
                    kept = String(before[..<clauseStart]) + String(clause[..<r.lowerBound])
                }
            }
            if kept.trimmed.isEmpty { out = tail }
            else {
                let sep = kept.last.map { ",.;:!?\n".contains($0) } == true ? " " : (tail.isEmpty ? "" : " ")
                out = kept.trimmed + (tail.isEmpty ? "" : sep + tail)
            }
        }
        return out
    }

    static let fillerRe = TextUtil.regex(#"(?<![\w'])(?:um+|uh+|uhm|erm|er|hmm+|mm+|mhm|ah+|uh-huh)(?![\w'])[,.]?\s?"#)
    static let fillerBracketedRe = TextUtil.regex(#",\s*(?:you know|i mean|sort of|kind of|like)\s*,\s*"#)
    static let fillerStartRe = TextUtil.regex(#"^(?:you know|i mean|sort of|kind of|like|so)\s*,\s*"#)
    static let fillerPhraseRe = TextUtil.regex(#"(?<=\s)(?:you know|i mean|sort of|kind of)\s*,\s*"#)
    static let fillerLeadRe = TextUtil.regex(#",\s*(?:you know|like|i mean|sort of|kind of)(?=[,.!?;:]|\s*$)"#)
    static func removeFillers(_ s: String) -> String {
        var out = s.replacing(fillerRe, with: "")
        out = out.replacing(fillerBracketedRe, with: " ")
        out = out.replacing(fillerStartRe, with: "")
        out = out.replacing(fillerPhraseRe, with: "")
        out = out.replacing(fillerLeadRe, with: "")
        return out
    }

    static let stutterRe = TextUtil.regex(#"\b(\w{2,})(?:\s+\1\b)+(?!\s*\1\b)"#)
    static let stutterAllow: Set<String> = ["that", "had", "very", "no", "bye", "ha", "so", "is", "do", "did", "yes", "okay", "ok", "well", "really", "please", "more", "many"]
    static func removeStutters(_ s: String) -> String {
        s.replacingMatches(stutterRe) { m, src in
            let w = src.group(m, 1)
            return stutterAllow.contains(w.lowercased()) ? src.group(m, 0) : w
        }
    }

    // spoken punctuation
    struct Punct { let re: NSRegularExpression; let replacement: String; let attach: Bool }
    static let periodBlock = #"(?<!\b(?:the|a|an|this|that|trial|grace|time|long|short|same|first|second|third|each|every|per|one|cooling|waiting|lockup|lock-up|warranty|probation|of|my|her|his|their|your|our|any|no|menstrual|late|rest|payback|holding)\s)"#
    static let commaBlock = #"(?<!\b(?:the|a|an|oxford|serial|inverted|trailing|leading|missing|extra|no)\s)"#
    static let punct: [Punct] = [
        Punct(re: TextUtil.regex(#"\s*"# + periodBlock + #"\b(?:period|full stop)\b\.?"#), replacement: ".", attach: true),
        Punct(re: TextUtil.regex(#"\s*"# + commaBlock + #"\bcomma\b,?"#), replacement: ",", attach: true),
        Punct(re: TextUtil.regex(#"\s*\bquestion mark\b\??"#), replacement: "?", attach: true),
        Punct(re: TextUtil.regex(#"\s*\bexclamation (?:point|mark)\b!?"#), replacement: "!", attach: true),
        Punct(re: TextUtil.regex(#"\s*(?<!\b(?:the|a|an|semi)\s)\bcolon\b:?"#), replacement: ":", attach: true),
        Punct(re: TextUtil.regex(#"\s*\bsemi-?colon\b;?"#), replacement: ";", attach: true),
        Punct(re: TextUtil.regex(#"\s*\bellipsis\b|\s*\bdot dot dot\b"#), replacement: "…", attach: true),
        Punct(re: TextUtil.regex(#"[,.]?\s*\bnew paragraph\b[,.]?\s*"#), replacement: "\n\n", attach: false),
        Punct(re: TextUtil.regex(#"[,.]?\s*\b(?:new line|newline|next line|line break)\b[,.]?\s*"#), replacement: "\n", attach: false),
        Punct(re: TextUtil.regex(#"\s*\b(?:open|left) (?:paren|parenthesis|bracket)\b\s*"#), replacement: " (", attach: false),
        Punct(re: TextUtil.regex(#"\s*\b(?:close|closed|right) (?:paren|parenthesis|bracket)\b"#), replacement: ")", attach: true),
        Punct(re: TextUtil.regex(#"\s*\b(?:em dash|emdash)\b\s*"#), replacement: " — ", attach: false),
        Punct(re: TextUtil.regex(#"(?<=\w)\s+\bhyphen\b\s+(?=\w)"#), replacement: "-", attach: false),
        Punct(re: TextUtil.regex(#"\s*\bdash\b\s*"#), replacement: " - ", attach: false),
        Punct(re: TextUtil.regex(#"\bhashtag\s+(?=\w)"#), replacement: "#", attach: false),
        Punct(re: TextUtil.regex(#"\s*\bat sign\b\s*"#), replacement: "@", attach: false),
        Punct(re: TextUtil.regex(#"\s*\bunderscore\b\s*"#), replacement: "_", attach: false),
        Punct(re: TextUtil.regex(#"\s*\b(?:forward )?slash\b\s*"#), replacement: "/", attach: false),
        Punct(re: TextUtil.regex(#"\s*\bbackslash\b\s*"#), replacement: "\\", attach: false),
        Punct(re: TextUtil.regex(#"\s*\bpercent sign\b"#), replacement: "%", attach: true),
        Punct(re: TextUtil.regex(#"\s*\bdollar sign\b\s*"#), replacement: " $", attach: false),
        Punct(re: TextUtil.regex(#"\s*\bampersand\b\s*"#), replacement: " & ", attach: false),
        Punct(re: TextUtil.regex(#"\s*\basterisk\b\s*"#), replacement: "*", attach: false),
        Punct(re: TextUtil.regex(#"\s*\bplus sign\b\s*"#), replacement: " + ", attach: false),
        Punct(re: TextUtil.regex(#"\s*\bequals sign\b\s*"#), replacement: " = ", attach: false),
        Punct(re: TextUtil.regex(#"(?<=\d)\s*\bdegree(?:s)? sign\b"#), replacement: "°", attach: true),
        Punct(re: TextUtil.regex(#"\s*\b(?:open|begin|start) quotes?\b\s*"#), replacement: " \u{201C}", attach: false),
        Punct(re: TextUtil.regex(#"\s*\b(?:close|end) quotes?\b|\s*\bunquote\b"#), replacement: "\u{201D}", attach: true),
    ]
    static func spokenPunctuation(_ s: String) -> String {
        var out = s
        for p in punct { out = out.replacing(p.re, with: p.replacement) }
        // "quote ... quote" pairs left over
        return out
    }

    // emails and URLs
    static let tlds = "com|net|org|io|ai|co|dev|me|app|edu|gov|uk|sa|ae|eg|de|fr|es|it|nl|ca|au|in|jp|xyz|info|biz|tv|cc|ly|to|so|sh|ws|cloud|tech|email|design|studio|store|online|site"
    static let emailRe = TextUtil.regex(#"\b([a-z0-9][a-z0-9._-]{0,40}(?:\s+dot\s+[a-z0-9][a-z0-9._-]{0,40})*)\s+at\s+([a-z0-9][a-z0-9-]{0,40})\s+dot\s+(\#(tlds))\b(?:\s+dot\s+(\#(tlds))\b)?"#)
    static let domainRe = TextUtil.regex(#"\b([a-z0-9][a-z0-9-]{1,40})\s+dot\s+(\#(tlds))\b(?:\s+dot\s+(\#(tlds))\b)?"#)
    static let wwwRe = TextUtil.regex(#"\b(?:w w w|www|triple w)\s+dot\s+"#)
    static let slashRe = TextUtil.regex(#"(\.(?:\#(tlds)))\s+slash\s+([a-z0-9][a-z0-9_-]*)"#)
    static func emailsAndURLs(_ s: String) -> String {
        var out = s.replacing(wwwRe, with: "www.")
        out = out.replacingMatches(emailRe) { m, src in
            let user = src.group(m, 1).replacingOccurrences(of: " dot ", with: ".").replacingOccurrences(of: " ", with: "").lowercased()
            let dom = src.group(m, 2).lowercased(), tld = src.group(m, 3).lowercased(), tld2 = src.group(m, 4).lowercased()
            return "\(user)@\(dom).\(tld)" + (tld2.isEmpty ? "" : ".\(tld2)")
        }
        out = out.replacingMatches(domainRe) { m, src in
            let dom = src.group(m, 1).lowercased(), tld = src.group(m, 2).lowercased(), tld2 = src.group(m, 3).lowercased()
            return "\(dom).\(tld)" + (tld2.isEmpty ? "" : ".\(tld2)")
        }
        out = out.replacing(slashRe, with: "$1/$2")
        return out
    }

    static let spaceBeforePunctRe = TextUtil.regex(#"\s+([,.;:!?%)\]}»…])"#)
    static let punctNoSpaceRe = TextUtil.regex(#"([,.;:!?])(?=[A-Za-z\x{0600}-\x{06FF}])"#)
    static let openNoSpaceRe = TextUtil.regex(#"([(\[{])\s+"#)
    static let multiPunctRe = TextUtil.regex(#"([,.;:!?])\s*(?:\1\s*)+"#)
    static let commaPeriodRe = TextUtil.regex(#",\s*([.!?])"#)
    static let multiSpaceRe = TextUtil.regex(#"[ \t]{2,}"#)
    static let spaceNewlineRe = TextUtil.regex(#"[ \t]*\n[ \t]*"#)
    static let tripleNewlineRe = TextUtil.regex(#"\n{3,}"#)
    static func tidySpacing(_ s: String) -> String {
        var out = s.replacing(spaceBeforePunctRe, with: "$1")
        out = out.replacing(punctNoSpaceRe, with: "$1 ")
        out = out.replacing(openNoSpaceRe, with: "$1")
        out = out.replacing(multiPunctRe, with: "$1")
        out = out.replacing(commaPeriodRe, with: "$1")
        out = out.replacing(multiSpaceRe, with: " ")
        out = out.replacing(spaceNewlineRe, with: "\n")
        out = out.replacing(tripleNewlineRe, with: "\n\n")
        // decimal numbers like "3. 5" glued back: "3.5"
        out = out.replacing(TextUtil.regex(#"(\d)\.\s(\d)"#), with: "$1.$2")
        return out.trimmed
    }

    static let sentenceStartRe = TextUtil.regex(#"(^|[.!?]\s+|\n\s*|[“(]\s*)([a-z])"#, [])
    static let pronounIRe = TextUtil.regex(#"\bi\b(?=$|[\s',.!?;:])"#, [])
    static let pronounIContractRe = TextUtil.regex(#"\bi(?=')"#, [])
    static func capitalize(_ s: String) -> String {
        var out = s.replacingMatches(sentenceStartRe) { m, src in src.group(m, 1) + src.group(m, 2).uppercased() }
        out = out.replacing(pronounIRe, with: "I")
        out = out.replacing(pronounIContractRe, with: "I")
        return out
    }

    static func terminalPunctuation(_ s: String) -> String {
        guard let last = s.last else { return s }
        if last.isLetter || last.isNumber || last == "\"" && s.dropLast().last?.isLetter == true {
            if last == "\"" { return s }
            if TextUtil.wordCount(s) >= 2 || s.count > 12 { return s + "." }
        }
        return s
    }
}
