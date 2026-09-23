import Foundation
import Observation

public enum CleanupLevel: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, light, medium, high
    public var id: String { rawValue }
    public var title: String {
        switch self { case .none: "None"; case .light: "Light"; case .medium: "Medium"; case .high: "High" }
    }
}

public enum SttEngineKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case parakeetV3      // FluidAudio Parakeet TDT 0.6B v3 (default)
    case parakeetV2      // English-only, higher recall
    case appleSpeech     // Apple SpeechAnalyzer
    case whisperKit      // WhisperKit large-v3-turbo (Arabic etc.)
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .parakeetV3: "Parakeet v3 (25 languages)"
        case .parakeetV2: "Parakeet v2 (English, most accurate)"
        case .appleSpeech: "Apple Speech (built-in)"
        case .whisperKit: "Whisper large-v3-turbo (Arabic + 90 languages)"
        }
    }
}

public enum FormatterKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case appleIntelligence, mlx, rulesOnly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence (on-device)"
        case .mlx: "Fast local model (MLX) — coming soon"
        case .rulesOnly: "Rules only"
        }
    }
}

public enum AudioRetention: String, CaseIterable, Codable, Sendable, Identifiable {
    case never, oneDay, fourteenDays
    public var id: String { rawValue }
    public var title: String {
        switch self { case .never: "Never store audio (default)"; case .oneDay: "Keep 24 h (enables Retry)"; case .fourteenDays: "Keep 14 days (enables Retry)" }
    }
}

public enum AppCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case personal, work, email, other
    public var id: String { rawValue }
    public var title: String {
        switch self { case .personal: "Personal messages"; case .work: "Work messages"; case .email: "Email"; case .other: "Other" }
    }
}

public enum WritingStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case formal, casual, veryCasual, excited
    public var id: String { rawValue }
    public var title: String {
        switch self { case .formal: "Formal"; case .casual: "Casual"; case .veryCasual: "Very Casual"; case .excited: "Excited!" }
    }
    public var example: String {
        switch self {
        case .formal: "Hi Sarah, I have finished the report. Let me know if you have questions."
        case .casual: "Hi Sarah, I finished the report. Let me know if you have questions"
        case .veryCasual: "hi sarah, finished the report, lmk if you have questions"
        case .excited: "Hi Sarah! I finished the report! Let me know if you have questions!"
        }
    }
    public static func options(for category: AppCategory) -> [WritingStyle] {
        switch category {
        case .personal: [.formal, .casual, .veryCasual]
        case .work, .email, .other: [.formal, .casual, .excited]
        }
    }
}

/// Observable, UserDefaults-backed preferences. Single instance on the main actor.
@MainActor @Observable
public final class Preferences {
    public static let shared = Preferences()
    private let d = UserDefaults.standard

    private init() {
        onboardingCompleted = d.bool(forKey: "onboardingCompleted")
        userName = d.string(forKey: "userName") ?? ""
        launchAtLogin = d.bool(forKey: "launchAtLogin")
        showFlowBarAlways = d.bool(forKey: "showFlowBarAlways")
        showInDock = d.bool(forKey: "showInDock")
        soundEffects = d.object(forKey: "soundEffects") as? Bool ?? true
        automaticUpdateChecks = d.object(forKey: "automaticUpdateChecks") as? Bool ?? true
        skippedUpdateVersion = d.string(forKey: "skippedUpdateVersion")
        muteMusicWhileDictating = d.bool(forKey: "muteMusicWhileDictating")
        hideFlowBarFromScreenShare = d.bool(forKey: "hideFlowBarFromScreenShare")
        cleanupLevel = CleanupLevel(rawValue: d.string(forKey: "cleanupLevel") ?? "") ?? .medium
        sttEngine = SttEngineKind(rawValue: d.string(forKey: "sttEngine") ?? "") ?? .parakeetV2
        formatter = FormatterKind(rawValue: d.string(forKey: "formatter") ?? "") ?? .appleIntelligence
        keepModelsLoaded = d.object(forKey: "keepModelsLoaded") as? Bool ?? true
        audioRetention = AudioRetention(rawValue: d.string(forKey: "audioRetention") ?? "") ?? .never
        contextAwareness = d.object(forKey: "contextAwareness") as? Bool ?? true
        languages = d.stringArray(forKey: "languages") ?? ["en"]
        autoDetectLanguage = d.object(forKey: "autoDetectLanguage") as? Bool ?? true
        preferredMicrophoneUID = d.string(forKey: "preferredMicrophoneUID")
        livePreview = d.bool(forKey: "livePreview")
        commandModeEnabled = d.object(forKey: "commandModeEnabled") as? Bool ?? true
        pressEnterCommand = d.object(forKey: "pressEnterCommand") as? Bool ?? true
        pressEnterExplained = d.bool(forKey: "pressEnterExplained")
        whisperMode = d.bool(forKey: "whisperMode")
        handsFreeSilenceStopSeconds = d.object(forKey: "handsFreeSilenceStopSeconds") as? Double ?? 8
        flowBarPosition = d.string(forKey: "flowBarPosition")
        hideFlowBarUntil = d.object(forKey: "hideFlowBarUntil") as? Date
        stylesByCategory = Self.decode([AppCategory: WritingStyle].self, d.data(forKey: "stylesByCategory")) ?? [:]
        extraAppsByCategory = Self.decode([AppCategory: [String]].self, d.data(forKey: "extraAppsByCategory")) ?? [:]
        shortcuts = Self.decode([ShortcutAction: [ShortcutBinding]].self, d.data(forKey: "shortcuts")) ?? ShortcutBinding.defaults
        notificationsEnabled = Self.decode([String: Bool].self, d.data(forKey: "notificationsEnabled")) ?? [:]
        explainersShown = Set(d.stringArray(forKey: "explainersShown") ?? [])
        secureInputBannerShown = d.bool(forKey: "secureInputBannerShown")
        airPodsWarningShown = d.bool(forKey: "airPodsWarningShown")
        seenFnKeyCount = d.integer(forKey: "seenFnKeyCount")
        devVocabulary = d.object(forKey: "devVocabulary") as? Bool ?? true
        fileTagging = d.object(forKey: "fileTagging") as? Bool ?? true
        variableRecognition = d.object(forKey: "variableRecognition") as? Bool ?? true
        learnFromEdits = d.object(forKey: "learnFromEdits") as? Bool ?? true
    }

    public var onboardingCompleted: Bool { didSet { d.set(onboardingCompleted, forKey: "onboardingCompleted") } }
    public var userName: String { didSet { d.set(userName, forKey: "userName") } }
    public var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin") } }
    public var showFlowBarAlways: Bool { didSet { d.set(showFlowBarAlways, forKey: "showFlowBarAlways") } }
    public var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }
    public var soundEffects: Bool { didSet { d.set(soundEffects, forKey: "soundEffects") } }
    public var automaticUpdateChecks: Bool { didSet { d.set(automaticUpdateChecks, forKey: "automaticUpdateChecks") } }
    public var skippedUpdateVersion: String? { didSet { d.set(skippedUpdateVersion, forKey: "skippedUpdateVersion") } }
    public var muteMusicWhileDictating: Bool { didSet { d.set(muteMusicWhileDictating, forKey: "muteMusicWhileDictating") } }
    public var hideFlowBarFromScreenShare: Bool { didSet { d.set(hideFlowBarFromScreenShare, forKey: "hideFlowBarFromScreenShare") } }
    public var cleanupLevel: CleanupLevel { didSet { d.set(cleanupLevel.rawValue, forKey: "cleanupLevel") } }
    public var sttEngine: SttEngineKind { didSet { d.set(sttEngine.rawValue, forKey: "sttEngine") } }
    public var formatter: FormatterKind { didSet { d.set(formatter.rawValue, forKey: "formatter") } }
    public var keepModelsLoaded: Bool { didSet { d.set(keepModelsLoaded, forKey: "keepModelsLoaded") } }
    public var audioRetention: AudioRetention { didSet { d.set(audioRetention.rawValue, forKey: "audioRetention") } }
    public var contextAwareness: Bool { didSet { d.set(contextAwareness, forKey: "contextAwareness") } }
    public var languages: [String] { didSet { d.set(languages, forKey: "languages") } }
    public var autoDetectLanguage: Bool { didSet { d.set(autoDetectLanguage, forKey: "autoDetectLanguage") } }
    public var preferredMicrophoneUID: String? { didSet { d.set(preferredMicrophoneUID, forKey: "preferredMicrophoneUID") } }
    public var livePreview: Bool { didSet { d.set(livePreview, forKey: "livePreview") } }
    public var commandModeEnabled: Bool { didSet { d.set(commandModeEnabled, forKey: "commandModeEnabled") } }
    public var pressEnterCommand: Bool { didSet { d.set(pressEnterCommand, forKey: "pressEnterCommand") } }
    public var pressEnterExplained: Bool { didSet { d.set(pressEnterExplained, forKey: "pressEnterExplained") } }
    public var whisperMode: Bool { didSet { d.set(whisperMode, forKey: "whisperMode") } }
    public var handsFreeSilenceStopSeconds: Double { didSet { d.set(handsFreeSilenceStopSeconds, forKey: "handsFreeSilenceStopSeconds") } }
    public var flowBarPosition: String? { didSet { d.set(flowBarPosition, forKey: "flowBarPosition") } }
    public var hideFlowBarUntil: Date? { didSet { d.set(hideFlowBarUntil, forKey: "hideFlowBarUntil") } }
    public var stylesByCategory: [AppCategory: WritingStyle] { didSet { d.set(Self.encode(stylesByCategory), forKey: "stylesByCategory") } }
    public var extraAppsByCategory: [AppCategory: [String]] { didSet { d.set(Self.encode(extraAppsByCategory), forKey: "extraAppsByCategory") } }
    public var shortcuts: [ShortcutAction: [ShortcutBinding]] { didSet { d.set(Self.encode(shortcuts), forKey: "shortcuts") } }
    public var notificationsEnabled: [String: Bool] { didSet { d.set(Self.encode(notificationsEnabled), forKey: "notificationsEnabled") } }
    public var explainersShown: Set<String> { didSet { d.set(Array(explainersShown), forKey: "explainersShown") } }
    public var secureInputBannerShown: Bool { didSet { d.set(secureInputBannerShown, forKey: "secureInputBannerShown") } }
    public var airPodsWarningShown: Bool { didSet { d.set(airPodsWarningShown, forKey: "airPodsWarningShown") } }
    public var seenFnKeyCount: Int { didSet { d.set(seenFnKeyCount, forKey: "seenFnKeyCount") } }
    public var devVocabulary: Bool { didSet { d.set(devVocabulary, forKey: "devVocabulary") } }
    public var fileTagging: Bool { didSet { d.set(fileTagging, forKey: "fileTagging") } }
    public var variableRecognition: Bool { didSet { d.set(variableRecognition, forKey: "variableRecognition") } }
    public var learnFromEdits: Bool { didSet { d.set(learnFromEdits, forKey: "learnFromEdits") } }

    public func isNotificationEnabled(_ key: String) -> Bool { notificationsEnabled[key] ?? true }

    public func resetAll() {
        if let bundle = Bundle.main.bundleIdentifier { d.removePersistentDomain(forName: bundle) }
    }

    private static func encode<T: Encodable>(_ v: T) -> Data? { try? JSONEncoder().encode(v) }
    private static func decode<T: Decodable>(_ t: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(t, from: data)
    }
}
