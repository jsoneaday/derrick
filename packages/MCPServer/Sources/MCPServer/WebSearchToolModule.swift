import Foundation
import MCP
import Structure

/// MCP boundary for DuckDuckGo search in the unified Go worker image.
public enum WebSearchToolModule: MCPToolModule {
    public static let id: AllowedMCPTool = .webSearch
    public static let defaultTimeoutSeconds = 30
    public static let maximumTimeoutSeconds = 60

    public static var inputSchema: Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Web search query. Use this to find pages; then call web.crawl on a chosen URL.")
                ]),
                "max_results": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum result links to return (1...10; default 8).")
                ]),
                "timeout_seconds": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum search time in seconds (1...60; default 30).")
                ])
            ]),
            "required": .array([
                .string("query")
            ])
        ])
    }

    public static func makeRegistration(
        run: @escaping @Sendable (_ input: Data, _ timeoutSeconds: Int) async throws -> DockerCLIResult
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: id,
            description: id.defaultDescription,
            inputSchema: inputSchema
        ) { arguments in
            do {
                let request = try makeRequest(arguments: arguments)
                let data = try JSONEncoder().encode(request)
                let dockerResult = try await run(data, request.timeoutSeconds)
                guard dockerResult.exitCode == 0 else {
                    return try failure(
                        status: .failed,
                        stage: .execution,
                        code: "web_search_worker_failed",
                        message: workerError(dockerResult)
                    ).encodedJSON()
                }

                do {
                    try GuestContractValidation.validateWebSearchResultJSON(dockerResult.stdout)
                } catch {
                    return try failure(
                        status: .failed,
                        stage: .execution,
                        code: "web_search_invalid_output",
                        message: "Search returned invalid JSON output."
                    ).encodedJSON()
                }

                guard let result = try? JSONDecoder().decode(
                    WebSearchWireResult.self,
                    from: dockerResult.stdout
                ) else {
                    return try failure(
                        status: .failed,
                        stage: .execution,
                        code: "web_search_invalid_output",
                        message: "Search returned invalid JSON output."
                    ).encodedJSON()
                }

                // Empty hits are a successful search with nothing to crawl, not a tool crash.
                return try ToolExecutionOutcome.completed(
                    output: ToolExecutionOutcome.Output(
                        format: .json,
                        value: String(decoding: dockerResult.stdout, as: UTF8.self)
                    ),
                    diagnostics: result.diagnostics.map {
                        ToolExecutionOutcome.Diagnostic(
                            severity: result.ok ? .warning : .info,
                            code: "web_search_diagnostic",
                            message: $0
                        )
                    },
                    exitCode: dockerResult.exitCode
                ).encodedJSON()
            } catch let error as WebSearchToolError {
                return try failure(
                    status: .blocked,
                    stage: .validation,
                    code: "web_search_validation",
                    message: error.localizedDescription
                ).encodedJSON()
            } catch {
                return try failure(
                    status: .failed,
                    stage: .execution,
                    code: "web_search_failed",
                    message: error.localizedDescription
                ).encodedJSON()
            }
        }
    }

    private static func makeRequest(
        arguments: [String: Value]
    ) throws -> WebSearchWireRequest {
        let query = stringValue(arguments["query"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxResults = intValue(arguments["max_results"]) ?? 8
        let timeoutSeconds = intValue(arguments["timeout_seconds"]) ?? defaultTimeoutSeconds

        guard !query.isEmpty else { throw WebSearchToolError.emptyQuery }
        guard query.count <= 300 else { throw WebSearchToolError.queryTooLong }
        if let reason = maliciousQueryReason(query) {
            throw WebSearchToolError.maliciousQuery(reason)
        }
        guard (1...10).contains(maxResults) else {
            throw WebSearchToolError.invalidMaxResults
        }
        guard (1...maximumTimeoutSeconds).contains(timeoutSeconds) else {
            throw WebSearchToolError.invalidTimeout
        }

        return WebSearchWireRequest(
            query: query,
            maxResults: maxResults,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func stringValue(_ value: Value?) -> String {
        guard let value else { return "" }
        switch value {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(Int(value))
        case .bool(let value): return value ? "true" : "false"
        default: return ""
        }
    }

    private static func intValue(_ value: Value?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    private static func maliciousQueryReason(_ query: String) -> String? {
        let normalized = query
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let patterns: [(String, String)] = [
            ("ddos", "distributed denial-of-service behavior is not allowed."),
            ("denial of service", "denial-of-service behavior is not allowed."),
            ("dos attack", "denial-of-service behavior is not allowed."),
            ("flood", "flooding a website is not allowed."),
            ("port scan", "port scanning is not a web search."),
            ("brute force", "brute-force activity is not allowed.")
        ]
        return patterns.first { normalized.contains($0.0) }?.1
    }

    private static func workerError(_ result: DockerCLIResult) -> String {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? "Search worker exited with \(result.exitCode)." : stderr
    }

    private static func failure(
        status: ToolExecutionOutcome.Status,
        stage: ToolExecutionOutcome.Stage,
        code: String,
        message: String,
        output: String? = nil
    ) -> ToolExecutionOutcome {
        ToolExecutionOutcome(
            status: status,
            stage: stage,
            output: output.map {
                ToolExecutionOutcome.Output(format: .json, value: $0)
            },
            diagnostics: [
                ToolExecutionOutcome.Diagnostic(
                    code: code,
                    message: message.isEmpty ? "Search failed without diagnostics." : message
                )
            ],
            retry: ToolExecutionOutcome.Retry(allowed: false)
        )
    }
}

private struct WebSearchWireRequest: Encodable, Sendable {
    let query: String
    let maxResults: Int
    let timeoutSeconds: Int

    enum CodingKeys: String, CodingKey {
        case query
        case maxResults = "max_results"
        case timeoutSeconds = "timeout_seconds"
    }
}

private struct WebSearchWireResult: Decodable, Sendable {
    let ok: Bool
    let diagnostics: [String]

    enum CodingKeys: String, CodingKey {
        case ok
        case diagnostics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        diagnostics = try container.decodeIfPresent([String].self, forKey: .diagnostics) ?? []
    }
}

private enum WebSearchToolError: Error, LocalizedError, Sendable {
    case emptyQuery
    case queryTooLong
    case maliciousQuery(String)
    case invalidMaxResults
    case invalidTimeout

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "A search query is required."
        case .queryTooLong:
            return "The search query is too long."
        case .maliciousQuery(let reason):
            return "Search blocked: \(reason)"
        case .invalidMaxResults:
            return "max_results must be between 1 and 10."
        case .invalidTimeout:
            return "timeout_seconds must be between 1 and 60."
        }
    }
}
