import SwiftUI
import UniformTypeIdentifiers

enum DictionarySort: String, CaseIterable { case starred = "Starred first", newest = "Newest", oldest = "Oldest", az = "A–Z" }

struct DictionaryView: View {
    @State private var entries: [DictionaryEntry] = []
    @State private var search = ""
    @State private var sort: DictionarySort = .starred
    @State private var selection: Set<Int64> = []
    @State private var showAdd = false
    @State private var editing: DictionaryEntry?
    @State private var toast: String?
    @State private var importPreview: [DictionaryEntry]?

    var filtered: [DictionaryEntry] {
        var list = entries
        if !search.isEmpty { list = list.filter { $0.word.localizedCaseInsensitiveContains(search) || ($0.misspelling ?? "").localizedCaseInsensitiveContains(search) } }
        switch sort {
        case .starred: list.sort { ($0.starred ? 0 : 1, $1.createdAt) < ($1.starred ? 0 : 1, $0.createdAt) }
        case .newest: list.sort { $0.createdAt > $1.createdAt }
        case .oldest: list.sort { $0.createdAt < $1.createdAt }
        case .az: list.sort { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Dictionary", subtitle: "Words Vunu should always get right. Add names, jargon, and misspellings to correct.")
            HStack(spacing: 10) {
                SearchField(text: $search)
                Picker("", selection: $sort) { ForEach(DictionarySort.allCases, id: \.self) { Text($0.rawValue) } }.frame(width: 140)
                Spacer()
                if !selection.isEmpty { Button("Delete \(selection.count)") { deleteSelected() }.buttonStyle(DangerButtonStyle()) }
                Button("Import CSV") { importCSV() }.buttonStyle(SecondaryButtonStyle())
                Button("+ Add new") { showAdd = true }.buttonStyle(PrimaryButtonStyle())
            }
            if let toast { Toast(message: toast) }
            List(selection: $selection) {
                ForEach(filtered) { e in
                    HStack(spacing: 10) {
                        Button { toggleStar(e) } label: { Image(systemName: e.starred ? "star.fill" : "star").foregroundStyle(e.starred ? Tokens.orange : Tokens.grey) }.buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.word).font(Fonts.ui(14, weight: .medium)).foregroundStyle(HubColors.text)
                            if let m = e.misspelling, !m.isEmpty { Text("Corrects “\(m)”").font(Fonts.ui(11)).foregroundStyle(HubColors.secondaryText) }
                        }
                        Spacer()
                        Button { editing = e } label: { Image(systemName: "pencil") }.buttonStyle(.plain).foregroundStyle(HubColors.secondaryText)
                        Button { delete([e]) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(HubColors.secondaryText)
                    }
                    .padding(.vertical, 4)
                    .tag(e.id ?? -1)
                }
            }
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: Tokens.cardRadius).fill(HubColors.card))
            if entries.isEmpty { Text("No words yet. Try adding your name or a product you mention often.").font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText) }
        }
        .padding(32)
        .onAppear(perform: reload)
        .sheet(isPresented: $showAdd) { DictionaryEditor(entry: nil) { save($0) } }
        .sheet(item: $editing) { e in DictionaryEditor(entry: e) { save($0) } }
        .sheet(item: Binding(get: { importPreview.map { ImportBox(items: $0) } }, set: { if $0 == nil { importPreview = nil } })) { box in
            VStack(spacing: 14) {
                Text("Import \(box.items.count) words?").font(Fonts.ui(15, weight: .semibold))
                Text(box.items.prefix(8).map(\.word).joined(separator: ", ") + (box.items.count > 8 ? "…" : "")).font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText)
                HStack { Button("Cancel") { importPreview = nil }.buttonStyle(SecondaryButtonStyle()); Button("Import") { box.items.forEach { try? Database.shared.save($0) }; importPreview = nil; reload(); flash("Imported \(box.items.count) words") }.buttonStyle(PrimaryButtonStyle()) }
            }.padding(24).frame(width: 380)
        }
        .background(KeyShortcut(key: "f", modifiers: .command) { }) // ⌘F focuses search via first responder chain
    }

    struct ImportBox: Identifiable { let id = UUID(); let items: [DictionaryEntry] }

    private func reload() { entries = (try? Database.shared.dictionary()) ?? [] }
    private func save(_ e: DictionaryEntry) {
        var entry = e
        entry.word = entry.word.trimmed
        guard !entry.word.isEmpty, entry.word.count <= 60 else { flash("Word must be 1–60 characters"); return }
        if entries.contains(where: { $0.id != entry.id && $0.word.caseInsensitiveCompare(entry.word) == .orderedSame }) { flash("“\(entry.word)” is already in your dictionary"); return }
        try? Database.shared.save(entry); reload()
        Task { await ModelManager.shared.activeEngine.setVocabulary(entries.map(\.word)) }
    }
    private func toggleStar(_ e: DictionaryEntry) { var c = e; c.starred.toggle(); try? Database.shared.save(c); reload() }
    private func delete(_ list: [DictionaryEntry]) { try? Database.shared.deleteDictionary(ids: list.compactMap(\.id)); selection.removeAll(); reload() }
    private func deleteSelected() { delete(entries.filter { selection.contains($0.id ?? -1) }) }
    private func flash(_ m: String) { toast = m; Task { try? await Task.sleep(for: .seconds(2.5)); if toast == m { toast = nil } } }

    private func importCSV() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.commaSeparatedText, .plainText]; p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var items: [DictionaryEntry] = []
        let existing = Set(entries.map { $0.word.lowercased() })
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            guard let first = cols.first, !first.isEmpty, first.lowercased() != "word", first.lowercased() != "misspelling" else { continue }
            if cols.count == 2, !cols[1].isEmpty {
                guard !existing.contains(cols[1].lowercased()) else { continue }
                items.append(DictionaryEntry(word: cols[1], misspelling: first))
            } else {
                guard !existing.contains(first.lowercased()) else { continue }
                items.append(DictionaryEntry(word: first))
            }
        }
        importPreview = items
    }
}

struct DictionaryEditor: View {
    var entry: DictionaryEntry?
    var onSave: (DictionaryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var word = ""
    @State private var correct = false
    @State private var misspelling = ""
    @State private var starred = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry == nil ? "Add to dictionary" : "Edit word").font(Fonts.ui(16, weight: .semibold))
            TextField("Word or phrase (≤ 60 characters)", text: $word).textFieldStyle(.roundedBorder).font(Fonts.ui(13))
            Toggle("Correct a misspelling", isOn: $correct).font(Fonts.ui(13))
            if correct { TextField("When Vunu hears… (wrong spelling)", text: $misspelling).textFieldStyle(.roundedBorder).font(Fonts.ui(13)) }
            Toggle("Star (priority)", isOn: $starred).font(Fonts.ui(13))
            HStack { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()); Button("Save") { save() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.return, modifiers: .command) }
        }
        .padding(24).frame(width: 420)
        .onAppear { if let e = entry { word = e.word; misspelling = e.misspelling ?? ""; correct = !(e.misspelling ?? "").isEmpty; starred = e.starred } }
    }
    private func save() {
        var e = entry ?? DictionaryEntry(word: word)
        e.word = word; e.misspelling = correct ? misspelling.trimmed : nil; e.starred = starred
        onSave(e); dismiss()
    }
}

/// Invisible view that installs a keyboard shortcut handler (used for ⌘F etc.).
struct KeyShortcut: View {
    var key: KeyEquivalent; var modifiers: EventModifiers; var action: () -> Void
    var body: some View { Button("", action: action).keyboardShortcut(key, modifiers: modifiers).opacity(0).frame(width: 0, height: 0) }
}
