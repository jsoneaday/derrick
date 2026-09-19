import Foundation
import Structure

/// Host-forced fetch of the published Agent Plugins Specification before factory build.
enum AgentPluginSpecFetch {
    typealias ExecuteTool = VendorDocsFetch.ExecuteTool

    struct Document: Sendable {
        let summary: String
        let sourceURL: String
        let usedLiveFetch: Bool
    }

    static func resolve(
        workflowID: String,
        request: WorkflowStartRequest,
        baseContext: ExecutionContextWire,
        executeTool: ExecuteTool,
        log: (String) async throws -> Void
    ) async throws -> Document {
        let url = AgentPluginSpec.publishedURL.absoluteString
        try await log("Reading the Agent Plugins Specification…")
        do {
            let crawlResult = try await executeTool(
                AllowedMCPTool.webCrawl.rawValue,
                try crawlArguments(startURL: url),
                baseContext,
                request.principal,
                request.helperAPIKey,
                request.helperReviewerModelJSON,
                workflowID,
                "spec"
            )
            if !crawlResult.isError,
               let summary = AgentPluginSpec.summary(fromCrawlToolText: crawlResult.text),
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await log("Using the live Agent Plugins Specification.")
                return Document(summary: summary, sourceURL: url, usedLiveFetch: true)
            }
            try await log("Live specification page was empty; using bundled fallback (prefer live next time).")
        } catch {
            try await log("Could not fetch the live specification; using bundled fallback (prefer live next time).")
        }
        return Document(
            summary: AgentPluginSpec.bundledFallbackSummary(),
            sourceURL: url,
            usedLiveFetch: false
        )
    }

    private static func crawlArguments(startURL: String) throws -> String {
        let payload: [String: Any] = [
            "start_url": startURL,
            "goal": """
            Extract the normative Agent Plugins package requirements: plugin.json, component discovery, \
            skills (SKILL.md required), optional references, and client conformance notes. \
            Prefer concise rules over marketing text.
            """,
            "max_pages": 2,
            "max_depth": 0,
            "timeout_seconds": 120,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
