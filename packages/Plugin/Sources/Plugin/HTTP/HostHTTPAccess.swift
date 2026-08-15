import Foundation

/// Soft-blacklist decision before a host HTTP hop. Hard SSRF is separate and never prompted.
public enum BlacklistHTTPPolicy: Sendable {
    public enum Result: Sendable, Equatable {
        case allow
        case prompt(BlacklistEntry)
    }

    /// Exceptions win. Else a blacklist hit prompts. Else allow.
    public static func evaluate(
        host: String,
        blacklist: [BlacklistEntry],
        exceptions: [BlacklistEntry]
    ) -> Result {
        if case .hit = BlacklistMatcher.match(host: host, entries: exceptions) {
            return .allow
        }
        if case .hit(let entry) = BlacklistMatcher.match(host: host, entries: blacklist) {
            return .prompt(entry)
        }
        return .allow
    }
}

/// Injected into `HostHTTPClient`. MCPServer must not own DB or UI.
public protocol HostHTTPAccessGate: Sendable {
    func authorize(url: URL, invokeID: String) async -> HostHTTPAccessDecision
}

public enum HostHTTPAccessDecision: Sendable, Equatable {
    case allow
    case deny(String)
}

public struct AllowAllHostHTTPAccessGate: HostHTTPAccessGate {
    public init() {}

    public func authorize(url: URL, invokeID: String) async -> HostHTTPAccessDecision {
        _ = url
        _ = invokeID
        return .allow
    }
}
