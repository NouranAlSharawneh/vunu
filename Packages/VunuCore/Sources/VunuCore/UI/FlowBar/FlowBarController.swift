import AppKit
import SwiftUI
import Observation

/// Owns the Flow Bar panel + the notice toast panel; positions them on the screen of the focused window.
@MainActor
public final class FlowBarController {
    public static let shared = FlowBarController()
    private let panel = FlowBarPanel()
    private let toast = ToastPanel()
    private var hostingView: NSHostingView<AnyView>?
    private var observation: Task<Void, Never>?
    private var hideTimer: Task<Void, Never>?
    public var onOpenSettings: (() -> Void)?
    public var onOpenHistory: (() -> Void)?
    private var customOrigin: CGPoint?

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
        let host = NSHostingView(rootView: AnyView(view))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        hostingView = host
        panel.onRightClick = { [weak self] e in self?.showMenu(e) }
        panel.onDragEnded = { [weak self] in self?.persistPosition() }
        if let saved = Preferences.shared.flowBarPosition { let parts = saved.split(separator: ","); if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) { customOrigin = CGPoint(x: x, y: y) } }
        applySharingType()
        observe()
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
            position(panel, aboveBottomBy: 24)
            if !panel.isVisible { panel.alphaValue = 1; panel.orderFrontRegardless() }
        } else if panel.isVisible {
            hideTimer?.cancel()
            hideTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(s.state == .idle ? 250 : 0))
                guard !Task.isCancelled, let self else { return }
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.2; self.panel.animator().alphaValue = 0 } completionHandler: {
                    Task { @MainActor in if !SessionCoordinator.shared.state.isActive && !Preferences.shared.showFlowBarAlways { self.panel.orderOut(nil) }; self.panel.alphaValue = 1 }
                }
            }
        }
        // toast
        if let n = s.notice {
            toast.show(n, near: panel.isVisible ? panel.frame : nil, screen: targetScreen())
        } else { toast.hide() }
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

    private func position(_ p: NSPanel, aboveBottomBy: CGFloat) {
        p.contentView?.layoutSubtreeIfNeeded()
        let size = hostingView?.fittingSize ?? p.frame.size
        p.setContentSize(size)
        let screen = targetScreen()
        let vf = screen.visibleFrame
        var origin: CGPoint
        if let c = customOrigin, vf.insetBy(dx: -20, dy: -20).contains(CGPoint(x: c.x + size.width / 2, y: c.y + size.height / 2)) {
            origin = CGPoint(x: c.x + (c.x - c.x), y: c.y)
            // keep centered on the pill's saved center when width changes
            origin.x = c.x - (size.width - 128) / 2
        } else {
            origin = CGPoint(x: vf.midX - size.width / 2, y: vf.minY + aboveBottomBy)
        }
        origin.x = max(vf.minX, min(origin.x, vf.maxX - size.width))
        origin.y = max(vf.minY, min(origin.y, vf.maxY - size.height))
        p.setFrameOrigin(origin)
    }

    private func persistPosition() {
        let f = panel.frame
        // store the origin as if the pill were idle-width (128 incl. padding) so it stays centered across state widths
        let idleOrigin = CGPoint(x: f.origin.x + (f.width - 128) / 2, y: f.origin.y)
        customOrigin = idleOrigin
        Preferences.shared.flowBarPosition = "\(Int(idleOrigin.x)),\(Int(idleOrigin.y))"
    }

    public func resetPosition() { customOrigin = nil; Preferences.shared.flowBarPosition = nil; refresh() }

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
