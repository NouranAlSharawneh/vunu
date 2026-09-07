import AppKit
import VunuCore

@main
final class VunuMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.launch(arguments: CommandLine.arguments)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        HubWindowController.shared.show()
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.terminate()
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
