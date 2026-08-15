import Foundation
import MCP
import MCPToolCatalog
import Plugin

public enum ScriptExecutionToolModule: MCPToolModule {
    public static let id: AllowedMCPTool = .scriptExec

    public static var inputSchema: Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "description": .object([
                    "type": .string("string"),
                    "description": .string("Human description of what the script does.")
                ]),
                "reason": .object([
                    "type": .string("string"),
                    "description": .string("Why this script is needed.")
                ]),
                "script": .object([
                    "type": .string("string"),
                    "description": .string("TypeScript 7. import { netFetch, type HandleEvent, type HandleResult } from \"derrick\". export function handle(event: HandleEvent): HandleResult. Must return Envelope[] JSON. Native tsc runs in the guest; failures abort with the compiler output.")
                ]),
                "user_prompt": .object([
                    "type": .string("string"),
                    "description": .string("Original user prompt to validate relevance.")
                ]),
                "dependencies": .object([
                    "type": .string("object"),
                    "description": .string("npm package name → version range. Installed during setup before network is cut. Install hooks may run.")
                ]),
                "timeout_seconds": .object([
                    "type": .string("number"),
                    "description": .string("Tool timeout in seconds (1...300).")
                ])
            ]),
            "required": .array([.string("description"), .string("reason"), .string("script")])
        ])
    }

    public static func makeRegistration(
        description: String? = nil,
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        reviewer: (any ScriptReviewer)?,
        logger: @escaping @Sendable (String) -> Void
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: id,
            description: description,
            inputSchema: inputSchema
        ) { arguments in
            try await ScriptExecutionRuntime.run(
                arguments: arguments,
                stdinExecutor: stdinExecutor,
                reviewer: reviewer,
                logger: logger
            )
        }
    }
}
