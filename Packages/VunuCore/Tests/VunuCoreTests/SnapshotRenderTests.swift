import XCTest
import SwiftUI
import AppKit
@testable import VunuCore

/// Renders real views offscreen into docs/screenshots when VUNU_SNAPSHOTS points at an output directory.
@MainActor
final class SnapshotRenderTests: XCTestCase {
    func testRenderScreenshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["VUNU_SNAPSHOTS"] else { throw XCTSkip("set VUNU_SNAPSHOTS=<dir>") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let s = SessionCoordinator.shared
        let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app")
        let target = FocusSnapshot(pid: 1, bundleID: "com.apple.Terminal", appName: "Terminal", icon: icon, element: nil, role: "AXTextArea", subrole: nil, isSecure: false, isEditable: true, isTerminal: true, isCodeEditor: false, isBrowser: false, browserURL: nil, windowFrame: nil, category: .other, isMessaging: false, takenAt: Date(), contextMs: 0)

        func pill(_ name: String) {
            let v = FlowBarView(session: s, onCancel: {}, onConfirm: {}, onClickIdle: {}, showLanguage: false, languages: ["en"], onPickLanguage: { _ in })
                .padding(24).background(Color(hex: 0x2B2B30))
            write(v, "\(dir)/\(name).png", scale: 2)
        }
        s.debugSet(state: .idle); pill("flowbar-idle")
        s.audio.debugLevelOverride = 0.7
        s.debugSet(state: .recording, target: target)
        // let the waveform animate a few frames
        for _ in 0..<12 { try await Task.sleep(for: .milliseconds(33)) }
        pill("flowbar-recording")
        s.debugSet(state: .transcribing, target: target); pill("flowbar-processing")
        s.audio.debugLevelOverride = nil
        s.debugSet(state: .idle)

        try? Database.shared.save(DictionaryEntry(word: "Supabase", starred: true))
        try? Database.shared.save(DictionaryEntry(word: "Nunu", misspelling: "new new"))
        try? Database.shared.save(Snippet(phrase: "my email address", replacement: "nunu@example.com"))
        for (page, name) in [(HubPage.style, "hub-style"), (.settings, "hub-settings"), (.dictionary, "hub-dictionary"), (.snippets, "hub-snippets"), (.help, "hub-help")] {
            HubState.shared.page = page
            windowShot(HubRootView(), size: NSSize(width: 1040, height: 700), "\(dir)/\(name).png")
        }
        try? Database.shared.deleteDictionary(ids: (try? Database.shared.dictionary())?.filter { ["Supabase", "Nunu"].contains($0.word) }.compactMap(\.id) ?? [])
    }

    /// AppKit-backed offscreen render (handles ScrollView / List / Picker that ImageRenderer skips).
    private func windowShot<V: View>(_ view: V, size: NSSize, _ path: String) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        win.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { XCTFail("rep"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func write<V: View>(_ view: V, _ path: String, scale: CGFloat) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { XCTFail("render \(path)"); return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
