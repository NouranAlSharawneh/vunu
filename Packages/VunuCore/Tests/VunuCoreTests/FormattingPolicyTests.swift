import XCTest
@testable import VunuCore

final class MessagingAppPolicyTests: XCTestCase {
    func testMessagingStripsShort() {
        XCTAssertEqual(MessagingAppPolicy.apply("See you at 5.", isMessaging: true, style: nil), "See you at 5")
        XCTAssertEqual(MessagingAppPolicy.apply("One. Two. Three.", isMessaging: true, style: nil), "One. Two. Three.")
        XCTAssertEqual(MessagingAppPolicy.apply("Really?", isMessaging: true, style: nil), "Really?")
        XCTAssertEqual(MessagingAppPolicy.apply("Wow!", isMessaging: true, style: .veryCasual), "Wow!")
        XCTAssertEqual(MessagingAppPolicy.apply("See you at 5.", isMessaging: true, style: nil, lineHasPunctuation: true), "See you at 5.")
    }
    func testStyles() {
        XCTAssertEqual(MessagingAppPolicy.apply("See you at 5.", isMessaging: false, style: .formal), "See you at 5.")
        XCTAssertEqual(MessagingAppPolicy.apply("See you at 5.", isMessaging: false, style: .casual), "See you at 5")
        XCTAssertEqual(MessagingAppPolicy.apply("See you at 5.", isMessaging: false, style: .veryCasual), "See you at 5")
        XCTAssertEqual(MessagingAppPolicy.apply("See you at 5.", isMessaging: false, style: .excited), "See you at 5.")
        XCTAssertEqual(MessagingAppPolicy.apply("See you at 5.", isMessaging: false, style: nil), "See you at 5.")
    }
    func testVeryCasualLowercasesButPreservesDictionary() {
        XCTAssertEqual(StylePolicy.apply("Hey Sarah, GitHub is down.", style: .veryCasual, preserve: ["GitHub"]), "hey sarah, GitHub is down.")
    }
}

final class SnippetExpanderTests: XCTestCase {
    let ex = SnippetExpander(snippets: [Snippet(phrase: "my email address", replacement: "nunu@example.com"), Snippet(phrase: "sig", replacement: "Best,\nNunu")])
    func testWholeDictation() { XCTAssertEqual(ex.expand("My email address."), "nunu@example.com") }
    func testInline() { XCTAssertEqual(ex.expand("Send it to my email address please"), "Send it to nunu@example.com please") }
    func testNoPartialWord() { XCTAssertEqual(ex.expand("signature"), "signature") }
    func testCaseInsensitive() { XCTAssertEqual(ex.expand("MY EMAIL ADDRESS is old"), "nunu@example.com is old") }
}

final class DictionaryApplierTests: XCTestCase {
    let d = DictionaryApplier(entries: [DictionaryEntry(word: "Nunu", misspelling: "new new"), DictionaryEntry(word: "GitHub"), DictionaryEntry(word: "Wispr Flow", misspelling: "whisper flow")])
    func testMisspelling() { XCTAssertEqual(d.apply("hi new new, how is github"), "hi Nunu, how is GitHub") }
    func testPhrase() { XCTAssertEqual(d.apply("I use whisper flow daily"), "I use Wispr Flow daily") }
    func testWholeWordOnly() { XCTAssertEqual(d.apply("githubber"), "githubber") }
}

final class CasingSpacingTests: XCTestCase {
    func testMidSentence() {
        let d = CasingSpacing.decide(text: "And then we left.", context: SurroundingText(before: "We ate dinner", after: ""))
        XCTAssertTrue(d.leadingSpace); XCTAssertTrue(d.lowercaseFirst); XCTAssertFalse(d.trailingSpace)
        XCTAssertEqual(CasingSpacing.apply("And then we left.", d), " and then we left.")
    }
    func testAfterSentence() {
        let d = CasingSpacing.decide(text: "Next thing.", context: SurroundingText(before: "Done. ", after: ""))
        XCTAssertFalse(d.leadingSpace); XCTAssertFalse(d.lowercaseFirst)
    }
    func testAfterPeriodNoSpace() {
        let d = CasingSpacing.decide(text: "Next thing.", context: SurroundingText(before: "Done.", after: ""))
        XCTAssertTrue(d.leadingSpace); XCTAssertFalse(d.lowercaseFirst)
    }
    func testTrailingSpaceBeforeLetter() {
        let d = CasingSpacing.decide(text: "inserted", context: SurroundingText(before: "before ", after: "after"))
        XCTAssertFalse(d.leadingSpace); XCTAssertTrue(d.trailingSpace)
    }
    func testProperNounKept() {
        let d = CasingSpacing.decide(text: "Nunu said hi.", context: SurroundingText(before: "and then", after: ""), properNouns: ["Nunu"])
        XCTAssertFalse(d.lowercaseFirst)
        let i = CasingSpacing.decide(text: "I said hi.", context: SurroundingText(before: "and then", after: ""))
        XCTAssertFalse(i.lowercaseFirst)
    }
    func testEmptyLineStart() {
        let d = CasingSpacing.decide(text: "Hello.", context: SurroundingText(before: "line one\n", after: ""))
        XCTAssertFalse(d.leadingSpace); XCTAssertFalse(d.lowercaseFirst)
    }
    func testNoContext() {
        let d = CasingSpacing.decide(text: "Hello.", context: nil)
        XCTAssertEqual(CasingSpacing.apply("Hello.", d), "Hello.")
    }
}

final class GuardRailsTests: XCTestCase {
    func testRejectsAnswers() {
        XCTAssertNotNil(GuardRails.check(input: "what is the capital of france", output: "The capital of France is Paris.", dictionaryWords: []))
        XCTAssertNotNil(GuardRails.check(input: "um can you send the report", output: "Sure! Here is the report.", dictionaryWords: []))
        XCTAssertNotNil(GuardRails.check(input: "hello there friend", output: "```\nHello there, friend.\n```", dictionaryWords: []))
    }
    func testAcceptsCleanup() {
        XCTAssertNil(GuardRails.check(input: "um so the the meeting is at 3 tomorrow", output: "So the meeting is at 3 tomorrow.", dictionaryWords: []))
        XCTAssertNil(GuardRails.check(input: "coffee at 2 actually 3 works", output: "Coffee at 3 works.", dictionaryWords: []))
    }
    func testNumbersAndDictionary() {
        XCTAssertNotNil(GuardRails.check(input: "call me at 555 1234 today", output: "Call me at 555 4321 today.", dictionaryWords: []))
        XCTAssertNotNil(GuardRails.check(input: "ping Nunu about github", output: "Ping Nuno about GitHub.", dictionaryWords: ["Nunu"]))
    }
}

final class AppCategoryTests: XCTestCase {
    func testCategories() {
        let r = AppCategoryResolver()
        XCTAssertEqual(r.category(bundleID: "com.tinyspeck.slackmacgap", url: nil), .work)
        XCTAssertEqual(r.category(bundleID: "com.apple.Safari", url: URL(string: "https://mail.google.com/mail/u/0/")), .email)
        XCTAssertEqual(r.category(bundleID: "com.google.Chrome", url: URL(string: "https://web.whatsapp.com/")), .personal)
        XCTAssertEqual(r.category(bundleID: "com.apple.TextEdit", url: nil), .other)
        XCTAssertEqual(AppCategoryResolver(extraApps: [.email: ["com.apple.TextEdit"]]).category(bundleID: "com.apple.TextEdit", url: nil), .email)
        XCTAssertTrue(AppCategoryResolver.isMessaging(bundleID: "com.apple.MobileSMS", url: nil))
        XCTAssertFalse(AppCategoryResolver.isMessaging(bundleID: "com.apple.mail", url: nil))
    }
}

final class InserterChunkTests: XCTestCase {
    func testChunks() {
        let text = (0..<60).map { "line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n")
        let chunks = Inserter.chunks(text, size: 800)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text)
        for c in chunks { XCTAssertLessThanOrEqual(c.count, 900) }
    }
}

final class PressEnterTests: XCTestCase {
    func testDetection() async {
        let p = FormattingPipeline(llm: nil)
        var ctx = FormatContext(); ctx.cleanupLevel = .none
        let out = await p.format("send the invoice today press enter", context: ctx)
        XCTAssertTrue(out.pressEnter)
        XCTAssertEqual(out.text, "Send the invoice today.")
        let out2 = await p.format("please press enter twice to confirm", context: ctx)
        XCTAssertFalse(out2.pressEnter)
    }
}
