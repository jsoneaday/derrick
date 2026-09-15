import Foundation
import Structure
import Testing
@testable import DerrickBackend

@Suite struct VendorDocsFetchTests {
    @Test func dockerHelperRejectIsWebToolsNotReady() async throws {
        let outcome = try await VendorDocsFetch.resolve(
            sourceName: "Slack",
            documentationURL: nil,
            workflowID: "wf",
            request: Self.request,
            baseContext: Self.context,
            executeTool: { _, _, _, _, _, _, _, _ in
                MCPToolCallResultDTO(
                    requestID: "s",
                    ok: false,
                    isError: true,
                    text: "",
                    message: "XPC validation: docker flag is not allowed: image inspect"
                )
            },
            log: { _ in }
        )
        guard case .failed(let failure, let url) = outcome else {
            Issue.record("expected failed lookup")
            return
        }
        #expect(failure == .webToolsNotReady)
        #expect(url == nil)
    }

    @Test func emptySearchHitsAreSearchEmptyNotWebTools() async throws {
        let worker = """
        {"ok":false,"query":"Slack API authentication documentation","hits":[],"diagnostics":["DuckDuckGo returned no usable search results."]}
        """
        let wrapped = try ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .json, value: worker)
        ).encodedJSON()
        let outcome = try await VendorDocsFetch.resolve(
            sourceName: "Slack",
            documentationURL: nil,
            workflowID: "wf",
            request: Self.request,
            baseContext: Self.context,
            executeTool: { _, _, _, _, _, _, _, _ in
                MCPToolCallResultDTO(
                    requestID: "s",
                    ok: true,
                    isError: false,
                    text: wrapped
                )
            },
            log: { _ in }
        )
        guard case .failed(let failure, _) = outcome else {
            Issue.record("expected failed lookup")
            return
        }
        #expect(failure == .searchEmpty)
    }

    @Test func searchHitThenCrawlNotesReturnAPage() async throws {
        let hits = """
        {"ok":true,"query":"Slack API","hits":[{"title":"Tokens","url":"https://docs.slack.dev/authentication/tokens","snippet":"Create a bot token."}],"diagnostics":[]}
        """
        let pages = """
        {"pages":[{"url":"https://docs.slack.dev/authentication/tokens","title":"Tokens","text":"Slack apps authenticate HTTP calls with a bot token in the Authorization header.","status_code":200}]}
        """
        let searchJSON = try ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .json, value: hits)
        ).encodedJSON()
        let crawlJSON = try ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .json, value: pages)
        ).encodedJSON()
        let outcome = try await VendorDocsFetch.resolve(
            sourceName: "Slack",
            documentationURL: nil,
            workflowID: "wf",
            request: Self.request,
            baseContext: Self.context,
            executeTool: { tool, _, _, _, _, _, _, _ in
                MCPToolCallResultDTO(
                    requestID: "s",
                    ok: true,
                    isError: false,
                    text: tool == AllowedMCPTool.webSearch.rawValue ? searchJSON : crawlJSON
                )
            },
            log: { _ in }
        )
        guard case .page(let page) = outcome else {
            Issue.record("expected docs page")
            return
        }
        #expect(page.url.contains("docs.slack.dev"))
        #expect(page.summary.lowercased().contains("bot token"))
    }

    @Test func inboxAPISearchUsesConversationQuery() async throws {
        var searchArgs = ""
        let outcome = try await VendorDocsFetch.resolve(
            sourceName: "Slack",
            documentationURL: nil,
            workflowID: "wf",
            request: Self.request,
            baseContext: Self.context,
            executeTool: { tool, args, _, _, _, _, _, _ in
                if tool == AllowedMCPTool.webSearch.rawValue {
                    searchArgs = args
                }
                return MCPToolCallResultDTO(
                    requestID: "s",
                    ok: false,
                    isError: true,
                    text: "",
                    message: "search skipped"
                )
            },
            log: { _ in },
            purpose: .inboxAPI
        )
        guard case .failed(let failure, _) = outcome else {
            Issue.record("expected failed lookup")
            return
        }
        #expect(failure == .searchEmpty)
        #expect(searchArgs.contains("conversations"))
        #expect(searchArgs.contains("threads"))
    }

    private static let request = WorkflowStartRequest(
        kind: .connectorAuthDiscover,
        sessionID: "session",
        agentID: "ui",
        inputJSON: "{}",
        principal: .agent(sessionID: "session", agentID: "ui")
    )

    private static let context = ExecutionContextWire(
        sessionID: "session",
        principal: .agent(sessionID: "session", agentID: "ui")
    )
}
