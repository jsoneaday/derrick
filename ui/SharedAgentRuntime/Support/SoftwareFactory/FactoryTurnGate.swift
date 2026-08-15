import Foundation
import MemorySystem
import ServiceContracts

extension FactoryTurnGate {
    static func nextRequiredStep(sessionID: String, records: [ToolCallRecord]) -> NextStep? {
        nextRequiredStep(sessionID: sessionID, records: records.map(Record.init(toolCall:)))
    }

    static func continuationPrompt(
        sessionID: String,
        originalPrompt: String,
        assistantToolRequest: String?,
        toolResultSummary: String?,
        records: [ToolCallRecord]
    ) -> String? {
        continuationPrompt(
            sessionID: sessionID,
            originalPrompt: originalPrompt,
            assistantToolRequest: assistantToolRequest,
            toolResultSummary: toolResultSummary,
            records: records.map(Record.init(toolCall:))
        )
    }
}

private extension FactoryTurnGate.Record {
    init(toolCall: ToolCallRecord) {
        self.init(name: toolCall.name, result: toolCall.result)
    }
}
