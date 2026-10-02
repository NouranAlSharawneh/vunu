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
        let singlePaste = target.bundleID.map { AppCatalog.singlePasteTerminals.contains($0) } ?? false
        let chunked = isTerminal && !singlePaste && payload.count > 1_500
        // A restore still pending from the previous dictation means the clipboard holds our text, not the user's: keep the original.
        let snapshot: PasteboardSnapshot
        if let p = pendingRestore, await MainActor.run(body: { NSPasteboard.general.changeCount }) == p.changeCount {
            p.task.cancel()
            snapshot = p.snapshot
        } else {
            snapshot = await MainActor.run { PasteboardSnapshot() }
        }
        pendingRestore = nil
        let pieces = chunked ? Self.chunks(payload, size: 800) : [payload]
        var ours = 0
        for (i, piece) in pieces.enumerated() {
            ours = await MainActor.run { PasteboardSnapshot.writeText(piece) }
            KeySynth.commandV()
            try? await Task.sleep(for: .milliseconds(i < pieces.count - 1 ? 60 : 0))
        }
        // Apps read the pasteboard some time after ⌘V (cmux ~1–1.6 s, Electron a few hundred ms). Restoring before that pastes
        // the old clipboard, or nothing. Hold long enough, and never in a way Esc (task cancellation) can cut short.
        let hold = Self.restoreHold(isTerminal: isTerminal, isElectron: target.isBrowserElectron)
        let written = ours
        if pressEnter {
            await Self.uncancellableSleep(hold)
            KeySynth.returnKey()
            try? await Task.sleep(for: .milliseconds(50))
            await MainActor.run { Self.restore(snapshot, ifStill: written) }
        } else {
            let task = Task.detached {
                try? await Task.sleep(for: hold)
                guard !Task.isCancelled else { return }
                await MainActor.run { Self.restore(snapshot, ifStill: written) }
            }
            pendingRestore = (snapshot, written, task)
        }
        return .inserted(path: chunked ? "paste-chunked" : "paste")
    }

    private var pendingRestore: (snapshot: PasteboardSnapshot, changeCount: Int, task: Task<Void, Never>)?

    static func restoreHold(isTerminal: Bool, isElectron: Bool) -> Duration {
        isTerminal ? .milliseconds(2_500) : isElectron ? .milliseconds(800) : .milliseconds(250)
    }

    /// Put the user's clipboard back only if it still holds our text; anything they copied meanwhile wins.
    @MainActor static func restore(_ snapshot: PasteboardSnapshot, ifStill changeCount: Int) {
        guard NSPasteboard.general.changeCount == changeCount else {
            Log.file("paste", "restore skipped: clipboard changed since paste")
            return
        }
        snapshot.restore()
    }

    /// Esc cancels the processing task, which would turn every `Task.sleep` into a no-op; detached tasks are not cancelled with it.
    static func uncancellableSleep(_ d: Duration) async {
        await Task.detached { try? await Task.sleep(for: d) }.value
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
