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
                    "description": .string("Human description of the complete terminal result, including what the script extracts or produces after any host HTTP request.")
                ]),
                "reason": .object([
                    "type": .string("string"),
                    "description": .string("Why this script is needed.")
                ]),
                "script": .object([
                    "type": .string("string"),
                    "description": .string("Standalone Python source (default) or Swift when language is swift. Reads one JSON event from standard input and writes a JSON array of Derrick envelopes to standard output. Use http.request envelopes for host HTTP and result.emit/message.post for terminal output.")
                ]),
                "language": .object([
                    "type": .string("string"),
                    "description": .string("Guest language: python (default) or swift (legacy). Omit to auto-detect from source.")
                ]),
                "user_prompt": .object([
                    "type": .string("string"),
                    "description": .string("Original user prompt. Required so the reviewer can verify that the terminal result fulfills the user's request.")
                ]),
                "dependencies": .object([
                    "type": .string("object"),
                    "description": .string("Must be empty. Guest script dependencies are not supported.")
                ]),
                "timeout_seconds": .object([
                    "type": .string("number"),
                    "description": .string("Tool timeout in seconds (1...300).")
                ])
            ]),
            "required": .array([
                .string("description"),
                .string("reason"),
                .string("script"),
                .string("user_prompt"),
            ])
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
