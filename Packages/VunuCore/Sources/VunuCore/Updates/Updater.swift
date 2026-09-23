import Foundation
import AppKit
import Observation
import Security

/// Self-update from GitHub Releases: check `releases/latest`, download the zip, verify the new app is signed by the
/// same certificate as the running one (so TCC grants carry over), swap the bundle in place and relaunch.
/// The only network request Vunu makes besides the one-time model download; can be turned off in Settings.
@MainActor @Observable
public final class Updater {
    public static let shared = Updater()
    nonisolated public static let repo = "NouranAlSharawneh/vunu"

    public struct Release: Sendable, Equatable {
        public let version: String
        public let notes: String
        public let zipURL: URL
        public let pageURL: URL
    }

    public enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading
        case installing
        case failed(String)
    }

    public private(set) var status: Status = .idle
    public private(set) var lastChecked: Date?
    public var available: Release? { if case .available(let r) = status { r } else { nil } }
    nonisolated public static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    private var timer: Task<Void, Never>?
    private init() {}

    /// Background checks: shortly after launch, then daily. No-op when automatic checks are off.
    public func startAutomaticChecks() {
        timer?.cancel()
        guard Preferences.shared.automaticUpdateChecks else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    public func check(userInitiated: Bool) async {
        if status == .checking || status == .downloading || status == .installing { return }
        status = .checking
        do {
            let release = try await Self.fetchLatest()
            lastChecked = Date()
            if Self.isNewer(release.version, than: Self.currentVersion) {
                status = .available(release)
                Log.file("update", "available \(release.version) (running \(Self.currentVersion))")
                if !userInitiated, Preferences.shared.skippedUpdateVersion != release.version {
                    SessionCoordinator.shared.show(SessionNotice(.info, "Vunu \(release.version) is available", detail: "Install it from the menu bar or Settings → System", duration: 8))
                }
            } else {
                status = .upToDate
            }
        } catch {
            status = userInitiated ? .failed("Couldn't check for updates: \(error.localizedDescription)") : .idle
            Log.file("update", "check failed: \(error)")
        }
    }

    /// Download, verify and install `release`, then relaunch. Refuses while a dictation is in progress.
    public func install(_ release: Release) async {
        guard SessionCoordinator.shared.state == .idle || SessionCoordinator.shared.state == .cancelled else {
            status = .failed("Finish the current dictation first"); return
        }
        status = .downloading
        do {
            let newApp = try await Self.downloadAndUnpack(release.zipURL)
            status = .installing
            try Self.verify(newApp: newApp, expectedVersion: release.version)
            try Self.scheduleSwapAndRelaunch(newApp: newApp)
            Log.file("update", "installing \(release.version); relaunching")
            NSApp.terminate(nil)
        } catch {
            status = .failed(error.localizedDescription)
            Log.file("update", "install failed: \(error)")
        }
    }

    public func skip(_ release: Release) {
        Preferences.shared.skippedUpdateVersion = release.version
        status = .idle
    }

    // MARK: GitHub

    struct GitHubRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let body: String?
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    nonisolated static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Vunu/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("GitHub returned \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        return try parse(data)
    }

    nonisolated static func parse(_ data: Data) throws -> Release {
        let gh = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !gh.draft, !gh.prerelease else { throw UpdateError.message("latest release is not final") }
        guard let asset = gh.assets.first(where: { $0.name.hasPrefix("Vunu") && $0.name.hasSuffix(".zip") }) else { throw UpdateError.message("release has no Vunu zip") }
        let version = gh.tag_name.hasPrefix("v") ? String(gh.tag_name.dropFirst()) : gh.tag_name
        return Release(version: version, notes: gh.body ?? "", zipURL: asset.browser_download_url, pageURL: gh.html_url)
    }

    /// Numeric dotted-version comparison ("0.10.0" > "0.9.3").
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: download / verify / swap

    nonisolated static func downloadAndUnpack(_ url: URL) async throws -> URL {
        let (tmpZip, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("download failed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vunu-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("Vunu.zip")
        try FileManager.default.moveItem(at: tmpZip, to: zip)
        let unzipped = dir.appendingPathComponent("unzipped", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path])
        let app = unzipped.appendingPathComponent("Vunu.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError.message("Vunu.app not found in the download") }
        return app
    }

    /// Same bundle ID, expected version, valid signature, and the same leaf certificate as the running app
    /// (or `reference`, for tests).
    nonisolated static func verify(newApp: URL, expectedVersion: String, reference: URL? = nil) throws {
        let refBundleID = reference.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? Bundle.main.bundleIdentifier
        guard let info = Bundle(url: newApp)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == refBundleID,
              info["CFBundleShortVersionString"] as? String == expectedVersion else { throw UpdateError.message("downloaded app doesn't match the release") }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), nil) == errSecSuccess
        else { throw UpdateError.message("the update's code signature is invalid") }
        guard let newCert = leafCertificate(of: staticCode) else { throw UpdateError.message("the update is not signed") }
        var selfStatic: SecStaticCode?
        if let reference {
            _ = SecStaticCodeCreateWithPath(reference as CFURL, [], &selfStatic)
        } else {
            var selfCode: SecCode?
            if SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode { _ = SecCodeCopyStaticCode(selfCode, [], &selfStatic) }
        }
        guard let selfStatic, let ownCert = leafCertificate(of: selfStatic) else { throw UpdateError.message("couldn't read Vunu's own signature") }
        guard newCert == ownCert else { throw UpdateError.message("the update is signed by a different certificate") }
    }

    nonisolated private static func leafCertificate(of code: SecStaticCode) -> Data? {
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any],
              let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }

    /// The running bundle can't be replaced from inside the process, so a detached shell waits for Vunu to quit,
    /// swaps the bundle, clears quarantine and reopens it (same steps as scripts/install.sh).
    nonisolated static func scheduleSwapAndRelaunch(newApp: URL) throws {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.message("\(parent.path) isn't writable; update with the install command instead")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(q(target.path)).old
        mv \(q(target.path)) \(q(target.path)).old && ditto \(q(newApp.path)) \(q(target.path)) || { rm -rf \(q(target.path)); mv \(q(target.path)).old \(q(target.path)); }
        rm -rf \(q(target.path)).old
        xattr -dr com.apple.quarantine \(q(target.path)) 2>/dev/null
        open \(q(target.path))
        rm -rf \(q(newApp.deletingLastPathComponent().deletingLastPathComponent().path))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        try p.run()
    }

    nonisolated private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.message("\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus))") }
    }
}

public enum UpdateError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
}
