import Testing
@testable import MCPToolCatalog

struct MCPToolCatalogTests {
    @Test func allCasesHaveStableRawValues() {
        #expect(AllowedMCPTool.scriptExec.rawValue == "script_exec")
        #expect(AllowedMCPTool.sessionMemorySearch.rawValue == "session_memory_search")
        #expect(Set(AllowedMCPTool.allCases.map(\.rawValue)).count == AllowedMCPTool.allCases.count)
    }

    @Test func defaultDescriptionsAreNonEmpty() {
        for tool in AllowedMCPTool.allCases {
            #expect(!tool.defaultDescription.isEmpty)
            #expect(tool.toolName == tool.rawValue)
        }
    }
}
