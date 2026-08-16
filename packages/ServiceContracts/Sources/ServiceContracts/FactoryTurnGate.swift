import Foundation

/// Host-owned Software Factory pipeline. A factory session is not finished until
/// promote (or sample install) has run; the model must not `complete` earlier.
public enum FactoryTurnGate {
    public struct Record: Equatable, Sendable {
        public var name: String
        public var result: String?

        public init(name: String, result: String? = nil) {
            self.name = name
            self.result = result
        }
    }

    public struct NextStep: Equatable, Sendable {
        public var toolName: String
        public var instruction: String

        public init(toolName: String, instruction: String) {
            self.toolName = toolName
            self.instruction = instruction
        }
    }

    private struct ToolPayload: Decodable {
        var ok: Bool?
        var stage: String?
        var error: String?
        var next: String?
        var askUser: Bool?
        var staticFindings: [String]?

        enum CodingKeys: String, CodingKey {
            case ok, stage, error, next
            case askUser = "ask_user"
            case staticFindings = "static_findings"
        }
    }

    public static let factoryBuild = "factory.build"
    public static let factoryWritePackage = "factory.write_package"
    public static let factoryReview = "factory.review"
    public static let factoryTest = "factory.test"
    /// Previous wire name. Still a pipeline test step if it appears in an older transcript.
    public static let factoryHarnessRun = "factory.harness_run"
    public static let factoryPromote = "factory.promote"
    public static let factoryInstallSample = "factory.install_sample"

    public static func isHostDiscoveryTool(_ name: String) -> Bool {
        name == "tool_search" || name == "tool" || name == "tool_batch"
    }

    public static func isPipelineTool(_ name: String) -> Bool {
        switch name {
        case factoryBuild, factoryWritePackage, factoryReview, factoryTest, factoryHarnessRun, factoryPromote, factoryInstallSample:
            return true
        default:
            return false
        }
    }

    public static func nextRequiredStep(sessionID: String, records: [Record]) -> NextStep? {
        guard FactorySessionID.isFactorySession(sessionID) else { return nil }

        let last = records.last { isPipelineTool($0.name) }
        guard let last else {
            return NextStep(
                toolName: factoryBuild,
                instruction: "Call factory.build with goal set to the user's request."
            )
        }

        let payload = decodePayload(last.result)

        switch last.name {
        case factoryPromote, factoryInstallSample:
            if payload.ok == true || payload.stage == "promoted" {
                return nil
            }
            if (payload.error ?? "").localizedCaseInsensitiveContains("declined") {
                return nil
            }
            if (payload.error ?? "").localizedCaseInsensitiveContains("timed out") {
                return NextStep(
                    toolName: factoryPromote,
                    instruction: "The update card timed out. Call factory.promote again so the user can approve."
                )
            }
            if payload.ok == false {
                return retryAfterFailure(toolName: last.name, payload: payload)
            }
            return nil

        case factoryBuild:
            if payload.askUser == true {
                return nil
            }
            if payload.ok == false {
                return NextStep(
                    toolName: factoryBuild,
                    instruction: "Call factory.build again. \(payload.error ?? "goal is required")"
                )
            }
            return writeStep

        case factoryWritePackage:
            if payload.ok == false {
                let findings = (payload.staticFindings ?? []).joined(separator: "; ")
                if findings.isEmpty { return writeStep }
                return NextStep(
                    toolName: factoryWritePackage,
                    instruction: "Call factory.write_package again. \(findings)"
                )
            }
            return reviewStep

        case factoryReview:
            return payload.ok == false ? writeStep : testStep

        case factoryTest, factoryHarnessRun:
            return payload.ok == false ? writeStep : promoteStep

        default:
            return writeStep
        }
    }

    public static func continuationPrompt(
        sessionID: String,
        originalPrompt: String,
        assistantToolRequest: String?,
        toolResultSummary: String?,
        records: [Record]
    ) -> String? {
        guard let next = nextRequiredStep(sessionID: sessionID, records: records) else {
            return nil
        }
        var sections: [String] = [
            "Original user prompt:",
            originalPrompt,
        ]
        if let assistantToolRequest, !assistantToolRequest.isEmpty {
            sections.append("You requested the following tool call:\n\(assistantToolRequest)")
        }
        if let toolResultSummary, !toolResultSummary.isEmpty {
            sections.append("Tool execution result:\n\(toolResultSummary)")
        }
        sections.append(
            """
            Factory is not finished. Do not complete. Next tool: \(next.toolName). \(next.instruction)
            """
        )
        return sections.joined(separator: "\n\n")
    }

    /// Factory is a host pipeline, not a chat tool budget. Chat's cap of 3–10 would stop install.
    public static let pipelineToolRounds = 32

    /// Shown to the user when the factory turn hits the tool-round cap. Not a tool spec.
    public static func userFacingStopMessage(sessionID: String, records: [Record]) -> String {
        if isFactorySessionNeedsWork(sessionID: sessionID, records: records) {
            return "The plugin change did not finish. Send the same request again."
        }
        return "Stopped: max tool rounds reached. Raise the session limit when prompted, or change Settings → Usage limits."
    }

    private static func isFactorySessionNeedsWork(sessionID: String, records: [Record]) -> Bool {
        nextRequiredStep(sessionID: sessionID, records: records) != nil
            || FactorySessionID.isFactorySession(sessionID)
    }

    private static var writeStep: NextStep {
        NextStep(
            toolName: factoryWritePackage,
            instruction: "Call factory.write_package with plugin_id, description, and handle."
        )
    }

    private static var reviewStep: NextStep {
        NextStep(
            toolName: factoryReview,
            instruction: "Call factory.review (no arguments)."
        )
    }

    private static var testStep: NextStep {
        NextStep(
            toolName: factoryTest,
            instruction: "Call factory.test."
        )
    }

    private static var promoteStep: NextStep {
        NextStep(
            toolName: factoryPromote,
            instruction: "Call factory.promote."
        )
    }

    private static func retryAfterFailure(toolName: String, payload: ToolPayload) -> NextStep? {
        let error = payload.error ?? "failed"
        if error.localizedCaseInsensitiveContains("write a package") {
            return writeStep
        }
        if error.localizedCaseInsensitiveContains("review must pass") {
            return reviewStep
        }
        if error.localizedCaseInsensitiveContains("harness_run must pass")
            || error.localizedCaseInsensitiveContains("test must pass") {
            return testStep
        }
        return NextStep(
            toolName: toolName,
            instruction: "The last call failed: \(error). Fix the arguments and call \(toolName) again."
        )
    }

    private static func decodePayload(_ raw: String?) -> ToolPayload {
        guard let raw, let brace = raw.firstIndex(of: "{") else {
            return ToolPayload()
        }
        let json = String(raw[brace...])
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ToolPayload.self, from: data) else {
            return ToolPayload()
        }
        return decoded
    }
}
