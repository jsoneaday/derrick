import Foundation
import MCP
import MCPToolCatalog
import Structure

/// Schemas + registration helpers for hierarchical multi-agent tools (MA-2).
public enum AgentOrchestrationToolModule {
    public static func spawnRegistration(
        handler: @escaping @Sendable (_ goal: String, _ task: String, _ agentID: String?) async throws -> String
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: .agentsSpawn,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "goal": .object([
                        "type": .string("string"),
                        "description": .string("Short goal for the worker.")
                    ]),
                    "task": .object([
                        "type": .string("string"),
                        "description": .string("Concrete task instructions for the worker.")
                    ]),
                    "agent_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional stable worker id (slug). Auto-generated if omitted.")
                    ])
                ]),
                "required": .array([.string("goal"), .string("task")])
            ])
        ) { arguments in
            let goal = stringArg(arguments, "goal") ?? ""
            let task = stringArg(arguments, "task") ?? ""
            let agentID = stringArg(arguments, "agent_id")
            guard !goal.isEmpty, !task.isEmpty else {
                throw NSError(
                    domain: "AgentOrchestration",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "goal and task are required"]
                )
            }
            return try await handler(goal, task, agentID)
        }
    }

    public static func completeTaskRegistration(
        handler: @escaping @Sendable (_ result: String, _ agentID: String?) async throws -> String
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: .agentsCompleteTask,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "result": .object([
                        "type": .string("string"),
                        "description": .string("Concise result for the parent agent.")
                    ]),
                    "agent_id": .object([
                        "type": .string("string"),
                        "description": .string("Worker agent id (from Agent-ID in the task). Required when multiple workers run in parallel.")
                    ])
                ]),
                "required": .array([.string("result")])
            ])
        ) { arguments in
            let result = stringArg(arguments, "result") ?? ""
            let agentID = stringArg(arguments, "agent_id")
            return try await handler(result, agentID)
        }
    }

    public static func listRegistration(
        handler: @escaping @Sendable (_ childrenOnly: Bool) async throws -> String
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: .agentsList,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "children_only": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, only list direct children of the caller.")
                    ])
                ])
            ])
        ) { arguments in
            let childrenOnly = boolArg(arguments, "children_only") ?? false
            return try await handler(childrenOnly)
        }
    }

    public static func sendRegistration(
        handler: @escaping @Sendable (_ toAgentID: String, _ message: String) async throws -> String
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: .agentsSend,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "to_agent_id": .object([
                        "type": .string("string"),
                        "description": .string("Parent or child agent id only.")
                    ]),
                    "message": .object([
                        "type": .string("string"),
                        "description": .string("Message body.")
                    ])
                ]),
                "required": .array([.string("to_agent_id"), .string("message")])
            ])
        ) { arguments in
            let to = stringArg(arguments, "to_agent_id") ?? ""
            let message = stringArg(arguments, "message") ?? ""
            guard !to.isEmpty, !message.isEmpty else {
                throw NSError(
                    domain: "AgentOrchestration",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "to_agent_id and message are required"]
                )
            }
            return try await handler(to, message)
        }
    }

    public static func cancelRegistration(
        handler: @escaping @Sendable (_ agentID: String) async throws -> String
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: .agentsCancel,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "agent_id": .object([
                        "type": .string("string"),
                        "description": .string("Agent id to cancel.")
                    ])
                ]),
                "required": .array([.string("agent_id")])
            ])
        ) { arguments in
            let id = stringArg(arguments, "agent_id") ?? ""
            guard !id.isEmpty else {
                throw NSError(
                    domain: "AgentOrchestration",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "agent_id is required"]
                )
            }
            return try await handler(id)
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

    private static func boolArg(_ arguments: [String: Value], _ key: String) -> Bool? {
        guard let value = arguments[key] else { return nil }
        switch value {
        case .bool(let b): return b
        case .string(let s):
            let lowered = s.lowercased()
            if lowered == "true" || lowered == "1" { return true }
            if lowered == "false" || lowered == "0" { return false }
            return nil
        case .int(let i): return i != 0
        default: return nil
        }
    }
}
