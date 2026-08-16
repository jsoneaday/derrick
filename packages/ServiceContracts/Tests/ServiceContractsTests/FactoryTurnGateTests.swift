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
        #expect(step?.instruction.contains("factory.write_package") == true)
        #expect(step?.instruction.contains("organizations") != true)
    }

    @Test func buildAskUserPausesPipeline() {
        let records = [
            FactoryTurnGate.Record(
                name: "factory.build",
                result: #"{"ok":false,"ask_user":true,"candidates":["daily-news","daily-news-summary"]}"#
            ),
        ]
        #expect(FactoryTurnGate.nextRequiredStep(sessionID: "factory-abc", records: records) == nil)
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

    @Test func writeReviewTestPromoteSequence() {
        let session = "factory-seq"
        var records = [
            FactoryTurnGate.Record(name: "factory.build", result: #"{"ok":true,"stage":"spec"}"#),
            FactoryTurnGate.Record(name: "factory.write_package", result: #"{"ok":true,"stage":"written"}"#),
        ]
        #expect(FactoryTurnGate.nextRequiredStep(sessionID: session, records: records)?.toolName == FactoryTurnGate.factoryReview)

        records.append(FactoryTurnGate.Record(name: "factory.review", result: #"{"ok":true,"stage":"reviewed"}"#))
        #expect(FactoryTurnGate.nextRequiredStep(sessionID: session, records: records)?.toolName == FactoryTurnGate.factoryTest)

        records.append(FactoryTurnGate.Record(name: "factory.test", result: #"{"ok":true,"stage":"tested"}"#))
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

    @Test func writeParamTypeFindingsRetryWrite() {
        let records = [
            FactoryTurnGate.Record(
                name: "factory.write_package",
                result: #"{"ok":false,"stage":"written","static_findings":["PluginParams cannot use an index signature"]}"#
            ),
        ]
        #expect(
            FactoryTurnGate.nextRequiredStep(sessionID: "factory-x", records: records)?.toolName
                == FactoryTurnGate.factoryWritePackage
        )
    }

    @Test func legacyHarnessRunNameStillCountsAsTest() {
        let records = [
            FactoryTurnGate.Record(name: "factory.review", result: #"{"ok":true,"stage":"reviewed"}"#),
            FactoryTurnGate.Record(name: "factory.harness_run", result: #"{"ok":true,"stage":"harnessed"}"#),
        ]
        #expect(
            FactoryTurnGate.nextRequiredStep(sessionID: "factory-x", records: records)?.toolName
                == FactoryTurnGate.factoryPromote
        )
        #expect(FactoryTurnGate.isPipelineTool("factory.harness_run"))
        #expect(FactoryTurnGate.isPipelineTool("factory.test"))
    }

    @Test func writeOtherFailureRetriesWrite() {
        let records = [
            FactoryTurnGate.Record(
                name: "factory.write_package",
                result: #"{"ok":false,"stage":"written","static_findings":["Guest fetch() is banned"]}"#
            ),
        ]
        #expect(
            FactoryTurnGate.nextRequiredStep(sessionID: "factory-x", records: records)?.toolName
                == FactoryTurnGate.factoryWritePackage
        )
    }

    @Test func userDeniedPromoteIsTerminal() {
        let records = [
            FactoryTurnGate.Record(name: "factory.promote", result: #"{"ok":false,"error":"User declined the install."}"#),
        ]
        #expect(FactoryTurnGate.nextRequiredStep(sessionID: "factory-x", records: records) == nil)
    }

    @Test func promoteTimeoutRetriesPromote() {
        let records = [
            FactoryTurnGate.Record(
                name: "factory.promote",
                result: #"{"ok":false,"error":"Install approval timed out. Call factory.promote again."}"#
            ),
        ]
        #expect(
            FactoryTurnGate.nextRequiredStep(sessionID: "factory-x", records: records)?.toolName
                == FactoryTurnGate.factoryPromote
        )
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
        #expect(prompt?.contains("Do not complete") == true)
        #expect(prompt?.contains("factory.write_package") == true)
        #expect(prompt?.contains("Set status to \"complete\"") != true)
        #expect(prompt?.contains("Produce the final user-facing response") != true)
    }

    @Test func stopMessageDoesNotDumpWriteSpec() {
        let records = [
            FactoryTurnGate.Record(
                name: "factory.write_package",
                result: #"{"ok":false,"stage":"written","static_findings":["PluginParams cannot use an index signature"]}"#
            ),
        ]
        let message = FactoryTurnGate.userFacingStopMessage(sessionID: "factory-x", records: records)
        #expect(message.contains("factory.write_package") != true)
        #expect(message.contains("PluginParams") != true)
        #expect(message.contains("did not finish") == true)
    }
}
