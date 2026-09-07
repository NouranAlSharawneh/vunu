import Foundation
import CoreGraphics
import ApplicationServices

/// Normalized view of a CGEvent handed to the hotkey engine. Built on the tap thread; cheap.
public struct RawKeyEvent: Sendable {
    public enum Kind: Sendable { case flagsChanged, keyDown, keyUp, mouseDown, mouseUp }
    public let kind: Kind
    public let keyCode: UInt16
    public let flags: CGEventFlags
    public let mouseButton: Int
    public let isRepeat: Bool
    public let time: TimeInterval
}

/// Decision returned by the hotkey engine for each event.
public enum TapDecision: Sendable {
    case pass
    case swallow
}

public enum VunuError: Error, LocalizedError, Sendable {
    case accessibilityDenied, microphoneDenied, tapCreationFailed, modelNotLoaded(String), engineUnavailable(String), noAudio, insertionFailed(String)
    public var errorDescription: String? {
        switch self {
        case .accessibilityDenied: "Accessibility permission is required for the fn hotkey."
        case .microphoneDenied: "Microphone permission is required."
        case .tapCreationFailed: "Could not install the keyboard event tap."
        case .modelNotLoaded(let m): "Model not loaded: \(m)"
        case .engineUnavailable(let e): "Engine unavailable: \(e)"
        case .noAudio: "No audio captured."
        case .insertionFailed(let why): "Could not insert text: \(why)"
        }
    }
}

/// Global CGEventTap on a dedicated thread. The handler must return in well under 1 ms.
/// Events that Vunu itself posts are tagged with `Self.selfMarker` and skipped.
public final class EventTapMonitor: @unchecked Sendable {
    public static let selfMarker: Int64 = 0x56554E55 // "VUNU"

    public typealias Handler = @Sendable (CGEvent, RawKeyEvent) -> TapDecision

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let handler: Handler
    private let lock = NSLock()
    public private(set) var isRunning = false

    public init(handler: @escaping Handler) { self.handler = handler }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Install the tap. Throws when Accessibility is not granted.
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        if isRunning { return }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: EventTapMonitor.callback, userInfo: info) else {
            throw AXIsProcessTrusted() ? VunuError.tapCreationFailed : VunuError.accessibilityDenied
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = src
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self, let src = self.source, let tap = self.tap else { ready.signal(); return }
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "dev.nunu.vunu.eventtap"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        _ = ready.wait(timeout: .now() + 2)
        isRunning = true
        Log.hotkeys.info("event tap installed")
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard isRunning else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop, let source { CFRunLoopRemoveSource(runLoop, source, .commonModes); CFRunLoopStop(runLoop) }
        tap = nil; source = nil; runLoop = nil; thread = nil
        isRunning = false
        Log.hotkeys.info("event tap removed")
    }

    /// Tear down and re-install (after wake / unlock).
    public func restart() throws { stop(); try start() }

    /// Re-enable if macOS disabled the tap (timeout / user input).
    public func reenable() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true); Log.hotkeys.warning("event tap re-enabled") }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<EventTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == EventTapMonitor.selfMarker {
            return Unmanaged.passUnretained(event)
        }
        let kind: RawKeyEvent.Kind
        switch type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .otherMouseDown: kind = .mouseDown
        case .otherMouseUp: kind = .mouseUp
        default: return Unmanaged.passUnretained(event)
        }
        let raw = RawKeyEvent(
            kind: kind,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            mouseButton: Int(event.getIntegerValueField(.mouseEventButtonNumber)),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            time: Double(event.timestamp) / 1_000_000_000
        )
        switch monitor.handler(event, raw) {
        case .pass: return Unmanaged.passUnretained(event)
        case .swallow: return nil
        }
    }
}
