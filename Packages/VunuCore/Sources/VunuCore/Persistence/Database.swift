import Foundation
import GRDB

/// SQLite via GRDB. One queue; all reads/writes go through here.
public final class Database: Sendable {
    public static let shared = Database()
    public let queue: DatabaseQueue

    private init() {
        var config = Configuration()
        config.foreignKeysEnabled = true
        if let q = try? DatabaseQueue(path: Paths.database.path, configuration: config) {
            queue = q
        } else {
            Log.persistence.error("database open failed — falling back to in-memory")
            queue = try! DatabaseQueue(configuration: config)
        }
        do { try migrate(); Log.persistence.info("database ready at \(Paths.database.path)") } catch { Log.persistence.error("migration failed: \(error)") }
    }

    public init(inMemory: Bool) {
        queue = try! DatabaseQueue()
        try? migrate()
    }

    private func migrate() throws {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "transcript") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("durationSec", .double).notNull().defaults(to: 0)
                t.column("rawText", .text).notNull().defaults(to: "")
                t.column("formattedText", .text).notNull().defaults(to: "")
                t.column("editedText", .text)
                t.column("insertedText", .text)
                t.column("appBundleID", .text)
                t.column("appName", .text).notNull().defaults(to: "")
                t.column("audioPath", .text)
                t.column("status", .text).notNull().defaults(to: "done")
                t.column("errorMessage", .text)
                t.column("timingsJSON", .text)
                t.column("language", .text)
                t.column("mode", .text).notNull().defaults(to: "pushToTalk")
                t.column("flagged", .boolean).notNull().defaults(to: false)
                t.column("aiEditApplied", .boolean).notNull().defaults(to: false)
                t.column("wordCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "dictionaryEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("word", .text).notNull().unique(onConflict: .ignore)
                t.column("misspelling", .text)
                t.column("starred", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "snippet") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("phrase", .text).notNull().unique(onConflict: .replace)
                t.column("replacement", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        try m.migrate(queue)
    }

    // MARK: transcripts
    @discardableResult public func save(_ t: Transcript) throws -> Transcript {
        try queue.write { db in var c = t; try c.save(db); return c }
    }
    public func transcripts(limit: Int = 500, search: String? = nil) throws -> [Transcript] {
        try queue.read { db in
            var req = Transcript.order(Column("createdAt").desc).limit(limit)
            if let s = search, !s.isEmpty {
                let pat = "%\(s)%"
                req = req.filter(Column("formattedText").like(pat) || Column("rawText").like(pat) || Column("appName").like(pat))
            }
            return try req.fetchAll(db)
        }
    }
    public func transcript(id: Int64) throws -> Transcript? { try queue.read { try Transcript.fetchOne($0, key: id) } }
    public func latestTranscript() throws -> Transcript? {
        try queue.read { try Transcript.filter(Column("status") == TranscriptStatus.done.rawValue).order(Column("createdAt").desc).fetchOne($0) }
    }
    public func deleteTranscript(id: Int64) throws { _ = try queue.write { try Transcript.deleteOne($0, key: id) } }
    public func markStaleProcessing() throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE transcript SET status = ? WHERE status = ?", arguments: [TranscriptStatus.recovering.rawValue, TranscriptStatus.processing.rawValue])
        }
    }
    public struct Stats: Sendable { public var totalWords: Int; public var avgWPM: Double; public var streakDays: Int; public var sessions: Int }
    public func stats() throws -> Stats {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT wordCount, durationSec, createdAt FROM transcript WHERE status = 'done'")
            var words = 0, secs = 0.0
            var days = Set<String>()
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
            for r in rows {
                let w: Int = r["wordCount"]; let d: Double = r["durationSec"]; let c: Date = r["createdAt"]
                words += w; secs += d; days.insert(fmt.string(from: c))
            }
            var streak = 0
            var day = Date()
            while days.contains(fmt.string(from: day)) { streak += 1; day = Calendar.current.date(byAdding: .day, value: -1, to: day)! }
            let wpm = secs > 0 ? Double(words) / (secs / 60) : 0
            return Stats(totalWords: words, avgWPM: wpm, streakDays: streak, sessions: rows.count)
        }
    }

    public func wordsToday() throws -> Int {
        try queue.read { db in
            let start = Calendar.current.startOfDay(for: Date())
            return try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(wordCount),0) FROM transcript WHERE status = 'done' AND createdAt >= ?", arguments: [start]) ?? 0
        }
    }

    // MARK: dictionary
    public func dictionary() throws -> [DictionaryEntry] { try queue.read { try DictionaryEntry.order(Column("createdAt").desc).fetchAll($0) } }
    @discardableResult public func save(_ e: DictionaryEntry) throws -> DictionaryEntry { try queue.write { db in var c = e; try c.save(db); return c } }
    public func deleteDictionary(ids: [Int64]) throws { _ = try queue.write { try DictionaryEntry.deleteAll($0, keys: ids) } }

    // MARK: snippets
    public func snippets() throws -> [Snippet] { try queue.read { try Snippet.order(Column("createdAt").desc).fetchAll($0) } }
    @discardableResult public func save(_ s: Snippet) throws -> Snippet { try queue.write { db in var c = s; try c.save(db); return c } }
    public func deleteSnippet(id: Int64) throws { _ = try queue.write { try Snippet.deleteOne($0, key: id) } }
}
