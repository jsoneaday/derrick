import Foundation
import MCP
import MCPToolCatalog

/// Local orchestration tools: agent places durable job/schedule orders (not MCPService effectors).
public enum JobOrchestrationToolModule {
    public static func createJobRegistration(
        handler: @escaping @Sendable (
            _ runAfterSeconds: Int?,
            _ runAt: String?,
            _ toolName: String,
            _ toolArgumentsJSON: String,
            _ wakeAfter: Bool,
            _ wakePrompt: String?,
            _ description: String?
        ) async throws -> String
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: .jobsCreate,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "run_after_seconds": .object([
                        "type": .string("integer"),
                        "description": .string("Delay from now in seconds (0...86400). Converted to absolute run time. Prefer this for 'in N minutes'.")
                    ]),
                    "run_at": .object([
                        "type": .string("string"),
                        "description": .string("Absolute fire time: ISO-8601 or local 'HH:mm' / 'h:mm a' (next occurrence). Prefer for 'at 3pm'.")
                    ]),
                    "tool_name": .object([
                        "type": .string("string"),
                        "description": .string("Effector to freeze (v1: script_exec only).")
                    ]),
                    "tool_arguments": .object([
                        "type": .string("object"),
                        "description": .string("Frozen effector args. For script_exec use {description,reason,script} where script is standalone Swift reading JSON from stdin and writing Derrick envelope JSON to stdout. Keep script short; put real line breaks as \\n only (one compact JSON line).")
                    ]),
                    "wake_after": .object([
                        "type": .string("boolean"),
                        "description": .string("If true (default), wake this agent after the tool with wake_prompt + tool result.")
                    ]),
                    "wake_prompt": .object([
                        "type": .string("string"),
                        "description": .string("Short wake instructions (required if wake_after). Keep under ~120 chars.")
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("Optional human label / correlation.")
                    ])
                ]),
                "required": .array([.string("tool_name"), .string("tool_arguments")])
            ])
        ) { arguments in
            let toolName = stringArg(arguments, "tool_name") ?? ""
            let argsJSON = try objectArgJSON(arguments, "tool_arguments")
            let wakeAfter = boolArg(arguments, "wake_after") ?? true
            let wakePrompt = stringArg(arguments, "wake_prompt")
            let description = stringArg(arguments, "description")
            let runAfter = intArg(arguments, "run_after_seconds")
            let runAt = stringArg(arguments, "run_at")
            return try await handler(runAfter, runAt, toolName, argsJSON, wakeAfter, wakePrompt, description)
        }
    }

    public static func createScheduleRegistration(
        handler: @escaping @Sendable (
            _ name: String,
            _ recurrence: String,
            _ intervalSeconds: Int?,
            _ runAfterSeconds: Int?,
            _ nextFireAt: String?,
            _ toolName: String,
            _ toolArgumentsJSON: String,
            _ wakeAfter: Bool,
            _ wakePrompt: String?
        ) async throws -> String
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: .jobsScheduleCreate,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Schedule name (unique label for the user).")
                    ]),
                    "recurrence": .object([
                        "type": .string("string"),
                        "description": .string("'once' (fire once then disable) or 'interval' (repeat).")
                    ]),
                    "interval_seconds": .object([
                        "type": .string("integer"),
                        "description": .string("Required for interval; minimum 60.")
                    ]),
                    "run_after_seconds": .object([
                        "type": .string("integer"),
                        "description": .string("First fire delay from now (optional).")
                    ]),
                    "next_fire_at": .object([
                        "type": .string("string"),
                        "description": .string("First fire absolute time (ISO-8601 or local time).")
                    ]),
                    "tool_name": .object([
                        "type": .string("string"),
                        "description": .string("Effector template (v1: script_exec).")
                    ]),
                    "tool_arguments": .object([
                        "type": .string("object"),
                        "description": .string("Frozen effector arguments.")
                    ]),
                    "wake_after": .object([
                        "type": .string("boolean"),
                        "description": .string("Wake agent after each fire (default true).")
                    ]),
                    "wake_prompt": .object([
                        "type": .string("string"),
                        "description": .string("Wake instructions (required if wake_after).")
                    ])
                ]),
                "required": .array([
                    .string("name"),
                    .string("recurrence"),
                    .string("tool_name"),
                    .string("tool_arguments")
                ])
            ])
        ) { arguments in
            let name = stringArg(arguments, "name") ?? ""
            let recurrence = stringArg(arguments, "recurrence") ?? "once"
            let interval = intArg(arguments, "interval_seconds")
            let runAfter = intArg(arguments, "run_after_seconds")
            let nextFire = stringArg(arguments, "next_fire_at")
            let toolName = stringArg(arguments, "tool_name") ?? ""
            let argsJSON = try objectArgJSON(arguments, "tool_arguments")
            let wakeAfter = boolArg(arguments, "wake_after") ?? true
            let wakePrompt = stringArg(arguments, "wake_prompt")
            return try await handler(
                name, recurrence, interval, runAfter, nextFire, toolName, argsJSON, wakeAfter, wakePrompt
            )
        }
    }

    // MARK: - Arg helpers

    private static func stringArg(_ arguments: [String: Value], _ key: String) -> String? {
        guard let value = arguments[key] else { return nil }
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(Int(d))
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

    private static func intArg(_ arguments: [String: Value], _ key: String) -> Int? {
        guard let value = arguments[key] else { return nil }
        switch value {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    private static func objectArgJSON(_ arguments: [String: Value], _ key: String) throws -> String {
        guard let value = arguments[key] else {
            throw NSError(
                domain: "JobOrchestration",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "\(key) is required"]
            )
        }
        switch value {
        case .object:
            return try encodeValueJSON(value)
        case .string(let s):
            // Allow stringified JSON object
            if let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               obj is [String: Any]
            {
                return s
            }
            throw NSError(
                domain: "JobOrchestration",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "\(key) must be a JSON object"]
            )
        default:
            throw NSError(
                domain: "JobOrchestration",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "\(key) must be a JSON object"]
            )
        }
    }

    private static func encodeValueJSON(_ value: Value) throws -> String {
        // Reuse Lib path if available — MCPServer may not depend on Lib; encode via JSONSerialization
        let any = try valueToAny(value)
        let data = try JSONSerialization.data(withJSONObject: any, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func valueToAny(_ value: Value) throws -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .data(_, let data): return data.base64EncodedString()
        case .array(let arr): return try arr.map { try valueToAny($0) }
        case .object(let obj):
            var out: [String: Any] = [:]
            for (k, v) in obj {
                out[k] = try valueToAny(v)
            }
            return out
        }
    }
}
