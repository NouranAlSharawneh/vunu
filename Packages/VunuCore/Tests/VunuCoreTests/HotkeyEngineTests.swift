import XCTest
import Carbon.HIToolbox
@testable import VunuCore

final class HotkeyEngineTests: XCTestCase {
    final class Sink: @unchecked Sendable { var events: [HotkeyEvent] = []; let lock = NSLock()
        func add(_ e: HotkeyEvent) { lock.lock(); events.append(e); lock.unlock() } }

    func make() -> (HotkeyEngine, Sink) {
        let sink = Sink()
        let e = HotkeyEngine { sink.add($0) }
        return (e, sink)
    }
    var t: TimeInterval = 1000
    func raw(_ kind: RawKeyEvent.Kind, _ key: Int, flags: CGEventFlags = [], dt: TimeInterval = 0.05, button: Int = 0) -> (CGEvent, RawKeyEvent) {
        t += dt
        let ev = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: kind == .keyDown)!
        ev.flags = flags
        return (ev, RawKeyEvent(kind: kind, keyCode: UInt16(key), flags: flags, mouseButton: button, isRepeat: false, time: t))
    }
    func fnDown(_ e: HotkeyEngine, dt: TimeInterval = 0.05) -> TapDecision { let (ev, r) = raw(.flagsChanged, kVK_Function, flags: .maskSecondaryFn, dt: dt); return e.handle(ev, r) }
    func fnUp(_ e: HotkeyEngine, dt: TimeInterval = 0.05) -> TapDecision { let (ev, r) = raw(.flagsChanged, kVK_Function, flags: [], dt: dt); return e.handle(ev, r) }

    func testFnHoldIsSwallowedAndEmitsPTT() {
        let (e, s) = make()
        XCTAssertEqual(fnDown(e), .swallow)
        XCTAssertEqual(fnUp(e, dt: 1.0), .swallow)
        XCTAssertEqual(s.events, [.holdBegan(.pushToTalk), .holdEnded(.pushToTalk)])
    }

    func testFnPlusArrowPassesThroughAndAborts() {
        let (e, s) = make()
        _ = fnDown(e)
        let (ev, r) = raw(.keyDown, kVK_LeftArrow, flags: .maskSecondaryFn, dt: 0.1)
        XCTAssertEqual(e.handle(ev, r), .pass)
        let (ev2, r2) = raw(.keyUp, kVK_LeftArrow, flags: .maskSecondaryFn)
        XCTAssertEqual(e.handle(ev2, r2), .pass)
        XCTAssertEqual(fnUp(e), .pass, "fn-up must pass through after a system fn combo")
        XCTAssertEqual(s.events, [.holdBegan(.pushToTalk), .holdAborted(.pushToTalk)])
    }

    func testFnSpaceTogglesHandsFree() {
        let (e, s) = make()
        _ = fnDown(e)
        let (ev, r) = raw(.keyDown, kVK_Space, flags: .maskSecondaryFn)
        XCTAssertEqual(e.handle(ev, r), .swallow)
        let (ev2, r2) = raw(.keyUp, kVK_Space, flags: .maskSecondaryFn)
        XCTAssertEqual(e.handle(ev2, r2), .swallow)
        _ = fnUp(e)
        XCTAssertEqual(s.events, [.holdBegan(.pushToTalk), .triggered(.handsFree), .holdEnded(.pushToTalk)])
    }

    func testDoubleTap() {
        let (e, s) = make()
        _ = fnDown(e); _ = fnUp(e, dt: 0.1)
        _ = fnDown(e, dt: 0.2)
        XCTAssertTrue(s.events.contains(.fnDoubleTap))
    }

    func testEscapeCancelsOnlyDuringSession() {
        let (e, s) = make()
        let (ev, r) = raw(.keyDown, kVK_Escape)
        XCTAssertEqual(e.handle(ev, r), .pass, "Esc passes through when idle")
        e.setSessionActive(true)
        let (ev2, r2) = raw(.keyDown, kVK_Escape)
        XCTAssertEqual(e.handle(ev2, r2), .swallow)
        XCTAssertTrue(s.events.contains(.triggered(.cancel)))
    }

    func testOptionSScratchpadHold() {
        let (e, s) = make()
        let (m, mr) = raw(.flagsChanged, kVK_Option, flags: .maskAlternate)
        XCTAssertEqual(e.handle(m, mr), .pass, "option alone passes through")
        let (d, dr) = raw(.keyDown, kVK_ANSI_S, flags: .maskAlternate)
        XCTAssertEqual(e.handle(d, dr), .swallow)
        let (u, ur) = raw(.keyUp, kVK_ANSI_S, flags: .maskAlternate, dt: 0.8)
        XCTAssertEqual(e.handle(u, ur), .swallow)
        let (m2, mr2) = raw(.flagsChanged, kVK_Option, flags: [])
        _ = e.handle(m2, mr2)
        XCTAssertEqual(s.events, [.holdBegan(.scratchpad), .holdEnded(.scratchpad)])
    }

    func testCommandControlVPastesLast() {
        let (e, s) = make()
        _ = e.handle(raw(.flagsChanged, kVK_Command, flags: .maskCommand).0, raw(.flagsChanged, kVK_Command, flags: .maskCommand).1)
        let (c, cr) = raw(.flagsChanged, kVK_Control, flags: [.maskCommand, .maskControl])
        _ = e.handle(c, cr)
        let (v, vr) = raw(.keyDown, kVK_ANSI_V, flags: [.maskCommand, .maskControl])
        XCTAssertEqual(e.handle(v, vr), .swallow)
        XCTAssertEqual(s.events.last, .triggered(.pasteLast))
    }

    func testPlainTypingPassesThrough() {
        let (e, s) = make()
        let (d, dr) = raw(.keyDown, kVK_ANSI_A)
        XCTAssertEqual(e.handle(d, dr), .pass)
        XCTAssertTrue(s.events.isEmpty)
    }
}
