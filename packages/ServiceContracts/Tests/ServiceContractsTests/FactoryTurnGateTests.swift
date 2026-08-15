import Foundation
import Testing
@testable import ServiceContracts

@Suite struct FactoryTurnGateTests {
    @Test func factorySessionWithoutToolsRequiresBuild() {
        let step = FactoryTurnGate.nextRequiredStep(sessionID: "factory-1", records: [])
        #expect(step?.toolName == FactoryTurnGate.factoryBuild)
        #expect(FactoryTurnGate.nextRequiredStep(sessionID: "chat-1", records: []) == nil)
    }

    @Test func buildSuccessRequiresWrite() {
        let records = [
            FactoryTurnGate.Record(name: "factory.build", result: #"{"ok":true,"stage":"spec","goal":"news"}"#),
        ]
        let step = FactoryTurnGate.nextRequiredStep(sessionID: "factory-abc", records: records)
        #expect(step?.toolName == FactoryTurnGate.factoryWritePackage)
    }

    @Test func buildMissingGoalRetriesBuild() {
        let records = [
            FactoryTurnGate.Record(
                name: "factory.build",
                result: #"{"ok":false,"error":"goal is required. Pass the user's request as goal."}"#
            ),
        ]
        let step = FactoryTurnGate.nextRequiredStep(sessionID: "factory-abc", records: records)
        #expect(step?.toolName == FactoryTurnGate.factoryBuild)
        #expect(step?.instruction.contains("goal") == true)
    }

    @Test func writeReviewHarnessPromoteSequence() {
        let session = "factory-seq"
        var records = [
            FactoryTurnGate.Record(name: "factory.build", result: #"{"ok":true,"stage":"spec"}"#),
            FactoryTurnGate.Record(name: "factory.write_package", result: #"{"ok":true,"stage":"written"}"#),
        ]
        #expect(FactoryTurnGate.nextRequiredStep(sessionID: session, records: records)?.toolName == FactoryTurnGate.factoryReview)

        records.append(FactoryTurnGate.Record(name: "factory.review", result: #"{"ok":true,"stage":"reviewed"}"#))
        #expect(FactoryTurnGate.nextRequiredStep(sessionID: session, records: records)?.toolName == FactoryTurnGate.factoryHarnessRun)

        records.append(FactoryTurnGate.Record(name: "factory.harness_run", result: #"{"ok":true,"stage":"harnessed"}"#))
        #expect(FactoryTurnGate.nextRequiredStep(sessionID: session, records: records)?.toolName == FactoryTurnGate.factoryPromote)

        records.append(FactoryTurnGate.Record(name: "factory.promote", result: #"{"ok":true,"stage":"promoted"}"#))
        #expect(FactoryTurnGate.nextRequiredStep(sessionID: session, records: records) == nil)
    }

    @Test func reviewFailureReturnsToWrite() {
        let records = [
            FactoryTurnGate.Record(name: "factory.write_package", result: #"{"ok":true,"stage":"written"}"#),
            FactoryTurnGate.Record(name: "factory.review", result: #"{"ok":false,"stage":"written","summary":"sockets"}"#),
        ]
        #expect(
            FactoryTurnGate.nextRequiredStep(sessionID: "factory-x", records: records)?.toolName
                == FactoryTurnGate.factoryWritePackage
        )
    }

    @Test func userDeniedPromoteIsTerminal() {
        let records = [
            FactoryTurnGate.Record(name: "factory.promote", result: #"{"ok":false,"error":"User did not approve install."}"#),
        ]
        #expect(FactoryTurnGate.nextRequiredStep(sessionID: "factory-x", records: records) == nil)
    }

    @Test func toolSearchDoesNotAdvanceStage() {
        let records = [
            FactoryTurnGate.Record(name: "tool_search", result: #"{"ok":false}"#),
        ]
        #expect(
            FactoryTurnGate.nextRequiredStep(sessionID: "factory-x", records: records)?.toolName
                == FactoryTurnGate.factoryBuild
        )
        #expect(FactoryTurnGate.isHostDiscoveryTool("tool_search"))
        #expect(FactoryTurnGate.isHostDiscoveryTool("tool"))
        #expect(FactoryTurnGate.isHostDiscoveryTool("tool_batch"))
        #expect(!FactoryTurnGate.isHostDiscoveryTool("factory.build"))
    }

    @Test func continuationPromptForbidsCompleteAndDoesNotAskForFinalAnswer() {
        let prompt = FactoryTurnGate.continuationPrompt(
            sessionID: "factory-x",
            originalPrompt: "create a news plugin",
            assistantToolRequest: "factory.build (goal=create a news plugin)",
            toolResultSummary: #"{"ok":true,"stage":"spec"}"#,
            records: [FactoryTurnGate.Record(name: "factory.build", result: #"{"ok":true,"stage":"spec"}"#)]
        )
        #expect(prompt?.contains("Do not set status to complete") == true)
        #expect(prompt?.contains("factory.write_package") == true)
        #expect(prompt?.contains("Set status to \"complete\"") != true)
        #expect(prompt?.contains("Produce the final user-facing response") != true)
    }
}
