import Foundation
import os

/// Central logging: os.Logger per category + a rolling file log at ~/Library/Logs/Vunu/vunu.log.
public enum Log {
    public static let subsystem = "dev.nunu.vunu"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let speech = Logger(subsystem: subsystem, category: "speech")
    public static let formatting = Logger(subsystem: subsystem, category: "formatting")
    public static let context = Logger(subsystem: subsystem, category: "context")
    public static let insertion = Logger(subsystem: subsystem, category: "insertion")
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let models = Logger(subsystem: subsystem, category: "models")
    public static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Also append to the rolling file log. Cheap enough for per-session events; do not call from the tap callback.
    public static func file(_ category: String, _ message: String) {
        FileLog.shared.write(category: category, message: message)
    }
}

/// Rolling file log (2 MB, keeps one .1 backup). Thread-safe via a serial queue.
public final class FileLog: Sendable {
    public static let shared = FileLog()
    private let queue = DispatchQueue(label: "dev.nunu.vunu.filelog", qos: .utility)
    private let url: URL
    private let maxBytes = 2 * 1024 * 1024

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Vunu")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("vunu.log")
    }

    public var fileURL: URL { url }

    public func write(category: String, message: String) {
        let ts = ISO8601DateFormatter.shared.string(from: Date())
        let line = "\(ts) [\(category)] \(message)\n"
        queue.async { [url, maxBytes] in
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > maxBytes {
                let backup = url.deletingPathExtension().appendingPathExtension("1.log")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: url, to: backup)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
