import Foundation

public enum TextUtil {
    public static func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.count
    }
    public static func words(_ s: String) -> [String] {
        s.split { $0.isWhitespace || $0.isNewline }.map(String.init)
    }
    /// Lowercased alphanumeric tokens (for diffs / guard rails).
    public static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" ) }.map(String.init).filter { !$0.isEmpty }
    }
    public static func isArabicScript(_ s: String) -> Bool {
        var arabic = 0, latin = 0
        for u in s.unicodeScalars {
            switch u.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: arabic += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        return arabic > latin
    }
    public static func capitalizeFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }
    public static func lowercaseFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }
    /// Levenshtein distance over token arrays.
    public static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
    public static func regex(_ pattern: String, _ opts: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: opts)
    }
}

extension String {
    func replacing(_ re: NSRegularExpression, with template: String) -> String {
        re.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }
    func replacingMatches(_ re: NSRegularExpression, _ transform: (NSTextCheckingResult, String) -> String) -> String {
        var out = self
        let matches = re.matches(in: self, range: NSRange(startIndex..., in: self))
        for m in matches.reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: transform(m, self))
        }
        return out
    }
    func group(_ m: NSTextCheckingResult, _ i: Int) -> String {
        guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: self) else { return "" }
        return String(self[r])
    }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
