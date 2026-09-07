import SwiftUI
import AppKit

/// Floating 420×300 mini editor near the cursor. ⌥S opens it; holding ⌥S dictates into it.
@MainActor
public final class ScratchpadController {
    public static let shared = ScratchpadController()
    private let panel: NSPanel
    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Scratchpad"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(HubColors.background)
        panel.contentView = NSHostingView(rootView: ScratchpadView(onClose: { [weak panel] in panel?.orderOut(nil) }))
    }
    public func toggle() {
        if panel.isVisible { panel.orderOut(nil); return }
        let m = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: m.x - 40, y: m.y - 320))
        panel.makeKeyAndOrderFront(nil)
    }
    public func show() { if !panel.isVisible { toggle() } }
}

struct ScratchpadView: View {
    var onClose: () -> Void
    @State private var session = SessionCoordinator.shared
    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $session.scratchpadText).font(Fonts.ui(14)).foregroundStyle(HubColors.text).scrollContentBackground(.hidden).padding(10)
            Divider()
            HStack {
                Text(session.state.isCapturing && session.mode == .scratchpad ? "Listening…" : "Hold ⌥S to dictate here").font(Fonts.ui(11)).foregroundStyle(HubColors.secondaryText)
                Spacer()
                Button("Clear") { session.scratchpadText = "" }.buttonStyle(SecondaryButtonStyle())
                Button("Copy") { PasteboardSnapshot.writeText(session.scratchpadText) }.buttonStyle(SecondaryButtonStyle())
                Button("Insert") {
                    let text = session.scratchpadText
                    onClose()
                    Task { try? await Task.sleep(for: .milliseconds(150)); let t = await FocusTracker.shared.snapshot(); _ = await Inserter.shared.insert(text, into: t) }
                }.buttonStyle(PrimaryButtonStyle())
            }.padding(10)
        }
        .background(HubColors.background)
    }
}

/// Hub page version of the scratchpad.
struct ScratchpadPageView: View {
    @State private var session = SessionCoordinator.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Scratchpad", subtitle: "A place to dictate freely, then copy or insert. ⌥S opens the floating version anywhere.")
            TextEditor(text: $session.scratchpadText).font(Fonts.ui(14)).foregroundStyle(HubColors.text).scrollContentBackground(.hidden).padding(12)
                .background(RoundedRectangle(cornerRadius: Tokens.cardRadius).fill(HubColors.card))
            HStack { Spacer(); Button("Clear") { session.scratchpadText = "" }.buttonStyle(SecondaryButtonStyle()); Button("Copy") { PasteboardSnapshot.writeText(session.scratchpadText) }.buttonStyle(PrimaryButtonStyle()) }
        }.padding(32)
    }
}
