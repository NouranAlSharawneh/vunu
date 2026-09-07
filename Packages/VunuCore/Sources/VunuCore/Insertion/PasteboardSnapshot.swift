import Foundation
import AppKit

/// Saves and restores the general pasteboard around a synthetic ⌘V.
/// Skips file URLs / RTFD / PDF / audio (same as Wispr) — those are not restored.
public struct PasteboardSnapshot: @unchecked Sendable {
    public static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    public static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let skipped: Set<String> = ["public.file-url", "com.apple.flat-rtfd", "com.adobe.pdf", "public.audio", "com.apple.finder.noderef", "NSFilenamesPboardType"]

    private var items: [[NSPasteboard.PasteboardType: Data]] = []
    public private(set) var changeCount: Int

    public init(_ pb: NSPasteboard = .general) {
        changeCount = pb.changeCount
        for item in pb.pasteboardItems ?? [] {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types where !Self.skipped.contains(type.rawValue) && !type.rawValue.hasPrefix("dyn.") {
                if let d = item.data(forType: type) { dict[type] = d }
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
