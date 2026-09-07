import Foundation
import ApplicationServices

/// Text around the caret, used for spacing/casing decisions.
public struct SurroundingText: Sendable, Equatable {
    public var before: String
    public var after: String
    public var selectionLength: Int
    public init(before: String = "", after: String = "", selectionLength: Int = 0) { self.before = before; self.after = after; self.selectionLength = selectionLength }
    public static let empty = SurroundingText()
}

public enum SurroundingTextReader {
    /// ≤ 30 ms budget; returns nil when the element can't be read (or is secure).
    public static func read(_ snap: FocusSnapshot) -> SurroundingText? {
        guard !snap.isSecure, let box = snap.element else { return nil }
        let el = box.element
        let sw = Stopwatch()
        guard let sel = AX.range(el, kAXSelectedTextRangeAttribute) else { return nil }
        let total = AX.int(el, kAXNumberOfCharactersAttribute)
        let loc = sel.location, len = sel.length
        let beforeStart = max(0, loc - 200)
        var before = AX.stringForRange(el, CFRange(location: beforeStart, length: loc - beforeStart)) ?? ""
        var after = ""
        if let total { let afterLen = min(50, max(0, total - (loc + len))); if afterLen > 0 { after = AX.stringForRange(el, CFRange(location: loc + len, length: afterLen)) ?? "" } }
        if before.isEmpty && after.isEmpty && sw.elapsedMs < 20, let value = AX.string(el, kAXValueAttribute), value.count < 20_000 {
            let chars = Array(value)
            let l = min(loc, chars.count)
            before = String(chars[max(0, l - 200)..<l])
            let e = min(chars.count, l + len)
            after = String(chars[e..<min(chars.count, e + 50)])
        }
        if sw.elapsedMs > 30 { return nil }
        return SurroundingText(before: before, after: after, selectionLength: len)
    }
}
