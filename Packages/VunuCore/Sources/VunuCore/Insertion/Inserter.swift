import Foundation
import AppKit
import ApplicationServices

public enum InsertResult: Sendable, Equatable {
    case inserted(path: String)     // "ax" | "paste" | "paste-chunked"
    case clipboardOnly(reason: String)  // text left on clipboard; user must ⌘⌃V
    case blocked(reason: String)
}

/// The paste engine: AX fast path → clipboard paste (with restore) → clipboard-only fallback.
public actor Inserter {
    public static let shared = Inserter()
    private init() {}

    public func insert(_ text: String, into target: FocusSnapshot?, pressEnter: Bool = false) async -> InsertResult {
        guard !text.isEmpty else { return .blocked(reason: "empty") }
        guard let target else {
            await MainActor.run { _ = PasteboardSnapshot.writeText(text) }
            return .clipboardOnly(reason: "no target")
        }
        if target.isSecure { return .blocked(reason: "secure field") }
        if target.isKnownNonText {
            await MainActor.run { _ = PasteboardSnapshot.writeText(text) }
            return .clipboardOnly(reason: "no text field")
        }

        // Path A: AX selected-text replacement (native text views).
        if target.supportsAXInsert, let box = target.element {
            let ok = await FocusTracker.shared.perform { Self.axInsert(box.element, text) }
            if ok {
                if pressEnter { try? await Task.sleep(for: .milliseconds(30)); KeySynth.returnKey() }
                return .inserted(path: "ax")
            }
        }

        // Path B: clipboard paste with restore.
        let isTerminal = target.isTerminal || target.isCodeEditor
        var payload = text
        if isTerminal, payload.hasSuffix("\n") { payload.removeLast() }
        let chunked = isTerminal && payload.count > 1_500
        let snapshot = await MainActor.run { PasteboardSnapshot() }
        let pieces = chunked ? Self.chunks(payload, size: 800) : [payload]
        for (i, piece) in pieces.enumerated() {
            let cc = await MainActor.run { PasteboardSnapshot.writeText(piece) }
            _ = cc
            KeySynth.commandV()
            try? await Task.sleep(for: .milliseconds(i < pieces.count - 1 ? 60 : 0))
        }
        // Wait for the target to read the pasteboard: changeCount stays ours; just wait a bounded time.
        try? await Task.sleep(for: .milliseconds(isTerminal ? 250 : 120))
        if pressEnter { KeySynth.returnKey() }
        await MainActor.run { snapshot.restore() }
        return .inserted(path: chunked ? "paste-chunked" : "paste")
    }

    /// Copy-only (Path C / manual re-paste).
    public func copyToClipboard(_ text: String) async {
        await MainActor.run { _ = PasteboardSnapshot.writeText(text) }
    }

    /// Re-paste helper for ⌘⌃V: writes text, posts ⌘V, does not restore (user asked for it on the clipboard).
    public func pasteLast(_ text: String) async {
        await MainActor.run { _ = PasteboardSnapshot.writeText(text) }
        try? await Task.sleep(for: .milliseconds(20))
        KeySynth.commandV()
    }

    nonisolated static func axInsert(_ el: AXUIElement, _ text: String) -> Bool {
        let before = AX.int(el, kAXNumberOfCharactersAttribute) ?? AX.string(el, kAXValueAttribute)?.count
        guard AX.set(el, kAXSelectedTextAttribute, text as CFString) else { return false }
        // verify within ~50 ms
        let deadline = Date().addingTimeInterval(0.05)
        repeat {
            let after = AX.int(el, kAXNumberOfCharactersAttribute) ?? AX.string(el, kAXValueAttribute)?.count
            if let b = before, let a = after, a != b { return true }
            if before == nil, after != nil { return true }
            usleep(5_000)
        } while Date() < deadline
        return false
    }

    static func chunks(_ s: String, size: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let piece = String(line) + "\n"
            if current.count + piece.count > size, !current.isEmpty { out.append(current); current = "" }
            current += piece
        }
        if current.hasSuffix("\n") && !s.hasSuffix("\n") { current.removeLast() }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
