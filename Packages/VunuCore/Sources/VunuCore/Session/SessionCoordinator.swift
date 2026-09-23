import Foundation
import AppKit
import Observation

/// Orchestrates one dictation at a time: hotkey → capture → VAD → ASR → format → insert → history.
@MainActor @Observable
public final class SessionCoordinator {
    public static let shared = SessionCoordinator()

    // observable UI state
    public private(set) var state: SessionState = .idle
    public private(set) var mode: SessionMode = .pushToTalk
    public private(set) var target: FocusSnapshot?
    public private(set) var recordingStartedAt: Date?
    public private(set) var lastTranscript: Transcript?
    public private(set) var lastTimings = StageTimings()
    public private(set) var previewText = ""
    public var notice: SessionNotice?
    public private(set) var secureInputActive = false
    public private(set) var processingSince: Date?
    public var scratchpadText: String = ""
    public var onScratchpadRequested: (@MainActor () -> Void)?
    public var onCommandModeResult: (@MainActor (String, String) -> Void)?   // (original, rewritten)

    // components
    public let audio = AudioCapture()
    public let hotkeys: HotkeyEngine
    public private(set) var tap: EventTapMonitor?
    private let muter = OutputMuter()
    private var armTimer: Task<Void, Never>?
    private var maxTimer: Task<Void, Never>?
    private var silenceTimer: Task<Void, Never>?
    private var noticeTimer: Task<Void, Never>?
    private var preview: LivePreviewSession?
    private var previewFeeder: Task<Void, Never>?
    private var commandSelection: String?
    private var processingTask: Task<Void, Never>?
    private var handsFreeFromDoubleTap = false
    private var micWarnedThisSession = false
    private var visibleSymbols: [String] = []
    private var editWatcher: Task<Void, Never>?
    private var lastCommandInstruction: String?

    private init() {
        let engine = HotkeyEngine { event in
            Task { @MainActor in SessionCoordinator.shared.handle(event) }
        }
        hotkeys = engine
        hotkeys.setBindings(Preferences.shared.shortcuts)
        let extra = Preferences.shared.extraAppsByCategory
        FocusTracker.extraApps.withLock { $0 = extra }
    }

    // MARK: lifecycle

    public func startHotkeys() throws {
        if tap == nil {
            tap = EventTapMonitor { [hotkeys] event, raw in hotkeys.handle(event, raw) }
        }
        try tap?.start()
    }
    public func restartHotkeys() { try? tap?.restart() }
    public func reloadBindings() { hotkeys.setBindings(Preferences.shared.shortcuts) }

    /// The engine is started on demand (key-down) and released when idle so the mic-in-use indicator only shows while dictating.
    public func warmAudio() {
        audio.onDeviceChanged = { change in Task { @MainActor in SessionCoordinator.shared.deviceChangedMidSession(change) } }
    }

    public func applyMicrophonePreference() {
        audio.selectDevice(uid: Preferences.shared.preferredMicrophoneUID)
    }

    // MARK: hotkey events

    func handle(_ e: HotkeyEvent) {
        switch e {
        case .holdBegan(.pushToTalk): beginPTT()
        case .holdEnded(.pushToTalk): endPTT()
        case .holdAborted(.pushToTalk): if mode == .pushToTalk, state.isCapturing { cancel(silent: true) }
        case .holdBegan(.commandMode): beginCommandMode()
        case .holdEnded(.commandMode): if mode == .commandMode { stopAndProcess() }
        case .holdAborted(.commandMode): if mode == .commandMode { cancel(silent: true) }
        case .holdBegan(.scratchpad): beginScratchpad()
        case .holdEnded(.scratchpad): if mode == .scratchpad, state.isCapturing { stopAndProcess() }
        case .holdAborted(.scratchpad): break
        case .triggered(.handsFree): toggleHandsFree()
        case .triggered(.cancel): cancel(silent: false)
        case .triggered(.pasteLast): Task { await pasteLast() }
        case .triggered(.copyLast): Task { await copyLast() }
        case .triggered(.scratchpad): onScratchpadRequested?()
        case .fnDoubleTap: lockHandsFree()
        case .fnTripleTap: cancel(silent: false)
        case .secureInput(let on): secureInputChanged(on)
        default: break
        }
    }

    private func beginPTT() {
        Preferences.shared.seenFnKeyCount += 1
        guard state == .idle || state == .cancelled || state.isError else {
            if state.isProcessing { stillProcessing() }
            return
        }
        mode = .pushToTalk
        arm()
    }

    private func endPTT() {
        guard mode == .pushToTalk else { return }
        switch state {
        case .armed: cancel(silent: true)               // tap < 250 ms
        case .recording: stopAndProcess()
        default: break
        }
    }

    private func toggleHandsFree() {
        switch state {
        case .idle, .cancelled, .error:
            mode = .handsFree
            arm(immediate: true)
        case .armed, .recording:
            if mode == .handsFree { stopAndProcess() } else { mode = .handsFree; Log.session.info("locked hands-free via toggle") }
        default: stillProcessing()
        }
    }

    private func lockHandsFree() {
        switch state {
        case .armed, .recording:
            mode = .handsFree
            handsFreeFromDoubleTap = true
            if state == .armed { enterRecording() }
            Log.session.info("locked hands-free via double-tap")
        case .idle, .cancelled, .error:
            mode = .handsFree
            arm(immediate: true)
        default: break
        }
    }

    private func beginCommandMode() {
        guard Preferences.shared.commandModeEnabled else { return }
        guard state == .idle || state == .armed || state == .cancelled || state.isError else { return }
        mode = .commandMode
        // read the selection now
        Task {
            let sel = await FocusTracker.shared.perform { () -> String? in
                guard let snap = FocusTracker.shared.snapshotSync(readBrowserURL: false), let el = snap.element?.element, !snap.isSecure else { return nil }
                return AX.string(el, kAXSelectedTextAttribute)
            }
            self.commandSelection = sel
            if sel?.isEmpty ?? true { self.show(SessionNotice(.warning, "Select some text first", detail: "Command Mode edits the selected text")) }
        }
        if state == .armed { enterRecording() } else { arm(immediate: true) }
    }

    private func beginScratchpad() {
        onScratchpadRequested?()
        guard state == .idle || state == .cancelled || state.isError else { return }
        mode = .scratchpad
        arm()
    }

    private func stillProcessing() {
        // Allow a new session if processing finishes within 300 ms.
        Task {
            for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(50)); if !state.isProcessing { break } }
            if state.isProcessing { show(SessionNotice(.info, "Still processing your last dictation", duration: 2)) }
        }
    }

    // MARK: state transitions

    private func arm(immediate: Bool = false) {
        notice = nil
        previewText = ""
        let sw = Stopwatch()
        do { try audio.beginRecording(gain: Preferences.shared.whisperMode ? 2.5 : 1) } catch {
            state = .error("Microphone unavailable")
            show(SessionNotice(.error, "Selected microphone is unavailable", action: .chooseMicrophone))
            return
        }
        state = .armed
        hotkeys.setSessionActive(true)
        Task {
            let snap = await FocusTracker.shared.snapshot()
            if self.state.isCapturing { self.target = snap }
            if let snap, snap.isCodeEditor || snap.isTerminal, Preferences.shared.variableRecognition {
                self.visibleSymbols = await FocusTracker.shared.perform { EditorReader.symbols(snap) }
            } else { self.visibleSymbols = [] }
            // Prewarm the exact LLM session for this app's style so the first token is fast on release.
            if Preferences.shared.formatter == .appleIntelligence, Preferences.shared.cleanupLevel != .none {
                let ctx = self.makeContext(target: snap)
                let req = LLMRequest(text: "", dictionaryWords: ctx.dictionary.map(\.word), userName: ctx.userName, style: ctx.style, language: ctx.language, level: ctx.cleanupLevel)
                await ModelManager.shared.appleFM.prewarm(for: req)
            }
        }
        Log.session.debug("armed in \(sw.elapsedMs) ms")
        armTimer?.cancel()
        if immediate { enterRecording() } else {
            armTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, self.state == .armed else { return }
                self.enterRecording()
            }
        }
    }

    private func enterRecording() {
        guard state == .armed else { return }
        state = .recording
        recordingStartedAt = Date()
        Sounds.shared.playPing()
        if Preferences.shared.muteMusicWhileDictating { muter.muteIfPlaying() }
        startMaxTimer()
        if mode == .handsFree { startSilenceWatch() }
        if Preferences.shared.livePreview { startPreview() }
        Log.file("session", "recording (\(mode.rawValue)) → \(target?.appName ?? "?")")
    }

    private func startMaxTimer() {
        maxTimer?.cancel()
        maxTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(19 * 60))
            guard let self, !Task.isCancelled, self.state == .recording else { return }
            self.show(SessionNotice(.warning, "Less than a minute left", duration: 8))
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, self.state == .recording else { return }
            self.show(SessionNotice(.info, "Transcription session ended", duration: 4))
            self.stopAndProcess(reason: "time limit")
        }
    }

    private func startSilenceWatch() {
        silenceTimer?.cancel()
        let limit = Preferences.shared.handsFreeSilenceStopSeconds
        guard limit > 0 else { return }
        silenceTimer = Task { [weak self] in
            var quietSince: Date? = nil
            var heardSpeech = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.state == .recording, self.mode == .handsFree else { return }
                let lvl = self.audio.level
                if lvl > 0.25 { heardSpeech = true; quietSince = nil }
                else if heardSpeech {
                    if quietSince == nil { quietSince = Date() }
                    else if Date().timeIntervalSince(quietSince!) > limit { self.stopAndProcess(reason: "silence"); return }
                }
            }
        }
    }

    private func startPreview() {
        let p = LivePreviewSession { text in Task { @MainActor in SessionCoordinator.shared.previewText = text } }
        preview = p
        let code = Preferences.shared.languages.first ?? "en"
        let locale = Locale(identifier: code == "en" ? "en-US" : code)
        previewFeeder = Task { [weak self] in
            guard let self else { return }
            // Assets must be installed for the locale; kick off the install once and skip preview this session.
            let installed = await AppleSpeechEngine.installedLocales()
            guard installed.contains(where: { $0.identifier.hasPrefix(String(locale.identifier.prefix(2))) }) else {
                Log.speech.info("preview: installing speech assets for \(locale.identifier)")
                try? await ModelManager.shared.appleSpeech.load { _, _ in }
                return
            }
            do { try await p.start(locale: locale) } catch { Log.speech.error("preview start failed: \(error)"); return }
            var fed = 0
            while !Task.isCancelled, self.state == .recording {
                try? await Task.sleep(for: .milliseconds(300))
                let all = self.audio.snapshotSamples()
                if all.count > fed { await p.feed(Array(all[fed...])); fed = all.count }
            }
        }
    }

    private func stopPreview() {
        previewFeeder?.cancel(); previewFeeder = nil
        if let p = preview { Task { await p.stop() } }
        preview = nil
    }

    public func stopAndProcess(reason: String = "user") {
        guard state == .armed || state == .recording else { return }
        if reason != "user" { Log.file("session", "stopped (\(reason))") }
        armTimer?.cancel(); maxTimer?.cancel(); silenceTimer?.cancel()
        let wasArmed = state == .armed
        state = .stopping
        stopPreview()
        muter.restoreIfNeeded()
        let samples = audio.endRecording()
        let duration = Double(samples.count) / AudioCapture.sampleRate
        let startMode = mode
        let keyUp = Stopwatch()
        if wasArmed || duration < 0.25 { state = .cancelled; finishIdle(); return }
        processingSince = Date()
        processingTask = Task { await process(samples: samples, duration: duration, mode: startMode, keyUp: keyUp) }
    }

    public func cancel(silent: Bool) {
        armTimer?.cancel(); maxTimer?.cancel(); silenceTimer?.cancel()
        stopPreview()
        muter.restoreIfNeeded()
        let wasCapturing = state.isCapturing
        if state.isProcessing { processingTask?.cancel() }
        let samples = wasCapturing ? audio.endRecording() : []
        let duration = Double(samples.count) / AudioCapture.sampleRate
        if wasCapturing, duration > 3, Preferences.shared.audioRetention != .never {
            var t = Transcript(durationSec: duration, appBundleID: target?.bundleID, appName: target?.appName ?? "", status: .cancelled, mode: mode.rawValue)
            t.audioPath = AudioStore.save(samples)?.path
            try? Database.shared.save(t)
        }
        state = .cancelled
        if !silent { Sounds.shared.playError() }
        Log.file("session", "cancelled (\(silent ? "silent" : "user")), \(String(format: "%.1f", duration)) s")
        finishIdle(delay: silent ? 0 : 0.4)
    }

    private func finishIdle(delay: TimeInterval = 0) {
        hotkeys.setSessionActive(false)
        processingSince = nil
        handsFreeFromDoubleTap = false
        commandSelection = nil
        let m = mode
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            // Only a newly started capture may keep the state; everything else settles to idle.
            if !self.state.isCapturing { self.state = .idle; self.target = nil; self.previewText = "" }
            _ = m
            self.audio.releaseIfIdle()
        }
    }

    // MARK: pipeline

    private func process(samples: [Float], duration: Double, mode: SessionMode, keyUp: Stopwatch) async {
        var timings = StageTimings()
        timings.captureMs = duration * 1000
        let prefs = Preferences.shared
        let targetAtKeyDown = target

        // 0. persist audio first (never lose a dictation)
        var record = Transcript(durationSec: duration, appBundleID: targetAtKeyDown?.bundleID, appName: targetAtKeyDown?.appName ?? "", status: .processing, mode: mode.rawValue)
        if prefs.audioRetention != .never { record.audioPath = AudioStore.save(samples)?.path }
        record = (try? Database.shared.save(record)) ?? record

        // 1. VAD trim
        state = .transcribing
        let vadSw = Stopwatch()
        let vad = await ModelManager.shared.vad.trim(samples)
        timings.vadMs = vadSw.elapsedMs
        guard vad.hadSpeech else {
            if duration < 1 { shake() } else { show(SessionNotice(.warning, micWarnedThisSession ? "We couldn't hear you" : "Is your microphone muted?", duration: 3)); micWarnedThisSession = true }
            record.status = .cancelled
            try? Database.shared.save(record)
            finishIdle(); return
        }

        // 2. ASR
        let engine = await ModelManager.shared.bestAvailableEngine()
        let loaded = await engine.isLoaded
        if !loaded {
            show(SessionNotice(.info, "Loading speech model…", detail: "First run downloads ~600 MB. Your dictation will be transcribed as soon as it's ready.", duration: 60))
            await ModelManager.shared.load(prefs.sttEngine)
            if notice?.title == "Loading speech model…" { notice = nil }
        }
        let asrSw = Stopwatch()
        // With one language selected the hint is always sent (Parakeet v3 filters non-matching scripts, e.g. no Cyrillic for English).
        let hint = prefs.languages.count == 1 ? prefs.languages.first : (prefs.autoDetectLanguage ? nil : prefs.languages.first)
        let asr: TranscriptionResult
        do { asr = try await engine.transcribe(vad.samples, languageHint: hint) } catch {
            timings.asrMs = asrSw.elapsedMs
            record.status = .failed; record.errorMessage = error.localizedDescription
            try? Database.shared.save(record)
            state = .error("Transcription failed")
            Sounds.shared.playError()
            Log.file("session", "asr failed: \(error)")
            finishIdle(delay: 1.2); return
        }
        timings.asrMs = asrSw.elapsedMs
        record.rawText = asr.text
        record.language = asr.language
        guard !asr.text.trimmed.isEmpty else {
            shake(); record.status = .cancelled; try? Database.shared.save(record); finishIdle(); return
        }
        if Task.isCancelled { record.status = .cancelled; try? Database.shared.save(record); finishIdle(); return }

        // 3. Command Mode → rewrite selection instead of formatting
        if mode == .commandMode {
            await runCommandMode(instruction: asr.text, record: record, timings: timings)
            return
        }

        // 4. Formatting
        state = .formatting
        let ctx = makeContext(target: targetAtKeyDown)
        let pipeline = FormattingPipeline(llm: prefs.formatter == .appleIntelligence ? ModelManager.shared.appleFM : nil)
        let out = await pipeline.format(asr.text, context: ctx)
        timings.rulesMs = out.rulesMs; timings.llmMs = out.llmMs; timings.llmUsed = out.llmUsed; timings.llmRejected = out.llmRejectReason
        record.formattedText = out.text
        record.aiEditApplied = out.llmUsed
        record.wordCount = TextUtil.wordCount(out.text)

        // 5. Target at release + surrounding text
        state = .inserting
        let ctxSw = Stopwatch()
        var releaseTarget = await FocusTracker.shared.snapshot(readBrowserURL: false) ?? targetAtKeyDown
        // Switched apps mid-dictation (⌘Tab, Space swipe, click): the text belongs where dictation started.
        if mode != .scratchpad, let k = targetAtKeyDown, let r = releaseTarget, r.pid != k.pid {
            if await FocusTracker.shared.refocus(k) {
                Log.file("session", "returned to \(k.appName) from \(r.appName) to insert")
                releaseTarget = k
            } else {
                Log.file("session", "could not return to \(k.appName); inserting into \(r.appName)")
            }
        }
        let finalTarget: FocusSnapshot? = {
            if let r = releaseTarget, let k = targetAtKeyDown, r.pid == k.pid, r.element == nil { return k }
            return releaseTarget
        }()
        var surrounding: SurroundingText? = nil
        if prefs.contextAwareness, let ft = finalTarget { surrounding = await FocusTracker.shared.perform { SurroundingTextReader.read(ft) } }
        let decision = CasingSpacing.decide(text: out.text, context: surrounding, properNouns: ctx.dictionary.map(\.word) + [prefs.userName])
        var textToInsert = out.text
        if decision.lineHasPunctuation == false, finalTarget?.isMessaging == true { textToInsert = MessagingAppPolicy.apply(textToInsert, isMessaging: true, style: ctx.style, lineHasPunctuation: false) }
        textToInsert = CasingSpacing.apply(textToInsert, decision)
        timings.contextMs = ctxSw.elapsedMs
        record.insertedText = textToInsert
        if let t = finalTarget { record.appBundleID = t.bundleID; record.appName = t.appName; target = t }

        // 6. Insert
        let insSw = Stopwatch()
        let pressEnter = out.pressEnter && prefs.pressEnterCommand
        let result: InsertResult
        if mode == .scratchpad {
            scratchpadText += (scratchpadText.isEmpty ? "" : " ") + out.text
            result = .inserted(path: "scratchpad")
        } else {
            result = await Inserter.shared.insert(textToInsert, into: finalTarget, pressEnter: pressEnter)
        }
        timings.insertMs = insSw.elapsedMs
        timings.totalMs = keyUp.elapsedMs
        switch result {
        case .inserted(let path):
            timings.insertPath = path
            record.status = .done
            Sounds.shared.playTick()
            if prefs.learnFromEdits, mode != .scratchpad, let t = finalTarget, !t.isTerminal { startEditWatcher(target: t, inserted: textToInsert, recordID: record.id) }
            if out.pressEnter && !prefs.pressEnterExplained {
                prefs.pressEnterExplained = true
                show(SessionNotice(.info, "\"Press enter\" command", detail: "Say \"press enter\" at the end of a dictation to send it. Turn this off in Settings → Experimental.", action: .enablePressEnter, duration: 8))
            } else if out.llmUsed { explainOnce(raw: asr.text, cleaned: out.text) }
        case .clipboardOnly(let reason):
            timings.insertPath = "clipboard(\(reason))"
            record.status = .done
            show(SessionNotice(.warning, "Click a textbox and use ⌘⌃V to paste", action: .copy(out.text), duration: 6))
        case .blocked(let reason):
            timings.insertPath = "blocked(\(reason))"
            record.status = .done
            await Inserter.shared.copyToClipboard(out.text)
            show(SessionNotice(.warning, "Paste blocked", detail: "Vunu can't paste right now. Text saved to clipboard", action: .copy(out.text), duration: 6))
        }
        record.timingsJSON = (try? JSONEncoder().encode(timings)).flatMap { String(data: $0, encoding: .utf8) }
        record = (try? Database.shared.save(record)) ?? record
        lastTranscript = record
        lastTimings = timings
        Log.file("session", "done → \(finalTarget?.appName ?? "?") [\(finalTarget?.role ?? "no element")] · \(timings.summary) · \"\(out.text.prefix(80))\"")
        Log.session.info("\(timings.summary)")
        state = .idle
        finishIdle()
        AudioStore.collectGarbage(retention: prefs.audioRetention)
        if prefs.keepModelsLoaded { await ModelManager.shared.appleFM.prewarm() }
    }

    private func runCommandMode(instruction: String, record: Transcript, timings: StageTimings) async {
        var rec = record
        rec.rawText = instruction
        let lower = instruction.lowercased()
        if let range = lower.range(of: #"^(?:search|google)(?: google)?(?: for)?\s+"#, options: .regularExpression) {
            let q = String(instruction[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
            if let url = URL(string: "https://www.google.com/search?q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)) { NSWorkspace.shared.open(url) }
            rec.formattedText = "Search: \(q)"; rec.status = .done; try? Database.shared.save(rec)
            state = .idle; finishIdle(); return
        }
        guard let selection = commandSelection, !selection.isEmpty else {
            rec.status = .cancelled; try? Database.shared.save(rec)
            show(SessionNotice(.warning, "No text selected", detail: "Select text, then hold fn+⌃ and describe the change"))
            state = .idle; finishIdle(); return
        }
        state = .formatting
        lastCommandInstruction = instruction
        do {
            let rewritten = try await ModelManager.shared.appleFM.rewrite(selection: selection, instruction: instruction, deadline: .seconds(8))
            let cleaned = FormattingPipeline.stripWrapping(rewritten)
            if cleaned.trimmed == selection.trimmed || cleaned.isEmpty {
                rec.status = .cancelled; try? Database.shared.save(rec)
                show(SessionNotice(.info, "No change", detail: "The model kept the text as it was. Try a more specific instruction."))
                state = .idle; finishIdle(); return
            }
            state = .inserting
            let t = await FocusTracker.shared.snapshot(readBrowserURL: false)
            _ = await Inserter.shared.insert(cleaned, into: t)
            rec.formattedText = cleaned; rec.insertedText = selection; rec.status = .done; rec.aiEditApplied = true
            try? Database.shared.save(rec)
            lastTranscript = rec
            Sounds.shared.playTick()
            onCommandModeResult?(selection, cleaned)
        } catch {
            rec.status = .failed; rec.errorMessage = error.localizedDescription; try? Database.shared.save(rec)
            show(SessionNotice(.error, "Couldn't apply that edit", detail: AppleFMFormatter.reason(for: error)))
        }
        state = .idle
        finishIdle()
    }

    public func makeContext(target: FocusSnapshot?) -> FormatContext {
        let prefs = Preferences.shared
        var ctx = FormatContext()
        ctx.category = target?.category ?? .other
        ctx.isMessaging = target?.isMessaging ?? false
        ctx.style = prefs.stylesByCategory[ctx.category]
        ctx.dictionary = (try? Database.shared.dictionary()) ?? []
        ctx.snippets = ((try? Database.shared.snippets()) ?? []) + SnippetExpander.defaults.filter { !$0.replacement.isEmpty }
        ctx.userName = prefs.userName
        ctx.cleanupLevel = prefs.cleanupLevel
        ctx.formatterKind = prefs.formatter
        ctx.devVocabulary = prefs.devVocabulary
        ctx.isCodeTarget = (target?.isTerminal ?? false) || (target?.isCodeEditor ?? false)
        ctx.visibleSymbols = visibleSymbols
        ctx.vibe.fileTagging = prefs.fileTagging
        ctx.vibe.variableRecognition = prefs.variableRecognition
        ctx.language = Locale.current.localizedString(forLanguageCode: prefs.languages.first ?? "en") ?? "English"
        return ctx
    }

    /// Re-run ASR + formatting on a saved row (Retry / Recover).
    public func retry(_ t: Transcript) {
        guard state == .idle || state.isError || state == .cancelled, let path = t.audioPath, let samples = AudioStore.load(URL(fileURLWithPath: path)) else {
            show(SessionNotice(.warning, "Audio for this dictation is no longer available")); return
        }
        hotkeys.setSessionActive(true)
        target = nil
        processingSince = Date()
        state = .stopping
        var copy = t; copy.status = .processing; try? Database.shared.save(copy)
        processingTask = Task { await process(samples: samples, duration: t.durationSec, mode: .pushToTalk, keyUp: Stopwatch()) }
    }

    // MARK: last transcript helpers

    public func pasteLast() async {
        guard let t = lastTranscript ?? (try? Database.shared.latestTranscript()) else { return }
        await Inserter.shared.pasteLast(t.displayText)
    }
    public func copyLast() async {
        guard let t = lastTranscript ?? (try? Database.shared.latestTranscript()) else { return }
        await Inserter.shared.copyToClipboard(t.displayText)
        show(SessionNotice(.success, "Copied", duration: 1.5))
    }

    // MARK: notices

    public func show(_ n: SessionNotice) {
        notice = n
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(n.duration))
            guard !Task.isCancelled else { return }
            if self?.notice?.id == n.id { self?.notice = nil }
        }
    }

    private func shake() {
        state = .error("no audio")
        Task { try? await Task.sleep(for: .milliseconds(350)); if case .error = self.state { self.state = .idle } }
        finishIdle(delay: 0.35)
    }

    private func explainOnce(raw: String, cleaned: String) {
        let prefs = Preferences.shared
        let rawWords = TextUtil.tokens(raw), cleanWords = TextUtil.tokens(cleaned)
        if cleaned.contains("\n1.") || cleaned.hasPrefix("1.") || cleaned.contains("\n- ") {
            if !prefs.explainersShown.contains("list") { prefs.explainersShown.insert("list"); show(SessionNotice(.success, "Turned that into a list", detail: "Vunu formats spoken lists automatically", duration: 5)) }
        } else if rawWords.count - cleanWords.count >= 2 {
            if !prefs.explainersShown.contains("repetition") { prefs.explainersShown.insert("repetition"); show(SessionNotice(.success, "We removed a repetition", detail: "Fillers and false starts are cleaned up for you", duration: 5)) }
        }
    }

    private func secureInputChanged(_ on: Bool) {
        secureInputActive = on
        if on, !Preferences.shared.secureInputBannerShown {
            Preferences.shared.secureInputBannerShown = true
            show(SessionNotice(.warning, "Shortcuts limited", detail: "Another app holds Secure Keyboard Entry. Hold-to-talk keeps working; Esc and fn+Space may not.", duration: 8))
        }
    }

    private func deviceChangedMidSession(_ change: AudioCapture.DeviceChange) {
        guard state.isCapturing else { return }
        // A format/route change on the same mic (e.g. Bluetooth profile switch, audio starting elsewhere) is not a disconnect:
        // the engine has already restarted and keeps appending to the same recording.
        guard change == .deviceLost else { return }
        let sofar = audio.snapshotSamples()
        show(SessionNotice(.warning, "Microphone disconnected", action: sofar.count > 8000 ? .insert("") : .none, duration: 8))
        if sofar.count > 8000 { stopAndProcess(reason: "microphone lost") } else { cancel(silent: true) }
    }

    #if DEBUG
    /// Test/preview hook: force a state + target for offscreen rendering.
    public func debugSet(state: SessionState, mode: SessionMode = .pushToTalk, target: FocusSnapshot? = nil) { self.state = state; self.mode = mode; self.target = target }
    #endif

    /// Command Mode "Retry": re-run the last instruction on the current selection.
    public func retryCommandMode() {
        guard let instruction = lastCommandInstruction, state == .idle else { return }
        Task {
            let sel = await FocusTracker.shared.perform { () -> String? in
                guard let snap = FocusTracker.shared.snapshotSync(readBrowserURL: false), let el = snap.element?.element, !snap.isSecure else { return nil }
                return AX.string(el, kAXSelectedTextAttribute)
            }
            guard let sel, !sel.isEmpty else { show(SessionNotice(.warning, "Select the text first, then Retry")); return }
            commandSelection = sel
            hotkeys.setSessionActive(true)
            processingSince = Date()
            var rec = Transcript(appName: "Command Mode", status: .processing, mode: SessionMode.commandMode.rawValue)
            rec = (try? Database.shared.save(rec)) ?? rec
            await runCommandMode(instruction: instruction, record: rec, timings: StageTimings())
        }
    }

    /// Learn from edits: for 60 s after an insertion, watch the target text; a single changed word is offered for the Dictionary.
    private func startEditWatcher(target: FocusSnapshot, inserted: String, recordID: Int64?) {
        editWatcher?.cancel()
        let insertedTrim = inserted.trimmed
        guard TextUtil.wordCount(insertedTrim) >= 1, insertedTrim.count <= 2_000 else { return }
        editWatcher = Task { [weak self] in
            var offered = Set<String>()
            for delay in [15, 30, 60] {
                try? await Task.sleep(for: .seconds(delay - (delay == 15 ? 0 : delay == 30 ? 15 : 30)))
                guard let self, !Task.isCancelled, !self.state.isActive else { return }
                guard let value = await FocusTracker.shared.perform({ EditorReader.value(target, maxLength: 60_000) }) else { continue }
                if value.contains(insertedTrim) { continue }   // untouched
                guard let (wrong, right) = EditWatcher.singleWordCorrection(original: insertedTrim, current: value) else { continue }
                let key = wrong.lowercased() + "→" + right
                guard !offered.contains(key) else { continue }
                offered.insert(key)
                if let id = recordID, var t = try? Database.shared.transcript(id: id) { t.editedText = insertedTrim.replacingOccurrences(of: wrong, with: right); try? Database.shared.save(t) }
                await MainActor.run {
                    self.show(SessionNotice(.info, "Add “\(right)” to your Dictionary?", detail: "You changed “\(wrong)” to “\(right)”. Vunu will use it from now on.", action: .addToDictionary(word: right, misspelling: wrong), duration: 12))
                }
                return
            }
        }
    }

    /// Whether processing has taken > 1.5 s (Flow Bar "Taking longer than usual").
    public var takingLonger: Bool { processingSince.map { Date().timeIntervalSince($0) > 1.5 } ?? false }
}
