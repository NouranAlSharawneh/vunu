import AppKit
import SwiftUI
import CoreAudio

/// Wires everything together. Called from the thin app target's NSApplicationDelegate.
@MainActor
public final class AppController {
    public static let shared = AppController()
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private init() {}

    public func launch(arguments: [String]) {
        Log.file("app", "launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") args=\(arguments.dropFirst())")
        NSApp.setActivationPolicy(Preferences.shared.showInDock ? .regular : .accessory)
        _ = Database.shared
        try? Database.shared.markStaleProcessing()
        _ = Sounds.shared
        _ = MenuBarController.shared
        _ = FlowBarController.shared
        wireCallbacks()
        observeSystem()

        let session = SessionCoordinator.shared
        if Permissions.microphoneGranted { session.warmAudio(); session.applyMicrophonePreference() }
        if Permissions.accessibilityGranted {
            do { try session.startHotkeys() } catch { Log.hotkeys.error("tap start failed: \(error)"); Log.file("hotkeys", "tap start failed: \(error)") }
        }
        if !Preferences.shared.onboardingCompleted || !Permissions.accessibilityGranted || !Permissions.microphoneGranted {
            OnboardingWindowController.shared.onFinished = { [weak self] in self?.afterOnboarding() }
            OnboardingWindowController.shared.show()
        } else {
            Task { await ModelManager.shared.loadSelected() }
        }
        if arguments.contains("--benchmark") { Task { try? await Task.sleep(for: .seconds(3)); await runBenchmarkToLog() } }
        if arguments.contains("--hub") { HubWindowController.shared.show() }
        AudioStore.collectGarbage(retention: Preferences.shared.audioRetention)
        Updater.shared.startAutomaticChecks()
    }

    private func afterOnboarding() {
        let s = SessionCoordinator.shared
        if Permissions.microphoneGranted { s.warmAudio(); s.applyMicrophonePreference() }
        if Permissions.accessibilityGranted { try? s.startHotkeys() }
        Task { await ModelManager.shared.loadSelected() }
        HubWindowController.shared.show(page: .home)
    }

    private func wireCallbacks() {
        MenuBarController.shared.onOpenHub = { HubWindowController.shared.show(page: .home) }
        MenuBarController.shared.onOpenSettings = { HubWindowController.shared.show(page: .settings) }
        MenuBarController.shared.onOpenShortcuts = { HubWindowController.shared.show(page: .settings); HubState.shared.showShortcutsDialog = true }
        MenuBarController.shared.onOpenHelp = { HubWindowController.shared.show(page: .help) }
        MenuBarController.shared.onDebugHUD = { HubWindowController.shared.show(); HubState.shared.showDebugHUD = true }
        FlowBarController.shared.onOpenSettings = { HubWindowController.shared.show(page: .settings) }
        FlowBarController.shared.onOpenHistory = { HubWindowController.shared.show(page: .home) }
        SessionCoordinator.shared.onScratchpadRequested = { ScratchpadController.shared.show() }
        SessionCoordinator.shared.onCommandModeResult = { original, rewritten in CommandDiffController.shared.show(original: original, rewritten: rewritten) }
    }

    private func observeSystem() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in try? await Task.sleep(for: .seconds(2)); SessionCoordinator.shared.restartHotkeys(); Log.file("hotkeys", "tap restarted after wake") }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in try? await Task.sleep(for: .seconds(1)); SessionCoordinator.shared.restartHotkeys() }
        }
        // periodic tap health check (cheap)
        Task {
            while true {
                try? await Task.sleep(for: .seconds(30))
                SessionCoordinator.shared.tap?.reenable()
            }
        }
        // audio device list changes → notify pickers
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in NotificationCenter.default.post(name: .vunuAudioDevicesChanged, object: nil) }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private func runBenchmarkToLog() async {
        await ModelManager.shared.loadSelected()
        let samples = BenchmarkFixture.samples()
        let b = await ModelManager.shared.benchmark(samples: samples, seconds: Double(samples.count) / AudioCapture.sampleRate)
        Log.file("bench", "audio \(String(format: "%.1f", b.audioSeconds)) s · asr \(Int(b.asrMs)) ms · rules \(String(format: "%.1f", b.rulesMs)) ms · llm \(Int(b.llmMs)) ms \(b.llmRejected.map { "(rejected: \($0))" } ?? "(accepted)") · rss \(Int(ModelManager.shared.residentMemoryMB)) MB")
        Log.file("bench", "text: \(b.text)")
    }

    public static func relaunch() {
        let url = Bundle.main.bundleURL
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"\(url.path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    public func terminate() {
        SessionCoordinator.shared.tap?.stop()
        SessionCoordinator.shared.audio.stop()
        Log.file("app", "quit")
    }
}

/// "See changes" diff sheet for Command Mode results.
@MainActor
public final class CommandDiffController {
    public static let shared = CommandDiffController()
    private var panel: NSPanel?
    private init() {}
    public func show(original: String, rewritten: String) {
        let p = panel ?? {
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            w.title = "Changes"; w.isFloatingPanel = true; w.level = .floating; w.isReleasedWhenClosed = false; w.collectionBehavior = [.canJoinAllSpaces]
            panel = w; return w
        }()
        p.contentView = NSHostingView(rootView: DiffView(original: original, rewritten: rewritten, onClose: { [weak p] in p?.orderOut(nil) }))
        p.center(); p.orderFrontRegardless()
    }
}

struct DiffView: View {
    let original: String
    let rewritten: String
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("See changes").font(Fonts.ui(15, weight: .semibold))
            ScrollView { diffText.font(Fonts.ui(13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(HubColors.card))
            HStack {
                Button("Undo") { Task { let t = await FocusTracker.shared.snapshot(); _ = await Inserter.shared.insert(original, into: t); onClose() } }.buttonStyle(SecondaryButtonStyle())
                Button("Copy") { PasteboardSnapshot.writeText(rewritten) }.buttonStyle(SecondaryButtonStyle())
                Button("Retry") { onClose(); Task { try? await Task.sleep(for: .milliseconds(200)); SessionCoordinator.shared.retryCommandMode() } }.buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Accept") { onClose() }.buttonStyle(PrimaryButtonStyle())
            }
        }.padding(16).frame(width: 520, height: 340)
    }
    private var diffText: Text {
        let a = original.split(separator: " ").map(String.init), b = rewritten.split(separator: " ").map(String.init)
        // LCS-based word diff
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty && !b.isEmpty { for i in stride(from: a.count - 1, through: 0, by: -1) { for j in stride(from: b.count - 1, through: 0, by: -1) { dp[i][j] = a[i] == b[j] ? dp[i+1][j+1] + 1 : max(dp[i+1][j], dp[i][j+1]) } } }
        var i = 0, j = 0
        var out = Text("")
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { out = out + Text(a[i] + " "); i += 1; j += 1 }
            else if j < b.count, i >= a.count || dp[i][j+1] >= dp[i+1][j] { out = out + Text(b[j] + " ").foregroundColor(Tokens.deepGreen).bold(); j += 1 }
            else if i < a.count { out = out + Text(a[i] + " ").strikethrough().foregroundColor(Tokens.orange); i += 1 }
        }
        return out
    }
}
