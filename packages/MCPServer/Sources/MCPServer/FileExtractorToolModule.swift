import Foundation
import MCP
import MCPToolCatalog
import ServiceContracts

public enum FileExtractorToolModule: MCPToolModule {
    public static let id: AllowedMCPTool = .filesExtract
    public static let defaultTimeoutSeconds = 120
    public static let maximumTimeoutSeconds = 180

    public static var inputSchema: Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "operation": .object([
                    "type": .string("string"),
                    "description": .string("extract (text/markdown) or convert (csv↔xlsx, pdf/docx/html→markdown). Default extract.")
                ]),
                "output_format": .object([
                    "type": .string("string"),
                    "description": .string("markdown, txt, csv, or xlsx. Default markdown.")
                ]),
                "filenames": .object([
                    "type": .string("array"),
                    "description": .string("Original attached file names. Omit to process every file in this chat.")
                ]),
                "timeout_seconds": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum worker time in seconds (1...180; default 120).")
                ])
            ])
        ])
    }

    public static func makeRegistration(
        sessionID: @escaping @Sendable () -> String?,
        prepareWorkspace: @escaping @Sendable (_ sessionID: String, _ filenames: [String]?) throws -> FileJobWorkspace = {
            try FileJobWorkspace.prepare(sessionID: $0, requestedFilenames: $1)
        },
        run: @escaping @Sendable (
            _ input: Data,
            _ workspace: FileJobWorkspace,
            _ timeoutSeconds: Int
        ) async throws -> DockerCLIResult
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: id,
            description: id.defaultDescription,
            inputSchema: inputSchema
        ) { arguments in
            do {
                let parsed = try makeRequest(arguments: arguments)
                guard let sessionID = sessionID()?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !sessionID.isEmpty
                else {
                    throw FileExtractorToolError.missingSession
                }
                let workspace = try prepareWorkspace(sessionID, parsed.filenames)
                defer { workspace.removeJobDirectories() }
                let workerRequest = FileExtractorWireRequest(
                    operation: parsed.operation,
                    outputFormat: parsed.outputFormat,
                    files: workspace.copiedFilenames
                )
                let payload = try JSONEncoder().encode(workerRequest)
                let dockerResult = try await run(payload, workspace, parsed.timeoutSeconds)
                let workerJSON = String(decoding: dockerResult.stdout, as: UTF8.self)
                let worker = (try? JSONDecoder().decode(FileExtractorWireResult.self, from: dockerResult.stdout))
                    ?? FileExtractorWireResult(ok: false, files: [], diagnostics: [workerJSON])
                let exported = (try? workspace.publishOutputs()) ?? []
                if dockerResult.exitCode != 0 && !worker.ok {
                    return try failure(
                        status: .failed,
                        stage: .execution,
                        code: "files_extract_worker_failed",
                        message: worker.diagnostics.joined(separator: "; ").ifEmpty(
                            "File extractor exited \(dockerResult.exitCode)."
                        )
                    ).encodedJSON()
                }
                let hostPayload = FileExtractorHostResult(
                    ok: worker.ok,
                    operation: parsed.operation,
                    exportDirectory: workspace.exportDirectory.path,
                    exportedFiles: exported,
                    files: worker.files,
                    diagnostics: worker.diagnostics
                )
                let encoded = try JSONEncoder().encode(hostPayload)
                if worker.ok {
                    return try ToolExecutionOutcome.completed(
                        output: ToolExecutionOutcome.Output(
                            format: .json,
                            value: String(decoding: encoded, as: UTF8.self)
                        ),
                        exitCode: dockerResult.exitCode
                    ).encodedJSON()
                }
                return try failure(
                    status: .failed,
                    stage: .execution,
                    code: "files_extract_failed",
                    message: worker.diagnostics.joined(separator: "; ").ifEmpty(
                        "File extraction failed."
                    ),
                    output: String(decoding: encoded, as: UTF8.self)
                ).encodedJSON()
            } catch let error as FileExtractorToolError {
                return try failure(
                    status: .blocked,
                    stage: .validation,
                    code: "files_extract_validation",
                    message: error.localizedDescription
                ).encodedJSON()
            } catch let error as FileJobWorkspaceError {
                return try failure(
                    status: .blocked,
                    stage: .validation,
                    code: "files_extract_validation",
                    message: error.localizedDescription
                ).encodedJSON()
            } catch {
                return try failure(
                    status: .failed,
                    stage: .execution,
                    code: "files_extract_failed",
                    message: error.localizedDescription
                ).encodedJSON()
            }
        }
    }

    private static func makeRequest(arguments: [String: Value]) throws -> ParsedRequest {
        let operation = stringValue(arguments["operation"]).lowercased()
        let resolvedOperation = operation.isEmpty ? "extract" : operation
        guard resolvedOperation == "extract" || resolvedOperation == "convert" else {
            throw FileExtractorToolError.invalidOperation
        }
        let format = stringValue(arguments["output_format"]).lowercased()
        let resolvedFormat = format.isEmpty ? "markdown" : format
        guard ["markdown", "txt", "csv", "xlsx"].contains(resolvedFormat) else {
            throw FileExtractorToolError.invalidFormat
        }
        let timeout = intValue(arguments["timeout_seconds"]) ?? defaultTimeoutSeconds
        guard (1...maximumTimeoutSeconds).contains(timeout) else {
            throw FileExtractorToolError.invalidTimeout
        }
        return ParsedRequest(
            operation: resolvedOperation,
            outputFormat: resolvedFormat,
            filenames: stringArray(arguments["filenames"]),
            timeoutSeconds: timeout
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

    private static func stringArray(_ value: Value?) -> [String]? {
        guard let value else { return nil }
        switch value {
        case .array(let values):
            return values.compactMap { item in
                if case .string(let text) = item { return text }
                return nil
            }
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        default:
            return nil
        }
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
            output: output.map { ToolExecutionOutcome.Output(format: .json, value: $0) },
            diagnostics: [
                ToolExecutionOutcome.Diagnostic(code: code, message: message)
            ],
            retry: ToolExecutionOutcome.Retry(allowed: false)
        )
    }
}

private struct ParsedRequest: Sendable {
    let operation: String
    let outputFormat: String
    let filenames: [String]?
    let timeoutSeconds: Int
}

private struct FileExtractorWireRequest: Encodable {
    let operation: String
    let outputFormat: String
    let files: [String]

    enum CodingKeys: String, CodingKey {
        case operation
        case outputFormat = "output_format"
        case files
    }
}

private struct FileExtractorWireResult: Decodable {
    let ok: Bool
    let files: [FileExtractorWireFile]
    let diagnostics: [String]

    init(ok: Bool, files: [FileExtractorWireFile], diagnostics: [String]) {
        self.ok = ok
        self.files = files
        self.diagnostics = diagnostics
    }

    enum CodingKeys: String, CodingKey {
        case ok, files, diagnostics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        files = try container.decodeIfPresent([FileExtractorWireFile].self, forKey: .files) ?? []
        diagnostics = try container.decodeIfPresent([String].self, forKey: .diagnostics) ?? []
    }
}

private struct FileExtractorWireFile: Codable {
    let inputName: String
    let outputName: String?
    let kind: String
    let byteCount: Int
    let preview: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case inputName = "input_name"
        case outputName = "output_name"
        case kind
        case byteCount = "byte_count"
        case preview
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputName = try container.decodeIfPresent(String.self, forKey: .inputName) ?? ""
        outputName = try container.decodeIfPresent(String.self, forKey: .outputName)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

private struct FileExtractorHostResult: Encodable {
    let ok: Bool
    let operation: String
    let exportDirectory: String
    let exportedFiles: [String]
    let files: [FileExtractorWireFile]
    let diagnostics: [String]

    enum CodingKeys: String, CodingKey {
        case ok
        case operation
        case exportDirectory = "export_directory"
        case exportedFiles = "exported_files"
        case files
        case diagnostics
    }
}

private enum FileExtractorToolError: Error, LocalizedError, Sendable {
    case missingSession
    case invalidOperation
    case invalidFormat
    case invalidTimeout

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Open a chat before extracting files."
        case .invalidOperation:
            return "operation must be extract or convert."
        case .invalidFormat:
            return "output_format must be markdown, txt, csv, or xlsx."
        case .invalidTimeout:
            return "timeout_seconds must be between 1 and 180."
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
