import XCTest
@testable import VunuCore

final class VibeCodingTests: XCTestCase {
    func testFileTagging() {
        XCTAssertEqual(VibeCodingRules.apply("look at main dot py and fix the bug", visibleSymbols: []), "look @main.py and fix the bug")
        XCTAssertEqual(VibeCodingRules.apply("add at session coordinator dot swift to context", visibleSymbols: []), "add @SessionCoordinator.swift to context")
        XCTAssertEqual(VibeCodingRules.apply("at focus tracker dot swift", visibleSymbols: ["FocusTracker"]), "@FocusTracker.swift")
        XCTAssertEqual(VibeCodingRules.apply("at user service dot py", visibleSymbols: []), "@user_service.py")
        XCTAssertEqual(VibeCodingRules.apply("open main dot py", visibleSymbols: []), "open `main.py`")
        XCTAssertEqual(VibeCodingRules.apply("at package.json", visibleSymbols: []), "@package.json")
        XCTAssertEqual(VibeCodingRules.apply("check the dot env file", visibleSymbols: []), "check the .env file")
    }
    func testIdentifiers() {
        XCTAssertEqual(VibeCodingRules.apply("rename getUserName to fetch_user_name", visibleSymbols: []), "rename `getUserName` to `fetch_user_name`")
        XCTAssertEqual(VibeCodingRules.apply("call session coordinator here", visibleSymbols: ["SessionCoordinator"]), "call session coordinator here")
        XCTAssertEqual(VibeCodingRules.apply("update the focustracker", visibleSymbols: ["FocusTracker"]), "update the `FocusTracker`")
        XCTAssertEqual(VibeCodingRules.apply("open config.yaml please", visibleSymbols: []), "open `config.yaml` please")
    }
    func testSymbolsExtraction() {
        let syms = VibeCodingRules.symbols(in: "let focusTracker = FocusTracker.shared\nfunc load_models() {}\nlet x = 1")
        XCTAssertTrue(syms.contains("focusTracker") && syms.contains("FocusTracker") && syms.contains("load_models"))
    }
    func testEditWatcher() {
        XCTAssertEqual(EditWatcher.singleWordCorrection(original: "ping Nuno about it", current: "hello\nping Nunu about it.")?.1, "Nunu")
        XCTAssertNil(EditWatcher.singleWordCorrection(original: "ping Nuno about it", current: "ping Nuno about it"))
        XCTAssertNil(EditWatcher.singleWordCorrection(original: "one two three", current: "completely different text here"))
    }
}
