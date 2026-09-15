import Foundation
import Structure

/// Reads vendor auth docs (search, then crawl) and classifies what secret Derrick needs.
enum PluginCreatorAccessDocsReview {
    struct Result: Sendable {
        let auth: ConnectorAuthDiscovery
        let documentationURL: String?
        let failure: PluginDocsLookupFailure?
    }

    static func discover(
        vendor: PluginFactoryCreateInput.ConnectorVendor,
        sourceName: String,
        documentationURL: String?,
        sessionID: String,
        apiKey: String?,
        reviewerModelJSON: String?,
        onProgress: ((String) -> Void)? = nil
    ) async -> Result {
        let page = await fetchDocs(
            vendor: vendor,
            sourceName: sourceName,
            documentationURL: documentationURL,
            sessionID: sessionID,
            apiKey: apiKey,
            reviewerModelJSON: reviewerModelJSON,
            onProgress: onProgress
        )
        if let failure = page.failure {
            return Result(
                auth: ConnectorAuthDiscovery(
                    authScheme: .apiKey,
                    secrets: [],
                    setupHint: nil,
                    crawlSummary: nil
                ),
                documentationURL: page.url,
                failure: failure
            )
        }
        let auth = await ConnectorAuthClassifier.classifyOrFallback(
            vendor: vendor,
            crawlSummary: page.summary,
            apiKey: apiKey,
            reviewerModelJSON: reviewerModelJSON
        )
        return Result(auth: auth.preferringCallCredential(), documentationURL: page.url, failure: nil)
    }

    private static func fetchDocs(
        vendor: PluginFactoryCreateInput.ConnectorVendor,
        sourceName: String,
        documentationURL: String?,
        sessionID: String,
        apiKey: String?,
        reviewerModelJSON: String?,
        onProgress: ((String) -> Void)?
    ) async -> (summary: String, url: String?, failure: PluginDocsLookupFailure?) {
        do {
            let inputJSON = try ConnectorAuthDiscoverInput(
                vendor: vendor,
                customVendorName: sourceName,
                documentationURL: documentationURL
            ).encodedJSON()
            let workflowSession = sessionID.isEmpty ? "plugin-wizard" : sessionID
            let handle = try await WorkflowRuntimeClient.shared.startWorkflow(
                WorkflowStartRequest(
                    kind: .connectorAuthDiscover,
                    sessionID: workflowSession,
                    agentID: "ui",
                    inputJSON: inputJSON,
                    principal: .agent(sessionID: workflowSession, agentID: "ui"),
                    helperAPIKey: apiKey,
                    helperReviewerModelJSON: reviewerModelJSON
                )
            )
            var after = 0
            while !Task.isCancelled {
                let poll = try await WorkflowRuntimeClient.shared.pollWorkflowUpdate(
                    WorkflowPollRequest(workflowID: handle.workflowID, afterSeq: after)
                )
                for event in poll.events {
                    after = max(after, event.seq)
                    if event.kind == "progress" {
                        onProgress?(event.message)
                    } else if event.kind == "log",
                              let message = Self.userFacingLog(event.message) {
                        onProgress?(message)
                    }
                }
                if poll.status == .completed {
                    if let json = poll.resultJSON,
                       let data = json.data(using: .utf8),
                       let result = try? JSONDecoder.service.decode(
                        ConnectorAuthDiscoverResult.self,
                        from: data
                       ) {
                        return (
                            result.crawlSummary,
                            result.documentationURL,
                            result.failureCode
                        )
                    }
                    return ("", nil, .webToolsNotReady)
                }
                if poll.status == .failed || poll.status == .cancelled {
                    return ("", nil, .webToolsNotReady)
                }
                try await Task.sleep(nanoseconds: 800_000_000)
            }
        } catch {
            return ("", nil, .webToolsNotReady)
        }
        return ("", nil, .webToolsNotReady)
    }

    private static func userFacingLog(_ message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("web.search ")
            || trimmed.lowercased().hasPrefix("web.crawl ") {
            return nil
        }
        if WorkerImageFailureDisplay.isWorkerImageIssue(trimmed) {
            return WorkerImageFailureDisplay.toolsNotReady
        }
        return trimmed
    }
}
