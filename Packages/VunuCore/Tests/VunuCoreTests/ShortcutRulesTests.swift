import XCTest
import Carbon.HIToolbox
@testable import VunuCore

final class ShortcutRulesTests: XCTestCase {
    let existing = ShortcutBinding.defaults
    func k(_ v: Int) -> UInt16 { UInt16(v) }

    func testReservedCombos() {
        XCTAssertEqual(ShortcutRules.validate(ShortcutBinding(modifiers: [.command], keyCode: k(kVK_ANSI_C)), for: .pasteLast, existing: existing), .reserved("⌘ C"))
        XCTAssertEqual(ShortcutRules.validate(ShortcutBinding(modifiers: [.fn], keyCode: k(kVK_F11)), for: .pasteLast, existing: existing), .reserved("fn F11"))
        XCTAssertEqual(ShortcutRules.validate(ShortcutBinding(modifiers: [.command, .shift], keyCode: k(kVK_ANSI_4)), for: .pasteLast, existing: existing), .reserved("⌘ ⇧ 4"))
        XCTAssertEqual(ShortcutRules.validate(ShortcutBinding(modifiers: [.control], keyCode: k(kVK_ANSI_A)), for: .pasteLast, existing: existing), .reserved("⌃ A"))
    }
    func testRules() {
        XCTAssertEqual(ShortcutRules.validate(ShortcutBinding(keyCode: k(kVK_ANSI_A)), for: .pasteLast, existing: existing), .missingModifier)
        XCTAssertNil(ShortcutRules.validate(ShortcutBinding(keyCode: k(kVK_Escape)), for: .cancel, existing: existing))
        XCTAssertEqual(ShortcutRules.validate(ShortcutBinding(modifiers: [.command, .option, .shift], keyCode: k(kVK_ANSI_P)), for: .pasteLast, existing: existing), .tooManyKeys)
        XCTAssertEqual(ShortcutRules.validate(ShortcutBinding(modifiers: [ModifierKey(.shift, side: .left), ModifierKey(.shift, side: .right)], keyCode: k(kVK_ANSI_P)), for: .pasteLast, existing: existing), .mixedSides(.shift))
        XCTAssertEqual(ShortcutRules.validate(ShortcutBinding(modifiers: [.command], keyCode: k(kVK_CapsLock)), for: .pasteLast, existing: existing), .capsLock)
        XCTAssertEqual(ShortcutRules.validate(ShortcutBinding(modifiers: [.fn], keyCode: k(kVK_Space)), for: .pasteLast, existing: existing), .inUse(.handsFree))
        XCTAssertNil(ShortcutRules.validate(ShortcutBinding(modifiers: [.fn]), for: .pushToTalk, existing: existing))
        XCTAssertNil(ShortcutRules.validate(ShortcutBinding(mouseButton: 2), for: .pushToTalk, existing: existing))
    }
    func testDisplayOrder() {
        let b = ShortcutBinding(modifiers: [.shift, .command, .fn, ModifierKey(.option, side: .right)], keyCode: k(kVK_ANSI_S))
        XCTAssertEqual(b.display, "fn ⌘ →⌥ ⇧ S")
    }
}
