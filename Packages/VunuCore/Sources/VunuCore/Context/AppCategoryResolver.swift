import Foundation

/// Resolves Personal / Work / Email / Other for a target app (+ browser URL), honoring user-added apps.
public struct AppCategoryResolver: Sendable {
    public var extraApps: [AppCategory: [String]]
    public init(extraApps: [AppCategory: [String]] = [:]) { self.extraApps = extraApps }

    public func category(bundleID: String?, url: URL?) -> AppCategory {
        if let bundleID {
            for (cat, apps) in extraApps where apps.contains(bundleID) { return cat }
            if AppCatalog.personalApps.contains(bundleID) { return .personal }
            if AppCatalog.workApps.contains(bundleID) { return .work }
            if AppCatalog.emailApps.contains(bundleID) { return .email }
        }
        if let host = url?.host() {
            for (cat, apps) in extraApps where apps.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return cat }
            if AppCatalog.hostMatches(host, AppCatalog.personalHosts) { return .personal }
            if AppCatalog.hostMatches(host, AppCatalog.workHosts) { return .work }
            if AppCatalog.hostMatches(host, AppCatalog.emailHosts) { return .email }
        }
        return .other
    }

    /// True when the messaging trailing-period rule applies.
    public static func isMessaging(bundleID: String?, url: URL?) -> Bool {
        if let bundleID, AppCatalog.messagingApps.contains(bundleID) { return true }
        if let host = url?.host(), AppCatalog.hostMatches(host, AppCatalog.messagingHosts) { return true }
        return false
    }
}
