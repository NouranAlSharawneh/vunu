import SwiftUI
import AppKit

struct HomeView: View {
    @State private var hub = HubState.shared
    @State private var search = ""
    @State private var transcripts: [Transcript] = []
    @State private var stats: Database.Stats?
    @State private var expanded: Set<Int64> = []
    @State private var confirmDelete: Transcript?
    @State private var selectedIndex: Int = 0
    private let prefs = Preferences.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                statsRow
                HStack { SearchField(text: $search); Spacer() }
                transcriptList
            }
            .padding(32)
        }
        .onAppear(perform: reload)
        .onChange(of: hub.transcriptsVersion) { _, _ in reload() }
        .onChange(of: search) { _, _ in reload() }
        .onChange(of: SessionCoordinator.shared.lastTranscript) { _, _ in reload() }
        .confirmationDialog("Delete this dictation permanently?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let t = confirmDelete, let id = t.id { AudioStore.delete(t.audioPath); try? Database.shared.deleteTranscript(id: id); reload() } }
        }
        .background(KeyboardNav(onPrev: { selectedIndex = max(0, selectedIndex - 1) }, onNext: { selectedIndex = min(transcripts.count - 1, selectedIndex + 1) }))
    }

    private var hero: some View {
        Card(padding: 24) {
            VStack(alignment: .leading, spacing: 8) {
                if prefs.userName.isEmpty {
                    Text("Welcome to Vunu").font(Fonts.heading(36)).foregroundStyle(HubColors.text)
                    HStack(spacing: 6) {
                        Text("Hold").font(Fonts.ui(13)).foregroundStyle(HubColors.secondaryText)
                        KeyChip(text: prefs.shortcuts[.pushToTalk]?.first?.display ?? "fn", active: true)
                        Text("to dictate anywhere").font(Fonts.ui(13)).foregroundStyle(HubColors.secondaryText)
                    }
                } else {
                    Text("Welcome back, \(prefs.userName)").font(Fonts.heading(36)).foregroundStyle(HubColors.text)
                    if let s = stats, s.avgWPM > 0 {
                        Text("You speak \(String(format: "%.1f", max(1, s.avgWPM / 45)))x faster than you type").font(Fonts.ui(13)).foregroundStyle(HubColors.secondaryText)
                    } else {
                        Text("Hold \(prefs.shortcuts[.pushToTalk]?.first?.display ?? "fn") and start talking").font(Fonts.ui(13)).foregroundStyle(HubColors.secondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 14) {
            statTile("Total words", "\(stats?.totalWords ?? 0)")
            statTile("Avg WPM", "\(Int(stats?.avgWPM ?? 0))")
            statTile("Streak", "🔥 \(stats?.streakDays ?? 0)")
        }
    }
    private func statTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Fonts.ui(12, weight: .medium)).foregroundStyle(Tokens.cream.opacity(0.8))
            Text(value).font(Fonts.heading(30)).foregroundStyle(Tokens.cream)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(RoundedRectangle(cornerRadius: Tokens.cardRadius).fill(Tokens.deepGreen))
    }

    private var grouped: [(String, [Transcript])] {
        let cal = Calendar.current
        let fmt = DateFormatter(); fmt.dateStyle = .long
        var groups: [(String, [Transcript])] = []
        for t in transcripts {
            let key = cal.isDateInToday(t.createdAt) ? "Today" : cal.isDateInYesterday(t.createdAt) ? "Yesterday" : fmt.string(from: t.createdAt)
            if let i = groups.firstIndex(where: { $0.0 == key }) { groups[i].1.append(t) } else { groups.append((key, [t])) }
        }
        return groups
    }

    private var transcriptList: some View {
        VStack(alignment: .leading, spacing: 18) {
            if transcripts.isEmpty {
                Text(search.isEmpty ? "Your dictations will appear here." : "No matches.").font(Fonts.ui(13)).foregroundStyle(HubColors.secondaryText).padding(.top, 8)
            }
            ForEach(grouped, id: \.0) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.0).font(Fonts.ui(12, weight: .semibold)).foregroundStyle(HubColors.secondaryText).padding(.leading, 4)
                    ForEach(Array(group.1.enumerated()), id: \.element.id) { _, t in
                        TranscriptRow(t: t, expanded: expanded.contains(t.id ?? -1), selected: transcripts.firstIndex(of: t) == selectedIndex,
                                      onToggle: { toggle(t) }, onDelete: { confirmDelete = t }, onChanged: reload)
                    }
                }
            }
        }
    }

    private func toggle(_ t: Transcript) { guard let id = t.id else { return }; if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }
    private func reload() {
        transcripts = (try? Database.shared.transcripts(search: search)) ?? []
        stats = try? Database.shared.stats()
    }
}

/// ⌘[ / ⌘] navigation.
struct KeyboardNav: NSViewRepresentable {
    var onPrev: () -> Void
    var onNext: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.contains(.command) else { return e }
            if e.charactersIgnoringModifiers == "[" { onPrev(); return nil }
            if e.charactersIgnoringModifiers == "]" { onNext(); return nil }
            return e
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coord { Coord() }
    final class Coord { var monitor: Any?; deinit { if let m = monitor { NSEvent.removeMonitor(m) } } }
}

struct TranscriptRow: View {
    let t: Transcript
    let expanded: Bool
    let selected: Bool
    var onToggle: () -> Void
    var onDelete: () -> Void
    var onChanged: () -> Void
    @State private var hover = false
    @State private var player: NSSound?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            appIcon.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(t.appName.isEmpty ? "Unknown app" : t.appName).font(Fonts.ui(12, weight: .semibold)).foregroundStyle(HubColors.text)
                    Text(t.createdAt.formatted(date: .omitted, time: .shortened)).font(Fonts.ui(11)).foregroundStyle(Tokens.grey)
                    statusBadge
                    Spacer()
                    if hover || expanded { actions }
                }
                Text(t.displayText.isEmpty ? (t.status == .cancelled ? "Cancelled — audio only" : "(no text)") : t.displayText)
                    .font(Fonts.ui(13)).foregroundStyle(HubColors.text).lineLimit(expanded ? nil : 2).textSelection(.enabled)
                if expanded, !t.rawText.isEmpty, t.rawText != t.displayText {
                    Text("Raw: \(t.rawText)").font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText).textSelection(.enabled)
                }
                if expanded, let tm = t.timings { Text(tm.summary).font(Fonts.ui(11)).foregroundStyle(Tokens.grey) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(hover || selected ? HubColors.card : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Tokens.lilac : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Copy") { PasteboardSnapshot.writeText(t.displayText) }
            if t.aiEditApplied { Button(t.editedText == nil ? "Undo AI edit" : "Redo AI edit") { toggleAIEdit() } }
            Button(t.flagged ? "Unflag" : "Flag") { var c = t; c.flagged.toggle(); try? Database.shared.save(c); onChanged() }
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }

    private var appIcon: some View {
        Group {
            if let b = t.appBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else { Image(systemName: "app.dashed").resizable().foregroundStyle(Tokens.grey) }
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch t.status {
        case .failed: Text("Failed").font(Fonts.ui(10, weight: .semibold)).foregroundStyle(Tokens.orange)
        case .cancelled: Text("Cancelled").font(Fonts.ui(10, weight: .semibold)).foregroundStyle(Tokens.grey)
        case .recovering: Text("Interrupted").font(Fonts.ui(10, weight: .semibold)).foregroundStyle(Tokens.orange)
        case .processing: Text("Processing…").font(Fonts.ui(10, weight: .semibold)).foregroundStyle(Tokens.grey)
        case .done: if t.flagged { Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(Tokens.orange) }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if !t.displayText.isEmpty { iconButton("doc.on.doc", "Copy") { PasteboardSnapshot.writeText(t.displayText) } }
            if let p = t.audioPath, FileManager.default.fileExists(atPath: p) {
                iconButton("play.fill", "Play audio") { player?.stop(); player = NSSound(contentsOfFile: p, byReference: true); player?.play() }
                iconButton("arrow.clockwise", t.status == .recovering ? "Recover" : "Retry") { SessionCoordinator.shared.retry(t) }
            }
            if t.aiEditApplied { iconButton("sparkles", t.editedText == nil ? "Undo AI edit" : "Redo AI edit") { toggleAIEdit() } }
            iconButton("trash", "Delete", action: onDelete)
        }
    }
    private func iconButton(_ sys: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: sys).font(.system(size: 11)).frame(width: 22, height: 22) }
            .buttonStyle(.plain).foregroundStyle(HubColors.secondaryText).help(help)
    }
    private func toggleAIEdit() {
        var c = t
        c.editedText = c.editedText == nil ? c.rawText : nil
        try? Database.shared.save(c); onChanged()
    }
}
