import Testing
import MCP
@testable import MCPClient

@Suite struct MCPClientTests {
    @Test func searchFiltersByName() async throws {
        let backend = InMemoryBackend()
        let client = MCPClient(backend: backend)

        let results = try await client.searchTools(matching: "search")

        #expect(results.map(\.name) == ["tool_search"])
    }

    @Test func batchCallToolsAggregatesResults() async throws {
        let backend = InMemoryBackend()
        let client = MCPClient(backend: backend)

        let request = MCPToolBatchRequest(
            invocations: [
                MCPToolInvocation(name: "tool_search", arguments: ["query": .string("search")]),
                MCPToolInvocation(name: "tool", arguments: ["name": .string("tool_call"), "arguments": .string("{}")])
            ],
            filterQuery: "tool"
        )

        let result = try await client.batchCallTools(request)

        #expect(result.results.count == 2)
        #expect(result.combinedContent.contains("tool_search"))
        #expect(result.isError == false)
    }
}

private struct InMemoryBackend: MCPBackend {
    let identifier = "memory"

    func searchTools(matching query: String) async throws -> [MCPToolDescriptor] {
        [
            MCPToolDescriptor(name: "tool_search", description: "Search tools"),
            MCPToolDescriptor(name: "tool_call", description: "Call a tool")
        ].filter {
            query.isEmpty || $0.name.contains(query) || $0.description?.contains(query) == true
        }
    }

    func callTool(named name: String, arguments: [String : Value]) async throws -> MCPToolResult {
        MCPToolResult(content: "\(name): \(arguments.count)")
    }

    func batchCallTools(_ request: MCPToolBatchRequest) async throws -> MCPToolBatchResult {
        let results = request.invocations.map { invocation in
            MCPToolResult(content: "\(invocation.toolName): \(invocation.arguments.count)")
        }
        return MCPToolBatchResult(
            results: results,
            combinedContent: results.map(\.content).joined(separator: "\n"),
            isError: false
        )
    }
}
