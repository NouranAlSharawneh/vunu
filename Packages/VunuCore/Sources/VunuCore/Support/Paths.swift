import Foundation

/// All on-disk locations used by Vunu.
public enum Paths {
    public static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Vunu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    public static let models: URL = sub("Models")
    public static let audio: URL = sub("Audio")
    public static let database: URL = appSupport.appendingPathComponent("vunu.sqlite")
    public static let logs: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Vunu")

    private static func sub(_ name: String) -> URL {
        let dir = appSupport.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
