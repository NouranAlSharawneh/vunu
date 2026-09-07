# BUILD PROMPT — "Vunu": a native, local-only Wispr Flow clone for macOS

> You are a senior macOS engineer. Build **Vunu**, a push-to-talk voice dictation app for macOS that behaves like Wispr Flow (wisprflow.ai) but runs **100% on-device** (no accounts, no network calls, free models only), is **native Swift/SwiftUI/AppKit** (not Electron), and is **fast** on a fanless MacBook Air. Everything below is researched from Wispr Flow's official help center, changelog, a forensic teardown of its bundle, open-source clones, and Apple's current APIs. Follow it exactly unless a rule below is technically impossible on the target machine, in which case implement the stated fallback and log why.
>
> Rename freely: the app name is a placeholder the owner picked to rhyme with their nickname "Nunu". Bundle ID `dev.nunu.vunu`.

---

## 0. Non-negotiables (read these twice)

1. **Hold `fn` to talk, release to insert.** Default push-to-talk key is the Apple **fn/Globe** key alone, exactly like Wispr Flow. Double-tap `fn` locks hands-free. `fn+Space` toggles hands-free. `Esc` cancels. `⌘⌃V` pastes last transcript. All rebindable.
2. **Recording survives app switching.** If the user holds `fn`, ⌘-Tabs to another app, keeps talking, and releases, the recording never pauses and the text is inserted into whatever text field is focused **at release time**. The hotkey monitor and audio capture are global and independent of which app is frontmost.
3. **Music never stops or ducks.** Recording must not pause, mute, or lower Spotify/Apple Music/YouTube. No `setVoiceProcessingEnabled(true)` on the input node (it ducks system audio on macOS). If voice processing is ever enabled, it must set `AUVoiceIOOtherAudioDuckingConfiguration` with `enableAdvancedDucking = false` and `duckingLevel = .min`. Ship an optional, **off-by-default** "Mute music while dictating" setting that mimics Wispr's behavior (mute the default output device, restore exact previous volume).
4. **Target-app awareness in the UI.** While recording, the **menu bar status item** and the **Flow Bar** swap their idle glyph for the **icon of the app that will receive the text** (e.g. Terminal/Ghostty icon when dictating into Claude Code, Slack icon in Slack). This is the owner's explicit request. Use `NSWorkspace.shared.frontmostApplication.icon`, updated on `NSWorkspace.didActivateApplicationNotification`.
5. **Latency budget:** ≤ 600 ms from key-release to text appearing for a 10-second utterance on the target machine; ≤ 1.2 s for 30 seconds of speech. Idle CPU < 1 %, idle RAM < 250 MB with models unloaded, < 900 MB with STT + LLM resident. Wispr Flow idles at ~800 MB / 8 % CPU (Electron); beat that by a wide margin.
6. **No cloud, no login, no telemetry.** All models are downloaded once from Hugging Face / Apple asset servers and cached under `~/Library/Application Support/Vunu/Models`.
7. **Never lose a dictation.** Every recording is saved to disk before transcription; if insertion fails the text stays on the clipboard and in History with a Retry button.

---

## 1. Target machine and toolchain (verified)

| Item | Value |
|---|---|
| Machine | MacBook Air, Apple **M4** (4P + 6E CPU, 10-core GPU, 16-core Neural Engine), **16 GB** unified memory, fanless |
| OS | **macOS 26.3 Tahoe** (build 25D125) |
| Xcode | **26.2**, Swift **6.2.3**, strict concurrency on |
| Tools present | Homebrew, Python 3.14, ffmpeg, **Ollama** (with `llama3.2:3b`, `qwen3:8b` already pulled — optional dev-time fallback only; do **not** make the shipped app depend on Ollama) |
| fn key system setting | Currently "Show Emoji & Symbols" (`AppleFnUsageType = 2`). The app must handle this (see §5.1). |
| Distribution | Personal use. Developer ID signing if available, otherwise a **stable self-signed certificate** so TCC permissions survive rebuilds. Not sandboxed (event taps + AX require it). Not App Store. |

Minimum deployment target: **macOS 26.0** (this unlocks Apple's on-device `SpeechAnalyzer` and `FoundationModels`; do not waste time supporting older macOS).

---

## 2. Product specification (behavioral parity with Wispr Flow)

Everything in this section is what Wispr Flow does today on macOS, verified from docs.wisprflow.ai. Replicate the behavior; the internals are yours.

### 2.1 Shortcuts (defaults, all rebindable, up to 4 bindings per action, ≤ 3 keys each)

| Action | Default | Behavior |
|---|---|---|
| Push to talk | `fn` (hold) | Record while held; release → transcribe → insert. If the Mac has no Apple fn key (external keyboard), fall back to `⌃⌥`. Mouse buttons (middle, Mouse 4–10) are also bindable, alone or with modifiers. |
| Hands-free | `fn+Space` | Toggle. Press → ping → record until pressed again (or ■ on the bar). |
| Lock hands-free from PTT | double-tap `fn` within 350 ms | Works from idle *and* mid-hold. |
| Command Mode | `fn+⌃` (hold) | Speak an instruction about the **selected text** ("make this more concise", "turn into bullets"); release → replaced in place. Double-press locks, triple-press dismisses. |
| Cancel | `Esc` | Immediately discard; nothing transcribed, clipboard untouched. Works while other modifiers are held. |
| Paste last transcript | `⌘⌃V` | Re-pastes the most recent result. |
| Copy last transcript | `⌘⌃C` | Copies without pasting. |
| Open Scratchpad | `⌥S` | Floating mini editor near the cursor with a Copy button; hold `⌥S` to dictate into it. |

Shortcut rules to enforce in the recorder UI: must include a modifier or mouse button (except `Esc` for Cancel); can't mix left/right variants of the same modifier; Caps Lock not allowed; reject ~60 reserved macOS combos (⌘C/V/X/Z/A/Q/W/Space/Tab, ⌘⇧3/4/5, fn+F11/F12, ⌃A/E/K, etc.) with toast "This shortcut is not allowed: …"; "This shortcut is already in use"; "Shortcut must contain 3 or fewer keys". Show ⌃ ⌘ ⌥ ⇧ glyphs; "→" marks right-hand variants; display keys in fixed order fn, ⌃, ⌘, ⌥, ⇧, then other keys.

Edge rules:
- A **tap shorter than 250 ms with no speech** is treated as an accidental press: no recording, no notification. Wispr shows "no audio detected" notices; we stay silent for < 250 ms and show a subtle bar shake for 250 ms–1 s of silence.
- If `fn` is held and **another key is pressed** (fn+arrow, fn+F-key, fn+Delete), abort the PTT session immediately (< 1 s in) and pass the key through, so system fn shortcuts keep working. If speech has already been captured for > 1 s, keep recording and swallow nothing else.
- **Secure Keyboard Entry** (Terminal's "Secure Keyboard Entry", 1Password, password fields): macOS still delivers modifier-flag changes but blocks regular keys. So `fn` hold-to-talk must keep working while `Esc`/`fn+Space` may not. Detect with `IsSecureEventInputEnabled()` and show a one-time banner "Shortcuts limited: another app holds Secure Keyboard Entry."
- While a previous transcript is still processing, a new press shows "Still processing your last dictation" (no queueing), unless processing finishes within 300 ms, in which case start normally.
- Max session 20 min; warn at 19 min; auto-stop and insert at 20.

### 2.2 Session state machine

`idle → armed (key down, < 250 ms) → recording → stopping → transcribing → formatting → inserting → idle`, plus `cancelled` and `error`. Every state has a Flow Bar look (§3) and a menu bar look. Emit start "ping" on entering `recording` and a soft "paste" tick on successful insertion (Settings → System → Sound toggles; both **on** by default, played through `NSSound` at low volume without touching other apps' audio).

### 2.3 Text insertion rules (the "paste engine")

Wispr inserts via the clipboard and so will we, with an AX fast-path:

1. Resolve the target: `AXUIElementCreateSystemWide()` → `kAXFocusedUIElementAttribute`. Remember the element **at key-down** and re-check **at release**; if focus moved to a different app, insert into the element focused at release (this is Wispr's documented behavior: "pastes into whichever app is focused when transcription finishes").
2. **Context read (≤ 30 ms budget, else skip):** read `kAXValueAttribute` + `kAXSelectedTextRangeAttribute` to get up to 200 chars before and 50 after the caret. Use it to decide: leading space (if previous char is not whitespace/open-bracket/start), trailing space (if next char is a letter), first-letter case (lowercase when continuing mid-sentence; keep caps for proper nouns matching the dictionary or the user's name), and whether to drop a trailing period in messaging apps.
3. **Insert:** 
   - Path A (preferred when the element supports it): set `kAXSelectedTextAttribute` to the new text — inserts at caret, no clipboard touch. Verify by re-reading value length; if unchanged within 50 ms, fall back.
   - Path B (universal): save pasteboard (all types except file URLs/RTFD/PDF/audio, which are not restored — same as Wispr), write plain text with `org.nspasteboard.ConcealedType` + `org.nspasteboard.TransientType` marker types (so clipboard managers skip it), post ⌘V via `CGEvent` from a `CGEventSource(stateID: .combinedSessionState)` to `.cghidEventTap`, wait for `NSPasteboard.changeCount`/200 ms, then **restore** the previous pasteboard. If the app is a terminal (Terminal, iTerm2, Ghostty, Warp, Kitty, Alacritty, VS Code/Cursor integrated terminal) strip the trailing newline; if the text is > 1,500 chars and the target is a TUI (Claude Code, Codex CLI) paste in **chunks** of ~800 chars with 60 ms gaps (Wispr does this for Claude Code).
   - Path C: if no focused text element (role not in AXTextField/AXTextArea/AXComboBox/AXWebArea/AXStaticText-editable, or AX unavailable), copy to clipboard and show the notification **"Click a textbox and use ⌘⌃V to paste"** with Copy button. Text remains on clipboard; previous clipboard is *not* restored (Wispr behavior).
4. Spoken **"press enter"** at the very end of a dictation → strip phrase, insert, then send Return (Settings → Experimental "Press Enter command", first detection shows an explainer with Enable/Disable).
5. Never insert into secure fields (`AXSecureTextField` / `kAXSubrole == AXSecureTextField`), and never read their contents for context.

### 2.4 Formatting pipeline ("Smart Formatting" + "Backtrack" + Styles)

Order of operations after ASR returns raw text:

1. **Dictionary replacements** (user "Correct a misspelling" rules, case-insensitive whole-word).
2. **Snippet expansion**: trigger phrase (≤ 60 chars) → expansion (≤ 4,000 chars); case-insensitive whole-word, no surrounding punctuation unless the whole dictation is the trigger.
3. **Rule-based pass (always, < 5 ms):** spoken punctuation ("period"/"full stop", "comma", "question mark", "exclamation point", "colon", "semicolon", "new line"/"next line"/"line break", "new paragraph", "open/close paren", "quote", "dash"/"em dash", "hashtag", "at sign", "underscore", "slash", "percent sign", "ellipsis", "degree sign", "plus"/"minus"/"equals" when clearly dictated as symbols); numbers ("seven" → "7" in times/dates/quantities); emails and URLs ("john at gmail dot com" → john@gmail.com, "wispr dot ai" → wispr.ai); filler removal ("um", "uh", "er", "hmm", "you know", "like" only when disfluent, "sort of/kind of" only when disfluent); stutter/duplicate removal ("the the" → "the"); sentence-initial capitalization; terminal punctuation.
4. **LLM pass (Auto Cleanup level None/Light/Medium/High, default Medium; skipped when raw text < 4 words or level None):** filler + false-start removal, **Backtrack** self-corrections ("coffee at 2 actually 3" → "coffee at 3"; triggers "actually", "scratch that", "never mind", "wait", "no", "I mean", or a natural restatement), paragraphing, spoken lists ("one… two…", "first… second…" → numbered list), apply the **Style** for the current app category, keep meaning and words otherwise. **Hard rule: the LLM must never answer, summarize, or continue the text; it only edits.** Output plain text only. If the LLM output differs from input by > 40 % of tokens or takes > 900 ms, discard it and use the rule-based result (log "cleanup rejected").
5. **Context-aware casing/spacing** (§2.3.2), then **messaging-app trailing-period rule**: in Messages, WhatsApp, Slack, Discord, Telegram, Signal, Teams, and web versions of Messenger/Instagram/X/Reddit, remove the trailing period when the dictation is ≤ 2 sentences and the line has no existing ./!/?. Casual style: remove up to ~10 sentences outside messaging apps; Very Casual: always remove; Formal/Excited/no style: keep. Never remove ! or ?.
6. Store `rawText`, `formattedText`, and `editedText` (if user edits within 60 s, capture via AX diff) in History; History row menu offers **Undo AI edit / Redo AI edit**.

**Styles** (Style page; per app category; English only; none pre-selected until the user picks): categories **Personal messages** (WhatsApp, Telegram, Discord, Instagram, Signal, Messages), **Work messages** (Slack, Teams, LinkedIn), **Email** (Gmail, Superhuman, Outlook, Apple Mail), **Other** (everything else). Options: **Formal** (caps + punctuation), **Casual** (caps + less punctuation), **Very Casual** (Personal only; no caps + less punctuation), **Excited!** (Work/Email/Other; more exclamations). Detect web apps by the browser's URL (read `AXDocument`/`AXURL` of the focused window in Safari/Chrome/Arc/Brave/Edge/Firefox/Zen). Users can assign extra apps to a category.

**Language:** default auto-detect among the user's selected languages (Settings → General → Languages; multi-select of the engine's supported set); detection is per session, not per word. Flow Bar shows a language picker on hover when ≥ 2 languages are selected. Arabic + English is a must-have pairing for the owner.

**Command Mode:** hold `fn+⌃`, read the selected text via AX, speak an instruction, release → LLM rewrites **only** the selection, replace via the paste engine, show a "See changes" pill on the Flow Bar that opens an inline diff (additions highlighted, removals struck through) with Accept / Undo / Copy / Retry. Also supports spoken "search Google for …" (opens default browser).

### 2.5 Dictionary and Snippets

- **Dictionary** page: Add new (word ≤ 60 chars), optional **Correct a misspelling** toggle (one wrong spelling → this word; one rule per word), **star** for priority, search (⌘F, `/`), sort Starred first / Newest / Oldest / A–Z, bulk select (⌘-click, ⇧-click) → delete, CSV import (1 col words or 2 col misspelling,correction; skip dupes; preview count). Dictionary words are also injected into the ASR as a bias/prompt list (see §4.2) and into the LLM prompt as "preserve these spellings".
- **Snippets** page: Add new → **Snippet** (trigger, ≤ 60) + **Expansion** (≤ 4,000), ⌘↩ saves; edit (pencil), delete (confirm shows trigger + expansion), search, sort Newest/Oldest/A–Z, JSON import `[{"phrase":"…","replacement":"…"}]` (≤ 3 MB, ≤ 1,000 items). Ship default snippets "my email address" (blank until set) and "organize thoughts prompt".

### 2.6 History and stats (Home page)

- Header: "Welcome back, {name}" (or the current PTT shortcut for new users), total words, streak, average WPM, "You speak Nx faster than you type" (baseline 45 WPM), search field.
- Transcript list grouped **Today / Yesterday / {date}**; each row: target app icon + name, time, formatted text (raw text on expand), hover actions Copy, Play audio (kept 14 days), Retry (re-run ASR+LLM from saved audio), Undo AI edit, Flag, Delete (confirm; permanent). `⌘[` / `⌘]` navigate.
- Cancelled sessions longer than 3 s are kept as audio-only rows. Failed transcriptions show a **Retry** button. If the app quits mid-dictation, next launch shows "Recover" on that row.
- Storage: SQLite via GRDB (`~/Library/Application Support/Vunu/vunu.sqlite`), audio as 16 kHz mono **Opus or FLAC** files, auto-deleted after 14 days (setting: Store locally / Auto-delete after 24 h / Never store).

### 2.7 Settings (Settings window, two sections)

**Settings**
- **General:** Shortcuts (dialog with per-action rows, "+ Add another", Reset to default), Microphone (ranked picker; "Built-in mic (recommended)"; live level bar; AirPods flagged ⚠ "wireless mics can drop the first words"; "Show other devices" for virtual devices; prompt "{device} detected — Switch / Don't switch"), Languages (multi-select + Auto-detect), App language.
- **System:** Launch at login (`SMAppService`), Show Flow Bar at all times (off by default, like Wispr), Show in Dock, Sound effects, **Mute music while dictating (off)**, Hide Flow Bar from screen shares (`NSWindow.sharingType = .none`), Notification categories, Reset & restart.
- **Models:** STT engine picker + download/progress/size, Formatting model picker (Apple Intelligence / local MLX model / Rules only), "Keep models loaded in memory" (on), benchmark button that reports measured latency.
- **Vibe coding:** Variable recognition (reads visible symbols from VS Code/Cursor/Windsurf via AX when Screen Reader Optimized mode is on; wraps recognized identifiers in backticks), File tagging ("at main.py" → `@main.py` in Cursor/Windsurf chat).
- **Experimental:** Command Mode, Press Enter command, Whisper mode (raise input gain + tighter VAD), Bulk import.

**Account** (local only): Name (used for proper-noun casing), Data & Privacy (Context awareness on/off; Local storage policy).

### 2.8 Onboarding (first launch, ≤ 5 steps, skippable)

1. Welcome → 2. Permissions cards: **Microphone** (Allow → system prompt), **Accessibility** (Allow → `AXIsProcessTrustedWithOptions` prompt + deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`); each card auto-advances when granted (poll every 500 ms). If the fn key is set to Emoji/Dictation in System Settings, show a card explaining that Vunu will intercept fn while running and offering a button that opens Keyboard settings (do **not** silently change the user's setting). → 3. Microphone test (level bars) → 4. Shortcut setup (shows fn default; "Try it yourself" demo text field: hold, speak, release; a second demo for double-tap hands-free) → 5. Languages + model download with progress → Done ("You're ready to Flow everywhere").

### 2.9 Menu bar item

Template glyph: a 4-bar waveform (like Wispr's ⫶-style bars) in idle; while `recording` swap to the **target app's icon** (16 pt, rounded) with a tiny red dot; `transcribing/formatting` shows the app icon with a spinning ring; `error` shows the glyph with an exclamation badge. Menu: Open Vunu, Paste last transcript, Copy last transcript, Shortcuts…, Microphone ▸, Languages ▸, Show/Hide Flow Bar, Settings…, Help, Quit. `LSUIElement = YES`; the main window opens via `NSApp.setActivationPolicy(.regular)` when shown and returns to `.accessory` when closed unless "Show in Dock" is on.

### 2.10 Notifications and error copy (verbatim where Wispr has copy)

- "Click a textbox and use ⌘⌃V to paste" (no text field)
- "Paste blocked" / "Flow can't paste right now. Text saved to clipboard"
- "Still processing your last dictation"
- "Is your microphone muted?" → "We couldn't hear you" → "Microphone is not working"
- "Microphone disconnected" (with **Insert** button for text captured so far)
- "Selected microphone is unavailable — Choose microphone"
- "Less than a minute left" (19 min) / "Transcription session ended — Recover text"
- "Taking longer than usual" (banner on the Flow Bar while transcribing > 1.5 s)
- First-time feature explainers ("We removed a repetition", "Turned that into a list") shown once, then a small confirmation; mutable under Notifications.

---

## 3. Visual specification (measured from Wispr Flow's own assets)

### 3.1 Design tokens

| Token | Value | Where |
|---|---|---|
| `ink` | `#1A1A1A` | Flow Bar fill, primary text |
| `cream` | `#FFFFEB` | App/Hub background (light), waveform bars on the Flow Bar |
| `creamMuted` | `#E4E4D0` | Secondary surfaces, dividers |
| `offWhite` | `#FCFCFB` | Buttons on dark, cards |
| `lilac` | `#F0D7FF` | Primary accent (CTA buttons, selected states, shortcut key chips turn this color when pressed correctly) |
| `deepGreen` | `#034F46` | Secondary accent (stats card, success) |
| `orange` | `#FFA946` | Highlight (filler words in demos, warnings) |
| `grey` | `#9D9C98` / `#71716E` | Secondary text / cancel button fill |
| `barBorder` | `#4D4A42` | 1 px hairline around the Flow Bar |
| Fonts | **Figtree** (UI, 13–15 pt) and **EB Garamond** (large headings only, e.g. "Welcome back") | Bundle both (OFL). Fallback: SF Pro / New York. |
| Radius | Pill = full; cards 16 pt; buttons 10 pt | |
| Dark mode | Hub follows system appearance: dark background `#141414`, text `#FFFFEB`, keep lilac accent. The Flow Bar is always dark. | |

### 3.2 Flow Bar (the floating pill) — exact geometry from Wispr's SVG, scaled ×1.25 for Retina legibility

- **Idle (only when "Show Flow Bar at all times"):** 120 × 35 pt pill, fill `ink` at 92 % opacity with `NSVisualEffectView` (.hudWindow, behind-window blending) so it looks translucent-black; 1 px `barBorder` stroke; **10 tiny dots** (2.8 pt squares, 2.8 pt radius, 5.3 pt pitch) in `cream` centered = flat waveform. No buttons. Hovering shows tooltip "Hold fn to dictate · Mic in use: {device}". Clicking starts a hands-free session. Right-click → menu (Hide for 1 hour, Settings, Microphone ▸, Languages ▸, Transcript history, Paste last transcript).
- **Recording:** widens with a 180 ms spring to 120 × 35 pt containing: left **cancel** button (22 pt circle, fill `#71716E`, white ✕ 1.5 pt stroke), center **waveform** of 10 bars (2.8 pt wide, pitch 5.3 pt, min height 2.8 pt, max 18 pt, `cream`, rounded caps) driven by the mic RMS at 60 fps with per-bar smoothing (attack 30 ms, release 120 ms, slight per-bar phase offset so it "flows" left→right), right **confirm/stop** button (22 pt circle, fill `offWhite`, dark ✓ in push-to-talk, ■ in hands-free). The **target app's icon** (18 pt) appears at the far left of the pill, before the cancel button, whenever a target app is known. The center of the pill is **not** clickable during recording (Wispr does this to prevent accidental stops).
- **Processing (transcribing/formatting):** buttons fade out, waveform bars morph into a 3-dot "breathing" loader; if > 1.5 s show a banner above the pill: "Taking longer than usual".
- **Success:** bars flash `deepGreen` once (120 ms) as the paste sound plays, then the pill returns to idle or fades out (200 ms) if not always-shown.
- **Error:** pill shakes ±4 pt (3 cycles, 250 ms) and shows an inline label in `orange`.
- **Position:** bottom-center of the screen that contains the **focused window** (fall back to `NSScreen.main`), 24 pt above the bottom edge, above the Dock (use `visibleFrame`). **Draggable**; when dragged, three pill-shaped drop zones appear inset from the bottom, left, and right edges; dropping on a side edge docks it vertically (rotated layout). Position persists. `Esc` cancels a drag.
- **Window:** `NSPanel` with `[.nonactivatingPanel, .borderless, .fullSizeContentView]`, `level = .statusBar + 1`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `isFloatingPanel = true`, `hidesOnDeactivate = false`, `backgroundColor = .clear`, `isOpaque = false`, `hasShadow = true`, `ignoresMouseEvents` toggled so that only the pill's opaque area takes clicks (transparent margins pass clicks through), `sharingType = .none` when "Hide from screen shares" is on. Content is SwiftUI in an `NSHostingView`. It must appear over full-screen apps and on every Space without stealing focus from the app being dictated into.

### 3.3 Menu bar item

- 18 × 18 pt template image: four vertical bars (heights 6, 12, 18, 9 pt, 2.5 pt wide, rounded) — Wispr's logo mark. 
- Recording: replace with the target app's icon (16 pt, 4 pt corner radius) plus a 5 pt red dot at bottom-right; if the target is unknown, show the bars in red. Pulse the dot at 1 Hz.
- Processing: app icon + a thin circular progress ring (indeterminate, 1.5 pt).
- Menu contents in §2.9.

### 3.4 Hub window (main app)

- Size 1040 × 700 pt default, min 860 × 560. Left sidebar 220 pt on `creamMuted` (dark: `#1C1C1C`): rows **Home, Dictionary, Snippets, Style, Scratchpad, History**(if you split it out; Wispr keeps history on Home) and at the bottom **Settings, Help**. Selected row: `lilac` pill background, `ink` text.
- **Home:** hero card with EB Garamond "Welcome back, {name}" (or "Hold fn to dictate" chip for new users), three stat tiles (Total words, Avg WPM, Streak 🔥N) in `deepGreen` with `cream` numerals in EB Garamond; a search field; then the grouped transcript list (rows 64 pt, app icon 24 pt, time in `grey`, text truncated to 2 lines, expands on click; hover reveals Copy / Play / Retry / ⋯).
- **Dictionary / Snippets:** toolbar with search (⌘F), sort menu, Import, "+ Add new" (lilac). List rows with star (Dictionary), pencil, trash. Add dialog = sheet with text fields and the "Correct a misspelling" toggle revealing a second field.
- **Style:** segmented tabs Personal messages / Work messages / Email / Other; below, 3–4 style cards (Formal / Casual / Very Casual / Excited!) each with a one-line example; the chosen card gets a `lilac` border; footer lists the apps in that category with an "Add app" button.
- **Settings:** split view: left list General / System / Models / Vibe coding / Experimental / Account; right pane forms using native SwiftUI `Form` styling with Figtree.

### 3.5 Scratchpad

Floating `NSPanel` 420 × 300 pt near the mouse cursor, cream background, a `TextEditor`, bottom bar with **Copy** and **Insert** buttons; hold `⌥S` to dictate into it; auto-closes after Insert.

### 3.6 Motion

All transitions ≤ 200 ms, spring damping 0.85. Waveform runs on a `CADisplayLink`-driven `TimelineView(.animation)` only while recording; zero timers while idle.

---

## 4. Architecture

### 4.1 Stack decisions (final)

| Layer | Choice | Why |
|---|---|---|
| Language / UI | Swift 6.2, SwiftUI for Hub/Settings/Flow Bar content, AppKit for `NSPanel`, `NSStatusItem`, event tap, pasteboard, AX | Native = tiny idle footprint, instant launch. Wispr's Electron shell is its biggest weakness. |
| Concurrency | Swift structured concurrency; `@MainActor` for UI; dedicated actors `AudioCapture`, `Transcriber`, `Formatter`, `Inserter`; event tap on its own thread + `CFRunLoop` | Never block the main thread; the tap callback must return in < 1 ms or macOS disables it. |
| STT primary | **NVIDIA Parakeet TDT 0.6B v3** via **FluidAudio** (`https://github.com/FluidInference/FluidAudio`, Apache-2.0; weights CC-BY-4.0, ~600 MB, CoreML on the Neural Engine) | Measured ~180 ms p50 for short clips on M4-class ANE, 2.1–2.7 % WER, punctuation + capitalization native, 25 languages. Use `AsrModels.downloadAndLoad(version: .v3)` and keep one `AsrManager` resident. |
| STT fallback + live preview | **Apple `SpeechAnalyzer` / `SpeechTranscriber`** (Speech framework, macOS 26; verified on this Mac: 30 locales, en-* assets already installed, **no Arabic**) | Zero download, system-managed, ~2.1 % LibriSpeech WER, `.volatileResults` for a live preview while the key is held. |
| STT for Arabic / other locales | **Nemotron 3.5 ASR Streaming 0.6B** via FluidAudio (`FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`, Arabic transcription-ready) first; **WhisperKit large-v3-turbo** (`argmaxinc/argmax-oss-swift`, MIT, 626 MB, ~1.5–2.5 s per 10 s clip) as the last resort | Parakeet v3 and Apple both lack Arabic. |
| VAD | FluidAudio `VadManager` (Silero CoreML) | Trim leading/trailing silence before ASR; auto-stop hands-free after 8 s of silence (setting). |
| Formatting LLM, tier 1 | **Apple `FoundationModels`** (`SystemLanguageModel.default`, verified **AVAILABLE** on this Mac). Measured here: 60-word transcript → ~880–930 ms warm, first token ~350 ms streaming; 3.7 s cold. | Free, no download, already on the machine. Too slow for the strict budget on long inputs, so gate it (see §4.3). |
| Formatting LLM, tier 2 | **MLX Swift** (`ml-explore/mlx-swift-examples`, package `MLXLLM`) with **`mlx-community/Qwen3-1.7B-4bit`** (≈1 GB) or **`LiquidAI/LFM2-1.2B`** 4-bit if available in MLX format; `/no_think` mode; prompt cache for the fixed system prompt | ~150–250 tok/s decode on M4 → a 40-token cleanup in ~250–400 ms. Offer as "Fast local model" in Settings → Models. |
| Formatting, tier 0 | Deterministic rules (§2.4 step 3) | Always runs; the only tier for ≤ 3 words or when level = None. |
| Storage | GRDB.swift (SQLite) + files | History, dictionary, snippets, settings (`UserDefaults` for prefs). |
| Model downloads | `swift-transformers` `HubApi` (resumable) or `URLSession` background downloads into `Application Support/Vunu/Models`; SHA check; progress UI | |
| Login item / updates | `SMAppService.mainApp`; Sparkle 2 optional (skip for the personal build) | |
| Project generation | **XcodeGen** (`project.yml`) so the whole project is text and reproducible; `xcodebuild` from CLI; SwiftPM for deps | The building agent cannot click through Xcode. |

### 4.2 Modules (one Swift package target each, `Vunu.app` is thin)

```
Vunu/
  App/                 VunuApp.swift (NSApplicationDelegateAdaptor), AppState (@Observable), MenuBarController
  Hotkeys/             EventTapMonitor (CGEventTap), ShortcutRecorder, ShortcutRules (reserved combos), FnKeyDetector
  Audio/               AudioCapture (AVAudioEngine tap → 16 kHz mono Float32 ring buffer), DeviceRanker (Core Audio), LevelMeter (RMS/peak @60 Hz), Sounds
  Speech/              TranscriptionEngine protocol; ParakeetEngine (FluidAudio); AppleSpeechEngine (SpeechAnalyzer); WhisperKitEngine; NemotronEngine; VAD
  Formatting/          RuleFormatter (spoken punctuation, numbers, emails, fillers); LLMFormatter protocol; AppleFMFormatter; MLXFormatter; StylePolicy; MessagingAppPolicy; DictionaryApplier; SnippetExpander; BacktrackHints
  Context/             FocusTracker (AX focused element + app + bundle id + browser URL), AppCategoryResolver (Personal/Work/Email/Other), SurroundingTextReader, SecureFieldGuard
  Insertion/           Inserter (AX setValue path, clipboard-paste path, chunked TUI path), PasteboardSnapshot, KeySynth (CGEvent ⌘V / Return)
  UI/FlowBar/          FlowBarPanel (NSPanel), FlowBarView (SwiftUI), WaveformView, DockingController (drag + drop zones), FlowBarMenu
  UI/Hub/              HubWindow, Sidebar, HomeView, DictionaryView, SnippetsView, StyleView, ScratchpadPanel, SettingsView(+ General/System/Models/VibeCoding/Experimental/Account), OnboardingFlow
  Persistence/         Database (GRDB), Models (Transcript, DictionaryEntry, Snippet, AppCategoryAssignment), AudioStore (Opus/FLAC, 14-day GC)
  Models/              ModelManager (download, verify, load/unload, warmup, benchmark)
  Session/             DictationSession (state machine, orchestrates: capture → VAD → ASR → format → insert), CommandModeSession
```

### 4.3 The dictation pipeline (per session, timings for a 10 s utterance on this Mac)

```
fn down (t=0)
 ├─ EventTapMonitor → SessionCoordinator.armed()             (<1 ms)
 ├─ FocusTracker.snapshot()  (frontmost app, AX focused element, category)   (≤ 30 ms, off-main)
 ├─ AudioCapture already running? (engine is kept running & pre-warmed when the app is active, tap installed, buffers discarded while idle → first buffer latency ≈ 0)
 ├─ t=250 ms still held → state .recording: ping, Flow Bar recording UI, menubar shows app icon
 └─ optional: AppleSpeechEngine.streamPreview(buffers) for live text under the pill (setting, off by default)
fn up (t=T)
 ├─ stop appending; VAD trim (≈10 ms)
 ├─ ParakeetEngine.transcribe(samples)                       (150–300 ms)
 ├─ RuleFormatter (≤ 5 ms) → DictionaryApplier → SnippetExpander
 ├─ if cleanupLevel ≥ Light && wordCount ≥ 4:
 │     LLMFormatter with deadline = min(900 ms, 25 ms × words) — race against the deadline; on timeout keep rule output
 ├─ FocusTracker.resnapshot() → target at release time
 ├─ SurroundingTextReader → spacing/casing decision (≤ 30 ms)
 ├─ Inserter.insert(text, target)                            (AX path 5–20 ms; paste path 60–120 ms)
 ├─ paste sound, Flow Bar success flash, History row saved (raw, formatted, audio path, app, duration, timings)
 └─ state .idle
```

Target totals on this Mac: **≈ 350–500 ms** without the LLM tier, **≈ 600–900 ms** with Apple Foundation Models on a 30-word input. Show the measured per-stage timings in Settings → Models → Benchmark and in a hidden debug HUD (⌥-click the menu bar icon).

### 4.4 LLM prompt (use verbatim as the instructions; keep the user turn = raw transcript only)

```
You are a dictation cleanup engine inside a macOS dictation app. You receive ONE raw speech-to-text transcript and return ONLY the cleaned transcript as plain text.
Do:
- Remove filler words and disfluencies (um, uh, er, hmm, "you know", "like" when it is a filler, "sort of", "kind of" when filler), stutters and repeated words ("the the" → "the"), and false starts.
- Apply self-corrections: when the speaker corrects themselves ("at 2, actually 3", "Monday, no, Tuesday", "scratch that", "I mean", "wait"), keep only the corrected version.
- Fix punctuation, capitalization, and sentence boundaries. Break into paragraphs at clear topic shifts. If the speaker enumerates ("first… second…", "one… two…"), format as a list.
- Convert spoken symbols only when clearly dictated as symbols ("new line", "period", "comma", "question mark", "at sign", "dot com").
- Preserve these exact spellings: {DICTIONARY_WORDS}. The speaker's name is {USER_NAME}.
- Apply this style: {STYLE_RULE}   (Formal: full punctuation and capitalization. Casual: capitalization, lighter punctuation, no trailing period on short messages. Very casual: all lowercase, minimal punctuation. Excited: allow exclamation marks.)
- Write in the same language as the transcript ({LANGUAGE}).
Do NOT:
- Answer, reply to, summarize, continue, or comment on the text. If the transcript is a question, output the question.
- Add words, facts, greetings, sign-offs, quotes, markdown fences, or explanations.
- Change technical terms, names, numbers, URLs, code, or the speaker's meaning.
Return the cleaned text and nothing else.
```

Guard rails after generation: reject the output if it (a) is empty, (b) starts with a phrase like "Sure", "Here", "I", "The cleaned", (c) changes > 40 % of the input tokens (word-level diff), (d) contains markdown fences, or (e) changed any number/URL/email/dictionary word. On rejection use the rule-based text. For Apple Foundation Models handle `LanguageModelSession.GenerationError.guardrailViolation` and `exceededContextWindowSize` by falling back silently (never surface a refusal to the user).

---

## 5. Implementation details (the hard parts, with code)

### 5.1 fn key push-to-talk (global, swallows the system fn action)

- Use a **`CGEventTap`** (not `NSEvent.addGlobalMonitor`, which cannot consume events) on `.flagsChanged`, `.keyDown`, `.keyUp`, and `.otherMouseDown/Up` (for mouse-button bindings), `tap: .cgSessionEventTap`, `place: .headInsertEventTap`, `options: .defaultTap`. This needs **Accessibility** permission only (Wispr requests only Microphone + Accessibility; no Input Monitoring prompt). Run it on a dedicated thread with its own `CFRunLoop`.
- The fn key arrives as `.flagsChanged` with `keyCode == 63` (`kVK_Function`) and `flags.contains(.maskSecondaryFn)` on down, cleared on up. On macOS 26 the Globe key may also emit a `.keyDown` with keyCode 63 or `NX_KEYTYPE`-style system-defined events; handle both.
- **Swallowing the system action:** returning `nil` (Unmanaged) from the callback for the fn `.flagsChanged` events prevents the Emoji picker / Dictation / Input-source switch from firing, regardless of the user's "Press 🌐 key to" setting. Only swallow when the fn event is *alone* (no other modifiers) and no other key is pressed during the hold; if another key is pressed while fn is held, re-post the swallowed fn-down (`CGEvent.post`) then pass everything through so fn+arrow/F-keys keep working, and cancel the arming.
- Re-enable on `kCGEventTapDisabledByTimeout` / `...ByUserInput` via `CGEvent.tapEnable(tap:enable:)`; also watch `NSWorkspace.didWakeNotification` and screen unlock to recreate the tap (Wispr documents a few seconds of dead shortcuts after wake).
- Double-tap detection: two fn-downs within 350 ms with the first hold < 300 ms → lock hands-free. Triple-tap → cancel.
- `Esc` cancel: match keyCode 53 on `.keyDown` regardless of modifier flags while a session is active, then swallow it.
- Detect Apple keyboards: `IOHIDManager` device with `kIOHIDVendorIDKey == 0x05AC` and a fn key usage, or simply "did we ever see keyCode 63" — if none seen in 5 s of use and an external keyboard is present, suggest `⌃⌥` in onboarding.

```swift
final class EventTapMonitor {
    private var tap: CFMachPort?; private var runLoop: CFRunLoop?
    private let thread = Thread { /* CFRunLoopRun() */ }
    func start(handler: @escaping (CGEvent, CGEventType) -> Bool /* true = swallow */) throws {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { proxy, type, event, refcon in
            let monitor = Unmanaged<EventTapMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { CGEvent.tapEnable(tap: monitor.tap!, enable: true); return Unmanaged.passUnretained(event) }
            return monitor.handle(event, type) ? nil : Unmanaged.passUnretained(event)   // nil = swallow
        }, userInfo: info) else { throw VunuError.accessibilityDenied }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        // on the dedicated thread: CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes); CGEvent.tapEnable(tap: tap, enable: true); CFRunLoopRun()
    }
    // handle(): keyCode 63 + .maskSecondaryFn → fnDown; keyCode 63 without it → fnUp; keep < 1 ms, dispatch to SessionCoordinator via a lock-free queue.
}
```

### 5.2 Audio capture (no ducking, instant start)

```swift
let engine = AVAudioEngine()
let input = engine.inputNode                     // NEVER call input.setVoiceProcessingEnabled(true)
let hw = input.outputFormat(forBus: 0)           // hardware rate (48 kHz), tap MUST use this format
let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
let converter = AVAudioConverter(from: hw, to: target)!   // one long-lived converter (recreating per buffer causes clicks)
input.installTap(onBus: 0, bufferSize: 2048, format: hw) { buf, _ in
    // convert → append Float32 samples to ring buffer only while session.isRecording; always feed LevelMeter (cheap RMS) while recording
}
try engine.start()   // keep running while the app is active; pause after 10 min idle to save power, restart on first fn-down (≈30 ms)
```
- Pick the input device explicitly (Core Audio `kAudioHardwarePropertyDefaultInputDevice` / set `kAudioOutputUnitProperty_CurrentDevice` on `input.audioUnit`) using the user's ranked list; default "Built-in mic (recommended)". If the selected device is Bluetooth, warn once: using the AirPods mic drops them into low-quality HFP mode and can miss the first words. Do **not** switch devices automatically mid-session.
- Handle `AVAudioEngineConfigurationChange` (device unplugged): restart the engine, keep the buffered samples, show "Microphone disconnected — Insert" if mid-session.
- Discard the first 60 ms after the engine starts (Wispr does too). Always save the raw session as 16 kHz FLAC/Opus before transcribing.
- "Mute music while dictating" (off): read/write the default output device's `kAudioDevicePropertyMute` (fall back to `kAudioDevicePropertyVolumeScalar` = 0 and restore the exact value); only when audio is actually playing (`kAudioDevicePropertyDeviceIsRunningSomewhere`); preserve a user-set mute.

### 5.3 Focus, context, and insertion (AX)

```swift
let sys = AXUIElementCreateSystemWide()
var focused: CFTypeRef?; AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
// read kAXRoleAttribute / kAXSubroleAttribute / kAXValueAttribute / kAXSelectedTextRangeAttribute / kAXSelectedTextAttribute
// insert: AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString)  → verify value grew; else paste path
```
- Set `AXUIElementSetMessagingTimeout(el, 0.05)` so a hung app can't stall the pipeline; run AX calls off the main thread.
- Electron/Chromium apps (Slack, Discord, VS Code, Claude desktop, Notion): AX read works only when the app has enabled accessibility; set `AXEnhancedUserInterface`/`AXManualAccessibility = true` on the app element to switch Chromium's AX tree on, then read. Insertion for these goes through the paste path.
- Terminals/TUI (Claude Code, Codex): paste path, strip trailing newline, chunk > 1,500 chars, wait for `changeCount` before restoring the clipboard, add 120 ms before restore (bracketed-paste apps read the pasteboard asynchronously).
- Browser URL for category detection: Safari `AXDocument`/`AXURL` on the focused window; Chromium browsers expose the URL on the toolbar's `AXTextField` value; Arc/Zen inherit Chromium/Firefox behavior. Read once at key-down; skip on timeout.
- Clipboard restore: snapshot all `NSPasteboard.general.pasteboardItems` types except public.file-url / com.apple.flat-rtfd / com.adobe.pdf / public.audio; write text with `NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")` and `"org.nspasteboard.TransientType"`; post ⌘V; wait for `changeCount` to advance or 200 ms; restore; log.

### 5.4 Flow Bar panel (non-activating, over full-screen apps)

```swift
final class FlowBarPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true; hidesOnDeactivate = false; isMovableByWindowBackground = false
        backgroundColor = .clear; isOpaque = false; hasShadow = true; animationBehavior = .utilityWindow
        contentView = NSHostingView(rootView: FlowBarView(model: model))
    }
    override var canBecomeKey: Bool { false }; override var canBecomeMain: Bool { false }
}
```
Position: `screen.visibleFrame.midX - width/2`, `screen.visibleFrame.minY + 24`, where `screen` = the screen containing the frontmost app's focused window (`kAXPositionAttribute` of `kAXFocusedWindowAttribute`), else `NSScreen.main`. Show with `orderFrontRegardless()`; never `makeKey`.

### 5.5 Permissions, signing, TCC stability

- `Info.plist`: `NSMicrophoneUsageDescription`, `LSUIElement = true`, `NSAppleEventsUsageDescription` (optional). No sandbox entitlement. Hardened runtime with `com.apple.security.device.audio-input`.
- Onboarding checks: `AVCaptureDevice.authorizationStatus(for: .audio)`, `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`. Deep links: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`, `?Privacy_Microphone`.
- TCC grants are keyed to the code signature: create one self-signed "Vunu Dev" code-signing certificate in Keychain Access (or use a Developer ID) and sign every build with it (`CODE_SIGN_IDENTITY`), same bundle id, so Accessibility doesn't reset on each rebuild. Provide `scripts/build.sh` (xcodegen → xcodebuild → codesign → copy to /Applications) and `scripts/reset-tcc.sh` (`tccutil reset Accessibility dev.nunu.vunu`).

### 5.6 Models: download, warmup, memory

- First launch downloads Parakeet v3 (~600 MB) with a progress bar; then runs a 1-second silent warmup so the CoreML compile happens before the first dictation. Keep it loaded. Apple SpeechTranscriber: call `AssetInventory.assetInstallationRequest(supporting:)` for the selected locales; `SpeechTranscriber.installedLocales` to show status.
- Foundation Models: create one `LanguageModelSession(instructions:)` per style, call `prewarm()` at launch and after each dictation, recreate the session when `transcriptEntries` exceed ~20 turns (context limit is 4,096 tokens).
- MLX tier: load lazily on first use when selected; unload after 15 min idle; show RSS in Settings → Models.
- All model files under `~/Library/Application Support/Vunu/Models/{parakeet-v3,whisperkit,mlx}`; "Delete" buttons per model.

---

## 6. Performance budgets (measured on this Mac; enforce with XCTest performance tests)

| Stage | Budget | Note |
|---|---|---|
| fn-down → recording UI visible | ≤ 40 ms | panel pre-created and hidden, not recreated |
| First audio sample captured after fn-down | ≤ 15 ms | engine already running |
| Parakeet, 10 s speech | ≤ 300 ms | warm |
| Rules formatter | ≤ 5 ms | |
| Apple FM cleanup, 30 words | ≤ 700 ms, hard deadline 900 ms | measured 880–930 ms for 60 words; deadline races the rule output |
| AX context read | ≤ 30 ms, else skip | |
| Insert (AX path / paste path) | ≤ 20 ms / ≤ 120 ms | |
| **Total, 10 s utterance, cleanup Light** | **≤ 600 ms** | |
| Idle CPU / RAM | < 1 % / < 250 MB (no models) ; < 900 MB with Parakeet + FM resident | Instruments "Allocations" check in CI script |
| Hub window open | ≤ 150 ms | lazy views |

---

## 7. Project setup for the building agent

1. `brew install xcodegen` (and `swiftlint` optional). Create `project.yml` targeting macOS 26.0, Swift 6, strict concurrency `complete`, `MACOSX_DEPLOYMENT_TARGET = 26.0`, `ENABLE_APP_SANDBOX = NO`, `ENABLE_HARDENED_RUNTIME = YES`, `LSUIElement = YES`.
2. SwiftPM dependencies: `FluidInference/FluidAudio` (from: latest 0.15.x), `groue/GRDB.swift`, `ml-explore/mlx-swift-examples` (MLXLLM, only if the MLX tier is enabled in the first milestone — otherwise add in M5), `argmaxinc/argmax-oss-swift` (WhisperKit; M6), `huggingface/swift-transformers` (HubApi downloads), `sindresorhus/KeyboardShortcuts` is **not** used (it can't record fn alone) — write the recorder yourself.
3. Fonts: bundle Figtree and EB Garamond (Google Fonts, OFL) via `ATSApplicationFontsPath`.
4. `scripts/build.sh`, `scripts/run.sh` (kills the previous instance, launches the new build, tails `~/Library/Logs/Vunu/vunu.log`), `scripts/bench.sh` (runs the built-in benchmark and prints per-stage timings), `scripts/reset-tcc.sh`.
5. Logging: `os.Logger` with subsystem `dev.nunu.vunu`, categories per module; a rolling file log; a debug HUD listing the last session's stage timings.
6. Tests: unit tests for RuleFormatter (table-driven: spoken punctuation, numbers, emails, fillers, stutters), ShortcutRules (reserved combos), MessagingAppPolicy, SnippetExpander, DictionaryApplier, SurroundingText casing/spacing; integration test that runs the pipeline on 10 bundled WAV fixtures and asserts WER < 5 % against expected text and total time < 600 ms.

---

## 8. Build order (each milestone must run end-to-end before the next)

**M1 — Skeleton + hotkey + audio (day 1).** Menu bar app, onboarding permissions, EventTapMonitor with fn hold/double-tap/Esc, AudioCapture with level meter, Flow Bar panel with idle/recording/processing states and waveform, app-icon swap in the menu bar and pill. Acceptance: hold fn anywhere (including over a full-screen app and while ⌘-Tabbing), see the pill + waveform, release → a stub inserts "[test]" via the paste engine into TextEdit, Notes, Slack, Safari, Terminal, and Claude Code in Ghostty; music in Spotify keeps playing at full volume throughout; clipboard restored.
**M2 — Parakeet STT.** Model download UI, warmup, transcription, History storage, Paste/Copy last transcript, cancelled/failed handling. Acceptance: 10 s clip → text in < 600 ms; History shows the row with the correct app icon.
**M3 — Formatting.** RuleFormatter + Dictionary + Snippets + context-aware spacing/casing + messaging-period rule + Styles UI + AppCategoryResolver (incl. browser URLs). Acceptance: the fixture set passes; "coffee at 2 actually 3" → "coffee at 3" via LLM tier.
**M4 — Apple Foundation Models tier** with deadline racing and guard rails; Auto Cleanup levels; Undo AI edit. Acceptance: no output ever "answers" a dictated question; timeouts fall back silently.
**M5 — Hub polish.** Home stats, search, Style page, Settings (all sections), Scratchpad, sounds, notifications, Flow Bar docking/dragging, Hide for 1 hour, screen-share hiding, launch at login.
**M6 — Multilingual + extras.** Apple SpeechTranscriber engine + live preview option, Nemotron/WhisperKit for Arabic, language picker on the pill, Command Mode with diff view, "press enter", Vibe-coding variable recognition and @file tagging, MLX fast-model tier, benchmark screen.

---

## 9. Do not

- Do not use Electron, Tauri, Python sidecars, or Ollama in the shipped app.
- Do not enable voice processing / echo cancellation on the input node (ducks music).
- Do not use `NSEvent.addGlobalMonitorForEvents` as the primary hotkey mechanism (can't swallow fn; the emoji picker would open).
- Do not stream partial text into the target app; insert once, on release (this is how Wispr keeps full-context cleanup; live preview only in the pill).
- Do not change the user's "Press 🌐 key to" system setting silently; explain and offer a button.
- Do not insert into secure text fields, and never read their contents.
- Do not block the main thread on AX, CoreML, or LLM calls; every stage has a deadline.
- Do not ship any network call other than model downloads; no analytics.
- Do not add features not in this document before M6 is done.

---

## 10. Source of truth used for this spec

Wispr Flow help center (docs.wisprflow.ai — Setup Guide; Starting your first dictation; Use Flow hands-free; Supported & Unsupported Keyboard Hotkey Shortcuts; Move and Dock the Flow Bar; Troubleshooting the Flow Bar; Fix text not pasting; Fix shortcuts blocked by Secure Keyboard Entry; Auto-mute music while dictating; Using Flow with Terminal apps; Use Flow with Cursor/VS Code; How to use Command Mode; Smart Formatting & Backtrack; Flow Styles; Dictionary; Snippets; Navigating the app; Context Awareness; Missing first words; Longer dictation sessions; Transforms), wisprflow.ai homepage + Flow Bar SVG asset (exact colors/geometry), wisprflow.ai/whats-new, Homebrew cask (`com.electron.wispr-flow`), a forensic teardown of the Wispr bundle (Electron + Swift helper with CGEventTap; clipboard paste with restore; Baseten gRPC ASR), FluidAudio / Parakeet benchmarks, Apple Speech + FoundationModels docs, and measurements taken on the owner's own Mac on 2026-09-07 (FoundationModels available; SpeechTranscriber 30 locales, no Arabic; FM cleanup 880–930 ms warm for 60 words).
