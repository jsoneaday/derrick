import DBRepository
import Foundation
import ServiceContracts

public enum WorkflowRuntimeError: Error, LocalizedError, Sendable {
    case mcpUnavailable
    case workflowNotFound
    case unsupportedKind(WorkflowKind)

    public var errorDescription: String? {
        switch self {
        case .mcpUnavailable:
            return "MCP tool host is not available in-process."
        case .workflowNotFound:
            return "Workflow was not found."
        case .unsupportedKind(let kind):
            return "Unsupported workflow kind \(kind.rawValue)."
        }
    }
}

/// Durable workflow coordinator (Process Manager) running inside derrickd.
public actor WorkflowRuntimeEngine {
    public static let shared = WorkflowRuntimeEngine()

    private var runningTasks: [String: Task<Void, Never>] = [:]
    private var cancelledWorkflows: Set<String> = []

    private init() {}

    public func startWorkflow(
        _ request: WorkflowStartRequest,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async throws -> WorkflowHandleDTO {
        let repo = try await repositoryProvider()
        let idempotencyKey = WorkflowRuntimeIdempotency.key(
            sessionID: request.sessionID,
            kind: request.kind,
            inputJSON: request.inputJSON
        )
        if let existing = try await repo.workflowRun(idempotencyKey: idempotencyKey) {
            return WorkflowHandleDTO(
                workflowID: existing.id,
                kind: request.kind,
                status: WorkflowRunStatus(rawValue: existing.status) ?? .running,
                deduplicated: true
            )
        }

        let workflowID = UUID().uuidString
        let baseContext = ExecutionContextWire(
            sessionID: request.sessionID,
            principal: request.principal,
            turnID: request.turnID,
            agentID: request.agentID,
            workflow: WorkflowContextWire(workflowID: workflowID, kind: request.kind),
            delivery: .liveChat,
            capabilities: [.syncWebCrawl, .hostReviewRetry]
        )
        let contextJSON = try baseContext.encodedJSON()
        let now = Date()
        let row = WorkflowRunRow(
            id: workflowID,
            kind: request.kind.rawValue,
            status: WorkflowRunStatus.running.rawValue,
            contextJSON: contextJSON,
            inputJSON: request.inputJSON,
            idempotencyKey: idempotencyKey,
            createdAt: now
        )
        try await repo.insertWorkflowRun(row)
        _ = try await repo.appendWorkflowEvent(
            workflowID: workflowID,
            kind: "progress",
            stage: "workflow",
            message: "Workflow started."
        )

        let task = Task {
            await self.runWorkflow(
                workflowID: workflowID,
                request: request,
                baseContext: baseContext,
                repositoryProvider: repositoryProvider
            )
        }
        runningTasks[workflowID] = task

        return WorkflowHandleDTO(
            workflowID: workflowID,
            kind: request.kind,
            status: .running,
            deduplicated: false
        )
    }

    public func pollWorkflowUpdate(
        _ request: WorkflowPollRequest,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async throws -> WorkflowPollResultDTO {
        let repo = try await repositoryProvider()
        guard let row = try await repo.workflowRun(id: request.workflowID) else {
            throw WorkflowRuntimeError.workflowNotFound
        }
        let events = try await repo.workflowEvents(workflowID: request.workflowID, afterSeq: request.afterSeq)
            .map {
                WorkflowEventDTO(
                    seq: $0.seq,
                    kind: $0.kind,
                    stage: $0.stage,
                    message: $0.message,
                    detailJSON: $0.detailJSON,
                    createdAt: ISO8601DateFormatter().string(from: $0.createdAt)
                )
            }
        let status = WorkflowRunStatus(rawValue: row.status) ?? .failed
        return WorkflowPollResultDTO(
            workflowID: row.id,
            status: status,
            events: events,
            resultJSON: row.resultJSON,
            errorMessage: row.errorMessage
        )
    }

    public func cancelWorkflow(
        _ request: WorkflowCancelRequest,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async throws -> ServiceAckDTO {
        cancelledWorkflows.insert(request.workflowID)
        runningTasks[request.workflowID]?.cancel()
        runningTasks.removeValue(forKey: request.workflowID)

        let repo = try await repositoryProvider()
        guard var row = try await repo.workflowRun(id: request.workflowID) else {
            throw WorkflowRuntimeError.workflowNotFound
        }
        row.status = WorkflowRunStatus.cancelled.rawValue
        row.errorMessage = request.reason
        row.finishedAt = Date.now
        try await repo.updateWorkflowRun(row)
        _ = try await repo.appendWorkflowEvent(
            workflowID: request.workflowID,
            kind: "log",
            stage: "workflow",
            message: "Workflow cancelled: \(request.reason)"
        )
        return ServiceAckDTO(ok: true, message: "cancelled")
    }

    private func runWorkflow(
        workflowID: String,
        request: WorkflowStartRequest,
        baseContext: ExecutionContextWire,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async {
        defer { runningTasks.removeValue(forKey: workflowID) }
        do {
            switch request.kind {
            case .pluginFactoryCreate:
                try await failWorkflow(
                    workflowID: workflowID,
                    message: "Plugin factory workflows are not available.",
                    repositoryProvider: repositoryProvider
                )
            default:
                try await failWorkflow(
                    workflowID: workflowID,
                    message: "Unsupported workflow kind \(request.kind.rawValue).",
                    repositoryProvider: repositoryProvider
                )
            }
        } catch {
            if !cancelledWorkflows.contains(workflowID) {
                try? await failWorkflow(
                    workflowID: workflowID,
                    message: error.localizedDescription,
                    repositoryProvider: repositoryProvider
                )
            }
        }
    }

    private func executeTool(
        toolName: String,
        argumentsJSON: String,
        context: ExecutionContextWire,
        principal: ServicePrincipal,
        helperAPIKey: String?,
        workflowID: String,
        stage: String,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async throws -> MCPToolCallResultDTO {
        guard let call = InProcessServiceBridges.mcpCallTool else {
            throw WorkflowRuntimeError.mcpUnavailable
        }
        let runID = UUID().uuidString
        let repo = try await repositoryProvider()
        let principalJSON = String(data: try JSONEncoder.service.encode(principal), encoding: .utf8) ?? "{}"
        let contextJSON = try context.encodedJSON()
        let toolRow = ToolRunRow(
            id: runID,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            principalJSON: principalJSON,
            contextJSON: contextJSON,
            status: ToolRunStatus.running.rawValue,
            resultText: nil,
            isError: false,
            errorMessage: nil,
            createdAt: Date.now,
            startedAt: Date.now
        )
        try await repo.insertToolRun(toolRow)

        let request = MCPToolCallRequest(
            requestID: runID,
            principal: principal,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            helperAPIKey: helperAPIKey,
            executionContextJSON: contextJSON
        )
        let result = try await call(request)

        var finished = toolRow
        finished.status = cancelledWorkflows.contains(workflowID)
            ? ToolRunStatus.cancelled.rawValue
            : (result.isError ? ToolRunStatus.failed.rawValue : ToolRunStatus.completed.rawValue)
        finished.resultText = result.text
        finished.isError = result.isError
        finished.finishedAt = Date.now
        try await repo.updateToolRun(finished)

        try await appendToolRunEvents(
            runID: runID,
            workflowID: workflowID,
            stage: stage,
            toolName: toolName,
            resultText: result.text,
            isError: result.isError,
            repositoryProvider: repositoryProvider
        )

        return result
    }

    private func appendToolRunEvents(
        runID: String,
        workflowID: String,
        stage: String,
        toolName: String,
        resultText: String,
        isError: Bool,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async throws {
        let repo = try await repositoryProvider()
        try await repo.appendToolRunEvent(
            runID: runID,
            kind: "stage",
            stage: stage,
            message: "\(toolName) finished isError=\(isError)"
        )
        if let outcome = ToolExecutionOutcome.decode(from: resultText) {
            if isError,
               let summary = outcome.failureSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                _ = try await repo.appendWorkflowEvent(
                    workflowID: workflowID,
                    kind: "log",
                    stage: stage,
                    message: summary
                )
            }
        }
        _ = try await repo.appendWorkflowEvent(
            workflowID: workflowID,
            kind: "log",
            stage: stage,
            message: "\(toolName) \(isError ? "failed" : "completed").",
            detailJSON: resultText
        )
    }

    private func log(
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

    private func failWorkflow(
        workflowID: String,
        message: String,
        resultJSON: String? = nil,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async throws {
        let repo = try await repositoryProvider()
        guard var row = try await repo.workflowRun(id: workflowID) else { return }
        row.status = WorkflowRunStatus.failed.rawValue
        row.errorMessage = message
        row.resultJSON = resultJSON ?? row.resultJSON
        row.finishedAt = Date.now
        try await repo.updateWorkflowRun(row)
        _ = try await repo.appendWorkflowEvent(
            workflowID: workflowID,
            kind: "log",
            stage: "workflow",
            message: message
        )
    }
}
