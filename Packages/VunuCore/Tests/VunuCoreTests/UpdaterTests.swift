import XCTest
@testable import VunuCore

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("0.2.1", than: "0.2.0"))
        XCTAssertTrue(Updater.isNewer("0.10.0", than: "0.9.3"))
        XCTAssertTrue(Updater.isNewer("1.0", than: "0.99.99"))
        XCTAssertFalse(Updater.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(Updater.isNewer("0.2", than: "0.2.0"))
        XCTAssertFalse(Updater.isNewer("0.1.9", than: "0.2.0"))
    }

    func testParseRelease() throws {
        let json = """
        {"tag_name":"v0.3.0","body":"Notes","html_url":"https://github.com/o/r/releases/tag/v0.3.0","draft":false,"prerelease":false,
         "assets":[{"name":"checksums.txt","browser_download_url":"https://example.com/c.txt"},
                   {"name":"Vunu-0.3.0.zip","browser_download_url":"https://example.com/Vunu-0.3.0.zip"}]}
        """
        let r = try Updater.parse(Data(json.utf8))
        XCTAssertEqual(r.version, "0.3.0")
        XCTAssertEqual(r.zipURL.absoluteString, "https://example.com/Vunu-0.3.0.zip")
        XCTAssertEqual(r.notes, "Notes")
    }

    func testParseRejectsPrereleaseAndMissingZip() {
        let pre = #"{"tag_name":"v1","html_url":"https://x.y","draft":false,"prerelease":true,"assets":[{"name":"Vunu.zip","browser_download_url":"https://x.y/a.zip"}]}"#
        XCTAssertThrowsError(try Updater.parse(Data(pre.utf8)))
        let noZip = #"{"tag_name":"v1","html_url":"https://x.y","draft":false,"prerelease":false,"assets":[]}"#
        XCTAssertThrowsError(try Updater.parse(Data(noZip.utf8)))
    }

    /// Live: fetch the latest GitHub release, download + unpack it, and verify it against the installed app's certificate.
    /// Set VUNU_LIVE_UPDATE_TEST=1 to run (needs network and /Applications/Vunu.app).
    func testLiveDownloadAndVerify() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VUNU_LIVE_UPDATE_TEST"] == "1", "live test disabled")
        let installed = URL(fileURLWithPath: "/Applications/Vunu.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: installed.path))
        let release = try await Updater.fetchLatest()
        let app = try await Updater.downloadAndUnpack(release.zipURL)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent().deletingLastPathComponent()) }
        XCTAssertNoThrow(try Updater.verify(newApp: app, expectedVersion: release.version, reference: installed))
        XCTAssertThrowsError(try Updater.verify(newApp: app, expectedVersion: "9.9.9", reference: installed))
    }
}
