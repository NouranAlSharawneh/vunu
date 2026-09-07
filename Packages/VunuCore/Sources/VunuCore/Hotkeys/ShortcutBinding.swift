import Foundation
import Carbon.HIToolbox

public enum ShortcutAction: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case pushToTalk, handsFree, commandMode, cancel, pasteLast, copyLast, scratchpad
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .handsFree: "Hands-free"
        case .commandMode: "Command Mode"
        case .cancel: "Cancel"
        case .pasteLast: "Paste last transcript"
        case .copyLast: "Copy last transcript"
        case .scratchpad: "Open Scratchpad"
        }
    }
    public var subtitle: String {
        switch self {
        case .pushToTalk: "Hold to record, release to insert"
        case .handsFree: "Press once to start, again to stop"
        case .commandMode: "Hold and describe how to edit the selected text"
        case .cancel: "Discard the current dictation"
        case .pasteLast: "Paste the most recent result again"
        case .copyLast: "Copy the most recent result"
        case .scratchpad: "Floating mini editor (hold to dictate into it)"
        }
    }
    /// Hold-style actions fire down/up; the rest fire once on chord-down.
    public var isHold: Bool { self == .pushToTalk || self == .commandMode || self == .scratchpad }
}

public enum ModifierKind: String, Codable, Sendable, CaseIterable, Hashable {
    case fn, control, command, option, shift
    /// Display order: fn, ⌃, ⌘, ⌥, ⇧
    public var order: Int { switch self { case .fn: 0; case .control: 1; case .command: 2; case .option: 3; case .shift: 4 } }
    public var glyph: String { switch self { case .fn: "fn"; case .control: "⌃"; case .command: "⌘"; case .option: "⌥"; case .shift: "⇧" } }
}

public enum ModifierSide: String, Codable, Sendable, Hashable { case any, left, right }

public struct ModifierKey: Codable, Sendable, Hashable {
    public var kind: ModifierKind
    public var side: ModifierSide
    public init(_ kind: ModifierKind, side: ModifierSide = .any) { self.kind = kind; self.side = side }
    public var display: String { side == .right ? "→" + kind.glyph : kind.glyph }
    public static let fn = ModifierKey(.fn)
    public static let control = ModifierKey(.control)
    public static let command = ModifierKey(.command)
    public static let option = ModifierKey(.option)
    public static let shift = ModifierKey(.shift)
}

/// A key chord: modifiers + optional regular key + optional mouse button. At most 3 keys total.
public struct ShortcutBinding: Codable, Sendable, Hashable, Identifiable {
    public var modifiers: Set<ModifierKey>
    public var keyCode: UInt16?
    public var mouseButton: Int?   // CGEvent button number: 2 = middle, 3... = Mouse 4+
    public var id: String { display }

    public init(modifiers: Set<ModifierKey> = [], keyCode: UInt16? = nil, mouseButton: Int? = nil) {
        self.modifiers = modifiers; self.keyCode = keyCode; self.mouseButton = mouseButton
    }

    public var keyCount: Int { modifiers.count + (keyCode == nil ? 0 : 1) + (mouseButton == nil ? 0 : 1) }
    public var isModifierOnly: Bool { keyCode == nil && mouseButton == nil }
    public var isFnAlone: Bool { modifiers == [.fn] && isModifierOnly }

    public var display: String {
        var parts = modifiers.sorted { ($0.kind.order, $0.side.rawValue) < ($1.kind.order, $1.side.rawValue) }.map(\.display)
        if let k = keyCode { parts.append(KeyNames.name(for: k)) }
        if let b = mouseButton { parts.append(b == 2 ? "Middle click" : "Mouse \(b + 1)") }
        return parts.joined(separator: " ")
    }

    public static let defaults: [ShortcutAction: [ShortcutBinding]] = [
        .pushToTalk: [ShortcutBinding(modifiers: [.fn])],
        .handsFree: [ShortcutBinding(modifiers: [.fn], keyCode: UInt16(kVK_Space))],
        .commandMode: [ShortcutBinding(modifiers: [.fn, .control])],
        .cancel: [ShortcutBinding(keyCode: UInt16(kVK_Escape))],
        .pasteLast: [ShortcutBinding(modifiers: [.command, .control], keyCode: UInt16(kVK_ANSI_V))],
        .copyLast: [ShortcutBinding(modifiers: [.command, .control], keyCode: UInt16(kVK_ANSI_C))],
        .scratchpad: [ShortcutBinding(modifiers: [.option], keyCode: UInt16(kVK_ANSI_S))],
    ]
    /// Fallback PTT when the keyboard has no Apple fn key.
    public static let pttFallback = ShortcutBinding(modifiers: [.control, .option])
}

public enum KeyNames {
    nonisolated(unsafe) private static let table: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Escape): "Esc", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓", UInt16(kVK_Home): "Home", UInt16(kVK_End): "End",
        UInt16(kVK_PageUp): "PgUp", UInt16(kVK_PageDown): "PgDn", UInt16(kVK_CapsLock): "Caps Lock",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12", UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C", UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E",
        UInt16(kVK_ANSI_F): "F", UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I", UInt16(kVK_ANSI_J): "J",
        UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L", UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
        UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R", UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T",
        UInt16(kVK_ANSI_U): "U", UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X", UInt16(kVK_ANSI_Y): "Y",
        UInt16(kVK_ANSI_Z): "Z", UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2", UInt16(kVK_ANSI_3): "3",
        UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5", UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9", UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_Equal): "=", UInt16(kVK_ANSI_LeftBracket): "[",
        UInt16(kVK_ANSI_RightBracket): "]", UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Semicolon): ";", UInt16(kVK_ANSI_Quote): "'",
        UInt16(kVK_ANSI_Comma): ",", UInt16(kVK_ANSI_Period): ".", UInt16(kVK_ANSI_Slash): "/", UInt16(kVK_ANSI_Grave): "`",
    ]
    public static func name(for keyCode: UInt16) -> String { table[keyCode] ?? "Key \(keyCode)" }
    public static func isModifierKeyCode(_ k: UInt16) -> Bool {
        [kVK_Function, kVK_Shift, kVK_RightShift, kVK_Control, kVK_RightControl, kVK_Option, kVK_RightOption, kVK_Command, kVK_RightCommand, kVK_CapsLock].contains(Int(k))
    }
}
