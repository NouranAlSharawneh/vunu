import XCTest
@testable import VunuCore

final class RuleFormatterTests: XCTestCase {
    let f = RuleFormatter()

    func testTable() {
        let cases: [(String, String)] = [
            // fillers + stutters + capitalization + terminal punctuation
            ("um so I think the the meeting is tomorrow", "So I think the meeting is tomorrow."),
            ("uh hello there", "Hello there."),
            ("it was, like, really big", "It was really big."),
            ("i think i'll go", "I think I'll go."),
            // spoken punctuation
            ("send me the file period thanks", "Send me the file. Thanks."),
            ("the trial period ends monday", "The trial period ends monday."),
            ("hello comma how are you question mark", "Hello, how are you?"),
            ("first line new line second line", "First line\nSecond line."),
            ("one thing new paragraph another thing", "One thing\n\nAnother thing."),
            ("wow exclamation point", "Wow!"),
            ("note colon call bob", "Note: call bob."),
            ("open paren see below close paren", "(See below)"),
            ("hashtag launch day", "#launch day."),
            ("well hyphen known fact", "Well-known fact."),
            // emails / urls
            ("email me at john at gmail dot com", "Email me at john@gmail.com."),
            ("go to wispr dot ai for more", "Go to wispr.ai for more."),
            ("visit w w w dot apple dot com slash mac", "Visit www.apple.com/mac."),
            // numbers
            ("meet at seven thirty pm", "Meet at 7:30 pm."),
            ("I have two cats", "I have two cats."),
            ("it costs twenty five dollars", "It costs $25."),
            ("about fifty percent done", "About 50% done."),
            ("three point five hours", "3.5 hours."),
            ("chapter seven is next", "Chapter 7 is next."),
            ("one of them left", "One of them left."),
            // backtrack
            ("call me at five scratch that at six", "Call me at 6."),
            ("send it to bob, scratch that, send it to alice", "Send it to alice."),
            // press enter handled by pipeline (not rules)
            ("thanks", "Thanks"),
            ("ok", "Ok"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(f.format(input), expected, "input: \(input)")
        }
    }

    func testArabicPassesThrough() {
        let s = "مرحبا كيف حالك"
        XCTAssertEqual(f.format(s), s)
    }

    func testPerformance() {
        let text = String(repeating: "um so I think the the meeting is tomorrow at seven pm comma and then we go period ", count: 8)
        let sw = Stopwatch()
        for _ in 0..<20 { _ = f.format(text) }
        XCTAssertLessThan(sw.elapsedMs / 20, 5, "rule formatter must run in < 5 ms")
    }
}

final class NumberRulesTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(NumberRules.parse(["twenty", "five"]), "25")
        XCTAssertEqual(NumberRules.parse(["one", "hundred", "and", "five"]), "105")
        XCTAssertEqual(NumberRules.parse(["three", "thousand"]), "3000")
        XCTAssertEqual(NumberRules.parse(["three", "point", "one", "four"]), "3.14")
        XCTAssertNil(NumberRules.parse(["hello"]))
    }
}

final class ListRulesTests: XCTestCase {
    let f = RuleFormatter()
    func testOrdinals() {
        XCTAssertEqual(f.format("here is what we need, first buy milk, second call mom, third finish the report"),
                       "Here is what we need:\n1. Buy milk\n2. Call mom\n3. Finish the report.")
    }
    func testNumberWords() {
        XCTAssertEqual(f.format("number one wake up number two drink coffee"), "1. Wake up\n2. Drink coffee.")
    }
    func testNoFalsePositive() {
        XCTAssertEqual(f.format("the first time I saw it I was second guessing"), "The first time I saw it I was second guessing.")
        XCTAssertEqual(f.format("we came in second place"), "We came in second place.")
    }
    func testBullets() {
        XCTAssertEqual(f.format("todo bullet point eggs bullet point bread"), "Todo:\n- Eggs\n- Bread.")
    }
}
