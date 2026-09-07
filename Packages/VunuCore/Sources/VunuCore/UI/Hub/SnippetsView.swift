import SwiftUI
import UniformTypeIdentifiers

enum SnippetSort: String, CaseIterable { case newest = "Newest", oldest = "Oldest", az = "A–Z" }

struct SnippetsView: View {
    @State private var snippets: [Snippet] = []
    @State private var search = ""
    @State private var sort: SnippetSort = .newest
    @State private var showAdd = false
    @State private var editing: Snippet?
    @State private var confirmDelete: Snippet?
    @State private var toast: String?

    var filtered: [Snippet] {
        var list = snippets
        if !search.isEmpty { list = list.filter { $0.phrase.localizedCaseInsensitiveContains(search) || $0.replacement.localizedCaseInsensitiveContains(search) } }
        switch sort {
        case .newest: list.sort { $0.createdAt > $1.createdAt }
        case .oldest: list.sort { $0.createdAt < $1.createdAt }
        case .az: list.sort { $0.phrase.localizedCaseInsensitiveCompare($1.phrase) == .orderedAscending }
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Snippets", subtitle: "Say a short phrase, insert a longer one. Try “my email address”.")
            HStack(spacing: 10) {
                SearchField(text: $search)
                Picker("", selection: $sort) { ForEach(SnippetSort.allCases, id: \.self) { Text($0.rawValue) } }.frame(width: 120)
                Spacer()
                Button("Import JSON") { importJSON() }.buttonStyle(SecondaryButtonStyle())
                Button("+ Add new") { showAdd = true }.buttonStyle(PrimaryButtonStyle())
            }
            if let toast { Toast(message: toast) }
            List {
                ForEach(filtered) { s in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.phrase).font(Fonts.ui(14, weight: .medium)).foregroundStyle(HubColors.text)
                            Text(s.replacement.isEmpty ? "(empty — set the expansion)" : s.replacement).font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText).lineLimit(2)
                        }
                        Spacer()
                        Button { editing = s } label: { Image(systemName: "pencil") }.buttonStyle(.plain).foregroundStyle(HubColors.secondaryText)
                        Button { confirmDelete = s } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(HubColors.secondaryText)
                    }.padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: Tokens.cardRadius).fill(HubColors.card))
        }
        .padding(32)
        .onAppear(perform: reload)
        .sheet(isPresented: $showAdd) { SnippetEditor(snippet: nil) { save($0) } }
        .sheet(item: $editing) { s in SnippetEditor(snippet: s) { save($0) } }
        .confirmationDialog("Delete snippet “\(confirmDelete?.phrase ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let id = confirmDelete?.id { try? Database.shared.deleteSnippet(id: id); reload() } }
        } message: { Text(confirmDelete?.replacement.prefix(200) ?? "") }
    }

    private func reload() {
        var list = (try? Database.shared.snippets()) ?? []
        if list.isEmpty && !UserDefaults.standard.bool(forKey: "defaultSnippetsSeeded") {
            SnippetExpander.defaults.forEach { try? Database.shared.save($0) }
            UserDefaults.standard.set(true, forKey: "defaultSnippetsSeeded")
            list = (try? Database.shared.snippets()) ?? []
        }
        snippets = list
    }
    private func save(_ s: Snippet) {
        guard !s.phrase.trimmed.isEmpty, s.phrase.count <= 60 else { flash("Snippet phrase must be 1–60 characters"); return }
        guard s.replacement.count <= 4000 else { flash("Expansion must be ≤ 4,000 characters"); return }
        try? Database.shared.save(s); reload()
    }
    private func flash(_ m: String) { toast = m; Task { try? await Task.sleep(for: .seconds(2.5)); if toast == m { toast = nil } } }
    private func importJSON() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) else { return }
        guard data.count <= 3 * 1024 * 1024 else { flash("File must be ≤ 3 MB"); return }
        struct Item: Decodable { let phrase: String; let replacement: String }
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else { flash("Expected [{\"phrase\":…,\"replacement\":…}]"); return }
        guard items.count <= 1000 else { flash("At most 1,000 snippets per import"); return }
        var n = 0
        for i in items where !i.phrase.isEmpty && i.phrase.count <= 60 && i.replacement.count <= 4000 { try? Database.shared.save(Snippet(phrase: i.phrase, replacement: i.replacement)); n += 1 }
        reload(); flash("Imported \(n) snippets")
    }
}

struct SnippetEditor: View {
    var snippet: Snippet?
    var onSave: (Snippet) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var replacement = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snippet == nil ? "New snippet" : "Edit snippet").font(Fonts.ui(16, weight: .semibold))
            Text("Snippet (what you say, ≤ 60 chars)").font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText)
            TextField("e.g. my email address", text: $phrase).textFieldStyle(.roundedBorder).font(Fonts.ui(13))
            Text("Expansion (what gets inserted, ≤ 4,000 chars)").font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText)
            TextEditor(text: $replacement).font(Fonts.ui(13)).frame(height: 140).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HubColors.divider))
            HStack { Text("\(replacement.count)/4000").font(Fonts.ui(11)).foregroundStyle(HubColors.secondaryText); Spacer(); Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()); Button("Save  ⌘↩") { save() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.return, modifiers: .command) }
        }
        .padding(24).frame(width: 480)
        .onAppear { if let s = snippet { phrase = s.phrase; replacement = s.replacement } }
    }
    private func save() { var s = snippet ?? Snippet(phrase: phrase, replacement: replacement); s.phrase = phrase.trimmed; s.replacement = replacement; onSave(s); dismiss() }
}
