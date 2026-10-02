import AppKit
import SwiftUI
import Observation

/// Owns the Flow Bar panel + the notice toast panel; positions them on the screen of the focused window.
///
/// The panel is a fixed-size transparent canvas; only the SwiftUI pill inside it changes size. Resizing the window per state
/// clipped the pill's left edge while its spring animation caught up (the window snapped narrower and re-centered first).
/// Mouse events pass through the canvas except over the visible content.
@MainActor
public final class FlowBarController {
    public static let shared = FlowBarController()
    /// Room for the widest content: the live preview (≤ 360 pt), the "taking longer" banner and the pill, plus the shadow.
    static let canvasSize = CGSize(width: 420, height: 180)
    /// Space under the content inside the canvas so the pill's shadow isn't clipped.
    static let bottomInset: CGFloat = 8
    private let panel = FlowBarPanel()
    private let toast = ToastPanel()
    private var observation: Task<Void, Never>?
    private var hideTimer: Task<Void, Never>?
    public var onOpenSettings: (() -> Void)?
    public var onOpenHistory: (() -> Void)?
    /// User-chosen spot: bottom-center of the content (the old idle window's bottom-center), screen coordinates.
    private var customAnchor: CGPoint?
    /// Visible content (pill + preview/banner) in the hosting view's top-left coordinates.
    private var contentRect: CGRect = .zero
    private var mouseMonitor: Any?
    private var hoverPoll: Timer?

    private init() {
        let view = FlowBarView(
            session: SessionCoordinator.shared,
            onCancel: { SessionCoordinator.shared.cancel(silent: false) },
            onConfirm: { SessionCoordinator.shared.stopAndProcess() },
            onClickIdle: { SessionCoordinator.shared.handle(.triggered(.handsFree)) },
            showLanguage: Preferences.shared.languages.count >= 2,
            languages: Preferences.shared.languages,
            onPickLanguage: { lang in var l = Preferences.shared.languages; l.removeAll { $0 == lang }; l.insert(lang, at: 0); Preferences.shared.languages = l }
        )
        let canvas = FlowBarCanvas(bottomInset: Self.bottomInset, onContentRect: { [weak self] rect in self?.contentRectChanged(rect) }) { view }
        let host = NSHostingView(rootView: AnyView(canvas))
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(Self.canvasSize)
        panel.ignoresMouseEvents = true
        panel.onRightClick = { [weak self] e in self?.showMenu(e) }
        panel.onDragEnded = { [weak self] in self?.persistPosition() }
        customAnchor = Self.loadAnchor()
        applySharingType()
        observe()
    }

    private static func parse(_ s: String?) -> CGPoint? {
        guard let parts = s?.split(separator: ","), parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Reads the saved anchor, migrating the ≤ 0.3.x value (origin of the 128×43 idle window) to its bottom-center.
    private static func loadAnchor() -> CGPoint? {
        let prefs = Preferences.shared
        if let a = parse(prefs.flowBarAnchor) { return a }
        guard let old = parse(prefs.flowBarPosition) else { return nil }
        let a = CGPoint(x: old.x + 64, y: old.y)
        prefs.flowBarAnchor = "\(Int(a.x)),\(Int(a.y))"
        prefs.flowBarPosition = nil
        return a
    }

    private func observe() {
        observation = Task { [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { cont in
                    withObservationTracking {
                        guard let self else { return }
                        _ = SessionCoordinator.shared.state
                        _ = SessionCoordinator.shared.notice
                        _ = SessionCoordinator.shared.target
                        _ = Preferences.shared.showFlowBarAlways
                        _ = Preferences.shared.hideFlowBarUntil
                        _ = Preferences.shared.hideFlowBarFromScreenShare
                    } onChange: { cont.resume() }
                }
                self?.refresh()
            }
        }
        refresh()
    }

    public func applySharingType() {
        let t: NSWindow.SharingType = Preferences.shared.hideFlowBarFromScreenShare ? .none : .readOnly
        panel.sharingType = t; toast.sharingType = t
    }

    private func refresh() {
        let s = SessionCoordinator.shared
        let prefs = Preferences.shared
        let hidden = prefs.hideFlowBarUntil.map { $0 > Date() } ?? false
        let shouldShow = !hidden && (s.state.isActive || (prefs.showFlowBarAlways && !s.state.isProcessing && s.state != .idle) || prefs.showFlowBarAlways)
        if shouldShow {
            hideTimer?.cancel()
            position()
            if !panel.isVisible { panel.alphaValue = 1; panel.orderFrontRegardless() }
            startMouseTracking()
        } else if panel.isVisible {
            hideTimer?.cancel()
            hideTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(s.state == .idle ? 250 : 0))
                guard !Task.isCancelled, let self else { return }
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.2; self.panel.animator().alphaValue = 0 } completionHandler: {
                    Task { @MainActor in
                        if !SessionCoordinator.shared.state.isActive && !Preferences.shared.showFlowBarAlways { self.panel.orderOut(nil); self.stopMouseTracking() }
                        self.panel.alphaValue = 1
                    }
                }
            }
        }
        // toast
        if let n = s.notice {
            toast.show(n, near: panel.isVisible ? contentScreenRect : nil, screen: targetScreen())
        } else { toast.hide() }
    }

    /// The visible content in screen coordinates.
    private var contentScreenRect: CGRect {
        let f = panel.frame
        return CGRect(x: f.minX + contentRect.minX, y: f.minY + f.height - contentRect.maxY, width: contentRect.width, height: contentRect.height)
    }

    private func contentRectChanged(_ rect: CGRect) {
        guard rect != contentRect else { return }
        contentRect = rect
        if panel.isVisible, let n = SessionCoordinator.shared.notice { toast.show(n, near: contentScreenRect, screen: targetScreen()) }
        updateMousePassThrough()
    }

    // MARK: click-through

    /// A global monitor sees the cursor reach the content while the canvas ignores the mouse; once the canvas takes
    /// events (and the monitor goes quiet), a 30 Hz poll notices the cursor leaving.
    private func startMouseTracking() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassThrough() }
        }
        updateMousePassThrough()
    }

    private func stopMouseTracking() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        hoverPoll?.invalidate(); hoverPoll = nil
        panel.ignoresMouseEvents = true
    }

    private func updateMousePassThrough() {
        let over = panel.isVisible && !contentRect.isEmpty && contentScreenRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if over || panel.isDragging {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            if hoverPoll == nil {
                let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateMousePassThrough() } }
                RunLoop.main.add(t, forMode: .common)
                hoverPoll = t
            }
        } else {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            hoverPoll?.invalidate(); hoverPoll = nil
        }
    }

    /// Screen containing the focused window (fallback: main).
    private func targetScreen() -> NSScreen {
        if let f = SessionCoordinator.shared.target?.windowFrame, let primary = NSScreen.screens.first {
            // AX uses top-left origin; convert to Cocoa
            let cocoaY = primary.frame.height - f.origin.y - f.height
            let center = CGPoint(x: f.midX, y: cocoaY + f.height / 2)
            if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return s }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Only moves the canvas; it never resizes. The content sits bottom-center, `bottomInset` above the canvas bottom.
    private func position() {
        let vf = targetScreen().visibleFrame
        var a: CGPoint
        if let c = customAnchor, vf.insetBy(dx: -20, dy: -20).contains(c) { a = c } else { a = CGPoint(x: vf.midX, y: vf.minY + 24) }
        // Keep the widest pill (~170 pt while recording) fully on screen; the transparent canvas may overhang.
        let half: CGFloat = 90
        a.x = max(vf.minX + half, min(a.x, vf.maxX - half))
        a.y = max(vf.minY, min(a.y, vf.maxY - 60))
        let origin = CGPoint(x: (a.x - Self.canvasSize.width / 2).rounded(), y: (a.y - Self.bottomInset).rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    private func persistPosition() {
        let f = panel.frame
        let a = CGPoint(x: f.midX, y: f.minY + Self.bottomInset)
        customAnchor = a
        Preferences.shared.flowBarAnchor = "\(Int(a.x)),\(Int(a.y))"
    }

    public func resetPosition() { customAnchor = nil; Preferences.shared.flowBarAnchor = nil; Preferences.shared.flowBarPosition = nil; refresh() }

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Hide for 1 hour", action: #selector(hideHour), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let mic = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        mic.submenu = MenuBuilders.microphoneMenu()
        menu.addItem(mic)
        let lang = NSMenuItem(title: "Languages", action: nil, keyEquivalent: "")
        lang.submenu = MenuBuilders.languageMenu()
        menu.addItem(lang)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Transcript history", action: #selector(openHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Paste last transcript", action: #selector(pasteLast), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reset position", action: #selector(resetPos), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: panel.contentView!)
    }
    @objc private func hideHour() { Preferences.shared.hideFlowBarUntil = Date().addingTimeInterval(3600) }
    @objc private func openHistory() { onOpenHistory?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func pasteLast() { Task { await SessionCoordinator.shared.pasteLast() } }
    @objc private func resetPos() { resetPosition() }
}

/// Small floating panel above the pill for notices with an optional action button.
final class ToastPanel: NSPanel {
    private var host: NSHostingView<AnyView>?
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60), styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true; hidesOnDeactivate = false; backgroundColor = .clear; isOpaque = false; hasShadow = true
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @MainActor func show(_ n: SessionNotice, near pillFrame: NSRect?, screen: NSScreen) {
        let view = AnyView(ToastView(notice: n))
        if host == nil { host = NSHostingView(rootView: view); host?.sizingOptions = [.intrinsicContentSize]; contentView = host } else { host?.rootView = view }
        contentView?.layoutSubtreeIfNeeded()
        let size = host?.fittingSize ?? frame.size
        setContentSize(size)
        let vf = screen.visibleFrame
        // Fixed anchor: just above where the pill lives (never re-anchors when the pill hides), so it doesn't jump.
        let x = (pillFrame?.midX ?? vf.midX) - size.width / 2
        let y = (pillFrame.map { max($0.maxY, vf.minY + 24 + 44) } ?? (vf.minY + 24 + 44)) + 10
        setFrameOrigin(NSPoint(x: max(vf.minX + 8, min(x, vf.maxX - size.width - 8)), y: min(y, vf.maxY - size.height - 8)))
        if !isVisible { alphaValue = 0; orderFrontRegardless(); NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 } }
    }
    @MainActor func hide() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = 0 } completionHandler: { Task { @MainActor in self.orderOut(nil); self.alphaValue = 1 } }
    }
}

struct ToastView: View {
    let notice: SessionNotice
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(Fonts.ui(13, weight: .semibold)).foregroundStyle(Tokens.cream)
                if let d = notice.detail { Text(d).font(Fonts.ui(11)).foregroundStyle(Tokens.grey).lineLimit(3) }
            }
            actionButton
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 380)
        .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.ink.opacity(0.95)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokens.barBorder)))
        .padding(6)
    }
    private var icon: String {
        switch notice.kind { case .info: "info.circle"; case .warning: "exclamationmark.triangle"; case .error: "xmark.octagon"; case .success: "checkmark.circle" }
    }
    private var color: Color {
        switch notice.kind { case .info: Tokens.lilac; case .warning: Tokens.orange; case .error: Tokens.orange; case .success: Color(hex: 0x6FD3A5) }
    }
    @ViewBuilder private var actionButton: some View {
        switch notice.action {
        case .copy(let text):
            Button("Copy") { PasteboardSnapshot.writeText(text); SessionCoordinator.shared.notice = nil }.buttonStyle(ToastButtonStyle())
        case .insert:
            Button("Insert") { SessionCoordinator.shared.notice = nil }.buttonStyle(ToastButtonStyle())
        case .openSettings:
            Button("Settings") { FlowBarController.shared.onOpenSettings?(); SessionCoordinator.shared.notice = nil }.buttonStyle(ToastButtonStyle())
        case .chooseMicrophone:
            Button("Choose microphone") { FlowBarController.shared.onOpenSettings?(); SessionCoordinator.shared.notice = nil }.buttonStyle(ToastButtonStyle())
        case .enablePressEnter:
            HStack(spacing: 4) {
                Button("Disable") { Preferences.shared.pressEnterCommand = false; SessionCoordinator.shared.notice = nil }.buttonStyle(ToastButtonStyle(secondary: true))
                Button("Keep on") { SessionCoordinator.shared.notice = nil }.buttonStyle(ToastButtonStyle())
            }
        case .addToDictionary(let word, let misspelling):
            HStack(spacing: 4) {
                Button("No") { SessionCoordinator.shared.notice = nil }.buttonStyle(ToastButtonStyle(secondary: true))
                Button("Add") { try? Database.shared.save(DictionaryEntry(word: word, misspelling: misspelling)); SessionCoordinator.shared.notice = nil }.buttonStyle(ToastButtonStyle())
            }
        case .openPrivacyPaste:
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") { NSWorkspace.shared.open(url) }
                SessionCoordinator.shared.notice = nil
            }.buttonStyle(ToastButtonStyle())
        case .recover:
            Button("Retry") { if let t = try? Database.shared.transcripts(limit: 1).first { SessionCoordinator.shared.retry(t) }; SessionCoordinator.shared.notice = nil }.buttonStyle(ToastButtonStyle())
        case .none: EmptyView()
        }
    }
}

struct ToastButtonStyle: ButtonStyle {
    var secondary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Fonts.ui(11, weight: .semibold)).foregroundStyle(secondary ? Tokens.cream : Tokens.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(secondary ? Tokens.greyDark : Tokens.lilac).opacity(configuration.isPressed ? 0.7 : 1))
    }
}
