import Foundation
import MCP
import Structure

/// Catalog module for `agent_profile_delegate`.
public enum AgentProfileDelegateToolModule {
    public static func makeRegistration(
        handler: @escaping @Sendable (_ profileHandle: String, _ task: String) async throws -> String
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: .agentProfileDelegate,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "profile_handle": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Target profile handle without $: developer, researcher, or general."
                        )
                    ]),
                    "task": .object([
                        "type": .string("string"),
                        "description": .string("Concrete task instructions for the delegated profile.")
                    ])
                ]),
                "required": .array([.string("profile_handle"), .string("task")])
            ])
        ) { arguments in
            let handle = stringArg(arguments, "profile_handle") ?? ""
            let task = stringArg(arguments, "task") ?? ""
            guard !handle.isEmpty, !task.isEmpty else {
                throw NSError(
                    domain: "AgentProfileDelegate",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "profile_handle and task are required"]
                )
            }
            return try await handler(handle, task)
        }
    }

    private static func stringArg(_ arguments: [String: Value], _ key: String) -> String? {
        guard let value = arguments[key] else { return nil }
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
}
