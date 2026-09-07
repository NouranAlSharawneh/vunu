import Foundation
import CoreGraphics
import Carbon.HIToolbox
import os

/// High-level hotkey events delivered to the session coordinator (on the main actor).
public enum HotkeyEvent: Sendable, Equatable {
    case holdBegan(ShortcutAction)          // chord fully pressed (PTT / Command Mode / Scratchpad)
    case holdEnded(ShortcutAction)          // chord released
    case holdAborted(ShortcutAction)        // another key was pressed during an fn hold (< 1 s) → discard, pass key through
    case triggered(ShortcutAction)          // toggle-style actions (hands-free, cancel, paste/copy last)
    case fnDoubleTap                        // two quick fn taps → lock hands-free
    case fnTripleTap                        // → cancel
    case secureInput(Bool)
}

/// Decides, per raw event, what to swallow and which high-level events to emit.
/// All state is touched only on the event-tap thread; config setters are lock-protected.
public final class HotkeyEngine: @unchecked Sendable {
    public typealias Emitter = @Sendable (HotkeyEvent) -> Void
    public typealias RecorderSink = @Sendable (RawKeyEvent, Set<ModifierKey>) -> Void

    private let emit: Emitter
    private let config = OSAllocatedUnfairLock(initialState: Config())

    private struct Config {
        var bindings: [ShortcutAction: [ShortcutBinding]] = ShortcutBinding.defaults
        var sessionActive = false        // set by the coordinator while armed/recording/processing
        var recorder: RecorderSink? = nil // when non-nil, every key event is forwarded and swallowed
    }

    // tap-thread state
    private var pressedModifiers: Set<ModifierKey> = []
    private var pressedKeys: Set<UInt16> = []
    private var swallowedKeys: Set<UInt16> = []
    private var pressedMouse: Set<Int> = []
    private var activeHolds: [ShortcutAction: ShortcutBinding] = [:]
    private var fnHeld = false
    private var fnDownAt: TimeInterval = 0
    private var fnPassthrough = false
    private var savedFnDown: CGEvent?
    private var fnTapDowns: [TimeInterval] = []
    private var lastFnHold: TimeInterval = 0
    private var lastSecureInput = false
    private var lastSecureCheck: TimeInterval = 0

    public init(emit: @escaping Emitter) { self.emit = emit }

    // MARK: config
    public func setBindings(_ b: [ShortcutAction: [ShortcutBinding]]) { config.withLock { $0.bindings = b } }
    public func setSessionActive(_ v: Bool) { config.withLock { $0.sessionActive = v } }
    public func setRecorder(_ sink: RecorderSink?) { config.withLock { $0.recorder = sink } }
    public var seenFnKey: Bool { fnTapDowns.isEmpty == false }

    // MARK: entry point (tap thread)
    public func handle(_ event: CGEvent, _ raw: RawKeyEvent) -> TapDecision {
        let cfg = config.withLock { $0 }
        pollSecureInput(now: raw.time)
        switch raw.kind {
        case .flagsChanged: return handleFlags(event, raw, cfg)
        case .keyDown: return handleKeyDown(event, raw, cfg)
        case .keyUp: return handleKeyUp(raw, cfg)
        case .mouseDown: return handleMouse(raw, down: true, cfg)
        case .mouseUp: return handleMouse(raw, down: false, cfg)
        }
    }

    private func pollSecureInput(now: TimeInterval) {
        guard now - lastSecureCheck > 2 else { return }
        lastSecureCheck = now
        let secure = IsSecureEventInputEnabled()
        if secure != lastSecureInput { lastSecureInput = secure; emit(.secureInput(secure)) }
    }

    // MARK: modifiers
    private static func modifierKey(for keyCode: UInt16) -> ModifierKey? {
        switch Int(keyCode) {
        case kVK_Function: ModifierKey(.fn)
        case kVK_Control: ModifierKey(.control, side: .left)
        case kVK_RightControl: ModifierKey(.control, side: .right)
        case kVK_Command: ModifierKey(.command, side: .left)
        case kVK_RightCommand: ModifierKey(.command, side: .right)
        case kVK_Option: ModifierKey(.option, side: .left)
        case kVK_RightOption: ModifierKey(.option, side: .right)
        case kVK_Shift: ModifierKey(.shift, side: .left)
        case kVK_RightShift: ModifierKey(.shift, side: .right)
        default: nil
        }
    }
    private static func mask(for kind: ModifierKind) -> CGEventFlags {
        switch kind {
        case .fn: .maskSecondaryFn; case .control: .maskControl; case .command: .maskCommand; case .option: .maskAlternate; case .shift: .maskShift
        }
    }

    private func handleFlags(_ event: CGEvent, _ raw: RawKeyEvent, _ cfg: Config) -> TapDecision {
        guard let mod = Self.modifierKey(for: raw.keyCode) else { return .pass }
        let maskPresent = raw.flags.contains(Self.mask(for: mod.kind))
        let isDown: Bool
        if !maskPresent {
            pressedModifiers = pressedModifiers.filter { $0.kind != mod.kind }
            isDown = false
        } else if pressedModifiers.contains(mod) {
            pressedModifiers.remove(mod); isDown = false
        } else {
            pressedModifiers.insert(mod); isDown = true
        }

        if let rec = cfg.recorder {
            rec(raw, pressedModifiers)
            return mod.kind == .fn ? .swallow : .pass
        }

        if mod.kind == .fn {
            if isDown { return fnDown(event, raw, cfg) } else { return fnUp(raw, cfg) }
        }
        // Non-fn modifier: never swallow, but update chords.
        recomputeModifierHolds(raw, cfg)
        return .pass
    }

    private func fnDown(_ event: CGEvent, _ raw: RawKeyEvent, _ cfg: Config) -> TapDecision {
        fnHeld = true
        fnDownAt = raw.time
        fnPassthrough = false
        savedFnDown = event.copy()
        // double / triple tap detection
        fnTapDowns = fnTapDowns.filter { raw.time - $0 < 0.8 }
        let prev = fnTapDowns.last
        fnTapDowns.append(raw.time)
        if let prev, raw.time - prev <= 0.35, lastFnHold < 0.3 {
            if fnTapDowns.count >= 3, raw.time - fnTapDowns[fnTapDowns.count - 3] <= 0.7 {
                fnTapDowns.removeAll()
                emit(.fnTripleTap)
            } else {
                emit(.fnDoubleTap)
            }
        }
        recomputeModifierHolds(raw, cfg)
        // fn alone is always swallowed so the Emoji/Dictation system action never fires.
        return .swallow
    }

    private func fnUp(_ raw: RawKeyEvent, _ cfg: Config) -> TapDecision {
        fnHeld = false
        lastFnHold = raw.time - fnDownAt
        savedFnDown = nil
        recomputeModifierHolds(raw, cfg)
        if fnPassthrough { fnPassthrough = false; return .pass }
        return .swallow
    }

    /// Match modifier-only hold bindings against the current modifier set; begin/end holds.
    private func recomputeModifierHolds(_ raw: RawKeyEvent, _ cfg: Config) {
        // end holds whose modifiers are no longer satisfied
        for (action, binding) in activeHolds where binding.isModifierOnly {
            if !modifiersSatisfied(binding.modifiers) {
                activeHolds[action] = nil
                emit(.holdEnded(action))
            }
        }
        // begin the best exact match (longest modifier set)
        var best: (ShortcutAction, ShortcutBinding)?
        for action in ShortcutAction.allCases where action.isHold {
            for b in cfg.bindings[action] ?? [] where b.isModifierOnly {
                if exactModifierMatch(b.modifiers), activeHolds[action] == nil {
                    if best == nil || b.modifiers.count > best!.1.modifiers.count { best = (action, b) }
                }
            }
        }
        if let (action, binding) = best {
            // A longer chord supersedes a shorter active one (fn → fn+⌃ = Command Mode).
            for (other, ob) in activeHolds where ob.isModifierOnly && ob.modifiers.isStrictSubset(of: binding.modifiers) {
                activeHolds[other] = nil
                emit(.holdAborted(other))
            }
            activeHolds[action] = binding
            emit(.holdBegan(action))
        }
    }

    private func modifiersSatisfied(_ required: Set<ModifierKey>) -> Bool {
        required.allSatisfy { req in
            pressedModifiers.contains { $0.kind == req.kind && (req.side == .any || $0.side == req.side) }
        }
    }
    private func exactModifierMatch(_ required: Set<ModifierKey>) -> Bool {
        guard modifiersSatisfied(required) else { return false }
        let kinds = Set(pressedModifiers.map(\.kind))
        return kinds == Set(required.map(\.kind))
    }

    // MARK: keys
    private func handleKeyDown(_ event: CGEvent, _ raw: RawKeyEvent, _ cfg: Config) -> TapDecision {
        if let rec = cfg.recorder { rec(raw, pressedModifiers); return .swallow }
        if raw.isRepeat { return swallowedKeys.contains(raw.keyCode) ? .swallow : .pass }
        pressedKeys.insert(raw.keyCode)

        // Cancel (Esc) while a session is active — regardless of modifiers.
        if cfg.sessionActive, matches(action: .cancel, keyCode: raw.keyCode, cfg: cfg, ignoreModifiers: true) {
            swallowedKeys.insert(raw.keyCode)
            emit(.triggered(.cancel))
            return .swallow
        }

        // Key-based bindings.
        for action in ShortcutAction.allCases where action != .cancel {
            guard let b = matchingBinding(action: action, keyCode: raw.keyCode, cfg: cfg) else { continue }
            swallowedKeys.insert(raw.keyCode)
            if action.isHold {
                activeHolds[action] = b
                emit(.holdBegan(action))
            } else {
                emit(.triggered(action))
            }
            return .swallow
        }

        // Some other key while fn is held → system fn shortcut. Pass through; abort a young PTT.
        if fnHeld {
            if raw.time - fnDownAt < 1.0 {
                for (action, b) in activeHolds where b.modifiers.contains(.fn) && b.isModifierOnly {
                    activeHolds[action] = nil
                    emit(.holdAborted(action))
                }
                fnPassthrough = true
                if let saved = savedFnDown {
                    saved.setIntegerValueField(.eventSourceUserData, value: EventTapMonitor.selfMarker)
                    saved.post(tap: .cghidEventTap)
                }
            }
            return .pass
        }
        return .pass
    }

    private func handleKeyUp(_ raw: RawKeyEvent, _ cfg: Config) -> TapDecision {
        if let rec = cfg.recorder { rec(raw, pressedModifiers); return .swallow }
        pressedKeys.remove(raw.keyCode)
        for (action, b) in activeHolds where b.keyCode == raw.keyCode {
            activeHolds[action] = nil
            emit(.holdEnded(action))
        }
        if swallowedKeys.remove(raw.keyCode) != nil { return .swallow }
        return .pass
    }

    private func handleMouse(_ raw: RawKeyEvent, down: Bool, _ cfg: Config) -> TapDecision {
        if let rec = cfg.recorder { rec(raw, pressedModifiers); return .swallow }
        if down {
            pressedMouse.insert(raw.mouseButton)
            for action in ShortcutAction.allCases {
                for b in cfg.bindings[action] ?? [] where b.mouseButton == raw.mouseButton && b.keyCode == nil {
                    guard exactModifierMatch(b.modifiers) || (b.modifiers.isEmpty && pressedModifiers.isEmpty) else { continue }
                    if action.isHold { activeHolds[action] = b; emit(.holdBegan(action)) } else { emit(.triggered(action)) }
                    return .swallow
                }
            }
        } else {
            pressedMouse.remove(raw.mouseButton)
            for (action, b) in activeHolds where b.mouseButton == raw.mouseButton {
                activeHolds[action] = nil
                emit(.holdEnded(action))
                return .swallow
            }
        }
        return .pass
    }

    private func matches(action: ShortcutAction, keyCode: UInt16, cfg: Config, ignoreModifiers: Bool) -> Bool {
        for b in cfg.bindings[action] ?? [] where b.keyCode == keyCode {
            if ignoreModifiers || exactModifierMatch(b.modifiers) || (b.modifiers.isEmpty && pressedModifiers.isEmpty) { return true }
        }
        return false
    }
    private func matchingBinding(action: ShortcutAction, keyCode: UInt16, cfg: Config) -> ShortcutBinding? {
        for b in cfg.bindings[action] ?? [] where b.keyCode == keyCode && b.mouseButton == nil {
            if b.modifiers.isEmpty { if pressedModifiers.isEmpty { return b } else { continue } }
            if exactModifierMatch(b.modifiers) { return b }
        }
        return nil
    }
}
