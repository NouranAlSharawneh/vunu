import Foundation

/// Terminal / editor targets (Claude Code, Cursor, VS Code…):
///  - File tagging: "at main dot py" / "at main.py" → "@main.py" (file name only, no path — the tool resolves it).
///  - Variable recognition: identifiers that look like code (camelCase, snake_case, dotted, or known symbols
///    visible in the editor) are wrapped in backticks and given their exact casing.
public enum VibeCodingRules {
    static let exts = RuleFormatter.fileExts + "|txt|md|json|yml|yaml|toml|py|ts|tsx|js|jsx|swift|go|rs|rb|java|kt|css|html|sql|sh|env|lock"
    static let spokenFileRe = TextUtil.regex(#"\b(?:at|(?:add|tag|mention)(?!\s+at\b))\s+([\w][\w-]{0,40}(?:\s+[\w][\w-]{0,40}){0,3}?)\s+dot\s+(\#(exts))\b"#)
    static let joinDotRe = TextUtil.regex(#"\b([\w][\w-]{0,60})\s+dot\s+(\#(exts))\b"#)
    static let joinedFileRe = TextUtil.regex(#"\b(?:at|add|tag|mention)\s+([\w][\w-]{0,60}\.(?:\#(exts)))\b"#)
    static let dotFileRe = TextUtil.regex(#"\bdot\s+(env|gitignore|zshrc|bashrc|npmrc|prettierrc|eslintrc)\b"#)
    static let bareFileRe = TextUtil.regex(#"(?<![@`\w/.])([\w][\w-]{0,60}\.(?:\#(exts)))(?![\w/])"#)
    static let identRe = TextUtil.regex(#"(?<![`@.\w])((?:[a-z]+[A-Z][A-Za-z0-9]*)|(?:[a-z0-9]+_[a-z0-9_]+)|(?:[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+))(?![`\w])(?!\.[a-z])"#, [])

    public struct Options: Sendable { public var fileTagging = true; public var variableRecognition = true; public init() {} }

    /// - Parameter visibleSymbols: identifiers read from the focused editor (may be empty).
    public static func apply(_ text: String, visibleSymbols: [String], options: Options = Options()) -> String {
        var out = text
        if options.fileTagging {
            out = out.replacing(dotFileRe, with: ".$1")
            out = out.replacingMatches(spokenFileRe) { m, src in "@" + fileName(src.group(m, 1), ext: src.group(m, 2).lowercased(), visibleSymbols: visibleSymbols) + "." + src.group(m, 2).lowercased() }
            out = out.replacing(joinedFileRe, with: "@$1")
            out = out.replacing(joinDotRe, with: "$1.$2")
        }
        if options.variableRecognition {
            // exact-cased symbols from the editor, matched case-insensitively on whole words
            for sym in visibleSymbols.sorted(by: { $0.count > $1.count }).prefix(400) where sym.count >= 3 {
                let re = TextUtil.regex("(?<![`@.\\w])" + NSRegularExpression.escapedPattern(for: sym) + "(?![`\\w])(?!\\.[a-z])")
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: NSRegularExpression.escapedTemplate(for: "`\(sym)`"))
            }
            out = out.replacingMatches(identRe) { m, src in "`" + src.group(m, 1) + "`" }
            out = out.replacing(bareFileRe, with: "`$1`")
            // never double-wrap or wrap tagged files
            out = out.replacingOccurrences(of: "``", with: "`").replacingOccurrences(of: "`@", with: "@")
        }
        return out
    }

    /// "session coordinator" + swift → SessionCoordinator; + py → session_coordinator; + ts → session-coordinator.
    /// A visible symbol whose letters match wins (exact casing).
    static func fileName(_ spoken: String, ext: String, visibleSymbols: [String]) -> String {
        let words = spoken.split(separator: " ").map(String.init)
        if words.count == 1 { return words[0] }
        let flat = words.joined().lowercased()
        if let sym = visibleSymbols.first(where: { $0.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") == flat }) { return sym }
        switch ext {
        case "swift", "kt", "java", "cs", "m", "mm", "h": return words.map { TextUtil.capitalizeFirst($0.lowercased()) }.joined()
        case "py", "sh", "zsh", "rb", "sql", "go", "rs", "php": return words.map { $0.lowercased() }.joined(separator: "_")
        default: return words.map { $0.lowercased() }.joined(separator: "-")
        }
    }

    static let symbolRe = TextUtil.regex(#"\b(?:[a-z]+[A-Z][A-Za-z0-9]*|[a-z][a-z0-9]*_[a-z0-9_]+|[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+)\b"#, [])
    /// Extract code identifiers from editor text (deduped, most frequent first).
    public static func symbols(in editorText: String) -> [String] {
        var counts: [String: Int] = [:]
        for m in symbolRe.matches(in: editorText, range: NSRange(editorText.startIndex..., in: editorText)) {
            let s = editorText.group(m, 0)
            if s.count >= 3 && s.count <= 40 { counts[s, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }
}
