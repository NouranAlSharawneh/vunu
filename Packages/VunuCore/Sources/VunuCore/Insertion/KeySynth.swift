import Foundation
import CoreGraphics
import Carbon.HIToolbox
import os

/// Posts synthetic keystrokes (⌘V, Return) tagged so our own event tap ignores them.
public enum KeySynth {
    /// Key code that types "v" with ⌘ in the current layout (Dvorak puts it elsewhere; "Dvorak – QWERTY ⌘" and non-Latin
    /// layouts such as Arabic map ⌘ shortcuts back to it). Refreshed on the main thread when the input source changes.
    private static let vKey = OSAllocatedUnfairLock<CGKeyCode>(initialState: CGKeyCode(kVK_ANSI_V))

    /// A private source: modifiers the user is physically holding are not merged into our events.
    private static func post(keyCode: CGKeyCode, flags: CGEventFlags, down: Bool) {
        let src = CGEventSource(stateID: .privateState)
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: EventTapMonitor.selfMarker)
        e.post(tap: .cghidEventTap)
    }

    public static func tap(keyCode: Int, flags: CGEventFlags = []) {
        post(keyCode: CGKeyCode(keyCode), flags: flags, down: true)
        post(keyCode: CGKeyCode(keyCode), flags: flags, down: false)
    }

    /// ⌘V for the current layout. Waits (≤ 1 s) for held modifiers to be released, then holds the key ~15 ms: some systems
    /// drop chords released instantly, and a still-held ⌥ or ⌃ would turn it into a different shortcut. ⌘ rides on the V
    /// events' flags rather than separate ⌘ key events, so ⌘ can never be left stuck down.
    /// `beforeKeyDown` runs right before the key is posted (after the modifier wait), to time-stamp the paste.
    public static func paste(beforeKeyDown: @Sendable () -> Void = {}) async -> (keyCode: CGKeyCode, waitedMs: Int) {
        let waited = await waitForModifiersReleased(timeout: .seconds(1))
        let key = vKey.withLock { $0 }
        beforeKeyDown()
        post(keyCode: key, flags: .maskCommand, down: true)
        await sleep(.milliseconds(15))
        post(keyCode: key, flags: .maskCommand, down: false)
        return (key, waited)
    }

    /// Synchronous ⌘V (Command Mode diff, paste-last).
    public static func commandV() { tap(keyCode: Int(vKey.withLock { $0 }), flags: .maskCommand) }
    public static func commandShiftV() { tap(keyCode: Int(vKey.withLock { $0 }), flags: [.maskCommand, .maskShift]) }
    public static func returnKey() { tap(keyCode: kVK_Return) }

    private static let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]

    /// Returns how long it waited, in ms.
    static func waitForModifiersReleased(timeout: Duration) async -> Int {
        let clock = ContinuousClock()
        let start = clock.now
        while !CGEventSource.flagsState(.hidSystemState).intersection(modifierMask).isEmpty, clock.now - start < timeout {
            await sleep(.milliseconds(10))
        }
        let elapsed = clock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Sleeps even if the calling task was cancelled (Esc cancels processing; key timing must still hold).
    static func sleep(_ d: Duration) async {
        await Task.detached { try? await Task.sleep(for: d) }.value
    }

    // MARK: layout

    /// Call on the main thread (TIS) at launch and whenever the input source changes.
    @MainActor public static func refreshLayout() {
        let code = resolveVKeyCode()
        vKey.withLock { $0 = code }
    }

    @MainActor private static func resolveVKeyCode() -> CGKeyCode {
        if let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(), let k = keyCode(producing: "v", in: src) { return k }
        if let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(), let k = keyCode(producing: "v", in: src) { return k }
        return CGKeyCode(kVK_ANSI_V)
    }

    @MainActor private static func keyCode(producing char: Character, in source: TISInputSource) -> CGKeyCode? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData), let target = char.unicodeScalars.first?.value else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let cmd = UInt32((cmdKey >> 8) & 0xFF)
        return data.withUnsafeBytes { bytes -> CGKeyCode? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), cmd, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                if status == noErr, length == 1, UInt32(chars[0]) == target { return CGKeyCode(code) }
            }
            return nil
        }
    }
}
