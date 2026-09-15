import Foundation
import MCP
import Plugin
import Structure

/// MCP entrypoint for the factory. The model supplies only the user's goal;
/// builder, runner, reviewer, compiler, and hash verification stay host-owned.
public enum PluginFactoryToolModule: MCPToolModule {
    public static let id: AllowedMCPTool = .pluginFactoryBuild

    public static var inputSchema: Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "goal": .object([
                    "type": .string("string"),
                    "description": .string("What the user wants the Agent Plugin to do.")
                ]),
                "host_manifest_json": .object([
                    "type": .string("string"),
                    "description": .string("Host-owned Agent Plugin plugin.json. When set, the builder only supplies Go source and tests.")
                ]),
            ]),
            "required": .array([.string("goal")])
        ])
    }

    public static func makeRegistration(
        build: @escaping @Sendable (String, PluginFactoryManifestInput?) async throws -> PluginFactoryRelease
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: id,
            description: id.defaultDescription,
            inputSchema: inputSchema
        ) { arguments in
            let goal = arguments["goal"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !goal.isEmpty else {
                return #"{"ok":false,"error":"goal is required."}"#
            }
            let hostManifest: PluginFactoryManifestInput?
            if let json = arguments["host_manifest_json"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !json.isEmpty {
                do {
                    hostManifest = try PluginFactoryManifestInput.fromEncodedJSON(json)
                } catch {
                    return #"{"ok":false,"error":"host_manifest_json is not a valid Agent Plugin manifest."}"#
                }
            } else {
                hostManifest = nil
            }
            do {
                let release = try await build(goal, hostManifest)
                let summary = FactoryBuildSummary(
                    pluginID: release.pluginID,
                    version: release.version,
                    contentHash: release.contentHash.rawValue,
                    reviewSummary: release.reviewSummary,
                    secrets: PluginSecretField.fields(fromManifestJSON: Data(release.manifestJSON.utf8))
                        .map(\.descriptor)
                )
                let data = try JSONEncoder().encode(summary)
                return try ToolExecutionOutcome.completed(
                    output: ToolExecutionOutcome.Output(
                        format: .json,
                        value: String(decoding: data, as: UTF8.self)
                    )
                ).encodedJSON()
            } catch let error as PluginFactoryError {
                return try failureOutcome(for: error).encodedJSON()
            } catch {
                return try ToolExecutionOutcome.failure(
                    stage: .execution,
                    diagnostics: [
                        ToolExecutionOutcome.Diagnostic(
                            code: "plugin_factory_failed",
                            message: error.localizedDescription
                        )
                    ],
                    retry: ToolExecutionOutcome.Retry(allowed: false)
                ).encodedJSON()
            }
        }
    }

    private static func failureOutcome(
        for error: PluginFactoryError
    ) -> ToolExecutionOutcome {
        let status: ToolExecutionOutcome.Status
        let stage: ToolExecutionOutcome.Stage
        let diagnostics: [ToolExecutionOutcome.Diagnostic]
        let retryAllowed: Bool
        switch error {
        case .invalidManifest, .invalidSkillPath, .reservedPluginID, .invalidSource:
            status = .blocked
            stage = .validation
            diagnostics = [diagnostic(for: error)]
            retryAllowed = false
        case .directRunFailed, .invalidDirectOutput:
            status = .failed
            stage = .execution
            diagnostics = [diagnostic(for: error)]
            retryAllowed = false
        case .reviewRejected(let summary, let findings):
            status = .blocked
            stage = .review
            diagnostics = reviewDiagnostics(summary: summary, findings: findings)
            retryAllowed = true
        case .draftValidationFailed(let findings):
            status = .blocked
            stage = .validation
            diagnostics = findings.map {
                ToolExecutionOutcome.Diagnostic(
                    code: "plugin_factory_draft_validation",
                    message: $0
                )
            }
            retryAllowed = true
        case .packageFailed:
            status = .failed
            stage = .compilation
            diagnostics = [diagnostic(for: error)]
            retryAllowed = false
        case .packagedRunFailed, .invalidPackagedOutput:
            status = .failed
            stage = .execution
            diagnostics = [diagnostic(for: error)]
            retryAllowed = false
        }
        return ToolExecutionOutcome.failure(
            status: status,
            stage: stage,
            diagnostics: diagnostics,
            retry: ToolExecutionOutcome.Retry(allowed: retryAllowed)
        )
    }

    private static func diagnostic(for error: PluginFactoryError) -> ToolExecutionOutcome.Diagnostic {
        ToolExecutionOutcome.Diagnostic(
            code: "plugin_factory_failed",
            message: error.localizedDescription
        )
    }

    private static func reviewDiagnostics(
        summary: String,
        findings: [String]
    ) -> [ToolExecutionOutcome.Diagnostic] {
        var diagnostics: [ToolExecutionOutcome.Diagnostic] = []
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            diagnostics.append(
                ToolExecutionOutcome.Diagnostic(
                    code: "plugin_factory_review_summary",
                    message: trimmedSummary
                )
            )
        }
        for finding in findings.prefix(12) {
            let trimmed = finding.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            diagnostics.append(
                ToolExecutionOutcome.Diagnostic(
                    code: "plugin_factory_review_finding",
                    message: trimmed
                )
            )
        }
        if diagnostics.isEmpty {
            diagnostics.append(
                ToolExecutionOutcome.Diagnostic(
                    code: "plugin_factory_failed",
                    message: "Plugin review rejected the draft."
                )
            )
        }
        return diagnostics
    }
}

private struct FactoryBuildSummary: Codable, Sendable {
    let ok = true
    let pluginID: String
    let version: String
    let contentHash: String
    let reviewSummary: String
    let secrets: [PluginSecretDescriptor]

    enum CodingKeys: String, CodingKey {
        case ok
        case pluginID = "plugin_id"
        case version
        case contentHash = "content_hash"
        case reviewSummary = "review_summary"
        case secrets
    }
}
