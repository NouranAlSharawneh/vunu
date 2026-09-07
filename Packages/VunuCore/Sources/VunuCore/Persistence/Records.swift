import Foundation
import GRDB

public enum TranscriptStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case done, failed, cancelled, recovering, processing
}

public struct Transcript: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "transcript"
    public var id: Int64?
    public var createdAt: Date
    public var durationSec: Double
    public var rawText: String
    public var formattedText: String
    public var editedText: String?
    public var insertedText: String?      // what actually went into the app (after casing/spacing)
    public var appBundleID: String?
    public var appName: String
    public var audioPath: String?
    public var status: TranscriptStatus
    public var errorMessage: String?
    public var timingsJSON: String?
    public var language: String?
    public var mode: String
    public var flagged: Bool
    public var aiEditApplied: Bool        // whether formattedText came from the LLM (for Undo/Redo AI edit)
    public var wordCount: Int

    public init(createdAt: Date = Date(), durationSec: Double = 0, rawText: String = "", formattedText: String = "", appBundleID: String? = nil,
                appName: String = "", audioPath: String? = nil, status: TranscriptStatus = .processing, mode: String = "pushToTalk") {
        self.createdAt = createdAt; self.durationSec = durationSec; self.rawText = rawText; self.formattedText = formattedText
        self.appBundleID = appBundleID; self.appName = appName; self.audioPath = audioPath; self.status = status; self.mode = mode
        self.flagged = false; self.aiEditApplied = false; self.wordCount = 0
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var displayText: String { editedText ?? formattedText }
    public var timings: StageTimings? {
        guard let j = timingsJSON, let d = j.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StageTimings.self, from: d)
    }
}

public struct DictionaryEntry: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "dictionaryEntry"
    public var id: Int64?
    public var word: String
    public var misspelling: String?
    public var starred: Bool
    public var createdAt: Date
    public init(word: String, misspelling: String? = nil, starred: Bool = false, createdAt: Date = Date()) {
        self.word = word; self.misspelling = misspelling; self.starred = starred; self.createdAt = createdAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Snippet: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "snippet"
    public var id: Int64?
    public var phrase: String
    public var replacement: String
    public var createdAt: Date
    public init(phrase: String, replacement: String, createdAt: Date = Date()) {
        self.phrase = phrase; self.replacement = replacement; self.createdAt = createdAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
