import XCTest
import AppKit
@testable import VunuCore

/// Runs against a private pasteboard with a no-op ⌘V; "the target app" is simulated by reading the pasteboard.
@MainActor
final class ClipboardGuardTests: XCTestCase {
    private var pb: NSPasteboard!
    private var posted = 0

    override func setUp() async throws {
        pb = NSPasteboard(name: NSPasteboard.Name("dev.nunu.vunu.tests.\(UUID().uuidString)"))
        posted = 0
    }
    override func tearDown() async throws { pb.releaseGlobally() }

    private func makeGuard(cap: Duration = .seconds(8)) -> ClipboardGuard {
        ClipboardGuard(pasteboard: pb, cap: cap, postPaste: { [weak self] stamp in stamp(); self?.posted += 1; return (9, 0) })
    }
    private func copy(_ s: String) { pb.clearContents(); pb.setString(s, forType: .string) }
    private func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    func testTargetReadsDictationThenOldClipboardReturns() async {
        copy("old")
        let g = makeGuard()
        _ = await g.paste("dictation", minHold: .milliseconds(300))
        XCTAssertEqual(posted, 1)
        await wait(100)
        XCTAssertEqual(pb.string(forType: .string), "dictation")   // the target's read (served by the promise)
        await wait(150)
        XCTAssertNotEqual(pb.string(forType: .string), "old", "must not restore before the minimum hold")
        await wait(600)
        XCTAssertEqual(pb.string(forType: .string), "old")
    }

    func testLateReaderStillGetsTheDictation() async {
        // cmux reads ~1.1–1.6 s after ⌘V; with no read yet nothing is restored before the cap.
        copy("old")
        let g = makeGuard(cap: .seconds(3))
        _ = await g.paste("dictation", minHold: .milliseconds(300))
        await wait(1_300)
        XCTAssertEqual(pb.string(forType: .string), "dictation")
        await wait(700)   // read at 1.3 s + quiet gap
        XCTAssertEqual(pb.string(forType: .string), "old")
    }

    func testSomethingCopiedDuringTheHoldIsKept() async {
        copy("old")
        let g = makeGuard()
        _ = await g.paste("dictation", minHold: .milliseconds(200))
        _ = pb.string(forType: .string)
        copy("copied meanwhile")
        await wait(700)
        XCTAssertEqual(pb.string(forType: .string), "copied meanwhile")
    }

    func testBackToBackDictationsRestoreTheOriginalClipboard() async {
        copy("old")
        let g = makeGuard()
        _ = await g.paste("one", minHold: .milliseconds(200))
        XCTAssertEqual(pb.string(forType: .string), "one")
        _ = await g.paste("two", minHold: .milliseconds(200))   // waits for "one"'s safe point, keeps "old" as the original
        XCTAssertEqual(pb.string(forType: .string), "two")
        await wait(700)
        XCTAssertEqual(pb.string(forType: .string), "old")
    }

    func testNoReadRestoresAtTheCap() async {
        copy("old")
        let g = makeGuard(cap: .milliseconds(600))
        _ = await g.paste("dictation", minHold: .milliseconds(200))
        await wait(1_000)
        XCTAssertEqual(pb.string(forType: .string), "old")
    }

    func testEarlyReadDoesNotShortenTheHoldForEnterOrTheNextDictation() async {
        // A clipboard manager reading right after ⌘V must not let "press enter" / the next paste go before a slow target.
        copy("old")
        let g = makeGuard()
        _ = await g.paste("dictation", minHold: .milliseconds(700))
        _ = pb.string(forType: .string)
        let clock = ContinuousClock()
        let start = clock.now
        await g.waitForSafePoint()
        XCTAssertGreaterThanOrEqual(clock.now - start, .milliseconds(600))
    }

    func testFinishNowRestoresImmediately() async {
        copy("old")
        let g = makeGuard()
        _ = await g.paste("dictation", minHold: .seconds(5))
        g.finishNow()
        XCTAssertEqual(pb.string(forType: .string), "old")
    }
}
