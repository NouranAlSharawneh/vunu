import Foundation
import Carbon.HIToolbox

/// Validation of shortcut bindings (mirrors Wispr's rules).
public enum ShortcutRules {
    public enum Violation: Equatable, Sendable {
        case tooManyKeys, missingModifier, capsLock, mixedSides(ModifierKind), reserved(String), inUse(ShortcutAction)
        public var message: String {
            switch self {
            case .tooManyKeys: "Shortcut must contain 3 or fewer keys"
            case .missingModifier: "Shortcut must include a modifier key or mouse button"
            case .capsLock: "Caps Lock can't be part of a shortcut"
            case .mixedSides(let k): "Can't combine left and right \(k.glyph) in one shortcut"
            case .reserved(let s): "This shortcut is not allowed: \(s)"
            case .inUse(let a): "This shortcut is already in use by \(a.title)"
            }
        }
    }

    private static func k(_ v: Int) -> UInt16 { UInt16(v) }
    /// Reserved macOS combos. (modifiers, keyCode)
    nonisolated(unsafe) static let reserved: [ShortcutBinding] = {
        var list: [ShortcutBinding] = []
        let cmd: Set<ModifierKey> = [.command]
        for key in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_S, kVK_ANSI_N, kVK_ANSI_O,
                    kVK_ANSI_P, kVK_ANSI_F, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_T, kVK_ANSI_R, kVK_ANSI_L, kVK_ANSI_B, kVK_ANSI_I, kVK_ANSI_U,
                    kVK_ANSI_E, kVK_ANSI_G, kVK_ANSI_D, kVK_ANSI_K, kVK_ANSI_J, kVK_ANSI_Y, kVK_Space, kVK_Tab, kVK_Return, kVK_Delete,
                    kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_ANSI_Grave, kVK_Escape] {
            list.append(ShortcutBinding(modifiers: cmd, keyCode: k(key)))
        }
        for key in [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_Z, kVK_ANSI_T, kVK_ANSI_N, kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_Q, kVK_ANSI_W, kVK_Tab, kVK_Delete] {
            list.append(ShortcutBinding(modifiers: [.command, .shift], keyCode: k(key)))
        }
        for key in [kVK_ANSI_D, kVK_ANSI_H, kVK_Escape, kVK_Space, kVK_ANSI_M] {
            list.append(ShortcutBinding(modifiers: [.command, .option], keyCode: k(key)))
        }
        for key in [kVK_ANSI_A, kVK_ANSI_E, kVK_ANSI_K, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_Z, kVK_ANSI_U, kVK_ANSI_F, kVK_ANSI_B, kVK_ANSI_P, kVK_ANSI_N,
                    kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Space, kVK_Tab] {
            list.append(ShortcutBinding(modifiers: [.control], keyCode: k(key)))
        }
        for key in [kVK_F11, kVK_F12, kVK_Delete, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_ANSI_Q, kVK_ANSI_E, kVK_ANSI_F] {
            list.append(ShortcutBinding(modifiers: [.fn], keyCode: k(key)))
        }
        list.append(ShortcutBinding(modifiers: [.control, .command], keyCode: k(kVK_ANSI_Q)))
        list.append(ShortcutBinding(modifiers: [.control, .command], keyCode: k(kVK_ANSI_F)))
        list.append(ShortcutBinding(modifiers: [.control, .command], keyCode: k(kVK_Space)))
        list.append(ShortcutBinding(modifiers: [.command], keyCode: k(kVK_Escape)))
        list.append(ShortcutBinding(modifiers: [.option, .shift], keyCode: k(kVK_Escape)))
        return list
    }()

    /// Validate a binding for `action` against the current table. Returns nil when OK.
    public static func validate(_ b: ShortcutBinding, for action: ShortcutAction,
                                existing: [ShortcutAction: [ShortcutBinding]]) -> Violation? {
        if b.keyCount > 3 { return .tooManyKeys }
        if let key = b.keyCode, Int(key) == kVK_CapsLock { return .capsLock }
        if b.modifiers.isEmpty && b.mouseButton == nil {
            let isEsc = action == .cancel && b.keyCode.map { Int($0) == kVK_Escape } == true
            if !isEsc { return .missingModifier }
        }
        for kind in ModifierKind.allCases {
            let sides = Set(b.modifiers.filter { $0.kind == kind }.map(\.side))
            if sides.count > 1 { return .mixedSides(kind) }
        }
        let normalized = normalize(b)
        if reserved.contains(where: { normalize($0) == normalized }) { return .reserved(b.display) }
        for (otherAction, list) in existing where otherAction != action {
            if list.contains(where: { normalize($0) == normalized }) { return .inUse(otherAction) }
        }
        return nil
    }

    /// Compare ignoring left/right side so ⌘C and →⌘C both count as reserved.
    static func normalize(_ b: ShortcutBinding) -> ShortcutBinding {
        ShortcutBinding(modifiers: Set(b.modifiers.map { ModifierKey($0.kind) }), keyCode: b.keyCode, mouseButton: b.mouseButton)
    }
}
