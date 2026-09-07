import Foundation

/// WhisperKit large-v3-turbo (Arabic + 90 languages). Wired in M6; until the package is added this reports unavailable.
public actor WhisperKitEngine: TranscriptionEngine {
    public static let shared = WhisperKitEngine()
    public let kind: SttEngineKind = .whisperKit
    public static let modelDirectory = Paths.models.appendingPathComponent("whisperkit", isDirectory: true)
    private var loaded = false
    private init() {}
    public var isLoaded: Bool { loaded }
    public var isDownloaded: Bool { FileManager.default.fileExists(atPath: Self.modelDirectory.appendingPathComponent("config.json").path) }
    public func load(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        throw VunuError.engineUnavailable("WhisperKit is not bundled in this build yet")
    }
    public func unload() async { loaded = false }
    public func transcribe(_ samples: [Float], languageHint: String?) async throws -> TranscriptionResult {
        throw VunuError.engineUnavailable("WhisperKit")
    }
}
