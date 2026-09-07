import SwiftUI
import AppKit

struct StyleView: View {
    @State private var category: AppCategory = .personal
    @State private var prefs = Preferences.shared
    @State private var addApp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Style", subtitle: "Choose how Vunu writes in each kind of app. Nothing is selected until you pick one.")
            Picker("", selection: $category) { ForEach(AppCategory.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 520)
            HStack(spacing: 14) {
                ForEach(WritingStyle.options(for: category)) { style in
                    let selected = prefs.stylesByCategory[category] == style
                    Button {
                        if selected { prefs.stylesByCategory[category] = nil } else { prefs.stylesByCategory[category] = style }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(style.title).font(Fonts.ui(15, weight: .semibold)).foregroundStyle(HubColors.text)
                            Text(style.example).font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText).lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(RoundedRectangle(cornerRadius: Tokens.cardRadius).fill(HubColors.card))
                        .overlay(RoundedRectangle(cornerRadius: Tokens.cardRadius).strokeBorder(selected ? Tokens.lilac : HubColors.divider, lineWidth: selected ? 2 : 1))
                    }.buttonStyle(.plain)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Apps in \(category.title)").font(Fonts.ui(13, weight: .semibold)).foregroundStyle(HubColors.text); Spacer(); Button("Add app") { addApp = true }.buttonStyle(SecondaryButtonStyle()) }
                    let builtIn = builtInApps(category)
                    let extra = prefs.extraAppsByCategory[category] ?? []
                    WrapView(items: builtIn.map { ($0, false) } + extra.map { ($0, true) }) { item in
                        HStack(spacing: 6) {
                            Text(displayName(item.0)).font(Fonts.ui(12))
                            if item.1 { Button { remove(item.0) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(HubColors.background)).foregroundStyle(HubColors.text)
                    }
                    if category == .other { Text("Everything not listed in the other categories.").font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText) }
                }
            }
            Spacer()
        }
        .padding(32)
        .fileImporter(isPresented: $addApp, allowedContentTypes: [.applicationBundle]) { result in
            if case .success(let url) = result, let bundle = Bundle(url: url)?.bundleIdentifier {
                var map = prefs.extraAppsByCategory
                for c in AppCategory.allCases { map[c]?.removeAll { $0 == bundle } }
                map[category, default: []].append(bundle)
                let final = map
                prefs.extraAppsByCategory = final
                FocusTracker.extraApps.withLock { $0 = final }
            }
        }
    }
    private func remove(_ b: String) { var map = prefs.extraAppsByCategory; map[category]?.removeAll { $0 == b }; let final = map; prefs.extraAppsByCategory = final; FocusTracker.extraApps.withLock { $0 = final } }
    private func builtInApps(_ c: AppCategory) -> [String] {
        switch c {
        case .personal: Array(AppCatalog.personalApps).sorted() + AppCatalog.personalHosts
        case .work: Array(AppCatalog.workApps).sorted() + AppCatalog.workHosts
        case .email: Array(AppCatalog.emailApps).sorted() + AppCatalog.emailHosts
        case .other: []
        }
    }
    private static let knownNames: [String: String] = [
        "com.facebook.archon": "Messenger", "com.tdesktop.Telegram": "Telegram", "ru.keepcoder.Telegram": "Telegram (App Store)",
        "org.whispersystems.signal-desktop": "Signal", "net.whatsapp.WhatsApp": "WhatsApp", "com.hnc.Discord": "Discord", "com.apple.MobileSMS": "Messages",
        "com.tinyspeck.slackmacgap": "Slack", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams (classic)", "com.linkedin.LinkedIn": "LinkedIn",
        "com.apple.mail": "Mail", "com.superhuman.electron": "Superhuman", "com.microsoft.Outlook": "Outlook", "com.readdle.smartemail-Mac": "Spark", "com.mimestream.Mimestream": "Mimestream",
        "com.apple.FaceTime": "FaceTime",
    ]
    private func displayName(_ id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        return Self.knownNames[id] ?? id
    }
}

/// Simple flow layout for chips.
struct WrapView<Item, Content: View>: View {
    var items: [Item]
    @ViewBuilder var content: (Item) -> Content
    var body: some View {
        FlowLayout(spacing: 6) { ForEach(Array(items.enumerated()), id: \.offset) { _, item in content(item) } }
    }
}
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
