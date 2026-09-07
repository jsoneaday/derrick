import DBRepository
import Foundation
import Structure

enum ConnectorAuthDiscoverWorkflow {
    static func run(
        workflowID: String,
        request: WorkflowStartRequest,
        baseContext: ExecutionContextWire,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository,
        executeTool: @escaping (
            String,
            String,
            ExecutionContextWire,
            ServicePrincipal,
            String?,
            String?,
            String,
            String
        ) async throws -> MCPToolCallResultDTO
    ) async throws {
        let input = try ConnectorAuthDiscoverInput.decodeJSON(request.inputJSON)
        guard input.vendor.isSelectableInWizard else {
            try await fail(
                workflowID: workflowID,
                stage: "vendor",
                message: "Only Slack connectors can be created right now.",
                repositoryProvider: repositoryProvider
            )
            return
        }
        guard let docURL = input.vendor.authenticationDocumentationStartURL else {
            try await complete(
                workflowID: workflowID,
                summary: "",
                repositoryProvider: repositoryProvider
            )
            return
        }

        try await log(
            workflowID: workflowID,
            stage: "auth",
            message: "Reading how \(input.vendor.displayName) authenticates…",
            repositoryProvider: repositoryProvider
        )
        let crawlArgs = try crawlArguments(startURL: docURL, vendor: input.vendor)
        let crawlResult = try await executeTool(
            AllowedMCPTool.webCrawl.rawValue,
            crawlArgs,
            baseContext,
            request.principal,
            request.helperAPIKey,
            request.helperReviewerModelJSON,
            workflowID,
            "auth"
        )
        if crawlResult.isError {
            try await fail(
                workflowID: workflowID,
                stage: "auth",
                message: userFacingToolError(
                    crawlResult,
                    fallback: "Could not read \(input.vendor.displayName) authentication docs."
                ),
                repositoryProvider: repositoryProvider
            )
            return
        }
        let summary = extractCrawlSummary(from: crawlResult.text) ?? ""
        try await complete(
            workflowID: workflowID,
            summary: summary,
            repositoryProvider: repositoryProvider
        )
    }

    private static func crawlArguments(
        startURL: String,
        vendor: PluginFactoryCreateInput.ConnectorVendor
    ) throws -> String {
        let payload: [String: Any] = [
            "start_url": startURL,
            "goal": """
            Summarize how a \(vendor.displayName) bot or app authenticates HTTP API calls: \
            token type (bot token, API key, basic auth, or OAuth), required scopes or permissions, \
            and which header or query parameter carries the secret. Ignore unrelated product pages.
            """,
            "max_pages": 6,
            "max_depth": 1,
            "timeout_seconds": 180,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func extractCrawlSummary(from text: String) -> String? {
        guard let outcome = ToolExecutionOutcome.decode(from: text),
              let value = outcome.output?.value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(8_000))
        }
        return String(value.prefix(8_000))
    }

    private static func userFacingToolError(_ result: MCPToolCallResultDTO, fallback: String) -> String {
        if let outcome = ToolExecutionOutcome.decode(from: result.text),
           let summary = outcome.failureSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        let trimmed = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func log(
        workflowID: String,
        stage: String,
        message: String,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async throws {
        let repo = try await repositoryProvider()
        _ = try await repo.appendWorkflowEvent(
            workflowID: workflowID,
            kind: "progress",
            stage: stage,
            message: message
        )
    }

    private static func fail(
        workflowID: String,
        stage: String,
        message: String,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async throws {
        let repo = try await repositoryProvider()
        guard var row = try await repo.workflowRun(id: workflowID) else { return }
        row.status = WorkflowRunStatus.failed.rawValue
        row.errorMessage = message
        row.finishedAt = Date.now
        try await repo.updateWorkflowRun(row)
        _ = try await repo.appendWorkflowEvent(
            workflowID: workflowID,
            kind: "log",
            stage: stage,
            message: message
        )
    }

    private static func complete(
        workflowID: String,
        summary: String,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async throws {
        let repo = try await repositoryProvider()
        guard var row = try await repo.workflowRun(id: workflowID) else { return }
        let resultJSON = try JSONEncoder.service.encode(ConnectorAuthDiscoverResult(crawlSummary: summary))
        row.status = WorkflowRunStatus.completed.rawValue
        row.resultJSON = String(decoding: resultJSON, as: UTF8.self)
        row.errorMessage = nil
        row.finishedAt = Date.now
        try await repo.updateWorkflowRun(row)
        _ = try await repo.appendWorkflowEvent(
            workflowID: workflowID,
            kind: "progress",
            stage: "complete",
            message: "Finished reading authentication docs."
        )
    }
}
