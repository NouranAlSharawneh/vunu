import SwiftUI
import ServiceManagement
import AppKit

public enum SettingsSection: String, CaseIterable, Identifiable {
    case general, system, models, vibeCoding, experimental, account
    public var id: String { rawValue }
    var title: String {
        switch self { case .general: "General"; case .system: "System"; case .models: "Models"; case .vibeCoding: "Vibe coding"; case .experimental: "Experimental"; case .account: "Account" }
    }
}

struct SettingsView: View {
    @State private var hub = HubState.shared
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(Fonts.heading(28)).foregroundStyle(HubColors.text).padding(.bottom, 10)
                ForEach([SettingsSection.general, .system, .models, .vibeCoding, .experimental]) { row($0) }
                Text("Account").font(Fonts.ui(11, weight: .semibold)).foregroundStyle(HubColors.secondaryText).padding(.top, 14).padding(.leading, 10)
                row(.account)
                Spacer()
            }
            .padding(24).frame(width: 220)
            Divider().overlay(HubColors.divider)
            ScrollView {
                Group {
                    switch hub.settingsSection {
                    case .general: GeneralSettings()
                    case .system: SystemSettings()
                    case .models: ModelsSettings()
                    case .vibeCoding: VibeCodingSettings()
                    case .experimental: ExperimentalSettings()
                    case .account: AccountSettings()
                    }
                }
                .padding(28).frame(maxWidth: 640, alignment: .leading)
            }
        }
    }
    private func row(_ s: SettingsSection) -> some View {
        Button { hub.settingsSection = s } label: {
            Text(s.title).font(Fonts.ui(13, weight: hub.settingsSection == s ? .semibold : .regular))
                .foregroundStyle(hub.settingsSection == s ? Tokens.ink : HubColors.text)
                .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(hub.settingsSection == s ? Tokens.lilac : .clear))
        }.buttonStyle(.plain)
    }
}

struct SettingRow<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Fonts.ui(13, weight: .medium)).foregroundStyle(HubColors.text)
                if let subtitle { Text(subtitle).font(Fonts.ui(11)).foregroundStyle(HubColors.secondaryText) }
            }
            Spacer()
            content
        }
        .padding(.vertical, 8)
        Divider().overlay(HubColors.divider)
    }
}

// MARK: General

struct GeneralSettings: View {
    @State private var prefs = Preferences.shared
    @State private var hub = HubState.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("General").font(Fonts.ui(18, weight: .semibold)).foregroundStyle(HubColors.text).padding(.bottom, 8)
            SettingRow(title: "Shortcuts", subtitle: "Push to talk: \(prefs.shortcuts[.pushToTalk]?.map(\.display).joined(separator: ", ") ?? "fn")") {
                Button("Change…") { hub.showShortcutsDialog = true }.buttonStyle(SecondaryButtonStyle())
            }
            MicrophonePicker()
            LanguagesPicker()
            SettingRow(title: "Auto Cleanup", subtitle: "How much the on-device model tidies your words. Rules always run.") {
                Picker("", selection: $prefs.cleanupLevel) { ForEach(CleanupLevel.allCases) { Text($0.title).tag($0) } }.frame(width: 130)
            }
            SettingRow(title: "App language", subtitle: "Interface language follows macOS") { Text(Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "English").font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText) }
        }
    }
}

struct MicrophonePicker: View {
    @State private var prefs = Preferences.shared
    @State private var devices: [AudioInputDevice] = []
    @State private var showOthers = false
    @State private var detected: AudioInputDevice?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(title: "Microphone", subtitle: "Built-in mic is recommended. Wireless mics can drop the first words.") {
                Picker("", selection: Binding(get: { prefs.preferredMicrophoneUID ?? "" }, set: { prefs.preferredMicrophoneUID = $0.isEmpty ? nil : $0; SessionCoordinator.shared.applyMicrophonePreference() })) {
                    Text("System default").tag("")
                    ForEach(devices) { d in Text(d.displayName + (d.isBluetooth ? " ⚠︎" : "")).tag(d.uid) }
                }.frame(width: 260)
            }
            HStack(spacing: 10) {
                LevelBar().frame(width: 220, height: 8)
                Toggle("Show other devices", isOn: $showOthers).font(Fonts.ui(11)).toggleStyle(.checkbox).onChange(of: showOthers) { _, _ in reload() }
            }
            if let d = detected {
                HStack {
                    Text("\(d.name) detected").font(Fonts.ui(12)).foregroundStyle(HubColors.text)
                    Button("Switch") { prefs.preferredMicrophoneUID = d.uid; SessionCoordinator.shared.applyMicrophonePreference(); detected = nil }.buttonStyle(PrimaryButtonStyle())
                    Button("Don't switch") { detected = nil }.buttonStyle(SecondaryButtonStyle())
                }
            }
            if let uid = prefs.preferredMicrophoneUID, devices.first(where: { $0.uid == uid })?.isBluetooth == true {
                Label("Using a Bluetooth mic drops it into low-quality mode and can miss the first words.", systemImage: "exclamationmark.triangle").font(Fonts.ui(11)).foregroundStyle(Tokens.orange)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .vunuAudioDevicesChanged)) { _ in
            let before = Set(devices.map(\.uid)); reload()
            if let new = devices.first(where: { !before.contains($0.uid) && $0.uid != prefs.preferredMicrophoneUID }) { detected = new }
        }
    }
    private func reload() { devices = AudioDevices.inputDevices(includeVirtual: showOthers) }
}

extension Notification.Name { static let vunuAudioDevicesChanged = Notification.Name("vunuAudioDevicesChanged") }

struct LevelBar: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let l = CGFloat(SessionCoordinator.shared.audio.level)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(HubColors.divider)
                    Capsule().fill(l > 0.85 ? Tokens.orange : Tokens.deepGreen).frame(width: max(4, g.size.width * l))
                }
            }
        }
        .onAppear { SessionCoordinator.shared.audio.startMonitoring() }
        .onDisappear { SessionCoordinator.shared.audio.stopMonitoring() }
    }
}

struct LanguagesPicker: View {
    @State private var prefs = Preferences.shared
    var body: some View {
        SettingRow(title: "Languages", subtitle: "Pick the languages you dictate in. Detection is per dictation.") {
            VStack(alignment: .trailing, spacing: 6) {
                Toggle("Auto-detect", isOn: $prefs.autoDetectLanguage).toggleStyle(.checkbox).font(Fonts.ui(12)).disabled(prefs.languages.count < 2)
                Menu {
                    ForEach(LanguageCatalog.common, id: \.self) { code in
                        Button {
                            var l = prefs.languages
                            if l.contains(code) { if l.count > 1 { l.removeAll { $0 == code } } } else { l.append(code) }
                            prefs.languages = l
                        } label: { HStack { if prefs.languages.contains(code) { Image(systemName: "checkmark") }; Text(LanguageCatalog.name(code)) } }
                    }
                } label: { Text(prefs.languages.map(LanguageCatalog.name).joined(separator: ", ")).font(Fonts.ui(12)).lineLimit(1) }
                .frame(width: 260)
                if prefs.languages.contains(where: { LanguageCatalog.engines(for: $0) == [.whisperKit] }) {
                    Text("Arabic and some languages need the Whisper engine (Settings → Models).").font(Fonts.ui(11)).foregroundStyle(Tokens.orange)
                }
            }
        }
    }
}

// MARK: System

struct SystemSettings: View {
    @State private var prefs = Preferences.shared
    @State private var confirmReset = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("System").font(Fonts.ui(18, weight: .semibold)).foregroundStyle(HubColors.text).padding(.bottom, 8)
            SettingRow(title: "Launch at login") { Toggle("", isOn: $prefs.launchAtLogin).toggleStyle(.switch).onChange(of: prefs.launchAtLogin) { _, on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { Log.app.error("login item: \(error)") }
            } }
            SettingRow(title: "Show Flow Bar at all times", subtitle: "Off: the bar appears only while dictating (like Wispr)") { Toggle("", isOn: $prefs.showFlowBarAlways).toggleStyle(.switch) }
            SettingRow(title: "Show in Dock") { Toggle("", isOn: $prefs.showInDock).toggleStyle(.switch).onChange(of: prefs.showInDock) { _, on in NSApp.setActivationPolicy(on ? .regular : .accessory) } }
            SettingRow(title: "Sound effects", subtitle: "Start ping and paste tick") { Toggle("", isOn: $prefs.soundEffects).toggleStyle(.switch) }
            SettingRow(title: "Mute music while dictating", subtitle: "Off by default. Mutes the output device and restores the exact volume after.") { Toggle("", isOn: $prefs.muteMusicWhileDictating).toggleStyle(.switch) }
            SettingRow(title: "Hide Flow Bar from screen shares") { Toggle("", isOn: $prefs.hideFlowBarFromScreenShare).toggleStyle(.switch).onChange(of: prefs.hideFlowBarFromScreenShare) { _, _ in FlowBarController.shared.applySharingType() } }
            SettingRow(title: "Hands-free auto-stop", subtitle: "Stop after this much silence (0 = never)") {
                Picker("", selection: $prefs.handsFreeSilenceStopSeconds) { Text("Never").tag(0.0); Text("5 s").tag(5.0); Text("8 s").tag(8.0); Text("15 s").tag(15.0) }.frame(width: 100)
            }
            Text("Notifications").font(Fonts.ui(13, weight: .semibold)).foregroundStyle(HubColors.text).padding(.top, 12)
            ForEach(["Feature explainers", "Microphone warnings", "Paste problems"], id: \.self) { key in
                SettingRow(title: key) { Toggle("", isOn: Binding(get: { prefs.isNotificationEnabled(key) }, set: { prefs.notificationsEnabled[key] = $0 })).toggleStyle(.switch) }
            }
            SettingRow(title: "Reset & restart", subtitle: "Clears settings (history and dictionary are kept)") {
                Button("Reset…") { confirmReset = true }.buttonStyle(DangerButtonStyle())
            }
            SettingRow(title: "Flow Bar position", subtitle: "Drag the bar to move it") { Button("Reset position") { FlowBarController.shared.resetPosition() }.buttonStyle(SecondaryButtonStyle()) }
        }
        .confirmationDialog("Reset all settings and restart Vunu?", isPresented: $confirmReset) {
            Button("Reset & restart", role: .destructive) { prefs.resetAll(); AppController.relaunch() }
        }
    }
}

// MARK: Models

struct ModelsSettings: View {
    @State private var prefs = Preferences.shared
    @State private var models = ModelManager.shared
    @State private var bench: ModelManager.Benchmark?
    @State private var benching = false
    @State private var downloaded: [SttEngineKind: Bool] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Models").font(Fonts.ui(18, weight: .semibold)).foregroundStyle(HubColors.text).padding(.bottom, 8)
            Text("Speech to text").font(Fonts.ui(13, weight: .semibold)).foregroundStyle(HubColors.text)
            ForEach(SttEngineKind.allCases) { kind in
                SettingRow(title: kind.title, subtitle: subtitle(kind)) {
                    HStack(spacing: 8) {
                        if prefs.sttEngine == kind { Text("Active").font(Fonts.ui(11, weight: .semibold)).foregroundStyle(Tokens.deepGreen) }
                        else { Button("Use") { prefs.sttEngine = kind; Task { await models.load(kind) } }.buttonStyle(SecondaryButtonStyle()).disabled(kind == .whisperKit) }
                        if models.loadedEngines.contains(kind) { Button("Unload") { Task { await models.unload(kind) } }.buttonStyle(SecondaryButtonStyle()) }
                        else if downloaded[kind] == true || kind == .appleSpeech { Button("Load") { Task { await models.load(kind) } }.buttonStyle(SecondaryButtonStyle()) }
                        else { Button("Download") { Task { await models.load(kind) } }.buttonStyle(PrimaryButtonStyle()).disabled(kind == .whisperKit) }
                        if downloaded[kind] == true, kind != .appleSpeech { Button { Task { await models.deleteModelFiles(kind); await refresh() } } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(HubColors.secondaryText) }
                    }
                }
            }
            if models.isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: models.downloadProgress).frame(maxWidth: 400)
                    Text(models.downloadLabel).font(Fonts.ui(11)).foregroundStyle(HubColors.secondaryText)
                }.padding(.vertical, 6)
            }
            if let e = models.lastError { Text(e).font(Fonts.ui(11)).foregroundStyle(Tokens.orange) }
            Text("Formatting").font(Fonts.ui(13, weight: .semibold)).foregroundStyle(HubColors.text).padding(.top, 12)
            SettingRow(title: "Formatting model", subtitle: "Apple Intelligence: \(models.fmAvailability)") {
                Picker("", selection: $prefs.formatter) { ForEach(FormatterKind.allCases) { Text($0.title).tag($0) } }.frame(width: 260).onChange(of: prefs.formatter) { _, v in if v == .mlx { prefs.formatter = .appleIntelligence } }
            }
            SettingRow(title: "Keep models loaded in memory", subtitle: "Faster first dictation; ~\(Int(models.residentMemoryMB)) MB resident now") { Toggle("", isOn: $prefs.keepModelsLoaded).toggleStyle(.switch) }
            SettingRow(title: "Benchmark", subtitle: bench.map { "ASR \(Int($0.asrMs)) ms · rules \(String(format: "%.1f", $0.rulesMs)) ms · LLM \(Int($0.llmMs)) ms\($0.llmRejected.map { " (\($0))" } ?? "") for \(String(format: "%.1f", $0.audioSeconds)) s audio" } ?? "Measures ASR + formatting latency on a sample clip") {
                Button(benching ? "Running…" : "Run benchmark") { runBench() }.buttonStyle(SecondaryButtonStyle()).disabled(benching)
            }
            if let b = bench { Text(b.text).font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText).padding(.top, 4) }
            Text("Models are stored in ~/Library/Application Support/Vunu/Models").font(Fonts.ui(11)).foregroundStyle(HubColors.secondaryText).padding(.top, 10)
        }
        .task { await refresh() }
        .onChange(of: models.isDownloading) { _, _ in Task { await refresh() } }
    }
    private func subtitle(_ k: SttEngineKind) -> String {
        switch k {
        case .parakeetV3: "~600 MB · 25 languages · fastest on the Neural Engine"
        case .parakeetV2: "~600 MB · English only, higher recall"
        case .appleSpeech: "Built into macOS · no download · \(prefs.languages.contains("ar") ? "no Arabic" : "many locales")"
        case .whisperKit: "~630 MB · needed for Arabic · coming in the next build"
        }
    }
    private func refresh() async { for k in SttEngineKind.allCases { downloaded[k] = await models.isDownloaded(k) }; models.updateMemory() }
    private func runBench() {
        benching = true
        Task {
            let samples = BenchmarkFixture.samples()
            bench = await models.benchmark(samples: samples, seconds: Double(samples.count) / AudioCapture.sampleRate)
            Log.file("bench", "asr \(Int(bench!.asrMs)) ms · rules \(bench!.rulesMs) ms · llm \(Int(bench!.llmMs)) ms · \(bench!.llmRejected ?? "accepted")")
            benching = false
        }
    }
}

enum BenchmarkFixture {
    /// Uses the newest saved dictation audio if available, otherwise 10 s synthesized with `say`.
    static func samples() -> [Float] {
        if let t = try? Database.shared.transcripts(limit: 20).first(where: { $0.audioPath != nil && $0.durationSec > 3 }), let p = t.audioPath, let s = AudioStore.load(URL(fileURLWithPath: p)) { return s }
        let url = Paths.appSupport.appendingPathComponent("bench.aiff")
        if !FileManager.default.fileExists(atPath: url.path) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-o", url.path, "um so I wanted to check in about the the meeting tomorrow at two, actually three, and see if you could send me the notes at john at gmail dot com period"]
            try? p.run(); p.waitUntilExit()
        }
        return AudioStore.load(url) ?? [Float](repeating: 0, count: 16_000 * 5)
    }
}

// MARK: Vibe coding / Experimental / Account

struct VibeCodingSettings: View {
    @State private var prefs = Preferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Vibe coding").font(Fonts.ui(18, weight: .semibold)).foregroundStyle(HubColors.text).padding(.bottom, 8)
            SettingRow(title: "Developer vocabulary", subtitle: "\(DevVocabulary.terms.count) built-in terms: Supabase, Claude Code, Postgres, Keycloak, Directus, Figma, Next.js, Kubernetes… Your Dictionary always wins.") { Toggle("", isOn: $prefs.devVocabulary).toggleStyle(.switch) }
            Text("Terminals (Terminal, iTerm2, Ghostty, Warp, Kitty, Alacritty) and editors already get the paste path with trailing-newline stripping and chunked paste for long text in Claude Code / Codex.").font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText).padding(.bottom, 8)
            SettingRow(title: "Variable recognition", subtitle: "In terminals and editors, code-looking words (camelCase, snake_case, file names) get backticks; identifiers visible in the editor keep their exact casing") { Toggle("", isOn: $prefs.variableRecognition).toggleStyle(.switch) }
            SettingRow(title: "File tagging", subtitle: "“at main dot py” → @main.py (name only, Claude Code / Cursor resolve the path)") { Toggle("", isOn: $prefs.fileTagging).toggleStyle(.switch) }
            SettingRow(title: "Learn from your edits", subtitle: "If you correct a word right after a dictation, Vunu offers to add it to the Dictionary") { Toggle("", isOn: $prefs.learnFromEdits).toggleStyle(.switch) }
        }
    }
}

struct ExperimentalSettings: View {
    @State private var prefs = Preferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Experimental").font(Fonts.ui(18, weight: .semibold)).foregroundStyle(HubColors.text).padding(.bottom, 8)
            SettingRow(title: "Command Mode", subtitle: "Select text, hold fn+⌃, say the change (\"make this shorter\"). A diff appears with Accept / Undo / Retry") { Toggle("", isOn: $prefs.commandModeEnabled).toggleStyle(.switch) }
            SettingRow(title: "Press Enter command", subtitle: "Say “press enter” at the end to send") { Toggle("", isOn: $prefs.pressEnterCommand).toggleStyle(.switch) }
            SettingRow(title: "Whisper mode", subtitle: "Raise input gain for quiet speech") { Toggle("", isOn: $prefs.whisperMode).toggleStyle(.switch) }
            SettingRow(title: "Live preview", subtitle: "Show Apple Speech's live text under the Flow Bar while you talk (English locales)") { Toggle("", isOn: $prefs.livePreview).toggleStyle(.switch) }
            SettingRow(title: "Bulk import", subtitle: "Dictionary CSV and Snippets JSON import live on their pages") { EmptyView() }
        }
    }
}

struct AccountSettings: View {
    @State private var prefs = Preferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Account").font(Fonts.ui(18, weight: .semibold)).foregroundStyle(HubColors.text).padding(.bottom, 8)
            Text("Local only. No sign-in, no sync, no telemetry.").font(Fonts.ui(12)).foregroundStyle(HubColors.secondaryText).padding(.bottom, 6)
            SettingRow(title: "Name", subtitle: "Used for the welcome message and to keep your name capitalized") { TextField("Your name", text: $prefs.userName).textFieldStyle(.roundedBorder).frame(width: 220) }
            Text("Data & Privacy").font(Fonts.ui(13, weight: .semibold)).foregroundStyle(HubColors.text).padding(.top, 12)
            SettingRow(title: "Context awareness", subtitle: "Read text around the caret to fix spacing and capitalization (never in password fields)") { Toggle("", isOn: $prefs.contextAwareness).toggleStyle(.switch) }
            SettingRow(title: "Audio storage", subtitle: "Recordings enable Play / Retry in History") {
                Picker("", selection: $prefs.audioRetention) { ForEach(AudioRetention.allCases) { Text($0.title).tag($0) } }.frame(width: 220)
            }
            SettingRow(title: "Open data folder") { Button("Show in Finder") { NSWorkspace.shared.open(Paths.appSupport) }.buttonStyle(SecondaryButtonStyle()) }
        }
    }
}
