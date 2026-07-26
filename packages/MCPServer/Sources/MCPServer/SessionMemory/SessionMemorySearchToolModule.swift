import Foundation
import MCP
import MCPToolCatalog

/// Catalog module for `session_memory_search`.
public enum SessionMemorySearchToolModule: MCPToolModule {
    public static let id: AllowedMCPTool = .sessionMemorySearch

    public static var inputSchema: Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Optional search text for matching prior memory entries.")
                ]),
                "limit": .object([
                    "type": .string("number"),
                    "description": .string("Number of prior entries to return per page.")
                ]),
                "page": .object([
                    "type": .string("number"),
                    "description": .string("Page number, starting at 1.")
                ])
            ]),
            "required": .array([.string("limit"), .string("page")])
        ])
    }

    public static func makeRegistration(
        description: String? = nil,
        handler: @escaping @Sendable (SessionMemorySearchArguments) async throws -> String
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: id,
            description: description,
            inputSchema: inputSchema
        ) { arguments in
            let data = try JSONEncoder().encode(arguments)
            let payload = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let searchArguments = SessionMemorySearchArguments(
                query: payload["query"] as? String,
                limit: integerValue(from: payload["limit"]) ?? 10,
                page: integerValue(from: payload["page"]) ?? 1
            )
            return try await handler(searchArguments)
        }
    }

    private static func integerValue(from value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
