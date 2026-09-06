import DBRepository
import Foundation
import Structure

enum PluginFactoryCreateWorkflow {
    private struct FactoryBuildResult: Decodable {
        let ok: Bool?
        let pluginID: String?
        let version: String?
        let reviewSummary: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case pluginID = "plugin_id"
            case version
            case reviewSummary = "review_summary"
            case error
        }
    }

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
        let input = try PluginFactoryCreateInput.decodeJSON(request.inputJSON)
        guard input.pluginType == .connector else {
            try await fail(
                workflowID: workflowID,
                stage: "type",
                message: "Only connector plugins are supported today. News reader and custom types are coming soon.",
                repositoryProvider: repositoryProvider
            )
            return
        }
        guard let vendor = input.vendor else {
            try await fail(
                workflowID: workflowID,
                stage: "vendor",
                message: "Choose a messaging vendor for this connector.",
                repositoryProvider: repositoryProvider
            )
            return
        }
        guard !input.description.isEmpty else {
            try await fail(
                workflowID: workflowID,
                stage: "description",
                message: "Choose a vendor and create the connector again.",
                repositoryProvider: repositoryProvider
            )
            return
        }

        var crawlSummary: String?
        if let docURL = vendor.documentationStartURL {
            try await log(
                workflowID: workflowID,
                stage: "docs",
                message: "Reading \(vendor.displayName) API docs. This can take a minute…",
                repositoryProvider: repositoryProvider
            )
            let crawlArgs = try crawlArguments(startURL: docURL, vendor: vendor, scope: input.scope)
            let crawlResult = try await executeTool(
                AllowedMCPTool.webCrawl.rawValue,
                crawlArgs,
                baseContext,
                request.principal,
                request.helperAPIKey,
                request.helperReviewerModelJSON,
                workflowID,
                "docs"
            )
            if crawlResult.isError {
                try await fail(
                    workflowID: workflowID,
                    stage: "docs",
                    message: userFacingToolError(crawlResult, fallback: "Could not read vendor API documentation."),
                    repositoryProvider: repositoryProvider
                )
                return
            }
            crawlSummary = extractCrawlSummary(from: crawlResult.text)
        } else {
            try await log(
                workflowID: workflowID,
                stage: "docs",
                message: "Skipping vendor doc crawl for a custom connector.",
                repositoryProvider: repositoryProvider
            )
        }

        try await log(
            workflowID: workflowID,
            stage: "factory",
            message: "Building \(vendor.displayName) connector — waiting on the plugin builder, then tests and safety review…",
            repositoryProvider: repositoryProvider
        )
        let goal = input.connectorBuildGoal(crawlSummary: crawlSummary)
        let buildArgs = try buildArguments(goal: goal)
        let buildResult = try await executeTool(
            AllowedMCPTool.pluginFactoryBuild.rawValue,
            buildArgs,
            baseContext,
            request.principal,
            request.helperAPIKey,
            request.helperReviewerModelJSON,
            workflowID,
            "factory"
        )
        if buildResult.isError {
            try await fail(
                workflowID: workflowID,
                stage: "factory",
                message: userFacingToolError(buildResult, fallback: "Plugin factory could not finish building the connector."),
                repositoryProvider: repositoryProvider
            )
            return
        }

        guard let summary = decodeBuildResult(buildResult.text),
              summary.ok != false,
              let pluginID = summary.pluginID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pluginID.isEmpty
        else {
            let decoded = decodeBuildResult(buildResult.text)
            let raw = decoded?.error
                ?? decoded?.reviewSummary
                ?? "Plugin factory did not return a saved connector."
            try await fail(
                workflowID: workflowID,
                stage: "factory",
                message: PluginFactoryCreateFailureMessage.userFacing(raw),
                repositoryProvider: repositoryProvider
            )
            return
        }

        let resultJSON = try JSONEncoder.service.encode(
            PluginFactoryCreateResult(
                pluginID: pluginID,
                version: summary.version ?? "1.0.0",
                vendor: vendor.rawValue,
                reviewSummary: summary.reviewSummary ?? ""
            )
        )
        let resultText = String(decoding: resultJSON, as: UTF8.self)
        try await complete(
            workflowID: workflowID,
            message: "\(vendor.displayName) connector saved as /\(pluginID). Enter credentials to finish setup.",
            resultJSON: resultText,
            repositoryProvider: repositoryProvider
        )
    }

    private static func crawlArguments(
        startURL: String,
        vendor: PluginFactoryCreateInput.ConnectorVendor,
        scope: PluginFactoryCreateInput.ConnectorScope
    ) throws -> String {
        let product = PluginFactoryCreateInput.defaultDescription(
            vendor: vendor,
            customVendorName: nil,
            scope: scope
        )
        let payload: [String: Any] = [
            "start_url": startURL,
            "goal": "Summarize \(vendor.displayName) bot/API authentication and message send/receive endpoints for: \(product)",
            "max_pages": 12,
            "max_depth": 2,
            "timeout_seconds": 420,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func buildArguments(goal: String) throws -> String {
        let payload = ["goal": goal]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func extractCrawlSummary(from text: String) -> String? {
        guard let outcome = ToolExecutionOutcome.decode(from: text),
              let value = outcome.output?.value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(12_000))
        }
        return String(value.prefix(12_000))
    }

    private static func decodeBuildResult(_ text: String) -> FactoryBuildResult? {
        guard let data = text.data(using: .utf8) else { return nil }
        if let outcome = ToolExecutionOutcome.decode(from: text),
           let value = outcome.output?.value,
           let inner = value.data(using: .utf8),
           let summary = try? JSONDecoder.service.decode(FactoryBuildResult.self, from: inner) {
            return summary
        }
        return try? JSONDecoder.service.decode(FactoryBuildResult.self, from: data)
    }

    private static func userFacingToolError(_ result: MCPToolCallResultDTO, fallback: String) -> String {
        if let outcome = ToolExecutionOutcome.decode(from: result.text),
           let summary = outcome.failureSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return PluginFactoryCreateFailureMessage.userFacing(summary)
        }
        let trimmed = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return PluginFactoryCreateFailureMessage.userFacing(trimmed.isEmpty ? fallback : trimmed)
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
        message: String,
        resultJSON: String,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async throws {
        let repo = try await repositoryProvider()
        guard var row = try await repo.workflowRun(id: workflowID) else { return }
        row.status = WorkflowRunStatus.completed.rawValue
        row.resultJSON = resultJSON
        row.errorMessage = nil
        row.finishedAt = Date.now
        try await repo.updateWorkflowRun(row)
        _ = try await repo.appendWorkflowEvent(
            workflowID: workflowID,
            kind: "progress",
            stage: "complete",
            message: message
        )
    }
}
