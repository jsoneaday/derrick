import Foundation

/// Request sent from the main app to the DockerRunnerHelper XPC service.
public struct DockerRunRequest: Codable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let stdinData: Data
    public let timeoutSeconds: Int

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        stdinData: Data,
        timeoutSeconds: Int
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.stdinData = stdinData
        self.timeoutSeconds = timeoutSeconds
    }
}

/// Response returned by the DockerRunnerHelper XPC service.
public struct DockerRunResponse: Codable, Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public let timedOut: Bool
    public let launchError: String?
    public var logs: [String]

    public init(
        stdout: Data,
        stderr: Data,
        exitCode: Int32,
        timedOut: Bool,
        launchError: String?,
        logs: [String]
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.launchError = launchError
        self.logs = logs
    }
}

/// XPC protocol for spawning a process outside the app sandbox.
@objc public protocol DockerProcessRunnerXPC: NSObjectProtocol {
    func runProcess(requestData: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// JSON array of domain suffixes for permanent egress allowlist.
    func setEgressAllowedDomainSuffixes(suffixesJSON: NSData, withReply reply: @escaping @Sendable (Bool) -> Void)
    /// JSON array of exact hosts granted for this app session only (Allow once).
    func grantEgressSessionHosts(hostsJSON: NSData, withReply reply: @escaping @Sendable (Bool) -> Void)
}

/// XPC protocol used by the helper to talk back to the app (logs + mid-flight egress prompts).
@objc public protocol DockerHelperLogSinkXPC: NSObjectProtocol {
    func appendLog(message: String)
    /// Mid-flight CONNECT hold: ask the user about `host`.
    /// Reply JSON object: `{"decision":"once"|"always"|"deny","actor":"...?"}`.
    func requestEgressHostAccess(host: String, withReply reply: @escaping @Sendable (NSData) -> Void)
}

/// Parsed reply from `requestEgressHostAccess`.
public struct EgressHostAccessReply: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable {
        case once
        case always
        case deny
    }

    public let decision: Decision
    public let actor: String?

    public init(decision: Decision, actor: String? = nil) {
        self.decision = decision
        self.actor = actor
    }

    public func encodeJSON() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(from data: Data) throws -> EgressHostAccessReply {
        try JSONDecoder().decode(EgressHostAccessReply.self, from: data)
    }
}
