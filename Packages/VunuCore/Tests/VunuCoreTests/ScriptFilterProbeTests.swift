import XCTest
@testable import VunuCore

final class ScriptFilterProbeTests: XCTestCase {
    func testEnglishHintBlocksCyrillic() async throws {
        let engine = ParakeetEngine(kind: .parakeetV3)
        guard await engine.isDownloaded, let wav = Bundle.module.url(forResource: "arabic_probe", withExtension: "wav", subdirectory: "Fixtures") else { throw XCTSkip("no model / fixture") }
        try await engine.load { _, _ in }
        let samples = AudioStore.load(wav)!
        let noHint = try await engine.transcribe(samples, languageHint: nil).text
        let enHint = try await engine.transcribe(samples, languageHint: "en").text
        print("no hint: \(noHint)\nen hint: \(enHint)")
        let cyrillic = { (s: String) in s.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } }
        XCTAssertFalse(cyrillic(enHint), "English hint must not produce Cyrillic")
    }
}
