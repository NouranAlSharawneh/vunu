import SwiftUI
import AppKit

/// Design tokens measured from Wispr Flow's assets.
public enum Tokens {
    public static let ink = Color(hex: 0x1A1A1A)
    public static let cream = Color(hex: 0xFFFFEB)
    public static let creamMuted = Color(hex: 0xE4E4D0)
    public static let offWhite = Color(hex: 0xFCFCFB)
    public static let lilac = Color(hex: 0xF0D7FF)
    public static let deepGreen = Color(hex: 0x034F46)
    public static let orange = Color(hex: 0xFFA946)
    public static let grey = Color(hex: 0x9D9C98)
    public static let greyDark = Color(hex: 0x71716E)
    public static let barBorder = Color(hex: 0x4D4A42)
    public static let darkBackground = Color(hex: 0x141414)
    public static let darkSidebar = Color(hex: 0x1C1C1C)

    public static let cardRadius: CGFloat = 16
    public static let buttonRadius: CGFloat = 10

    public static let nsInk = NSColor(srgbRed: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1)
    public static let nsCream = NSColor(srgbRed: 1, green: 1, blue: 0xEB/255, alpha: 1)
    public static let nsLilac = NSColor(srgbRed: 0xF0/255, green: 0xD7/255, blue: 1, alpha: 1)
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// Fonts: Figtree for UI, EB Garamond for large headings. Falls back to system fonts if the bundle lacks them.
public enum Fonts {
    public static func ui(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Figtree-Bold"
        case .semibold: name = "Figtree-SemiBold"
        case .medium: name = "Figtree-Medium"
        case .light, .thin, .ultraLight: name = "Figtree-Light"
        default: name = "Figtree-Regular"
        }
        if NSFont(name: name, size: size) != nil { return .custom(name, size: size) }
        return .system(size: size, weight: weight)
    }
    public static func heading(_ size: CGFloat = 32, weight: Font.Weight = .medium) -> Font {
        let name = weight == .regular ? "EBGaramond-Regular" : "EBGaramond-Medium"
        if NSFont(name: name, size: size) != nil { return .custom(name, size: size) }
        return .system(size: size, weight: weight, design: .serif)
    }
}

/// Adaptive hub colors (light: cream, dark: #141414).
public enum HubColors {
    @MainActor public static var isDark: Bool { NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    public static let background = Color(light: Tokens.cream, dark: Tokens.darkBackground)
    public static let sidebar = Color(light: Tokens.creamMuted, dark: Tokens.darkSidebar)
    public static let card = Color(light: Tokens.offWhite, dark: Color(hex: 0x1F1F1F))
    public static let text = Color(light: Tokens.ink, dark: Tokens.cream)
    public static let secondaryText = Color(light: Tokens.greyDark, dark: Tokens.grey)
    public static let divider = Color(light: Tokens.creamMuted, dark: Color(hex: 0x2A2A2A))
}

public extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}
