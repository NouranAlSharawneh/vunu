import XCTest
@testable import VunuCore

final class DevVocabularyTests: XCTestCase {
    func testTerms() {
        XCTAssertEqual(DevVocabulary.apply("we use super pace and key clock with postgress"), "we use Supabase and Keycloak with Postgres")
        XCTAssertEqual(DevVocabulary.apply("open cloud code and direct us in fig ma"), "open Claude Code and Directus in Figma")
        XCTAssertEqual(DevVocabulary.apply("deploy to versal with next js and tail wind"), "deploy to Vercel with Next.js and Tailwind")
        XCTAssertEqual(DevVocabulary.apply("the cloud is grey today"), "the cloud is grey today")
        XCTAssertEqual(DevVocabulary.apply("get up early"), "get up early")
    }
    func testPipelineOrder() async {
        let p = FormattingPipeline(llm: nil)
        var ctx = FormatContext(); ctx.cleanupLevel = .none
        let out = await p.format("um so the first one is super pace, second is cloud code, third is key clock", context: ctx)
        XCTAssertEqual(out.text, "So the first one is Supabase, second is Claude Code, third is Keycloak.")
    }
    func testPerformance() {
        let text = String(repeating: "we moved from fire base to super base and deployed on versal with next js ", count: 6)
        let sw = Stopwatch()
        for _ in 0..<10 { _ = DevVocabulary.apply(text) }
        XCTAssertLessThan(sw.elapsedMs / 10, 8)
    }
}
