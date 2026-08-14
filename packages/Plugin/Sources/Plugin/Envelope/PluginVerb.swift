import Foundation

/// Closed guest → host vocabulary. Unknown verbs fail closed.
public enum PluginVerb: String, Codable, Sendable, Hashable, CaseIterable {
    case messagePost = "message.post"
    case resultEmit = "result.emit"
    case uiPresent = "ui.present"
    case secretRequest = "secret.request"
    case jobSchedule = "job.schedule"
    case httpRequest = "http.request"
    case log

    /// Accepts official verbs plus short aliases models often emit (`result`, `message`, `http`).
    public static func parse(_ raw: String) -> PluginVerb? {
        if let exact = PluginVerb(rawValue: raw) { return exact }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "result", "emit", "done":
            return .resultEmit
        case "message", "post", "text":
            return .messagePost
        case "http", "fetch", "netfetch", "request":
            return .httpRequest
        case "log", "print":
            return .log
        default:
            return nil
        }
    }

    public var classification: PluginVerbClass {
        switch self {
        case .httpRequest, .uiPresent, .secretRequest:
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
