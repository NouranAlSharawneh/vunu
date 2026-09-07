import SwiftUI
import AVFoundation
import ApplicationServices
import AppKit

public enum Permissions {
    public static var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    public static func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
    public static func promptAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
    public static func openAccessibilitySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    public static func openMicrophoneSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
    public static func openKeyboardSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
    /// 0 = do nothing, 1 = change input source, 2 = emoji & symbols, 3 = start dictation
    public static var fnKeyUsage: Int {
        (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int) ?? 2
    }
}

@MainActor
public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = OnboardingWindowController()
    public var onFinished: (() -> Void)?
    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Welcome to Vunu"; w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: OnboardingView(onFinished: { OnboardingWindowController.shared.finish() }))
        w.center()
        super.init(window: w)
        w.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }
    public func show() { NSApp.setActivationPolicy(.regular); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func finish() { Preferences.shared.onboardingCompleted = true; window?.close(); onFinished?() }
    public func windowWillClose(_ notification: Notification) { if !Preferences.shared.showInDock && !HubWindowController.shared.window!.isVisible { NSApp.setActivationPolicy(.accessory) } }
}

struct OnboardingView: View {
    var onFinished: () -> Void
    @State private var step = 0
    @State private var mic = Permissions.microphoneGranted
    @State private var ax = Permissions.accessibilityGranted
    @State private var models = ModelManager.shared
    @State private var prefs = Preferences.shared
    @State private var demoText = ""
    @State private var poll: Task<Void, Never>?
    private let fnIsEmoji = Permissions.fnKeyUsage != 0

    var body: some View {
        VStack(spacing: 0) {
            HStack { ForEach(0..<6) { i in Capsule().fill(i <= step ? Tokens.lilac : HubColors.divider).frame(height: 4) } }.padding(.horizontal, 40).padding(.top, 28)
            Spacer()
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: micTest
                case 3: shortcutStep
                case 4: languagesAndModels
                default: done
                }
            }
            .frame(maxWidth: 560)
            Spacer()
            HStack {
                if step > 0 && step < 5 { Button("Back") { step -= 1 }.buttonStyle(SecondaryButtonStyle()) }
                Spacer()
                if step < 5 { Button("Skip") { step = 5 }.buttonStyle(.plain).foregroundStyle(HubColors.secondaryText) }
                Button(step == 5 ? "Start dictating" : "Continue") { if step == 5 { onFinished() } else { step += 1 } }.buttonStyle(PrimaryButtonStyle())
                    .disabled(step == 1 && !(mic && ax))
            }.padding(28)
        }
        .background(HubColors.background)
        .onAppear { startPolling() }
        .onDisappear { poll?.cancel() }
    }

    private func startPolling() {
        poll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let m = Permissions.microphoneGranted, a = Permissions.accessibilityGranted
                if m != mic { mic = m }
                if a != ax { ax = a; if a { try? SessionCoordinator.shared.startHotkeys() } }
                if m && ax && step == 1 && !(fnIsEmoji) { /* auto-advance */ step = 2 }
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: MenuBarController.glyph(color: Tokens.nsInk)).resizable().frame(width: 64, height: 64).foregroundStyle(HubColors.text)
            Text("Welcome to Vunu").font(Fonts.heading(40)).foregroundStyle(HubColors.text)
            Text("Hold fn, talk, release. Your words land in whatever you're typing in — formatted, on-device, private.").font(Fonts.ui(15)).foregroundStyle(HubColors.secondaryText).multilineTextAlignment(.center)
            TextField("What should we call you?", text: $prefs.userName).textFieldStyle(.roundedBorder).frame(width: 260).font(Fonts.ui(13))
        }
    }

    private var permissions: some View {
        VStack(spacing: 14) {
            Text("Two permissions").font(Fonts.heading(32)).foregroundStyle(HubColors.text)
            permissionCard("Microphone", "To hear you. Audio never leaves this Mac.", granted: mic) {
                Task { mic = await Permissions.requestMicrophone(); if !mic { Permissions.openMicrophoneSettings() } }
            }
            permissionCard("Accessibility", "To watch the fn key and insert text where your cursor is.", granted: ax) {
                Permissions.promptAccessibility(); Permissions.openAccessibilitySettings()
            }
            if fnIsEmoji {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your fn key is set to “\(Permissions.fnKeyUsage == 2 ? "Show Emoji & Symbols" : Permissions.fnKeyUsage == 3 ? "Start Dictation" : "Change Input Source")”").font(Fonts.ui(13, weight: .semibold)).foregroundStyle(HubColors.text)
                        Text("Vunu intercepts fn while it's running, so the emoji picker won't pop up. Nothing in your system settings is changed. If you'd rather set it to “Do Nothing”, open Keyboard settings.").font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText)
                        Button("Open Keyboard settings") { Permissions.openKeyboardSettings() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
    }
    private func permissionCard(_ title: String, _ detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text(title).font(Fonts.ui(14, weight: .semibold)).foregroundStyle(HubColors.text); Text(detail).font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText) }
                Spacer()
                if granted { Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(Tokens.deepGreen).font(Fonts.ui(12, weight: .semibold)) }
                else { Button("Allow", action: action).buttonStyle(PrimaryButtonStyle()) }
            }
        }
    }

    private var micTest: some View {
        VStack(spacing: 14) {
            Text("Say something").font(Fonts.heading(32)).foregroundStyle(HubColors.text)
            Text("The bar should move when you speak.").font(Fonts.ui(13)).foregroundStyle(HubColors.secondaryText)
            LevelBar().frame(width: 320, height: 14)
            MicrophonePicker().frame(maxWidth: 480)
        }
    }

    private var shortcutStep: some View {
        VStack(spacing: 14) {
            Text("Try it yourself").font(Fonts.heading(32)).foregroundStyle(HubColors.text)
            HStack(spacing: 6) { Text("Hold").font(Fonts.ui(13)); KeyChip(text: "fn", active: SessionCoordinator.shared.state.isCapturing); Text("speak, then release.").font(Fonts.ui(13)) }.foregroundStyle(HubColors.secondaryText)
            TextEditor(text: $demoText).font(Fonts.ui(14)).frame(height: 110).padding(8).background(RoundedRectangle(cornerRadius: 12).fill(HubColors.card)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(HubColors.divider))
            Text("Then try: double-tap fn to go hands-free, and press fn+Space (or ■ on the bar) to stop.").font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText)
            if !ax { Text("Accessibility isn't granted yet — the fn key won't work until it is.").font(Fonts.ui(12)).foregroundStyle(Tokens.orange) }
            if !models.loadedEngines.contains(prefs.sttEngine) { Text("The speech model is still loading (\(models.downloadLabel)) — you can continue and it will finish in the background.").font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText) }
        }
        .onAppear { Task { await models.loadSelected() } }
    }

    private var languagesAndModels: some View {
        VStack(spacing: 14) {
            Text("Languages & model").font(Fonts.heading(32)).foregroundStyle(HubColors.text)
            LanguagesPicker().frame(maxWidth: 480)
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(prefs.sttEngine.title).font(Fonts.ui(13, weight: .semibold)).foregroundStyle(HubColors.text)
                    if models.isDownloading { ProgressView(value: models.downloadProgress); Text(models.downloadLabel).font(Fonts.ui(11)).foregroundStyle(HubColors.secondaryText) }
                    else if models.loadedEngines.contains(prefs.sttEngine) { Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(Tokens.deepGreen).font(Fonts.ui(12, weight: .semibold)) }
                    else { Button("Download & load") { Task { await models.loadSelected() } }.buttonStyle(PrimaryButtonStyle()) }
                    if let e = models.lastError { Text(e).font(Fonts.ui(11)).foregroundStyle(Tokens.orange) }
                }
            }.frame(maxWidth: 480)
        }
        .onAppear { if !models.loadedEngines.contains(prefs.sttEngine) && !models.isDownloading { Task { await models.loadSelected() } } }
    }

    private var done: some View {
        VStack(spacing: 12) {
            Text("You're ready to Flow everywhere").font(Fonts.heading(34)).foregroundStyle(HubColors.text)
            Text("Vunu lives in your menu bar. Hold fn in any app to dictate.").font(Fonts.ui(14)).foregroundStyle(HubColors.secondaryText)
        }
    }
}
