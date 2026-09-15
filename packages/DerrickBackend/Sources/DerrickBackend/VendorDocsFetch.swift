import Foundation
import Structure

enum VendorDocsFetch {
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

    struct Page: Sendable {
        let url: String
        let summary: String
    }

    enum Outcome: Sendable {
        case page(Page)
        case failed(PluginDocsLookupFailure, url: String?)
    }

    enum Purpose: Sendable {
        case authentication
        case inboxAPI
    }

    static func resolve(
        sourceName: String,
        documentationURL: String?,
        workflowID: String,
        request: WorkflowStartRequest,
        baseContext: ExecutionContextWire,
        executeTool: ExecuteTool,
        log: (String) async throws -> Void,
        purpose: Purpose = .authentication
    ) async throws -> Outcome {
        let startURL: String
        if let documentationURL,
           let sanitized = VendorDocsLocator.sanitizedHTTPURL(documentationURL) {
            startURL = sanitized
        } else {
            try await log(searchProgress(sourceName: sourceName, purpose: purpose))
            switch try await searchDocumentationURL(
                sourceName: sourceName,
                workflowID: workflowID,
                request: request,
                baseContext: baseContext,
                executeTool: executeTool,
                purpose: purpose
            ) {
            case .failure(let failure):
                try await log("Search could not run.")
                return .failed(failure, url: nil)
            case .success(let found):
                guard let found else {
                    try await log("Search did not return a usable setup-docs URL.")
                    return .failed(.searchEmpty, url: nil)
                }
                startURL = found
                try await log("Search chose \(found)")
            }
        }

        try await log(readProgress(sourceName: sourceName, purpose: purpose))
        let crawlResult = try await executeTool(
            AllowedMCPTool.webCrawl.rawValue,
            try crawlArguments(startURL: startURL, sourceName: sourceName, purpose: purpose),
            baseContext,
            request.principal,
            request.helperAPIKey,
            request.helperReviewerModelJSON,
            workflowID,
            toolStage(purpose)
        )
        if crawlResult.isError {
            try await log("Could not read that page.")
            if lookupFailure(from: crawlResult) == .webToolsNotReady {
                return .failed(.webToolsNotReady, url: startURL)
            }
            return .failed(.crawlFailed, url: startURL)
        }
        let summary = VendorDocsLocator.crawlSummary(fromToolText: crawlResult.text) ?? ""
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try await log("That page had no usable setup notes.")
            return .failed(.emptyNotes, url: startURL)
        }
        return .page(Page(url: startURL, summary: summary))
    }

    private static func searchDocumentationURL(
        sourceName: String,
        workflowID: String,
        request: WorkflowStartRequest,
        baseContext: ExecutionContextWire,
        executeTool: ExecuteTool,
        purpose: Purpose
    ) async throws -> Result<String?, PluginDocsLookupFailure> {
        let payload: [String: Any] = [
            "query": searchQuery(sourceName: sourceName, purpose: purpose),
            "max_results": 8,
            "timeout_seconds": 30,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let args = String(decoding: data, as: UTF8.self)
        let result = try await executeTool(
            AllowedMCPTool.webSearch.rawValue,
            args,
            baseContext,
            request.principal,
            request.helperAPIKey,
            request.helperReviewerModelJSON,
            workflowID,
            toolStage(purpose)
        )
        if result.isError, lookupFailure(from: result) == .webToolsNotReady {
            return .failure(.webToolsNotReady)
        }
        let hits = VendorDocsLocator.hits(fromSearchToolText: result.text)
        return .success(
            VendorDocsLocator.preferredDocumentationURL(
                from: hits,
                sourceName: sourceName
            )
        )
    }

    private static func lookupFailure(from result: MCPToolCallResultDTO) -> PluginDocsLookupFailure? {
        let blob = "\(result.message)\n\(result.text)"
        if WorkerImageFailureDisplay.isWorkerImageIssue(blob) {
            return .webToolsNotReady
        }
        return nil
    }

    private static func toolStage(_ purpose: Purpose) -> String {
        switch purpose {
        case .authentication:
            return "auth"
        case .inboxAPI:
            return "docs"
        }
    }

    private static func crawlArguments(
        startURL: String,
        sourceName: String,
        purpose: Purpose
    ) throws -> String {
        let payload: [String: Any] = [
            "start_url": startURL,
            "goal": crawlGoal(sourceName: sourceName, purpose: purpose),
            "max_pages": 2,
            "max_depth": 0,
            "timeout_seconds": 180,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func searchQuery(sourceName: String, purpose: Purpose) -> String {
        switch purpose {
        case .authentication:
            return VendorDocsLocator.searchQuery(sourceName: sourceName)
        case .inboxAPI:
            return VendorDocsLocator.inboxAPISearchQuery(sourceName: sourceName)
        }
    }

    private static func searchProgress(sourceName: String, purpose: Purpose) -> String {
        switch purpose {
        case .authentication:
            return "Searching for \(sourceName) setup docs…"
        case .inboxAPI:
            return "Searching for \(sourceName) conversation API docs…"
        }
    }

    private static func readProgress(sourceName: String, purpose: Purpose) -> String {
        switch purpose {
        case .authentication:
            return "Reading how \(sourceName) authenticates…"
        case .inboxAPI:
            return "Reading how \(sourceName) lists conversations and threads…"
        }
    }

    private static func crawlGoal(sourceName: String, purpose: Purpose) -> String {
        switch purpose {
        case .authentication:
            return """
            Summarize how a \(sourceName) bot or app authenticates each HTTP API call. \
            Prefer the credential sent on the request (bot token, API key, or bearer token) \
            over OAuth client id and secret used only to install the app. Note token type, \
            required scopes or permissions, and which header or query parameter carries the secret. \
            Ignore unrelated product pages.
            """
        case .inboxAPI:
            return """
            Summarize how a \(sourceName) bot or app lists conversations (channels, rooms, DMs) \
            and loads messages in a thread. Note HTTP methods, pagination, and the identifiers \
            for a conversation versus a parent message. Ignore SSO and sign-in pages.
            """
        }
    }
}
