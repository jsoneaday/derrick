import Foundation
import MCP
import MCPToolCatalog
import Structure

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
                ]),
                "include_archived": .object([
                    "type": .string("boolean"),
                    "description": .string("When true, include memory older than 6 months. Default false.")
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
                page: integerValue(from: payload["page"]) ?? 1,
                includeArchived: boolValue(from: payload["include_archived"]) ?? false
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

    private static func boolValue(from value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            let lowered = string.lowercased()
            if lowered == "true" || lowered == "1" { return true }
            if lowered == "false" || lowered == "0" { return false }
        }
        return nil
    }
}
