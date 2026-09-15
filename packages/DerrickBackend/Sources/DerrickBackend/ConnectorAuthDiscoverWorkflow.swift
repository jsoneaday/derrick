import DBRepository
import Foundation
import Structure

enum ConnectorAuthDiscoverWorkflow {
    static func run(
        workflowID: String,
        request: WorkflowStartRequest,
        baseContext: ExecutionContextWire,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository,
        executeTool: @escaping VendorDocsFetch.ExecuteTool
    ) async throws {
        let input = try ConnectorAuthDiscoverInput.decodeJSON(request.inputJSON)
        let sourceName = input.customVendorName ?? input.vendor.displayName
        let outcome = try await VendorDocsFetch.resolve(
            sourceName: sourceName,
            documentationURL: input.documentationURL,
            workflowID: workflowID,
            request: request,
            baseContext: baseContext,
            executeTool: executeTool,
            log: { message in
                try await log(
                    workflowID: workflowID,
                    stage: "auth",
                    message: message,
                    repositoryProvider: repositoryProvider
                )
            }
        )
        switch outcome {
        case .page(let page):
            try await complete(
                workflowID: workflowID,
                summary: page.summary,
                documentationURL: page.url,
                failureCode: nil,
                repositoryProvider: repositoryProvider
            )
        case .failed(let failure, let url):
            try await complete(
                workflowID: workflowID,
                summary: "",
                documentationURL: url,
                failureCode: failure,
                repositoryProvider: repositoryProvider
            )
        }
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

    private static func complete(
        workflowID: String,
        summary: String,
        documentationURL: String?,
        failureCode: PluginDocsLookupFailure?,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async throws {
        let repo = try await repositoryProvider()
        guard var row = try await repo.workflowRun(id: workflowID) else { return }
        let resultJSON = try JSONEncoder.service.encode(
            ConnectorAuthDiscoverResult(
                crawlSummary: summary,
                documentationURL: documentationURL,
                failureCode: failureCode
            )
        )
        row.status = WorkflowRunStatus.completed.rawValue
        row.resultJSON = String(decoding: resultJSON, as: UTF8.self)
        row.errorMessage = nil
        row.finishedAt = Date.now
        try await repo.updateWorkflowRun(row)
        let done: String
        switch failureCode {
        case .webToolsNotReady:
            done = WorkerImageFailureDisplay.toolsNotReady
        case .searchEmpty, .crawlFailed, .emptyNotes:
            done = "Could not find authentication docs."
        case nil:
            done = summary.isEmpty
                ? "Could not find authentication docs."
                : "Finished reading authentication docs."
        }
        _ = try await repo.appendWorkflowEvent(
            workflowID: workflowID,
            kind: "progress",
            stage: "complete",
            message: done
        )
    }
}
