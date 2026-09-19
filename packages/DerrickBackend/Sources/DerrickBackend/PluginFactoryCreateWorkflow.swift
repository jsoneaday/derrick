import DBRepository
import Foundation
import Structure

/// Host-orchestrated plugin create: validate → Agent Plugin spec → vendor docs → factory build → promote.
/// Builder/review/trial still run inside `plugin_factory_build`, but the workflow logs finer stages and
/// maps tool failures to the matching stage for the UI.
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

    typealias ExecuteTool = (
        String,
        String,
        ExecutionContextWire,
        ServicePrincipal,
        String?,
        String?,
        String,
        String
    ) async throws -> MCPToolCallResultDTO

    static func run(
        workflowID: String,
        request: WorkflowStartRequest,
        baseContext: ExecutionContextWire,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository,
        executeTool: @escaping ExecuteTool
    ) async throws {
        try await log(
            workflowID: workflowID,
            stage: "validate",
            message: "Checking plugin create inputs…",
            repositoryProvider: repositoryProvider
        )
        let input = try PluginFactoryCreateInput.decodeJSON(request.inputJSON)
        guard input.pluginType == .connector || input.pluginType == .custom else {
            try await fail(
                workflowID: workflowID,
                stage: "type",
                message: "This plugin type cannot be built in the factory.",
                repositoryProvider: repositoryProvider
            )
            return
        }
        guard let pluginID = input.pluginID, !pluginID.isEmpty else {
            try await fail(
                workflowID: workflowID,
                stage: "name",
                message: "Name this plugin before creating it.",
                repositoryProvider: repositoryProvider
            )
            return
        }
        guard !input.description.isEmpty else {
            try await fail(
                workflowID: workflowID,
                stage: "description",
                message: "Describe what the plugin should do, then try again.",
                repositoryProvider: repositoryProvider
            )
            return
        }

        let spec = try await AgentPluginSpecFetch.resolve(
            workflowID: workflowID,
            request: request,
            baseContext: baseContext,
            executeTool: executeTool,
            log: { message in
                try await log(
                    workflowID: workflowID,
                    stage: "spec",
                    message: message,
                    repositoryProvider: repositoryProvider
                )
            }
        )

        if input.pluginType == .custom {
            try await runCustomBuild(
                workflowID: workflowID,
                request: request,
                input: input,
                pluginID: pluginID,
                spec: spec,
                baseContext: baseContext,
                repositoryProvider: repositoryProvider,
                executeTool: executeTool
            )
            return
        }

        guard let vendor = input.vendor else {
            try await fail(
                workflowID: workflowID,
                stage: "vendor",
                message: "Could not determine which messaging service this plugin targets.",
                repositoryProvider: repositoryProvider
            )
            return
        }
        guard let rawAuth = input.auth else {
            try await fail(
                workflowID: workflowID,
                stage: "auth",
                message: "Save the plugin credentials before creating it.",
                repositoryProvider: repositoryProvider
            )
            return
        }
        let auth = rawAuth.preferringCallCredential()
        guard auth.authScheme.isSupportedInWizard else {
            try await fail(
                workflowID: workflowID,
                stage: "auth",
                message: "OAuth connectors are not available yet. Use a bot token or API key.",
                repositoryProvider: repositoryProvider
            )
            return
        }

        var crawlSummary: String? = auth.crawlSummary
        if crawlSummary == nil {
            let sourceName = input.customVendorName ?? vendor.displayName
            let page = try await VendorDocsFetch.resolve(
                sourceName: sourceName,
                documentationURL: nil,
                workflowID: workflowID,
                request: request,
                baseContext: baseContext,
                executeTool: executeTool,
                log: { message in
                    try await log(
                        workflowID: workflowID,
                        stage: "docs",
                        message: message,
                        repositoryProvider: repositoryProvider
                    )
                }
            )
            switch page {
            case .page(let fetched):
                crawlSummary = fetched.summary
            case .failed:
                crawlSummary = nil
                try await log(
                    workflowID: workflowID,
                    stage: "docs",
                    message: "Continuing without vendor setup docs.",
                    repositoryProvider: repositoryProvider
                )
            }
        } else {
            try await log(
                workflowID: workflowID,
                stage: "docs",
                message: "Using the auth docs already read for this connector.",
                repositoryProvider: repositoryProvider
            )
        }

        var inboxAPISummary: String?
        let sourceName = input.customVendorName ?? vendor.displayName
        let inboxPage = try await VendorDocsFetch.resolve(
            sourceName: sourceName,
            documentationURL: nil,
            workflowID: workflowID,
            request: request,
            baseContext: baseContext,
            executeTool: executeTool,
            log: { message in
                try await log(
                    workflowID: workflowID,
                    stage: "docs",
                    message: message,
                    repositoryProvider: repositoryProvider
                )
            },
            purpose: .inboxAPI
        )
        switch inboxPage {
        case .page(let fetched):
            inboxAPISummary = fetched.summary
        case .failed:
            inboxAPISummary = nil
            try await log(
                workflowID: workflowID,
                stage: "docs",
                message: "Continuing without conversation API docs.",
                repositoryProvider: repositoryProvider
            )
        }

        try await log(
            workflowID: workflowID,
            stage: "skill",
            message: "Building Agent Plugin package (spec + guest)…",
            repositoryProvider: repositoryProvider
        )
        try await log(
            workflowID: workflowID,
            stage: "builder",
            message: "Building \(vendor.displayName) connector — draft, trial, then safety review…",
            repositoryProvider: repositoryProvider
        )
        let goal = input.connectorBuildGoal(
            crawlSummary: crawlSummary,
            inboxAPISummary: inboxAPISummary,
            agentPluginSpecSummary: spec.summary,
            agentPluginSpecSourceURL: spec.sourceURL
        )
        let buildArgs = try buildArguments(goal: goal, hostManifest: input.hostManifest)
        let buildResult = try await executeTool(
            AllowedMCPTool.pluginFactoryBuild.rawValue,
            buildArgs,
            baseContext,
            request.principal,
            request.helperAPIKey,
            request.helperReviewerModelJSON,
            workflowID,
            "builder"
        )
        if buildResult.isError {
            try await fail(
                workflowID: workflowID,
                stage: failureStage(from: buildResult, fallback: "builder"),
                message: userFacingToolError(
                    buildResult,
                    fallback: "Plugin factory could not finish building the connector."
                ),
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
                stage: "builder",
                message: PluginFactoryCreateFailureMessage.userFacing(raw),
                repositoryProvider: repositoryProvider
            )
            return
        }

        try await log(
            workflowID: workflowID,
            stage: "promote",
            message: "Saving /\(pluginID)…",
            repositoryProvider: repositoryProvider
        )
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
            message: "\(vendor.displayName) connector saved as /\(pluginID).",
            resultJSON: resultText,
            repositoryProvider: repositoryProvider
        )
    }

    private static func runCustomBuild(
        workflowID: String,
        request: WorkflowStartRequest,
        input: PluginFactoryCreateInput,
        pluginID: String,
        spec: AgentPluginSpecFetch.Document,
        baseContext: ExecutionContextWire,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository,
        executeTool: @escaping ExecuteTool
    ) async throws {
        try await log(
            workflowID: workflowID,
            stage: "skill",
            message: "Building Agent Plugin package (spec + guest)…",
            repositoryProvider: repositoryProvider
        )
        try await log(
            workflowID: workflowID,
            stage: "builder",
            message: "Building the guest program and running trial tests…",
            repositoryProvider: repositoryProvider
        )
        let goal = input.customBuildGoal(
            agentPluginSpecSummary: spec.summary,
            agentPluginSpecSourceURL: spec.sourceURL
        )
        let buildArgs = try buildArguments(goal: goal, hostManifest: nil)
        let buildResult = try await executeTool(
            AllowedMCPTool.pluginFactoryBuild.rawValue,
            buildArgs,
            baseContext,
            request.principal,
            request.helperAPIKey,
            request.helperReviewerModelJSON,
            workflowID,
            "builder"
        )
        if buildResult.isError {
            try await fail(
                workflowID: workflowID,
                stage: failureStage(from: buildResult, fallback: "builder"),
                message: userFacingToolError(
                    buildResult,
                    fallback: "Plugin factory could not finish building the plugin."
                ),
                repositoryProvider: repositoryProvider
            )
            return
        }

        guard let summary = decodeBuildResult(buildResult.text),
              summary.ok != false,
              let savedID = summary.pluginID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !savedID.isEmpty
        else {
            let decoded = decodeBuildResult(buildResult.text)
            let raw = decoded?.error
                ?? decoded?.reviewSummary
                ?? "Plugin factory did not return a saved plugin."
            try await fail(
                workflowID: workflowID,
                stage: "builder",
                message: PluginFactoryCreateFailureMessage.userFacing(raw),
                repositoryProvider: repositoryProvider
            )
            return
        }

        try await log(
            workflowID: workflowID,
            stage: "promote",
            message: "Saving /\(savedID)…",
            repositoryProvider: repositoryProvider
        )
        let resultJSON = try JSONEncoder.service.encode(
            PluginFactoryCreateResult(
                pluginID: savedID,
                version: summary.version ?? "1.0.0",
                vendor: "custom",
                reviewSummary: summary.reviewSummary ?? ""
            )
        )
        let resultText = String(decoding: resultJSON, as: UTF8.self)
        try await complete(
            workflowID: workflowID,
            message: "Plugin saved as /\(savedID).",
            resultJSON: resultText,
            repositoryProvider: repositoryProvider
        )
    }

    private static func buildArguments(goal: String, hostManifest: PluginFactoryManifestInput?) throws -> String {
        var payload: [String: Any] = ["goal": goal]
        if let hostManifest {
            payload["host_manifest_json"] = try hostManifest.encodedJSON()
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
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

    private static func failureStage(from result: MCPToolCallResultDTO, fallback: String) -> String {
        guard let outcome = ToolExecutionOutcome.decode(from: result.text) else {
            return fallback
        }
        switch outcome.stage {
        case .review:
            return "review"
        case .validation:
            return "package"
        case .compilation:
            return "package"
        case .execution:
            return "trial"
        case .none, .network, .timeout, .persistence:
            return fallback
        }
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
