import Foundation
import AppKit
import ApplicationServices

/// Everything we know about the app / element that will receive the text.
public struct FocusSnapshot: Sendable {
    public var pid: pid_t
    public var bundleID: String?
    public var appName: String
    public var icon: NSImage?
    public var element: AXElementBox?
    public var role: String?
    public var subrole: String?
    public var isSecure: Bool
    public var isEditable: Bool
    public var isTerminal: Bool
    public var isCodeEditor: Bool
    public var isBrowser: Bool
    public var browserURL: URL?
    public var windowFrame: CGRect?   // AX (top-left origin) coordinates of the focused window
    public var category: AppCategory
    public var isMessaging: Bool
    public var takenAt: Date
    public var contextMs: Double

    public var supportsAXInsert: Bool { element != nil && isEditable && !isTerminal && !isCodeEditor && !isBrowserElectron }
    var isBrowserElectron: Bool { bundleID.map { AppCatalog.electronApps.contains($0) || AppCatalog.chromiumBrowsers.contains($0) } ?? false }
    /// Roles that clearly cannot take text.
    public var isKnownNonText: Bool {
        guard let role else { return bundleID.map { AppCatalog.nonTextApps.contains($0) } ?? false }
        let nonText: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenu", "AXMenuItem", "AXMenuBar", "AXImage", "AXOutline",
                                    "AXTable", "AXList", "AXRow", "AXSlider", "AXTabGroup", "AXToolbar", "AXPopUpButton", "AXScrollBar", "AXLink"]
        return nonText.contains(role) && !isTerminal
    }
}

/// Reads the frontmost app + AX focused element. All AX work happens on a private serial queue (never main).
public final class FocusTracker: Sendable {
    public static let shared = FocusTracker()
    private let queue = DispatchQueue(label: "dev.nunu.vunu.ax", qos: .userInteractive)
    private init() {}

    public func snapshot(readBrowserURL: Bool = true) async -> FocusSnapshot? {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.snapshotSync(readBrowserURL: readBrowserURL)) }
        }
    }

    /// Run arbitrary AX work on the AX queue.
    public func perform<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: work()) } }
    }

    public func snapshotSync(readBrowserURL: Bool = true) -> FocusSnapshot? {
        let sw = Stopwatch()
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundle = app.bundleIdentifier
        let isTerminal = bundle.map { AppCatalog.terminals.contains($0) } ?? false
        let isEditor = bundle.map { AppCatalog.codeEditors.contains($0) } ?? false
        let isBrowser = bundle.map { AppCatalog.browsers.contains($0) } ?? false
        var snap = FocusSnapshot(pid: app.processIdentifier, bundleID: bundle, appName: app.localizedName ?? "App", icon: app.icon,
                                 element: nil, role: nil, subrole: nil, isSecure: false, isEditable: false, isTerminal: isTerminal,
                                 isCodeEditor: isEditor, isBrowser: isBrowser, browserURL: nil, windowFrame: nil, category: .other,
                                 isMessaging: false, takenAt: Date(), contextMs: 0)
        guard AXIsProcessTrusted() else { snap.contextMs = sw.elapsedMs; return snap }

        if let bundle, AppCatalog.electronApps.contains(bundle) || AppCatalog.chromiumBrowsers.contains(bundle) {
            AX.enableManualAccessibility(pid: app.processIdentifier)
        }
        let appEl = AX.app(pid: app.processIdentifier)
        var focused = AX.element(appEl, kAXFocusedUIElementAttribute)
        if focused == nil { focused = AX.element(AX.systemWide(), kAXFocusedUIElementAttribute) }
        if let el = focused {
            snap.element = AXElementBox(el)
            snap.role = AX.string(el, kAXRoleAttribute)
            snap.subrole = AX.string(el, kAXSubroleAttribute)
            snap.isSecure = snap.role == "AXSecureTextField" || snap.subrole == "AXSecureTextField"
            let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
            snap.isEditable = !snap.isSecure && (textRoles.contains(snap.role ?? "") || AX.isSettable(el, kAXSelectedTextAttribute))
        }
        if let win = AX.element(appEl, kAXFocusedWindowAttribute) {
            if let p = AX.point(win, kAXPositionAttribute), let s = AX.size(win, kAXSizeAttribute) { snap.windowFrame = CGRect(origin: p, size: s) }
            if readBrowserURL, isBrowser, sw.elapsedMs < 25 { snap.browserURL = BrowserURLReader.url(bundleID: bundle ?? "", window: win, app: appEl) }
        }
        snap.category = AppCategoryResolver(extraApps: FocusTracker.extraApps.withLock { $0 }).category(bundleID: bundle, url: snap.browserURL)
        snap.isMessaging = AppCategoryResolver.isMessaging(bundleID: bundle, url: snap.browserURL)
        snap.contextMs = sw.elapsedMs
        return snap
    }

    /// Mirror of Preferences.extraAppsByCategory, readable off-main.
    public static let extraApps = OSAllocatedUnfairLock<[AppCategory: [String]]>(initialState: [:])
}

import os

enum BrowserURLReader {
    static func url(bundleID: String, window: AXUIElement, app: AXUIElement) -> URL? {
        // Safari / WebKit: AXDocument on the window or the web area.
        if let doc = AX.string(window, kAXDocumentAttribute), let u = URL(string: doc) { return u }
        if let web = findWebArea(window, depth: 0), let doc = AX.string(web, kAXDocumentAttribute) ?? AX.string(web, "AXURL"), let u = URL(string: doc) { return u }
        // Chromium / Firefox: the address bar text field.
        if let field = findAddressField(window, depth: 0), let text = AX.string(field, kAXValueAttribute) {
            let s = text.contains("://") ? text : "https://" + text
            return URL(string: s)
        }
        return nil
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        guard let v = AX.value(el, kAXChildrenAttribute) as? [AnyObject] else { return [] }
        return v.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
    }
    private static func findWebArea(_ el: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 8 else { return nil }
        if AX.string(el, kAXRoleAttribute) == "AXWebArea" { return el }
        for c in children(el).prefix(12) { if let f = findWebArea(c, depth: depth + 1) { return f } }
        return nil
    }
    private static func findAddressField(_ el: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 7 else { return nil }
        if AX.string(el, kAXRoleAttribute) == "AXTextField" {
            let desc = (AX.string(el, kAXDescriptionAttribute) ?? "") + " " + (AX.string(el, kAXTitleAttribute) ?? "") + " " + (AX.string(el, kAXIdentifierAttribute) ?? "")
            let d = desc.lowercased()
            if d.contains("address") || d.contains("url") || d.contains("search or enter") || d.contains("location") { return el }
        }
        for c in children(el).prefix(20) { if let f = findAddressField(c, depth: depth + 1) { return f } }
        return nil
    }
}
