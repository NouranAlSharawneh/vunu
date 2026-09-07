import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Fonts.ui(13, weight: .semibold)).foregroundStyle(Tokens.ink)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Tokens.buttonRadius).fill(Tokens.lilac).opacity(configuration.isPressed ? 0.75 : 1))
    }
}
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Fonts.ui(13, weight: .medium)).foregroundStyle(HubColors.text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Tokens.buttonRadius).fill(HubColors.card).overlay(RoundedRectangle(cornerRadius: Tokens.buttonRadius).strokeBorder(HubColors.divider)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Fonts.ui(13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Tokens.buttonRadius).fill(Color.red.opacity(configuration.isPressed ? 0.7 : 0.9)))
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding)
            .background(RoundedRectangle(cornerRadius: Tokens.cardRadius).fill(HubColors.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.cardRadius).strokeBorder(HubColors.divider))
    }
}

struct PageHeader: View {
    var title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Fonts.heading(34)).foregroundStyle(HubColors.text)
            if let subtitle { Text(subtitle).font(Fonts.ui(13)).foregroundStyle(HubColors.secondaryText) }
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder = "Search"
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(HubColors.secondaryText)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(Fonts.ui(13))
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(HubColors.secondaryText) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(HubColors.card).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HubColors.divider)))
        .frame(maxWidth: 280)
    }
}

/// Shortcut key chip like Wispr's (turns lilac when "pressed").
struct KeyChip: View {
    var text: String
    var active = false
    var body: some View {
        Text(text).font(Fonts.ui(12, weight: .semibold)).foregroundStyle(active ? Tokens.ink : HubColors.text)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Tokens.lilac : HubColors.card).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HubColors.divider)))
    }
}

struct Toast: View {
    var message: String
    var body: some View {
        Text(message).font(Fonts.ui(12, weight: .medium)).foregroundStyle(Tokens.cream)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Tokens.ink))
    }
}
