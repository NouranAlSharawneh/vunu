import AppKit
import SwiftUI
import Observation

/// Status item: 4-bar waveform glyph idle; target-app icon + red dot while recording; icon + ring while processing.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    public static let shared = MenuBarController()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var observation: Task<Void, Never>?
    private var pulseTimer: Task<Void, Never>?
    private var pulseOn = true
    public var onOpenHub: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenShortcuts: (() -> Void)?
    public var onOpenHelp: (() -> Void)?
    public var onDebugHUD: (() -> Void)?

    private override init() {
        super.init()
        item.button?.image = Self.glyph(color: nil)
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        observe()
    }

    private func observe() {
        observation = Task { [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { cont in
                    withObservationTracking { _ = SessionCoordinator.shared.state; _ = SessionCoordinator.shared.target } onChange: { cont.resume() }
                }
                self?.refresh()
            }
        }
    }

    private func refresh() {
        let s = SessionCoordinator.shared
        let button = item.button
        switch s.state {
        case .armed, .recording:
            if let icon = s.target?.icon { button?.image = Self.badged(icon, dot: pulseOn, ring: false); button?.image?.isTemplate = false }
            else { button?.image = Self.glyph(color: .systemRed); button?.image?.isTemplate = false }
            startPulse()
        case .stopping, .transcribing, .formatting, .inserting:
            stopPulse()
            if let icon = s.target?.icon { button?.image = Self.badged(icon, dot: false, ring: true); button?.image?.isTemplate = false }
            else { button?.image = Self.glyph(color: .secondaryLabelColor); button?.image?.isTemplate = false }
        case .error:
            stopPulse()
            button?.image = Self.glyph(color: .systemOrange, badge: "!"); button?.image?.isTemplate = false
        default:
            stopPulse()
            button?.image = Self.glyph(color: nil); button?.image?.isTemplate = true
        }
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.pulseOn.toggle()
                if SessionCoordinator.shared.state.isCapturing { self.refresh() }
            }
        }
    }
    private func stopPulse() { pulseTimer?.cancel(); pulseTimer = nil; pulseOn = true }

    /// Four vertical rounded bars (6, 12, 18, 9 pt tall, 2.5 pt wide) in an 18×18 image.
    static func glyph(color: NSColor?, badge: String? = nil) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let heights: [CGFloat] = [6, 12, 18, 9]
            let w: CGFloat = 2.5, gap: CGFloat = (18 - 4 * w) / 5
            (color ?? .black).setFill()
            for (i, h) in heights.enumerated() {
                let x = gap + CGFloat(i) * (w + gap)
                NSBezierPath(roundedRect: NSRect(x: x, y: (18 - h) / 2, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
            }
            if let badge {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: 11, y: 0, width: 7, height: 7)).fill()
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 6), .foregroundColor: NSColor.white]
                (badge as NSString).draw(at: NSPoint(x: 13.2, y: 0.2), withAttributes: attrs)
            }
            return true
        }
        return img
    }

    /// App icon at 16 pt with 4 pt corners, + 5 pt red dot bottom-right, or a thin ring for processing.
    static func badged(_ icon: NSImage, dot: Bool, ring: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let r = NSRect(x: 1, y: 1, width: 16, height: 16)
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).addClip()
            icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.cgContext.resetClip()
            if dot {
                NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 11.5, y: -0.5, width: 7, height: 7)).fill()
                NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: 12.5, y: 0.5, width: 5, height: 5)).fill()
            }
            if ring {
                let p = NSBezierPath(); p.lineWidth = 1.5
                p.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 8.2, startAngle: 30, endAngle: 300)
                NSColor.controlAccentColor.setStroke(); p.stroke()
            }
            return true
        }
    }

    @objc private func clicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.modifierFlags.contains(.option) { onDebugHUD?(); return }
        let menu = buildMenu()
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        let state = SessionCoordinator.shared.state
        if state != .idle {
            let status = NSMenuItem(title: state.label, action: nil, keyEquivalent: ""); status.isEnabled = false; m.addItem(status); m.addItem(.separator())
        }
        if let st = try? Database.shared.stats(), st.sessions > 0 {
            let today = (try? Database.shared.wordsToday()) ?? 0
            let faster = st.avgWPM > 0 ? String(format: " · %.1fx faster than typing", max(1, st.avgWPM / 45)) : ""
            let line = NSMenuItem(title: "Today: \(today) words · 🔥 \(st.streakDays) day\(st.streakDays == 1 ? "" : "s")\(faster)", action: nil, keyEquivalent: "")
            line.isEnabled = false
            m.addItem(line)
            m.addItem(.separator())
        }
        m.addItem(withTitle: "Open Vunu", action: #selector(openHub), keyEquivalent: "").target = self
        m.addItem(withTitle: "Paste last transcript", action: #selector(pasteLast), keyEquivalent: "").target = self
        m.addItem(withTitle: "Copy last transcript", action: #selector(copyLast), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Shortcuts…", action: #selector(openShortcuts), keyEquivalent: "").target = self
        let mic = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: ""); mic.submenu = MenuBuilders.microphoneMenu(); m.addItem(mic)
        let lang = NSMenuItem(title: "Languages", action: nil, keyEquivalent: ""); lang.submenu = MenuBuilders.languageMenu(); m.addItem(lang)
        let bar = NSMenuItem(title: Preferences.shared.showFlowBarAlways ? "Hide Flow Bar" : "Show Flow Bar", action: #selector(toggleBar), keyEquivalent: ""); bar.target = self; m.addItem(bar)
        m.addItem(.separator())
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        m.addItem(withTitle: "Help", action: #selector(openHelp), keyEquivalent: "").target = self
        if let r = Updater.shared.available {
            m.addItem(withTitle: "Install Vunu \(r.version) and Relaunch", action: #selector(installUpdate), keyEquivalent: "").target = self
        } else {
            m.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Vunu", action: #selector(quit), keyEquivalent: "q").target = self
        return m
    }

    @objc private func openHub() { onOpenHub?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openShortcuts() { onOpenShortcuts?() }
    @objc private func openHelp() { onOpenHelp?() }
    @objc private func pasteLast() { Task { await SessionCoordinator.shared.pasteLast() } }
    @objc private func copyLast() { Task { await SessionCoordinator.shared.copyLast() } }
    @objc private func toggleBar() { Preferences.shared.showFlowBarAlways.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func installUpdate() { if let r = Updater.shared.available { Task { await Updater.shared.install(r) } } }
    @objc private func checkForUpdates() {
        onOpenSettings?()
        HubState.shared.settingsSection = .system
        Task { await Updater.shared.check(userInitiated: true) }
    }
}

/// Shared submenus used by the status item and the Flow Bar context menu.
@MainActor
enum MenuBuilders {
    static func microphoneMenu() -> NSMenu {
        let m = NSMenu()
        let current = Preferences.shared.preferredMicrophoneUID
        let auto = NSMenuItem(title: "System default", action: #selector(MicMenuTarget.pick(_:)), keyEquivalent: "")
        auto.target = MicMenuTarget.shared; auto.representedObject = ""; auto.state = current == nil ? .on : .off
        m.addItem(auto)
        for d in AudioDevices.inputDevices() {
            let it = NSMenuItem(title: d.displayName + (d.isBluetooth ? " ⚠︎" : ""), action: #selector(MicMenuTarget.pick(_:)), keyEquivalent: "")
            it.target = MicMenuTarget.shared; it.representedObject = d.uid; it.state = current == d.uid ? .on : .off
            m.addItem(it)
        }
        return m
    }
    static func languageMenu() -> NSMenu {
        let m = NSMenu()
        let selected = Preferences.shared.languages
        for code in LanguageCatalog.common {
            let it = NSMenuItem(title: LanguageCatalog.name(code), action: #selector(MicMenuTarget.toggleLanguage(_:)), keyEquivalent: "")
            it.target = MicMenuTarget.shared; it.representedObject = code; it.state = selected.contains(code) ? .on : .off
            m.addItem(it)
        }
        return m
    }
}

@MainActor
final class MicMenuTarget: NSObject {
    static let shared = MicMenuTarget()
    @objc func pick(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String
        Preferences.shared.preferredMicrophoneUID = (uid?.isEmpty ?? true) ? nil : uid
        SessionCoordinator.shared.applyMicrophonePreference()
    }
    @objc func toggleLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        var l = Preferences.shared.languages
        if l.contains(code) { if l.count > 1 { l.removeAll { $0 == code } } } else { l.append(code) }
        Preferences.shared.languages = l
    }
}

public enum LanguageCatalog {
    public static let common = ["en", "ar", "es", "fr", "de", "it", "pt", "nl", "ru", "uk", "pl", "tr", "hi", "ja", "ko", "zh"]
    public static func name(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: code) ?? code }
    /// Which engine can handle a language.
    public static func engines(for code: String) -> [SttEngineKind] {
        switch code {
        case "ar", "hi", "tr", "ja", "ko", "zh": return [.whisperKit]
        default: return [.parakeetV3, .appleSpeech, .whisperKit]
        }
    }
}
