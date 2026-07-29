//
//  PythonScriptExecutionToolModule.swift
//  MCPServer
//
//  Created by David Choi on 7/26/26.
//

import Foundation
import MCP
import MCPToolCatalog

public enum PythonScriptExecutionToolModule: MCPToolModule {
    public static let id: AllowedMCPTool = .pythonScriptExec

    public static var inputSchema: Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "mode": .object([
                    "type": .string("string"),
                    "enum": .array([.string("readonly"), .string("write")]),
                    "description": .string("Execution mode declaration. readonly forbids write-like behavior.")
                ]),
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
                    "description": .string("Python script source code.")
                ]),
                "user_prompt": .object([
                    "type": .string("string"),
                    "description": .string("Original user prompt to validate relevance.")
                ]),
                "expected_effects": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Declared intended effects (required for write mode).")
                ]),
                "python_packages": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Optional dependency names (PyPI packages). Baseline packages are curated and can be installed without allow_dependency_install.")
                ]),
                "allow_dependency_install": .object([
                    "type": .string("boolean"),
                    "description": .string("Allow per-run pip install of non-baseline packages. Requires allow_network=true.")
                ]),
                "timeout_seconds": .object([
                    "type": .string("number"),
                    "description": .string("Execution timeout in seconds (1...300).")
                ]),
                "allow_network": .object([
                    "type": .string("boolean"),
                    "description": .string("Enable container network access when the user request requires fetching live/current web data or installing packages.")
                ])
            ]),
            "required": .array([.string("mode"), .string("allow_network"), .string("description"), .string("reason"), .string("script")])
        ])
    }

    public static func makeRegistration(
        description: String? = nil,
        runner: any PythonScriptRunner,
        reviewer: (any PythonScriptReviewer)?,
        networkPreflight: PythonScriptNetworkPreflight? = nil,
        logger: @escaping @Sendable (String) -> Void
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: id,
            description: description,
            inputSchema: inputSchema
        ) { arguments in
            try await handleInvocation(
                arguments: arguments,
                runner: runner,
                reviewer: reviewer,
                networkPreflight: networkPreflight,
                logger: logger
            )
        }
    }

    private static func handleInvocation(
        arguments: [String: Value],
        runner: any PythonScriptRunner,
        reviewer: (any PythonScriptReviewer)?,
        networkPreflight: PythonScriptNetworkPreflight?,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let toolStarted = Date()
        return try await MCPServerHost.runPythonScriptToolBody(
            arguments: arguments,
            runner: runner,
            reviewer: reviewer,
            networkPreflight: networkPreflight,
            logger: logger,
            toolStarted: toolStarted
        )
    }
}
