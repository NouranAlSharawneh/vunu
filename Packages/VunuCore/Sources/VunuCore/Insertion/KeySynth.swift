import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// Posts synthetic keystrokes (⌘V, Return) tagged so our own event tap ignores them.
public enum KeySynth {
    private static func post(keyCode: CGKeyCode, flags: CGEventFlags, down: Bool) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: EventTapMonitor.selfMarker)
        e.post(tap: .cghidEventTap)
    }
    public static func tap(keyCode: Int, flags: CGEventFlags = []) {
        post(keyCode: CGKeyCode(keyCode), flags: flags, down: true)
        post(keyCode: CGKeyCode(keyCode), flags: flags, down: false)
    }
    public static func commandV() { tap(keyCode: kVK_ANSI_V, flags: .maskCommand) }
    public static func commandShiftV() { tap(keyCode: kVK_ANSI_V, flags: [.maskCommand, .maskShift]) }
    public static func returnKey() { tap(keyCode: kVK_Return) }
}
