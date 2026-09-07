import Foundation
import ApplicationServices
import AppKit

/// Thin, timeout-guarded wrappers over the AX C API. Call off the main thread.
public enum AX {
    public static let timeout: Float = 0.05

    public static func systemWide() -> AXUIElement {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, timeout)
        return el
    }
    public static func app(pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, timeout)
        return el
    }

    public static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var out: CFTypeRef?
        let st = AXUIElementCopyAttributeValue(el, attr as CFString, &out)
        return st == .success ? out : nil
    }
    public static func string(_ el: AXUIElement, _ attr: String) -> String? { value(el, attr) as? String }
    public static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr) else { return nil }
        guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let e = unsafeBitCast(v, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(e, timeout)
        return e
    }
    public static func int(_ el: AXUIElement, _ attr: String) -> Int? {
        guard let v = value(el, attr) else { return nil }
        return (v as? NSNumber)?.intValue
    }
    public static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        guard let v = value(el, attr) else { return nil }
        return (v as? NSNumber)?.boolValue
    }
    public static func range(_ el: AXUIElement, _ attr: String) -> CFRange? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        let axv = unsafeBitCast(v, to: AXValue.self)
        return AXValueGetValue(axv, .cfRange, &r) ? r : nil
    }
    public static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgPoint, &p) ? p : nil
    }
    public static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgSize, &s) ? s : nil
    }
    public static func stringForRange(_ el: AXUIElement, _ range: CFRange) -> String? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        let st = AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, param, &out)
        return st == .success ? out as? String : nil
    }
    public static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success && settable.boolValue
    }
    @discardableResult public static func set(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, attr as CFString, value) == .success
    }
    public static func pid(_ el: AXUIElement) -> pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(el, &p) == .success ? p : nil
    }
    /// Switch on Chromium/Electron accessibility trees.
    public static func enableManualAccessibility(pid: pid_t) {
        let a = app(pid: pid)
        set(a, "AXManualAccessibility", kCFBooleanTrue)
        set(a, "AXEnhancedUserInterface", kCFBooleanTrue)
    }
}

/// Box so an AXUIElement can travel inside Sendable snapshots. Only used from the AX queue / insertion path.
public final class AXElementBox: @unchecked Sendable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) { self.element = element }
}
