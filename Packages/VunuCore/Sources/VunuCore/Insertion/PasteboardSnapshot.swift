import Foundation
import AppKit
import os

/// Saves and restores the general pasteboard around a synthetic ⌘V.
/// Keeps text, rich text, HTML, images, URLs and file URLs (up to 20 MB); other private types are not restored.
public struct PasteboardSnapshot: @unchecked Sendable {
    public static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    public static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// Reading only these keeps the snapshot cheap (no forcing other apps' lazy data) and the reads minimal for macOS's
    /// pasteboard privacy rules.
    static let kept: [NSPasteboard.PasteboardType] = [.string, .rtf, .html, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), .URL, .fileURL]
    static let maxBytes = 20 * 1024 * 1024

    private var items: [[NSPasteboard.PasteboardType: Data]] = []
    public private(set) var changeCount: Int

    public init(_ pb: NSPasteboard = .general) {
        changeCount = pb.changeCount
        var total = 0
        for item in pb.pasteboardItems ?? [] {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            let types = Set(item.types)
            for type in Self.kept where types.contains(type) {
                if let d = item.data(forType: type), total + d.count <= Self.maxBytes { dict[type] = d; total += d.count }
            }
            if !dict.isEmpty { items.append(dict) }
        }
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Write our text (marked concealed + transient so clipboard managers skip it).
    @discardableResult public static func writeText(_ text: String, to pb: NSPasteboard = .general) -> Int {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: concealed)
        item.setData(Data(), forType: transient)
        pb.writeObjects([item])
        return pb.changeCount
    }

    /// Put the previous contents back.
    public func restore(to pb: NSPasteboard = .general) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let objs: [NSPasteboardItem] = items.map { dict in
            let it = NSPasteboardItem()
            for (t, d) in dict { it.setData(d, forType: t) }
            return it
        }
        pb.writeObjects(objs)
    }
}

/// Serves the dictation lazily and records when it is read, so we know the target app actually took it.
final class PasteReceipt: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    let text: String
    private let lock = NSLock()
    private var commandVAt: ContinuousClock.Instant?
    private var reads: [ContinuousClock.Instant] = []
    private(set) var fulfilled = false

    init(text: String) { self.text = text }

    func markCommandV() { lock.withLock { commandVAt = .now } }
    var pastedAt: ContinuousClock.Instant? { lock.withLock { commandVAt } }

    /// Last read after ⌘V was posted. Reads before it are clipboard managers, not the target.
    var lastReadAfterPaste: ContinuousClock.Instant? {
        lock.withLock { guard let c = commandVAt else { return nil }; return reads.last(where: { $0 >= c }) }
    }
    var readCount: Int { lock.withLock { reads.count } }

    // AppKit calls this on the main thread when an app asks for the promised string.
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: .string)
        lock.withLock { reads.append(.now); fulfilled = true }
    }
    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}

/// Owns writing the dictation to the clipboard for a ⌘V and putting the user's clipboard back.
///
/// Apps read the pasteboard some time after ⌘V — cmux ~1.1–1.6 s later, from a helper that pastes nothing if the clipboard
/// changed meanwhile; Electron a few hundred ms. Restoring on a fixed short timer pasted the old clipboard (or nothing).
/// Now:
/// - the dictation is a promise, so we see the target read it; a read only ever *extends* the hold (a clipboard manager can
///   read first — Handy saw exactly that with Alfred);
/// - the old clipboard comes back at max(minimum hold, last read + 250 ms), 8 s at most, and only if the clipboard still
///   holds our text — anything copied meanwhile wins;
/// - writes are serialized: the next dictation waits for the previous one's safe point instead of yanking the clipboard
///   from under a slow reader;
/// - a dictation started while a restore is pending keeps the *original* clipboard, never our own text.
@MainActor
public final class ClipboardGuard {
    public static let shared = ClipboardGuard()

    private struct Hold {
        let snapshot: PasteboardSnapshot?
        let changeCount: Int
        let receipt: PasteReceipt
        let minHold: Duration
        var task: Task<Void, Never>?
    }

    private let pb: NSPasteboard
    private var hold: Hold?
    private var loggedAccess = false
    static let quietGap: Duration = .milliseconds(250)
    /// Longest the dictation stays on the clipboard when no read is seen.
    private let cap: Duration
    /// Posts ⌘V, calling its argument right before the key-down (injectable so tests never type into the frontmost app).
    typealias PostPaste = @MainActor (_ beforeKeyDown: @escaping @Sendable () -> Void) async -> (keyCode: CGKeyCode, waitedMs: Int)
    private let postPaste: PostPaste

    init(pasteboard: NSPasteboard = .general, cap: Duration = .seconds(8),
         postPaste: @escaping PostPaste = { stamp in await KeySynth.paste(beforeKeyDown: stamp) }) {
        pb = pasteboard
        self.cap = cap
        self.postPaste = postPaste
    }

    public struct Delivery: Sendable {
        public let changeCount: Int
        public let keyCode: CGKeyCode
        public let modifierWaitMs: Int
        public let preservedClipboard: Bool
    }

    /// Writes `text`, posts ⌘V, and schedules the restore. Returns once ⌘V is posted.
    func paste(_ text: String, minHold: Duration, chunk: Bool = false) async -> Delivery {
        await waitForSafePoint(strict: !chunk)
        // Keep the user's original clipboard if a restore is still pending and the clipboard is still ours.
        var snapshot: PasteboardSnapshot?
        var preserved = false
        if let h = hold, pb.changeCount == h.changeCount {
            h.task?.cancel()
            snapshot = h.snapshot
            preserved = snapshot != nil
        } else if canReadClipboard() {
            snapshot = PasteboardSnapshot(pb)
            preserved = true
        }
        hold = nil

        let receipt = PasteReceipt(text: text)
        let item = NSPasteboardItem()
        item.setDataProvider(receipt, forTypes: [.string])
        item.setData(Data(), forType: PasteboardSnapshot.concealed)
        item.setData(Data(), forType: PasteboardSnapshot.transient)
        pb.prepareForNewContents(with: .currentHostOnly)   // never sync a dictation to the iPhone via Universal Clipboard
        pb.writeObjects([item])
        let changeCount = pb.changeCount

        // Stamp at the key-down itself (after the modifier wait), so earlier reads — clipboard managers — don't count.
        let key = await postPaste { receipt.markCommandV() }
        var h = Hold(snapshot: preserved ? snapshot : nil, changeCount: changeCount, receipt: receipt, minHold: minHold, task: nil)
        h.task = Task { @MainActor [weak self] in await self?.restoreWhenSafe(changeCount: changeCount) }
        hold = h
        return Delivery(changeCount: changeCount, keyCode: key.keyCode, modifierWaitMs: key.waitedMs, preservedClipboard: preserved)
    }

    /// Waits until the previous paste is safely delivered.
    /// - strict ("press enter", the next dictation): the restore condition — minimum hold passed and 250 ms since the last
    ///   read, or the cap. The pasteboard serves a promise once, so the only read we see may be a clipboard manager's.
    /// - chunk (the next piece of one terminal paste): a read after ⌘V + quiet gap is enough, else the minimum hold.
    func waitForSafePoint(strict: Bool = true) async {
        guard let h = hold, let start = h.receipt.pastedAt else { return }
        while true {
            let now = ContinuousClock.now
            let held = now - start >= h.minHold
            if let last = h.receipt.lastReadAfterPaste, now - last >= Self.quietGap, held || !strict { return }
            if held && (!strict || h.receipt.lastReadAfterPaste == nil) { return }
            if now - start >= cap { return }
            await KeySynth.sleep(.milliseconds(25))
        }
    }

    private func restoreWhenSafe(changeCount: Int) async {
        guard let h = hold, h.changeCount == changeCount, let start = h.receipt.pastedAt else { return }
        var outcome = "cap"
        while !Task.isCancelled {
            let now = ContinuousClock.now
            if let last = h.receipt.lastReadAfterPaste {
                if now - start >= h.minHold, now - last >= Self.quietGap { outcome = "read after \(Self.ms(last - start)) ms"; break }
            }
            if now - start >= cap { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled, hold?.changeCount == changeCount else { return }   // superseded by a newer paste
        hold = nil
        guard pb.changeCount == changeCount else {
            Log.file("paste", "clipboard kept: something was copied during the paste (\(outcome))")
            return
        }
        if let snapshot = h.snapshot {
            snapshot.restore(to: pb)
            Log.file("paste", "clipboard restored (\(outcome))")
        } else {
            Log.file("paste", "dictation left on the clipboard (\(outcome); clipboard couldn't be read)")
        }
    }

    /// App quit: put the user's clipboard back now if it still holds our text, otherwise make sure no empty promise is left.
    public func finishNow() {
        guard let h = hold else { return }
        h.task?.cancel()
        hold = nil
        guard pb.changeCount == h.changeCount else { return }
        if let snapshot = h.snapshot { snapshot.restore(to: pb) } else { PasteboardSnapshot.writeText(h.receipt.text, to: pb) }
    }

    /// macOS 15.4+ can ask the user, or deny, before an app reads the clipboard programmatically. When it would, skip the
    /// snapshot (and the restore) rather than prompting on every dictation; the dictation then stays on the clipboard.
    private func canReadClipboard() -> Bool {
        let behavior = pb.accessBehavior
        if !loggedAccess { loggedAccess = true; Log.file("paste", "clipboard access behavior: \(behavior.rawValue)") }
        switch behavior {
        case .alwaysDeny, .ask:
            if !Preferences.shared.explainersShown.contains("clipboard-access") {
                Preferences.shared.explainersShown.insert("clipboard-access")
                SessionCoordinator.shared.show(SessionNotice(.info, "Vunu can't restore your clipboard", detail: "macOS asks before Vunu reads the clipboard, so dictations stay on it. Allow Vunu in System Settings → Privacy & Security → Paste from Other Apps.", action: .openPrivacyPaste, duration: 10))
            }
            return false
        default:
            return true
        }
    }

    static func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
}
