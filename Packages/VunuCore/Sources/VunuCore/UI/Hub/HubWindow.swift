import AppKit
import SwiftUI

public enum HubPage: String, CaseIterable, Identifiable {
    case home, dictionary, snippets, style, scratchpad, settings, help
    public var id: String { rawValue }
    var title: String {
        switch self { case .home: "Home"; case .dictionary: "Dictionary"; case .snippets: "Snippets"; case .style: "Style"; case .scratchpad: "Scratchpad"; case .settings: "Settings"; case .help: "Help" }
    }
    var icon: String {
        switch self { case .home: "house"; case .dictionary: "character.book.closed"; case .snippets: "text.badge.plus"; case .style: "paintbrush"; case .scratchpad: "note.text"; case .settings: "gearshape"; case .help: "questionmark.circle" }
    }
}

@MainActor @Observable
public final class HubState {
    public static let shared = HubState()
    public var page: HubPage = .home
    public var settingsSection: SettingsSection = .general
    public var showShortcutsDialog = false
    public var transcriptsVersion = 0
    public var showDebugHUD = false
    private init() {}
    public func reloadTranscripts() { transcriptsVersion += 1 }
}

/// Main app window (LSUIElement app: shows in Dock only while open unless "Show in Dock").
@MainActor
public final class HubWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = HubWindowController()

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Vunu"
        w.minSize = NSSize(width: 860, height: 560)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: HubRootView())
        w.center()
        w.setFrameAutosaveName("VunuHub")
        super.init(window: w)
        w.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    public func show(page: HubPage? = nil) {
        if let page { HubState.shared.page = page }
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        if !Preferences.shared.showInDock { NSApp.setActivationPolicy(.accessory) }
    }
}

struct HubRootView: View {
    @State private var hub = HubState.shared
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $hub.page)
            Divider().overlay(HubColors.divider)
            Group {
                switch hub.page {
                case .home: HomeView()
                case .dictionary: DictionaryView()
                case .snippets: SnippetsView()
                case .style: StyleView()
                case .scratchpad: ScratchpadPageView()
                case .settings: SettingsView()
                case .help: HelpView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HubColors.background)
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(HubColors.background)
        .sheet(isPresented: $hub.showShortcutsDialog) { ShortcutsDialog() }
        .sheet(isPresented: $hub.showDebugHUD) { DebugHUDView() }
    }
}

struct Sidebar: View {
    @Binding var page: HubPage
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: MenuBarController.glyph(color: Tokens.nsInk)).renderingMode(.template).foregroundStyle(HubColors.text)
                Text("Vunu").font(Fonts.heading(22)).foregroundStyle(HubColors.text)
            }
            .padding(.horizontal, 16).padding(.top, 40).padding(.bottom, 12)
            ForEach([HubPage.home, .dictionary, .snippets, .style, .scratchpad]) { row($0) }
            Spacer()
            row(.settings)
            row(.help)
        }
        .padding(.horizontal, 12).padding(.bottom, 16)
        .frame(width: 220)
        .background(HubColors.sidebar)
    }
    private func row(_ p: HubPage) -> some View {
        Button { page = p } label: {
            HStack(spacing: 10) {
                Image(systemName: p.icon).frame(width: 18)
                Text(p.title).font(Fonts.ui(14, weight: page == p ? .semibold : .medium))
                Spacer()
            }
            .foregroundStyle(page == p ? Tokens.ink : HubColors.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(page == p ? Tokens.lilac : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Help").font(Fonts.heading(34)).foregroundStyle(HubColors.text)
                Group {
                    helpRow("Hold fn", "Speak, release to insert into whatever text field is focused — even if you ⌘-Tab while talking.")
                    helpRow("Double-tap fn or fn+Space", "Hands-free mode. Press again (or ■ on the bar) to stop.")
                    helpRow("Esc", "Cancel the current dictation without inserting anything.")
                    helpRow("⌘⌃V / ⌘⌃C", "Paste or copy the last transcript again.")
                    helpRow("fn+⌃ (Command Mode)", "Select text, hold, and say how to change it. Enable in Settings → Experimental.")
                    helpRow("Say \"period\", \"new line\", \"at sign\"…", "Spoken punctuation is converted. \"press enter\" at the end sends the message.")
                    helpRow("Music keeps playing", "Vunu never ducks or pauses other apps' audio. Optional \"Mute music while dictating\" is in Settings → System.")
                    helpRow("Everything is local", "Models live in ~/Library/Application Support/Vunu/Models. No accounts, no network except model downloads.")
                }
                Text("Log file: ~/Library/Logs/Vunu/vunu.log").font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText)
            }
            .padding(32)
        }
    }
    private func helpRow(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(Fonts.ui(14, weight: .semibold)).foregroundStyle(HubColors.text)
            Text(d).font(Fonts.ui(13)).foregroundStyle(HubColors.secondaryText)
        }
    }
}

struct DebugHUDView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let s = SessionCoordinator.shared
        let t = s.lastTimings
        VStack(alignment: .leading, spacing: 8) {
            Text("Last session timings").font(Fonts.ui(15, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Recording"); Text("\(Int(t.captureMs)) ms") }
                GridRow { Text("VAD"); Text("\(Int(t.vadMs)) ms") }
                GridRow { Text("ASR"); Text("\(Int(t.asrMs)) ms") }
                GridRow { Text("Rules"); Text(String(format: "%.1f ms", t.rulesMs)) }
                GridRow { Text("LLM"); Text(t.llmUsed ? "\(Int(t.llmMs)) ms" : "skipped (\(t.llmRejected ?? "-")) \(Int(t.llmMs)) ms") }
                GridRow { Text("Context"); Text("\(Int(t.contextMs)) ms") }
                GridRow { Text("Insert"); Text("\(Int(t.insertMs)) ms · \(t.insertPath)") }
                GridRow { Text("Total (key-up → inserted)").bold(); Text("\(Int(t.totalMs)) ms").bold() }
                GridRow { Text("First sample latency"); Text(String(format: "%.1f ms", s.audio.firstSampleLatencyMs)) }
                GridRow { Text("RSS"); Text(String(format: "%.0f MB", ModelManager.shared.residentMemoryMB)) }
                GridRow { Text("State"); Text(s.state.label) }
                GridRow { Text("Tap running"); Text(s.tap?.isRunning == true ? "yes" : "no") }
                GridRow { Text("Secure input"); Text(s.secureInputActive ? "yes" : "no") }
            }
            .font(Fonts.ui(12))
            HStack { Spacer(); Button("Close") { dismiss() } }
        }
        .padding(20).frame(width: 420)
        .onAppear { ModelManager.shared.updateMemory() }
    }
}
