import Foundation

public enum SessionState: Equatable, Sendable {
    case idle, armed, recording, stopping, transcribing, formatting, inserting, cancelled
    case error(String)

    public var isActive: Bool { self != .idle && self != .cancelled && !isError }
    public var isProcessing: Bool { self == .stopping || self == .transcribing || self == .formatting || self == .inserting }
    public var isCapturing: Bool { self == .armed || self == .recording }
    public var isError: Bool { if case .error = self { return true } else { return false } }
    public var label: String {
        switch self {
        case .idle: "Idle"; case .armed: "Armed"; case .recording: "Recording"; case .stopping: "Stopping"; case .transcribing: "Transcribing"
        case .formatting: "Formatting"; case .inserting: "Inserting"; case .cancelled: "Cancelled"; case .error(let e): "Error: \(e)"
        }
    }
}

public enum SessionMode: String, Sendable, Equatable { case pushToTalk, handsFree, commandMode, scratchpad }

/// Short, actionable messages shown on the Flow Bar / toast panel (verbatim Wispr copy where it exists).
public struct SessionNotice: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case info, warning, error, success }
    public enum Action: Sendable, Equatable { case none, copy(String), insert(String), openSettings, chooseMicrophone, enablePressEnter, recover, addToDictionary(word: String, misspelling: String) }
    public let id = UUID()
    public var kind: Kind
    public var title: String
    public var detail: String?
    public var action: Action
    public var duration: TimeInterval
    public init(_ kind: Kind, _ title: String, detail: String? = nil, action: Action = .none, duration: TimeInterval = 4) {
        self.kind = kind; self.title = title; self.detail = detail; self.action = action; self.duration = duration
    }
}
