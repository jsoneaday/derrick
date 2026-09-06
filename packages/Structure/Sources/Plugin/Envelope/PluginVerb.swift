import Foundation

/// Closed guest → host vocabulary. Unknown verbs fail closed.
public enum PluginVerb: String, Codable, Sendable, Hashable, CaseIterable {
    case messagePost = "message.post"
    case resultEmit = "result.emit"
    case uiPresent = "ui.present"
    case secretRequest = "secret.request"
    case storageRead = "storage.read"
    case storageWrite = "storage.write"
    case jobSchedule = "job.schedule"
    case httpRequest = "http.request"
    case log

    /// Official envelope-list `verb` enum values only.
    public static func parse(_ raw: String) -> PluginVerb? {
        PluginVerb(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public var classification: PluginVerbClass {
        switch self {
        case .httpRequest, .uiPresent, .secretRequest, .storageRead, .storageWrite:
            return .continuation
        case .resultEmit, .messagePost:
            return .terminal
        case .log, .jobSchedule:
            return .side
        }
    }
}

public enum PluginVerbClass: Sendable, Hashable {
    case continuation
    case terminal
    case side
}
