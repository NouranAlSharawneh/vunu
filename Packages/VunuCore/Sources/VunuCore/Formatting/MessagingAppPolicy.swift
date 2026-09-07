import Foundation

/// Trailing-period rule: messaging apps drop the final period on short dictations; styles adjust it further.
public enum MessagingAppPolicy {
    public static func sentenceCount(_ s: String) -> Int {
        let n = s.split { ".!?".contains($0) }.filter { !String($0).trimmed.isEmpty }.count
        return max(n, s.trimmed.isEmpty ? 0 : 1)
    }

    /// - Parameters:
    ///   - isMessaging: target is a messaging app / web messenger
    ///   - style: chosen style for the category (nil = none)
    ///   - lineHasPunctuation: the existing line at the caret already contains . ! ?
    public static func apply(_ text: String, isMessaging: Bool, style: WritingStyle?, lineHasPunctuation: Bool = false) -> String {
        guard text.hasSuffix(".") else { return text }   // never remove ! or ?
        let sentences = sentenceCount(text)
        let strip: Bool
        switch style {
        case .veryCasual: strip = true
        case .casual: strip = isMessaging ? sentences <= 2 && !lineHasPunctuation : sentences <= 10
        case .formal, .excited: strip = false
        case nil: strip = isMessaging && sentences <= 2 && !lineHasPunctuation
        }
        guard strip, !text.hasSuffix("..") else { return text }
        return String(text.dropLast())
    }
}
