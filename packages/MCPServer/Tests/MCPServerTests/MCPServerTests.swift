import Testing
@testable import MCPServer

@Suite struct MCPServerTests {
    @Test func registrySearchMatchesToolName() async throws {
        let registry = MCPToolRegistry()
        await registry.register(name: "tool_search", description: "Search tools") { _ in "ok" }

        let results = await registry.search(matching: "search")

        #expect(results.map(\.name) == ["tool_search"])
    }
}
