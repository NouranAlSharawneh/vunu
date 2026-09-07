import Foundation

/// Known bundle ids and web hosts used for app-category detection, terminal handling and browser URL reading.
public enum AppCatalog {
    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio",
    ]
    /// Editors whose integrated terminal / chat panes are common dictation targets (paste path, TUI chunking).
    public static let codeEditors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92" /* Cursor */, "com.exafunction.windsurf",
        "dev.zed.Zed", "com.jetbrains.intellij", "com.sublimetext.4",
    ]
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser",
        "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox", "app.zen-browser.zen", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
        "com.operasoftware.Opera", "company.thebrowser.dia",
    ]
    public static let chromiumBrowsers: Set<String> = browsers.subtracting(["com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox", "app.zen-browser.zen"])
    /// Electron/Chromium apps whose AX tree must be switched on before reading.
    public static let electronApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.anthropic.claudefordesktop",
        "notion.id", "com.figma.Desktop", "com.microsoft.teams2", "com.spotify.client", "com.openai.chat", "com.linear", "com.superhuman.electron",
        "com.exafunction.windsurf", "org.whispersystems.signal-desktop", "net.whatsapp.WhatsApp", "com.postmanlabs.mac",
    ]
    public static let personalApps: Set<String> = [
        "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.tdesktop.Telegram", "com.hnc.Discord",
        "org.whispersystems.signal-desktop", "com.facebook.archon", "com.apple.FaceTime",
    ]
    public static let workApps: Set<String> = ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.linkedin.LinkedIn"]
    public static let emailApps: Set<String> = ["com.apple.mail", "com.superhuman.electron", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.mimestream.Mimestream"]

    /// Apps where the messaging trailing-period rule applies (native).
    public static let messagingApps: Set<String> = personalApps.union(["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams"])

    public static let personalHosts = ["web.whatsapp.com", "web.telegram.org", "discord.com", "instagram.com", "messenger.com", "x.com", "twitter.com", "reddit.com", "signal.org"]
    public static let workHosts = ["app.slack.com", "slack.com", "teams.microsoft.com", "teams.live.com", "linkedin.com"]
    public static let emailHosts = ["mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com", "mail.superhuman.com", "mail.proton.me", "mail.yahoo.com", "fastmail.com"]
    public static let messagingHosts = personalHosts + ["app.slack.com", "teams.microsoft.com"]

    public static let nonTextApps: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.controlcenter", "com.apple.notificationcenterui"]

    public static func hostMatches(_ host: String, _ list: [String]) -> Bool {
        let h = host.lowercased()
        return list.contains { h == $0 || h.hasSuffix("." + $0) }
    }
}
