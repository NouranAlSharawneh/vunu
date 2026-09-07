import SwiftUI
import Carbon.HIToolbox

/// Per-action shortcut rows with "+ Add another", Reset to default, and a live recorder.
struct ShortcutsDialog: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prefs = Preferences.shared
    @State private var recording: (ShortcutAction, Int?)? = nil   // (action, index to replace or nil to add)
    @State private var toast: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Shortcuts").font(Fonts.ui(17, weight: .semibold)); Spacer(); Button("Reset to default") { prefs.shortcuts = ShortcutBinding.defaults; SessionCoordinator.shared.reloadBindings() }.buttonStyle(SecondaryButtonStyle()) }
            Text("Up to 4 bindings per action, 3 keys each. fn alone is allowed for push-to-talk.").font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(ShortcutAction.allCases) { action in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.title).font(Fonts.ui(13, weight: .semibold)).foregroundStyle(HubColors.text)
                                Text(action.subtitle).font(Fonts.ui(11)).foregroundStyle(HubColors.secondaryText)
                            }.frame(width: 220, alignment: .leading)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array((prefs.shortcuts[action] ?? []).enumerated()), id: \.offset) { i, b in
                                    HStack(spacing: 6) {
                                        Button { recording = (action, i) } label: { chips(b, active: recording?.0 == action && recording?.1 == i) }.buttonStyle(.plain)
                                        Button { remove(action, i) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(HubColors.secondaryText) }.buttonStyle(.plain)
                                    }
                                }
                                if (prefs.shortcuts[action]?.count ?? 0) < 4 {
                                    Button(recording?.0 == action && recording?.1 == nil ? "Press keys…" : "+ Add another") { recording = (action, nil) }.buttonStyle(SecondaryButtonStyle())
                                }
                            }
                            Spacer()
                        }
                        Divider().overlay(HubColors.divider)
                    }
                }
            }.frame(height: 400)
            if let toast { Toast(message: toast) }
            if recording != nil {
                ShortcutRecorder(onCaptured: { b in capture(b) }, onCancel: { recording = nil })
                    .frame(height: 0)
                Text("Recording… press the keys now (Esc to cancel)").font(Fonts.ui(12, weight: .medium)).foregroundStyle(Tokens.deepGreen)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()) }
        }
        .padding(24).frame(width: 640)
        .onDisappear { recording = nil }
    }

    private func chips(_ b: ShortcutBinding, active: Bool) -> some View {
        HStack(spacing: 4) { ForEach(b.display.split(separator: " ").map(String.init), id: \.self) { KeyChip(text: $0, active: active) } }
    }
    private func remove(_ a: ShortcutAction, _ i: Int) {
        var list = prefs.shortcuts[a] ?? []
        guard list.indices.contains(i) else { return }
        list.remove(at: i); prefs.shortcuts[a] = list; SessionCoordinator.shared.reloadBindings()
    }
    private func capture(_ b: ShortcutBinding) {
        guard let (action, index) = recording else { return }
        if let v = ShortcutRules.validate(b, for: action, existing: prefs.shortcuts) { flash(v.message); return }
        var list = prefs.shortcuts[action] ?? []
        if let index, list.indices.contains(index) { list[index] = b } else { list.append(b) }
        prefs.shortcuts[action] = list
        SessionCoordinator.shared.reloadBindings()
        recording = nil
    }
    private func flash(_ m: String) { toast = m; Task { try? await Task.sleep(for: .seconds(3)); if toast == m { toast = nil } } }
}

/// Captures a chord from the global event tap (so fn / mouse buttons work) and reports it once the chord is released.
struct ShortcutRecorder: View {
    var onCaptured: (ShortcutBinding) -> Void
    var onCancel: () -> Void
    @State private var box = RecorderBox()

    var body: some View {
        Color.clear
            .onAppear { start() }
            .onDisappear { SessionCoordinator.shared.hotkeys.setRecorder(nil) }
    }

    private func start() {
        let b = box
        SessionCoordinator.shared.hotkeys.setRecorder { raw, mods in
            Task { @MainActor in
                switch raw.kind {
                case .flagsChanged:
                    if !mods.isEmpty { b.maxMods = mods.count > b.maxMods.count ? mods : b.maxMods; b.mods = mods }
                    else if b.key == nil && b.mouse == nil && !b.maxMods.isEmpty { finish(b) }
                    else { b.mods = mods }
                    if mods.isEmpty && (b.key != nil || b.mouse != nil) { finish(b) }
                case .keyDown:
                    if Int(raw.keyCode) == kVK_Escape && b.maxMods.isEmpty { onCancel(); return }
                    if KeyNames.isModifierKeyCode(raw.keyCode) { return }
                    b.key = raw.keyCode; b.mods = mods; if mods.count > b.maxMods.count { b.maxMods = mods }
                case .keyUp:
                    if b.key == raw.keyCode { finish(b) }
                case .mouseDown:
                    b.mouse = raw.mouseButton; b.mods = mods
                case .mouseUp:
                    if b.mouse == raw.mouseButton { finish(b) }
                }
            }
        }
    }
    private func finish(_ b: RecorderBox) {
        let mods = b.key == nil && b.mouse == nil ? b.maxMods : (b.mods.isEmpty ? b.maxMods : b.mods)
        // collapse sides: if only one side of a kind was pressed keep it as .any unless it's the right side
        var set: Set<ModifierKey> = []
        for kind in ModifierKind.allCases {
            let sides = mods.filter { $0.kind == kind }
            if sides.isEmpty { continue }
            if sides.contains(where: { $0.side == .right }) && !sides.contains(where: { $0.side == .left }) { set.insert(ModifierKey(kind, side: .right)) }
            else { set.insert(ModifierKey(kind)) }
        }
        let binding = ShortcutBinding(modifiers: set, keyCode: b.key, mouseButton: b.mouse)
        b.reset()
        SessionCoordinator.shared.hotkeys.setRecorder(nil)
        onCaptured(binding)
    }
}

@MainActor final class RecorderBox {
    var mods: Set<ModifierKey> = []
    var maxMods: Set<ModifierKey> = []
    var key: UInt16?
    var mouse: Int?
    func reset() { mods = []; maxMods = []; key = nil; mouse = nil }
}
