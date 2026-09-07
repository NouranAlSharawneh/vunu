import Foundation

/// Spoken numbers → digits when the context is clearly numeric (times, dates, quantities, ≥ 10, decimals, units).
public enum NumberRules {
    static let units: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]
    static let magnitudes: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
    static let unitWords = "am|pm|a\\.m\\.|p\\.m\\.|o'clock|oclock|percent|%|dollars?|bucks|cents?|euros?|pounds?|riyals?|dirhams?|degrees?|minutes?|mins?|hours?|hrs?|seconds?|secs?|days?|weeks?|months?|years?|kg|kilos?|kilograms?|grams?|g|km|kilometers?|kilometres?|miles?|meters?|metres?|m|cm|mm|inches?|feet|foot|ft|lbs?|pounds?|mb|gb|tb|ms|px|pt|k|x|times|people|items?|units?|pieces?|copies|rows?|columns?|lines?|pages?|chapters?|tickets?|messages?|emails?|calls?|steps?|points?|percentages?|bytes?|calories|reps?|sets?"
    static let leadWords = "at|number|no\\.|chapter|page|room|version|step|option|figure|table|section|item|level|floor|line|episode|season|round|day|week|gate|seat|track|part|article|unit|apartment|suite|highway|route|exit|grade|age|aged|about|around|approximately|roughly|nearly|almost|over|under|only|just|another|plus|minus|times|divided by|multiplied by|x|#|\\$|€|£"

    static let numberSeqRe = TextUtil.regex(#"\b((?:(?:\#(units.keys.joined(separator: "|"))|hundred|thousand|million|billion|and|point|-)\s?)+)"#)

    /// Parse a spoken number sequence into (value, isDecimal string). Returns nil when the words don't form a number.
    static func parse(_ words: [String]) -> String? {
        var total = 0, current = 0
        var decimal: String? = nil
        var sawAny = false
        var i = 0
        var tokens = words.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.")) }
        tokens = tokens.flatMap { $0.contains("-") ? $0.split(separator: "-").map(String.init) : [$0] }
        while i < tokens.count {
            let w = tokens[i]
            if w == "and" { i += 1; continue }
            if w == "point" {
                guard sawAny else { return nil }
                var digits = ""
                var j = i + 1
                while j < tokens.count, let d = units[tokens[j]], d < 10 { digits += String(d); j += 1 }
                guard !digits.isEmpty else { return nil }
                decimal = digits; i = j; break
            }
            if let u = units[w] {
                // "twenty five" → 25; "five five" (digits read out) → 55; "oh" only inside a digit sequence
                if w == "oh", !sawAny { return nil }
                if current >= 20 && u < 10 && current % 10 == 0 { current += u }
                else if u < 10 && current < 10 && sawAny && total == 0 && w != "oh" && (units[tokens[i - 1]] ?? 99) < 10 { current = current * 10 + u } // read-out digits "four two"
                else if sawAny && current > 0 && u >= 10 && current < 10 { return nil } // "five twenty" ambiguous → leave
                else if sawAny && u >= 20 && current >= 20 { total += current; current = u } // "twenty thirty" → treat as separate? give up
                else { current += u }
                sawAny = true
            } else if let m = magnitudes[w] {
                guard sawAny else { return nil }
                if m == 100 { current = max(current, 1) * 100 } else { total += max(current, 1) * m; current = 0 }
            } else { return nil }
            i += 1
        }
        guard sawAny else { return nil }
        let value = total + current
        if let decimal { return "\(value).\(decimal)" }
        return String(value)
    }

    static let timeRe = TextUtil.regex(#"\b(\d{1,2})\s+(?:(\d{2})\s+)?(a\.?m\.?|p\.?m\.?|o'clock|oclock)\b"#)
    static let percentRe = TextUtil.regex(#"(\d)\s*percent\b"#)
    static let dollarRe = TextUtil.regex(#"\b(\d[\d,]*(?:\.\d+)?)\s+(dollars?|bucks)\b"#)
    static let ordinalRe = TextUtil.regex(#"\b(\d+)\s+(st|nd|rd|th)\b"#)
    static let leadRe = TextUtil.regex(#"\b(?:\#(leadWords))\s*$"#)
    static let unitRe = TextUtil.regex(#"^\s*(?:\#(unitWords))\b"#)

    static let hourWords = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve"
    static let minuteWords = "(?:oh\\s+)?(?:one|two|three|four|five|six|seven|eight|nine)|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|(?:twenty|thirty|forty|fifty)(?:\\s+(?:one|two|three|four|five|six|seven|eight|nine))?"
    static let spokenTimeRe = TextUtil.regex(#"\b(\#(hourWords))\s+(\#(minuteWords))\s+(a\.?m\.?|p\.?m\.?|o'clock|in the (?:morning|afternoon|evening))\b"#)

    static func spokenTimes(_ s: String) -> String {
        s.replacingMatches(spokenTimeRe) { m, src in
            let h = parse([src.group(m, 1)]) ?? "0"
            var minuteText = src.group(m, 2).lowercased()
            let leadingOh = minuteText.hasPrefix("oh ")
            if leadingOh { minuteText = String(minuteText.dropFirst(3)) }
            guard let mm = parse(TextUtil.words(minuteText)), let mv = Int(mm), mv < 60 else { return src.group(m, 0) }
            let suffix = src.group(m, 3).lowercased().replacingOccurrences(of: ".", with: "")
            let time = "\(h):\(String(format: "%02d", mv))"
            if suffix.hasPrefix("o'") { return time }
            if suffix.hasPrefix("in the") { return time + " " + src.group(m, 3) }
            return time + " " + suffix
        }
    }

    public static func apply(_ s: String) -> String {
        var out = spokenTimes(s)
        out = out.replacingMatches(numberSeqRe) { m, src in
            let match = src.group(m, 0)
            let trimmedMatch = match.trimmed
            let words = TextUtil.words(trimmedMatch)
            guard !words.isEmpty, let value = parse(words) else { return match }
            // decide whether to convert
            let before = String(src[..<Range(m.range, in: src)!.lowerBound])
            let after = String(src[Range(m.range, in: src)!.upperBound...])
            let numeric = Double(value) ?? 0
            let isDecimal = value.contains(".")
            let hasLead = leadRe.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) != nil
            let hasUnit = unitRe.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)) != nil
            let multiWord = words.filter { $0.lowercased() != "and" }.count >= 2
            let sentenceStart = before.trimmed.isEmpty || before.trimmed.last.map { ".!?\n".contains($0) } == true
            let convert = isDecimal || hasLead || hasUnit || numeric >= 10 && (multiWord || numeric >= 100) || (numeric >= 10 && !sentenceStart && numeric != 10 && numeric != 20 && numeric != 30) || (numeric == 0 && words.first?.lowercased() == "zero")
            // never convert a lone "one" ("one of them") or "a hundred"
            if words.count == 1, numeric <= 9, !hasLead, !hasUnit { return match }
            guard convert else { return match }
            let trailing = match.hasSuffix(" ") ? " " : ""
            return value + trailing
        }
        out = out.replacingMatches(timeRe) { m, src in
            let h = src.group(m, 1), mm = src.group(m, 2), suffix = src.group(m, 3).lowercased().replacingOccurrences(of: ".", with: "")
            if suffix.hasPrefix("o") { return mm.isEmpty ? "\(h) o'clock" : "\(h):\(mm)" }
            return mm.isEmpty ? "\(h) \(suffix)" : "\(h):\(mm) \(suffix)"
        }
        out = out.replacing(percentRe, with: "$1%")
        out = out.replacingMatches(dollarRe) { m, src in "$" + src.group(m, 1) }
        out = out.replacing(ordinalRe, with: "$1$2")
        return out
    }
}
