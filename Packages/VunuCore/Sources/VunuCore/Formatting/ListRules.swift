import Foundation

/// Deterministic spoken-list detection: "first …, second …, third …", "number one …, number two …",
/// "bullet point … bullet point …" → numbered / bulleted list. Only fires with ≥ 2 markers in order.
public enum ListRules {
    static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    static let ordinalRe = TextUtil.regex(#"(?:^|(?<=[,.;:!?]\s)|(?<=\s))(?<!\b(?:the|a|an|my|your|his|her|our|their|its|at|in|for|of|on|came|finished|placed|was|is|be|very|every|this|that)\s)(?:(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)(?:ly)?|number (one|two|three|four|five|six|seven|eight|nine|ten|\d+)|point number (\d+)|step (\d+))\b[,:]?\s+"#)
    static let bulletRe = TextUtil.regex(#"(?:^|(?<=[,.;:!?]\s)|(?<=\s))(?:bullet point|bullet|dash point|next bullet)[,:]?\s+"#)
    static let numberWords = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]

    public static func apply(_ s: String) -> String {
        if let out = applyNumbered(s) { return out }
        if let out = applyBullets(s) { return out }
        return s
    }

    static func index(of m: NSTextCheckingResult, in src: String) -> Int? {
        let ord = src.group(m, 1).lowercased()
        if let i = ordinals.firstIndex(of: ord) { return i + 1 }
        for g in 2...4 {
            let v = src.group(m, g).lowercased()
            if v.isEmpty { continue }
            if let n = Int(v) { return n }
            if let n = numberWords[v] { return n }
        }
        return nil
    }

    static func applyNumbered(_ s: String) -> String? {
        let matches = ordinalRe.matches(in: s, range: NSRange(s.startIndex..., in: s))
        guard matches.count >= 2 else { return nil }
        // markers must be strictly increasing and start at 1
        var expected = 1
        var used: [NSTextCheckingResult] = []
        for m in matches {
            guard let n = index(of: m, in: s) else { continue }
            if n == expected { used.append(m); expected += 1 }
        }
        guard used.count >= 2, let firstRange = Range(used[0].range, in: s) else { return nil }
        // With only two markers, require multi-word items to avoid "first line … second line" false positives.
        if used.count == 2 {
            for (i, m) in used.enumerated() {
                guard let r = Range(m.range, in: s) else { return nil }
                let end = i + 1 < used.count ? Range(used[i + 1].range, in: s)!.lowerBound : s.endIndex
                if TextUtil.wordCount(String(s[r.upperBound..<end])) < 2 { return nil }
            }
        }
        var intro = String(s[..<firstRange.lowerBound]).trimmed
        var items: [String] = []
        for (i, m) in used.enumerated() {
            guard let r = Range(m.range, in: s) else { continue }
            let end = i + 1 < used.count ? Range(used[i + 1].range, in: s)!.lowerBound : s.endIndex
            var item = String(s[r.upperBound..<end]).trimmed
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
            if let f = item.first, f.isLowercase { item = TextUtil.capitalizeFirst(item) }
            items.append(item)
        }
        if intro.hasSuffix(",") { intro.removeLast(); intro += ":" }
        else if !intro.isEmpty, let l = intro.last, !".:!?".contains(l) { intro += ":" }
        let list = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return intro.isEmpty ? list : intro + "\n" + list
    }

    static func applyBullets(_ s: String) -> String? {
        let matches = bulletRe.matches(in: s, range: NSRange(s.startIndex..., in: s))
        guard matches.count >= 2, let firstRange = Range(matches[0].range, in: s) else { return nil }
        var intro = String(s[..<firstRange.lowerBound]).trimmed
        var items: [String] = []
        for (i, m) in matches.enumerated() {
            guard let r = Range(m.range, in: s) else { continue }
            let end = i + 1 < matches.count ? Range(matches[i + 1].range, in: s)!.lowerBound : s.endIndex
            var item = String(s[r.upperBound..<end]).trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
            if let f = item.first, f.isLowercase { item = TextUtil.capitalizeFirst(item) }
            items.append(item)
        }
        if !intro.isEmpty, let l = intro.last, !".:!?".contains(l) { intro += ":" }
        let list = items.map { "- " + $0 }.joined(separator: "\n")
        return intro.isEmpty ? list : intro + "\n" + list
    }
}
