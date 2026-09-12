import Foundation
import MCP

public enum GuestScriptLanguage: String, Sendable, Equatable {
    case go

    public var verifierID: String { "go-check-v1" }

    /// `language` is optional and must be Go when set.
    public static func requestedLanguageIsUnsupported(_ arguments: [String: Value]) -> Bool {
        guard let raw = arguments["language"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !raw.isEmpty
        else {
            return false
        }
        return raw != "go" && raw != "golang"
    }
}

public struct SessionMemorySearchArguments: Sendable {
    public static let maxRowsPerRequest = 100

    public let query: String?
    public let limit: Int
    public let page: Int
    public let includeArchived: Bool

    public init(query: String? = nil, limit: Int = 10, page: Int = 1, includeArchived: Bool = false) {
        self.query = query
        self.limit = min(max(limit, 1), Self.maxRowsPerRequest)
        self.page = max(page, 1)
        self.includeArchived = includeArchived
    }
}

public protocol PluginHopHandler: Sendable {
    func handleUIPresent(payload: [String: PluginJSON]) async -> PluginHopEvent?
    func handleSecretRequest(payload: [String: PluginJSON]) async -> PluginHopEvent?
}

public struct DockerCLIResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public typealias DockerCLIExecutor = @Sendable (
    _ arguments: [String],
    _ stdin: Data,
    _ timeoutSeconds: Int
) async throws -> DockerCLIResult
