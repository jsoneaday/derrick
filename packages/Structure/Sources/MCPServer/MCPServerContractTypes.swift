import Foundation
import MCP

public enum GuestScriptLanguage: String, Sendable, Equatable {
    case python
    case swift

    public var verifierID: String {
        switch self {
        case .python:
            return "python-check-v1"
        case .swift:
            return "swift-check-v1"
        }
    }

    public static func resolve(arguments: [String: Value], script: String) -> GuestScriptLanguage {
        if let raw = arguments["language"]?.stringValue?.lowercased() {
            switch raw {
            case "python", "py":
                return .python
            case "swift":
                return .swift
            default:
                break
            }
        }
        if script.contains("import Foundation") || script.contains("import Swift") {
            return .swift
        }
        return .python
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
