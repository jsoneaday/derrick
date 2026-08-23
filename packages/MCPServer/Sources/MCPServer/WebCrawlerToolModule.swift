import Foundation
import MCP
import MCPToolCatalog
import ServiceContracts

/// MCP boundary for the prebuilt Swift crawler image.
///
/// The crawler is intentionally not generated source. This module validates
/// the small request contract, invokes the isolated worker, and translates its
/// JSON result into the common tool outcome.
public enum WebCrawlerToolModule: MCPToolModule {
    public static let id: AllowedMCPTool = .webCrawl

    public static var inputSchema: Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "start_url": .object([
                    "type": .string("string"),
                    "description": .string("HTTP(S) URL where the bounded crawl starts.")
                ]),
                "goal": .object([
                    "type": .string("string"),
                    "description": .string("What to find or summarize. Required for safety review.")
                ]),
                "max_pages": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum pages to visit (1...100; default 10).")
                ]),
                "max_depth": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum link depth from the start page (0...5; default 2).")
                ]),
                "timeout_seconds": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum crawl time in seconds (1...900; hard maximum 15 minutes).")
                ])
            ]),
            "required": .array([
                .string("start_url"),
                .string("goal")
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
                        code: "web_crawl_worker_failed",
                        message: workerError(dockerResult)
                    ).encodedJSON()
                }

                guard let result = try? JSONDecoder().decode(
                    WebCrawlerWireResult.self,
                    from: dockerResult.stdout
                ) else {
                    return try failure(
                        status: .failed,
                        stage: .execution,
                        code: "web_crawl_invalid_output",
                        message: "Crawler returned invalid JSON output."
                    ).encodedJSON()
                }

                if result.ok {
                    return try ToolExecutionOutcome.completed(
                        output: ToolExecutionOutcome.Output(
                            format: .json,
                            value: String(decoding: dockerResult.stdout, as: UTF8.self)
                        ),
                        diagnostics: result.diagnostics.map {
                            ToolExecutionOutcome.Diagnostic(
                                severity: .warning,
                                code: "web_crawl_diagnostic",
                                message: $0
                            )
                        },
                        exitCode: dockerResult.exitCode
                    ).encodedJSON()
                }

                let status: ToolExecutionOutcome.Status =
                    result.stopReason == "timeout" ? .timeout
                    : result.stopReason == "blocked" ? .blocked
                    : .failed
                let stage: ToolExecutionOutcome.Stage =
                    result.stopReason == "timeout" ? .timeout
                    : result.stopReason == "blocked" ? .validation
                    : .execution
                return try failure(
                    status: status,
                    stage: stage,
                    code: "web_crawl_failed",
                    message: result.diagnostics.joined(separator: "; "),
                    output: String(decoding: dockerResult.stdout, as: UTF8.self),
                    timedOut: status == .timeout
                ).encodedJSON()
            } catch let error as WebCrawlerToolError {
                return try failure(
                    status: .blocked,
                    stage: .validation,
                    code: "web_crawl_validation",
                    message: error.localizedDescription
                ).encodedJSON()
            } catch {
                return try failure(
                    status: .failed,
                    stage: .execution,
                    code: "web_crawl_failed",
                    message: error.localizedDescription
                ).encodedJSON()
            }
        }
    }

    private static func makeRequest(
        arguments: [String: Value]
    ) throws -> WebCrawlerWireRequest {
        let startURL = stringValue(arguments["start_url"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = stringValue(arguments["goal"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxPages = intValue(arguments["max_pages"]) ?? 10
        let maxDepth = intValue(arguments["max_depth"]) ?? 2
        let timeoutSeconds = intValue(arguments["timeout_seconds"]) ?? 120

        guard !startURL.isEmpty else { throw WebCrawlerToolError.invalidStartURL }
        guard let url = URL(string: startURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil
        else {
            throw WebCrawlerToolError.invalidStartURL
        }
        guard !goal.isEmpty else { throw WebCrawlerToolError.emptyGoal }
        guard goal.count <= 2_000 else { throw WebCrawlerToolError.goalTooLong }
        if let reason = maliciousGoalReason(goal) {
            throw WebCrawlerToolError.maliciousGoal(reason)
        }
        guard (1...100).contains(maxPages) else {
            throw WebCrawlerToolError.invalidPages
        }
        guard (0...5).contains(maxDepth) else {
            throw WebCrawlerToolError.invalidDepth
        }
        guard (1...900).contains(timeoutSeconds) else {
            throw WebCrawlerToolError.invalidTimeout
        }

        return WebCrawlerWireRequest(
            startURL: startURL,
            goal: goal,
            maxPages: maxPages,
            maxDepth: maxDepth,
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

    private static func maliciousGoalReason(_ goal: String) -> String? {
        let normalized = goal
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let patterns: [(String, String)] = [
            ("ddos", "distributed denial-of-service behavior is not allowed."),
            ("denial of service", "denial-of-service behavior is not allowed."),
            ("dos attack", "denial-of-service behavior is not allowed."),
            ("flood", "flooding a website is not allowed."),
            ("hammer", "repeatedly hammering a website is not allowed."),
            ("stress test", "load or stress testing a third-party website is not allowed."),
            ("load test", "load or stress testing a third-party website is not allowed."),
            ("port scan", "port scanning is not a web crawl."),
            ("brute force", "brute-force activity is not allowed."),
            ("infinite loop", "unbounded or infinite crawling is not allowed."),
            ("loop forever", "unbounded or infinite crawling is not allowed."),
            ("crawl forever", "unbounded or infinite crawling is not allowed."),
            ("never stop crawling", "unbounded or infinite crawling is not allowed."),
            ("unbounded crawl", "unbounded or infinite crawling is not allowed.")
        ]
        return patterns.first { normalized.contains($0.0) }?.1
    }

    private static func workerError(_ result: DockerCLIResult) -> String {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? "Crawler worker exited with \(result.exitCode)." : stderr
    }

    private static func failure(
        status: ToolExecutionOutcome.Status,
        stage: ToolExecutionOutcome.Stage,
        code: String,
        message: String,
        output: String? = nil,
        timedOut: Bool = false
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
                    message: message.isEmpty ? "Crawler failed without diagnostics." : message
                )
            ],
            retry: ToolExecutionOutcome.Retry(allowed: false),
            timedOut: timedOut
        )
    }
}

private struct WebCrawlerWireRequest: Encodable, Sendable {
    let startURL: String
    let goal: String
    let maxPages: Int
    let maxDepth: Int
    let timeoutSeconds: Int

    enum CodingKeys: String, CodingKey {
        case startURL = "start_url"
        case goal
        case maxPages = "max_pages"
        case maxDepth = "max_depth"
        case timeoutSeconds = "timeout_seconds"
    }
}

private struct WebCrawlerWireResult: Decodable, Sendable {
    let ok: Bool
    let stopReason: String
    let diagnostics: [String]

    enum CodingKeys: String, CodingKey {
        case ok
        case stopReason = "stop_reason"
        case diagnostics
    }
}

private enum WebCrawlerToolError: Error, LocalizedError, Sendable {
    case invalidStartURL
    case emptyGoal
    case goalTooLong
    case maliciousGoal(String)
    case invalidPages
    case invalidDepth
    case invalidTimeout

    var errorDescription: String? {
        switch self {
        case .invalidStartURL:
            return "start_url must be an http or https URL without embedded credentials."
        case .emptyGoal:
            return "A crawl goal is required."
        case .goalTooLong:
            return "The crawl goal is too long."
        case .maliciousGoal(let reason):
            return "Crawl blocked: \(reason)"
        case .invalidPages:
            return "max_pages must be between 1 and 100."
        case .invalidDepth:
            return "max_depth must be between 0 and 5."
        case .invalidTimeout:
            return "timeout_seconds must be between 1 and 900."
        }
    }
}
