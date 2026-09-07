import Foundation
import ApplicationServices

/// Reads editor / text-field contents through AX (bounded), used for symbol extraction and edit watching.
public enum EditorReader {
    public static func value(_ snap: FocusSnapshot, maxLength: Int) -> String? {
        guard !snap.isSecure, let el = snap.element?.element else { return nil }
        if let n = AX.int(el, kAXNumberOfCharactersAttribute), n > maxLength {
            return AX.stringForRange(el, CFRange(location: max(0, n - maxLength), length: maxLength))
        }
        return AX.string(el, kAXValueAttribute)
    }

    /// Identifiers visible in the focused editor element (or its focused window's text areas), best effort, ≤ 30 ms.
    public static func symbols(_ snap: FocusSnapshot) -> [String] {
        let sw = Stopwatch()
        var text = value(snap, maxLength: 40_000) ?? ""
        if text.count < 200, sw.elapsedMs < 15 {
            // editors often focus a tiny input; look at sibling text areas in the window
            let app = AX.app(pid: snap.pid)
            if let win = AX.element(app, kAXFocusedWindowAttribute) {
                text += collectText(win, depth: 0, budget: sw, limit: 40_000)
            }
        }
        return VibeCodingRules.symbols(in: text)
    }

    private static func collectText(_ el: AXUIElement, depth: Int, budget: Stopwatch, limit: Int) -> String {
        guard depth < 6, budget.elapsedMs < 25 else { return "" }
        var out = ""
        if let role = AX.string(el, kAXRoleAttribute), role == "AXTextArea" || role == "AXStaticText" {
            if let v = AX.string(el, kAXValueAttribute), v.count < limit { out += v + "\n" }
        }
        if let kids = AX.value(el, kAXChildrenAttribute) as? [AnyObject] {
            for k in kids.prefix(30) where CFGetTypeID(k) == AXUIElementGetTypeID() {
                out += collectText(unsafeBitCast(k, to: AXUIElement.self), depth: depth + 1, budget: budget, limit: limit)
                if out.count > limit { break }
            }
        }
        return out
    }
}

/// Word-level diff between what Vunu inserted and what the field contains later.
public enum EditWatcher {
    /// Returns (wrong, right) when exactly one word of the inserted text was replaced by another word.
    public static func singleWordCorrection(original: String, current: String) -> (String, String)? {
        let orig = original.split(separator: " ").map(String.init)
        guard orig.count >= 1 else { return nil }
        // locate the region: find the longest run of original words present in current
        let curWords = current.split { $0 == " " || $0 == "\n" }.map(String.init)
        guard curWords.count >= orig.count else { return nil }
        var best: (Int, Int)? = nil   // (start in current, mismatches)
        for start in 0...(curWords.count - orig.count) {
            var mismatches = 0
            for i in 0..<orig.count where strip(curWords[start + i]) != strip(orig[i]) { mismatches += 1; if mismatches > 1 { break } }
            if mismatches <= 1, best == nil || mismatches < best!.1 { best = (start, mismatches) }
            if mismatches == 0 { return nil }
        }
        guard let (start, mismatches) = best, mismatches == 1 else { return nil }
        for i in 0..<orig.count where strip(curWords[start + i]) != strip(orig[i]) {
            let wrong = strip(orig[i]), right = strip(curWords[start + i])
            guard right.count >= 2, wrong.count >= 2, right.rangeOfCharacter(from: .letters) != nil else { return nil }
            guard right.lowercased() != wrong.lowercased() || right != wrong else { return nil }
            return (wrong, right)
        }
        return nil
    }
    static func strip(_ w: String) -> String { w.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]{}“”‘’")) }
}
