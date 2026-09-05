import DBRepository
import Foundation
import Structure
import Testing
@testable import DerrickBackend

@Suite struct WorkflowRuntimeEngineTests {
    @Test func startWorkflowDedupesBySessionKindAndInput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )
        let repository = DBRepository(configuration: configuration)
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let previousMCP = InProcessServiceBridges.mcpCallTool
        defer { InProcessServiceBridges.mcpCallTool = previousMCP }

        InProcessServiceBridges.mcpCallTool = { request in
            switch request.toolName {
            case "web.crawl":
                let pages = #"{"pages":[{"url":"https://api.slack.com/docs","title":"Slack","text":"auth"}]}"#
                let outcome = try ToolExecutionOutcome.completed(
                    output: ToolExecutionOutcome.Output(format: .json, value: pages)
                ).encodedJSON()
                return MCPToolCallResultDTO(
                    requestID: request.requestID,
                    ok: true,
                    isError: false,
                    text: outcome
                )
            case "plugin_factory_build":
                let receipt = """
                {"plugin_id":"slack-connector","version":"1.0.0","content_hash":"abc","review_summary":"ok","secrets":[]}
                """
                let outcome = try ToolExecutionOutcome.completed(
                    output: ToolExecutionOutcome.Output(format: .json, value: receipt)
                ).encodedJSON()
                return MCPToolCallResultDTO(
                    requestID: request.requestID,
                    ok: true,
                    isError: false,
                    text: outcome
                )
            default:
                return MCPToolCallResultDTO(
                    requestID: request.requestID,
                    ok: false,
                    isError: true,
                    text: "",
                    message: "unexpected tool \(request.toolName)"
                )
            }
        }

        let request = WorkflowStartRequest(
            kind: .pluginFactoryCreate,
            sessionID: "session-1",
            agentID: "ui",
            inputJSON: "slack connector",
            principal: .agent(sessionID: "session-1", agentID: "ui")
        )
        let provider: @Sendable () async throws -> DBRepository = { repository }
        let first = try await WorkflowRuntimeEngine.shared.startWorkflow(request, repositoryProvider: provider)
        let second = try await WorkflowRuntimeEngine.shared.startWorkflow(request, repositoryProvider: provider)
        #expect(first.deduplicated == false)
        #expect(second.deduplicated == true)
        #expect(first.workflowID == second.workflowID)

        var status = WorkflowRunStatus.running
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let poll = try await WorkflowRuntimeEngine.shared.pollWorkflowUpdate(
                WorkflowPollRequest(workflowID: first.workflowID, afterSeq: 0),
                repositoryProvider: provider
            )
            status = poll.status
            if status != .running { break }
        }
        #expect(status == .failed)
    }

    @Test func startWorkflowAfterFailureStartsFreshRun() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )
        let repository = DBRepository(configuration: configuration)
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let idempotencyKey = WorkflowRuntimeIdempotency.key(
            sessionID: "session-retry",
            kind: .pluginFactoryCreate,
            inputJSON: "slack connector"
        )
        try await repository.insertWorkflowRun(
            WorkflowRunRow(
                id: "wf-old",
                kind: WorkflowKind.pluginFactoryCreate.rawValue,
                status: WorkflowRunStatus.failed.rawValue,
                contextJSON: "{}",
                inputJSON: "slack connector",
                idempotencyKey: idempotencyKey,
                errorMessage: "Plugin factory build failed.",
                createdAt: Date(),
                finishedAt: Date()
            )
        )

        let previousMCP = InProcessServiceBridges.mcpCallTool
        defer { InProcessServiceBridges.mcpCallTool = previousMCP }
        InProcessServiceBridges.mcpCallTool = { request in
            let outcome = try ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: #"{"pages":[]}"#)
            ).encodedJSON()
            return MCPToolCallResultDTO(
                requestID: request.requestID,
                ok: true,
                isError: false,
                text: outcome
            )
        }

        let request = WorkflowStartRequest(
            kind: .pluginFactoryCreate,
            sessionID: "session-retry",
            agentID: "ui",
            inputJSON: "slack connector",
            principal: .agent(sessionID: "session-retry", agentID: "ui")
        )
        let provider: @Sendable () async throws -> DBRepository = { repository }
        let handle = try await WorkflowRuntimeEngine.shared.startWorkflow(request, repositoryProvider: provider)
        #expect(handle.deduplicated == false)
        #expect(handle.workflowID != "wf-old")
        #expect(handle.status == .running)
    }
}
