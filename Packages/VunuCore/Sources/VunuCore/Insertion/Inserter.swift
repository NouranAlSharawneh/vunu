import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

public enum InsertResult: Sendable, Equatable {
    case inserted(path: String)     // "ax" | "paste" | "paste-chunked"
    case clipboardOnly(reason: String)  // text left on clipboard; the user presses ⌘V
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

        // Path B: clipboard paste. Run as an unstructured task: Esc cancels the processing task, and every wait in here
        // (modifier release, key timing, read-before-Return) must still hold.
        let isTerminal = target.isTerminal || target.isCodeEditor
        let isElectron = target.isBrowserElectron
        let singlePaste = target.bundleID.map { AppCatalog.singlePasteTerminals.contains($0) } ?? false
        let app = target.appName
        return await Task { @MainActor in
            await Self.pasteViaClipboard(text, isTerminal: isTerminal, isElectron: isElectron, singlePaste: singlePaste, pressEnter: pressEnter, app: app)
        }.value
    }

    /// Minimum time the dictation stays on the clipboard after ⌘V; a seen read extends it (see `ClipboardGuard`).
    static func minimumHold(isTerminal: Bool, isElectron: Bool) -> Duration {
        isTerminal ? .milliseconds(2_500) : isElectron ? .milliseconds(800) : .milliseconds(600)
    }

    @MainActor private static func pasteViaClipboard(_ text: String, isTerminal: Bool, isElectron: Bool, singlePaste: Bool, pressEnter: Bool, app: String) async -> InsertResult {
        var payload = text
        if isTerminal, payload.hasSuffix("\n") { payload.removeLast() }
        // Large terminal pastes go in chunks so TUIs don't collapse them; cmux takes one bracketed paste of any size and
        // would drop earlier chunks when the clipboard changes under its reader.
        let chunked = isTerminal && !singlePaste && payload.count > 1_500
        let pieces = chunked ? chunks(payload, size: 800) : [payload]
        let hold = minimumHold(isTerminal: isTerminal, isElectron: isElectron)
        let guardian = ClipboardGuard.shared
        var last: ClipboardGuard.Delivery?
        let clock = ContinuousClock()
        let start = clock.now
        for (i, piece) in pieces.enumerated() { last = await guardian.paste(piece, minHold: hold, chunk: i > 0) }   // a chunk waits for the previous one's read
        if pressEnter {
            await guardian.waitForSafePoint()   // Return only after the target took the text
            KeySynth.returnKey()
        }
        if let d = last {
            Log.file("paste", "→ \(app): \(pieces.count > 1 ? "\(pieces.count) chunks" : "⌘V") key \(d.keyCode), modifier wait \(d.modifierWaitMs) ms, clipboard \(d.preservedClipboard ? "saved" : "not readable"), \(ClipboardGuard.ms(clock.now - start)) ms\(IsSecureEventInputEnabled() ? ", secure input on" : "")")
        }
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

    /// Sets the selected text and confirms it took: the value or the selection must change within 300 ms. Comparing
    /// character counts missed same-length replacements, and a false "failed" here falls back to pasting a second copy.
    nonisolated static func axInsert(_ el: AXUIElement, _ text: String) -> Bool {
        let beforeValue = AX.string(el, kAXValueAttribute)
        let beforeRange = AX.range(el, kAXSelectedTextRangeAttribute)
        guard AX.set(el, kAXSelectedTextAttribute, text as CFString) else { return false }
        let deadline = Date().addingTimeInterval(0.3)
        repeat {
            let value = AX.string(el, kAXValueAttribute)
            let range = AX.range(el, kAXSelectedTextRangeAttribute)
            if value != beforeValue, value != nil { return true }
            if let r = range, let b = beforeRange, r.location != b.location || r.length != b.length { return true }
            if beforeValue == nil, beforeRange == nil, value != nil || range != nil { return true }
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
